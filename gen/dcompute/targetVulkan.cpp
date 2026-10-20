//===-- gen/dcompute/targetVulkan.cpp -----------------------------------------===//
//
//                         LDC – the LLVM D compiler
//
// Parts of this file are adapted from CodeGenFunction.cpp (Clang, LLVM).
// Therefore, this file is distributed under the LLVM license.
// See the LICENSE file for details.
//===----------------------------------------------------------------------===//

#include "llvm/Config/llvm-config.h"

#if LDC_LLVM_SUPPORTED_TARGET_SPIRV && LLVM_VERSION_MAJOR >= 23
#include "dmd/id.h"
#include "dmd/identifier.h"
#include "dmd/template.h"
#include "dmd/mangle.h"
#include "dmd/module.h"
#include "gen/abi/targets.h"
#include "gen/dcompute/target.h"
#include "gen/dcompute/druntime.h"
#include "gen/dcompute/shaderinterface.h"
#include "gen/logger.h"
#include "gen/optimizer.h"
#include "gen/uda.h"
#include "dmd/errors.h"
#include "driver/targetmachine.h"
#include "llvm/Transforms/Scalar.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/IR/IntrinsicsSPIRV.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringExtras.h"
#include "dmd/mtype.h"
#include "dmd/aggregate.h"
#include "gen/tollvm.h"
#include "ir/irtype.h"
#include "ir/irtypeaggr.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SCCIterator.h"
#include "llvm/Analysis/CallGraph.h"
#include <cstring>
#include <map>
#include <tuple>
#include <string>

using namespace dmd;

namespace {
class TargetVulkan : public DComputeTarget {
public:
  TargetVulkan(llvm::LLVMContext &c, int ver)
      : DComputeTarget(c, ver, ID::Vulkan, "vulkan", "spv", createSPIRVVulkanABI(),
                       // dcompute's Shared is workgroup memory (addrspace 3 in the
                       // SPIR-V backend) and Constant is UniformConstant (2).
                       {{0, 1, 3, 2, 4}}) {

    _ir = new IRState("dcomputeTargetVulkan", ctx);
    // "spirv-vulkan-foo"? foo = library, pixel, etc
    std::string targTriple = "spirv1.6-unknown-vulkan1.3-compute";
    _ir->module.setTargetTriple(llvm::Triple(targTriple));

    // No arch name: an explicit one replaces the triple's, and with it the
    // `1.6` sub-architecture that selects the SPIR-V version; the backend
    // would emit 1.4.
    auto floatABI = ::FloatABI::Hard;
    targetMachine = createTargetMachine(
            targTriple, "", "", {},
            ExplicitBitness::None, floatABI,
            llvm::Reloc::Static, llvm::CodeModel::Medium, llvm::CodeGenOptLevel::None, false);

    _ir->module.setDataLayout(targetMachine->createDataLayout());
     
    _ir->dcomputetarget = this;

    // D's plain integers are signed, and a shader's `int` must reach GLSL as
    // `int`: ask the SPIR-V backend for signed integer types, since LLVM's
    // integers carry no sign of their own.
    _ir->module.addModuleFlag(llvm::Module::Error, "spirv.signed-integers", 1);
    // dcompute's global pointers are the addresses a host hands a kernel
    // in its argument buffer: buffer device addresses (PhysicalStorageBuffer).
    _ir->module.addModuleFlag(llvm::Module::Error,
                              "spirv.physical-storage-buffer", 1);
    // A uniform block is its struct, with no struct wrapping it (`D25`).
    _ir->module.addModuleFlag(llvm::Module::Error, "spirv.struct-blocks", 1);
  }

  // A shader has no call stack: SPIR-V for Vulkan forbids recursion, and a
  // translator meets it as an endless inlining. Every cycle in the call graph
  // is an error at its first function, naming the functions on it.
  void rejectRecursion() {
    llvm::CallGraph graph(_ir->module);
    for (auto scc = llvm::scc_begin(&graph); !scc.isAtEnd(); ++scc) {
      if (!scc.hasCycle())
        continue;
      FuncDeclaration *first = nullptr;
      std::string names;
      for (llvm::CallGraphNode *node : *scc) {
        auto it = definitions.find(node->getFunction());
        if (it == definitions.end())
          continue;
        if (!first)
          first = it->second;
        if (!names.empty())
          names += "`, `";
        names += it->second->toPrettyChars();
      }
      error(first ? first->loc : Loc(), "device code may not recurse: `%s` %s",
            names.c_str(),
            scc->size() == 1 ? "calls itself" : "call each other");
    }
    if (global.errors)
      fatal();
  }

  void addMetadata() override {
    rejectRecursion();
    // Vulkan SPIR-V has no linkage: every function but the entry points must
    // be internal, or the module needs the `Linkage` capability and fails
    // validation. Entry points carry `hlsl.shader`; everything else that has a
    // body is a helper the entry points call.
    for (auto &f : _ir->module.functions()) {
      if (f.isDeclaration() || f.hasFnAttribute("hlsl.shader"))
        continue;
      f.setLinkage(llvm::GlobalValue::InternalLinkage);
      // And every helper folds into its entry point, as a GLSL compiler
      // would: a shader has no recursion, and a resource handle can only be
      // consumed in the function that obtained it -- it cannot be passed as
      // a function argument -- so a call boundary is never allowed to stand
      // between a `Sampler2D` parameter and the sample that reads it.
      f.removeFnAttr(llvm::Attribute::NoInline);
      f.addFnAttr(llvm::Attribute::AlwaysInline);
    }
  }

  llvm::AttrBuilder buildKernAttrs(StructLiteralExp *kernAttr) {
    auto b = llvm::AttrBuilder(ctx);
    b.addAttribute("hlsl.shader", "compute");
    Expressions* elts = static_cast<ArrayLiteralExp*>((*(kernAttr->elements))[0])->elements;
    std::string numthreads = "";
    numthreads += std::to_string(toInteger((*elts)[0])) + ",";
    numthreads += std::to_string(toInteger((*elts)[1])) + ",";
    numthreads += std::to_string(toInteger((*elts)[2]));

    b.addAttribute("hlsl.numthreads", numthreads);
    //  ?  "hlsl.wavesize"="8,128,64"
    //  ?  "hlsl.export"
    return b;
  }
  llvm::Function *buildFunction(FuncDeclaration *fd) {
    auto *void_func_void = llvm::FunctionType::get(llvm::Type::getVoidTy(ctx),{}, false);
    auto linkage = llvm::GlobalValue::LinkageTypes::ExternalLinkage;
    auto name = llvm::Twine(mangleExact(fd)) + llvm::Twine("_kernel");
    auto *f = llvm::Function::Create(void_func_void, linkage, name, _ir->module);
    // f->setCallingConv(llvm::CallingConv::SPIR_KERNEL);
    return f;
  }
  llvm::Type *buildArgType(llvm::Function *llf, llvm::SmallVector<llvm::Type *, 8> &args, llvm::StringRef name) {
    IF_LOG {
      Logger::cout() << "buildArgType: " << *llf << std::endl;
    }
    llvm::FunctionType *tf = llf->getFunctionType();
    for (unsigned int i = 0; i < tf->getNumParams(); i++) {
      llvm::Type *t = tf->getParamType(i);
      if (t->isPointerTy()){
        unsigned ptrSize = _ir->module.getDataLayout().getPointerSizeInBits();
        t = (ptrSize == 32)?getI32Type():getI64Type();
      }
      args[i] = t;
    }

    IF_LOG {
      for (auto *arg : args) {
        Logger::cout() << *arg;
      }
    }
    return llvm::StructType::create(ctx, args, name);
  }
  llvm::TargetExtType *buildTargetType(llvm::Type *argType) {
    return llvm::TargetExtType::get(ctx, "spirv.VulkanBuffer",
                                    {argType},
                                    {12/*StorageClass*/, 0 /*isWritable*/});
  }

  llvm::Value *buildIntrinsicCall(llvm::IRBuilder<> &builder, llvm::StringRef dbg, llvm::StringRef name,
                                  llvm::ArrayRef<llvm::Type *> types, llvm::ArrayRef<llvm::Value *> args) {
    IF_LOG {
      Logger::println("buildIntrinsicCall: %s", name.data());
    }
    LOG_SCOPE
    auto intrinsic = llvm::Intrinsic::getOrInsertDeclaration(&_ir->module,
                                                             llvm::Intrinsic::lookupIntrinsicID(name),
                                                             types);
    IF_LOG {
      Logger::cout() << "intrinsic = " << *intrinsic << std::endl;
      Logger::println("args:");
      LOG_SCOPE
      for (auto* arg : args) {
        Logger::cout() << *arg << std::endl;
      }
    }
    
    return builder.CreateCall(intrinsic, args, dbg);
  }

  void addKernelMetadata(FuncDeclaration *fd, llvm::Function *llf, StructLiteralExp *kernAttr) override {
    // Fake being HLSL
    llvm::Function *f = buildFunction(fd);
    f->addFnAttrs(buildKernAttrs(kernAttr));
    llf->setLinkage(llvm::GlobalValue::InternalLinkage);

    llvm::SmallVector<llvm::Type *, 8> argTypes(llf->getFunctionType()->getNumParams());
    auto name = llvm::Twine(mangleExact(fd)) + llvm::Twine("_args");
    auto *argType = buildArgType(llf, argTypes, name.str());
    llvm::Type *targetType = buildTargetType(argType);
  
    auto bb = llvm::BasicBlock::Create(ctx, "", f);
    llvm::IRBuilder<> builder(ctx);
    builder.SetInsertPoint(bb);

    llvm::Value *i32zero = llvm::ConstantInt::get(getI32Type(), 0, false);
    llvm::Value *i32one  = llvm::ConstantInt::get(getI32Type(), 1, false);
    llvm::Value *i1false = llvm::ConstantInt::get(llvm::Type::getInt1Ty(ctx),  0, false);
    
    // We can't use `DtoConstCString` here because it ends up in the wrong address space, So we use
    // `getCachedStringLiteral` directly with an explicitly supplied addrspace of `0`.
    // FIXME: call should have `notnull` attribute on pointer?
    auto *handle = buildIntrinsicCall(builder, "handle","llvm.spv.resource.handlefrombinding",
                                      {targetType},
                                      {i32zero, i32zero, i32one, i32zero, _ir->getCachedStringLiteral(name.str(), 0) });
    llvm::FunctionType *tf = llf->getFunctionType();
    auto *p11 = llvm::PointerType::get(ctx, 11);
    LOG_SCOPE
    llvm::SmallVector<llvm::Value *, 8> args(tf->getNumParams());

    for (unsigned int i = 0; i < tf->getNumParams(); i++) {
      llvm::Value *index = llvm::ConstantInt::get(getI32Type(), i, false);
      llvm::Value *gep = buildIntrinsicCall(builder, "pointer", "llvm.spv.resource.getpointer",
                                         {p11, targetType, index->getType()}, {handle, index});
      llvm::Type *fieldTy = argType->getStructElementType(i);
      
      args[i] = builder.CreateAlignedLoad(fieldTy, gep, _ir->module.getDataLayout().getABITypeAlign(fieldTy), false);
      
      llvm::Type *t = tf->getParamType(i);
      if (t->isPointerTy()) {
        args[i] = builder.CreateIntToPtr(args[i],t);
        if (fd->parameters && i < fd->parameters->length) {
          VarDeclaration *vd = (*fd->parameters)[i];
          Type *dty = vd->type->toBasetype();
          std::optional<DcomputePointer> p;
          if (dty->ty == TY::Tstruct && (p = toDcomputePointer(static_cast<TypeStruct*>(dty)->sym))) {
            llvm::Type *elemTy = DtoType(p->type);
            int realAS = _ir->dcomputetarget->mapping[p->addrspace];
            llvm::Value *ofType = llvm::PoisonValue::get(elemTy);
            llvm::Metadata *md = llvm::ValueAsMetadata::get(ofType);
            llvm::Value *mdVal = llvm::MetadataAsValue::get(ctx, md);
            auto assignFn = llvm::Intrinsic::getOrInsertDeclaration(
                &_ir->module, llvm::Intrinsic::spv_assign_ptr_type, {t});
            builder.CreateCall(assignFn,
                               {args[i], mdVal, llvm::ConstantInt::get(llvm::Type::getInt32Ty(ctx), realAS)});
          }
        }
      }
    }

    auto *kernelCall = builder.CreateCall(llf->getFunctionType(), llf, args);
    kernelCall->setCallingConv(llf->getCallingConv());
    builder.CreateRetVoid();
    IF_LOG Logger::cout() << *f << std::endl;
  }

  // ---- graphics stages ----------------------------------------------------
  //
  // Which functions are entry points, their profiles and their interface --
  // every variable with its location, binding or built-in -- are decided and
  // checked during semantic analysis (gen/dcompute/shaderinterface.d); here
  // the description is emitted.

  /// Attaches a `spirv.Decorations` node carrying one decoration.
  void decorate(llvm::GlobalVariable *gv, unsigned decoration, unsigned value) {
    auto *i32 = getI32Type();
    llvm::Metadata *pair[] = {
        llvm::ConstantAsMetadata::get(llvm::ConstantInt::get(i32, decoration)),
        llvm::ConstantAsMetadata::get(llvm::ConstantInt::get(i32, value))};
    gv->addMetadata("spirv.Decorations",
                    *llvm::MDNode::get(ctx, {llvm::MDNode::get(ctx, pair)}));
  }

  /// The LLVM name of a stage's interface variable, qualified by its stage
  /// and direction: entry points of every stage share one module, where a
  /// vertex output shares its name with the fragment input it feeds, and a
  /// push-constant block or a uniform may have an input's name. The variable
  /// carries its own name in `spirv.Name`.
  static std::string interfaceGlobalName(ShaderStage stage, llvm::StringRef name,
                                         bool output) {
    const char *qualifier = stage == ShaderStage::fragment ? ".fragment" : ".vertex";
    return (name + qualifier + (output ? ".out" : ".in")).str();
  }

  /// An interface variable (`Input`/`Output` storage class): thread-local,
  /// externally initialised, no initializer -- the shape the HLSL frontend
  /// emits, which the backend recognises as needing no Linkage capability.
  /// Entry points of one stage naming the same variable share it; semantic
  /// analysis has checked that they agree on it.
  llvm::GlobalVariable *buildInterfaceVariable(llvm::Type *ty, bool output,
                                               llvm::StringRef name,
                                               llvm::StringRef llvmName,
                                               unsigned decoration,
                                               unsigned value) {
    if (auto *existing = _ir->module.getGlobalVariable(llvmName, true))
      return existing;
    auto *gv = new llvm::GlobalVariable(
        _ir->module, ty, /*isConstant=*/!output,
        llvm::GlobalValue::ExternalLinkage, nullptr, llvmName, nullptr,
        llvm::GlobalValue::GeneralDynamicTLSModel, output ? 8 : 7,
        /*isExternallyInitialized=*/!output || decoration == 30);
    gv->setVisibility(llvm::GlobalValue::HiddenVisibility);
    decorate(gv, decoration, value);
    if (llvmName != name)
      gv->addMetadata("spirv.Name",
                      *llvm::MDNode::get(ctx, {llvm::MDString::get(ctx, name)}));
    return gv;
  }

  llvm::GlobalVariable *locationVariable(llvm::Type *ty, bool output,
                                         ShaderStage stage, const char *name,
                                         unsigned location) {
    return buildInterfaceVariable(ty, output, name,
                                  interfaceGlobalName(stage, name, output),
                                  /*Location*/ 30, location);
  }

  llvm::GlobalVariable *builtinVariable(llvm::Type *ty, bool output,
                                        const char *name, unsigned builtin) {
    return buildInterfaceVariable(ty, output, name,
                                  std::string("builtin.") + name,
                                  /*BuiltIn*/ 11, builtin);
  }

  /// A plain (non-block) uniform: `UniformConstant` storage, no initializer.
  llvm::GlobalVariable *buildUniform(llvm::Type *ty, llvm::StringRef name) {
    if (auto *existing = _ir->module.getGlobalVariable(name, true))
      return existing;
    auto *gv = new llvm::GlobalVariable(
        _ir->module, ty, /*isConstant=*/false, llvm::GlobalValue::ExternalLinkage,
        llvm::PoisonValue::get(ty), name, nullptr,
        llvm::GlobalValue::NotThreadLocal, /*UniformConstant*/ 2);
    gv->setVisibility(llvm::GlobalValue::HiddenVisibility);
    return gv;
  }

  // ---- uniform types --------------------------------------------------------
  //
  // The host binds a uniform struct's members by name, and LLVM struct members
  // have none, so a uniform struct's SPIR-V type is its own: the fields'
  // interface types in declaration order, without the padding or overlap the D
  // struct's LLVM type may carry, and named by `spirv.MemberNames`.
  // `fromInterface` converts a loaded value back to the D type. (Integers are
  // signed module-wide, by the `spirv.signed-integers` flag.)

  llvm::DenseMap<StructDeclaration *, llvm::StructType *> interfaceStructs;

  /// The SPIR-V-facing type of an interface variable of D type `t`.
  llvm::Type *interfaceType(Type *t) {
    t = t->toBasetype();
    switch (t->ty) {
    case TY::Tsarray:
      return llvm::ArrayType::get(
          interfaceType(t->nextOf()),
          toInteger(static_cast<TypeSArray *>(t)->dim));
    case TY::Tstruct:
      return interfaceStruct(static_cast<TypeStruct *>(t)->sym);
    default:
      return DtoType(t);
    }
  }

  /// A struct of the fields' interface types, in declaration order, named
  /// after the D struct and with its members named after the fields.
  llvm::StructType *interfaceStruct(StructDeclaration *sd) {
    if (auto *known = interfaceStructs.lookup(sd))
      return known;
    llvm::SmallVector<llvm::Type *, 8> fields;
    llvm::SmallVector<llvm::Metadata *, 8> names;
    for (VarDeclaration *field : sd->fields)
      fields.push_back(interfaceType(field->type));
    auto *st = llvm::StructType::create(ctx, fields, sd->ident->toChars());
    names.push_back(llvm::ConstantAsMetadata::get(llvm::PoisonValue::get(st)));
    for (VarDeclaration *field : sd->fields)
      names.push_back(llvm::MDString::get(ctx, field->ident->toChars()));
    _ir->module.getOrInsertNamedMetadata("spirv.MemberNames")
        ->addOperand(llvm::MDNode::get(ctx, names));
    interfaceStructs[sd] = st;
    return st;
  }

  /// `v`, loaded from an interface variable of D type `t`, as `t`'s value.
  llvm::Value *fromInterface(llvm::IRBuilder<> &builder, llvm::Value *v,
                             Type *t) {
    t = t->toBasetype();
    llvm::Type *dty = DtoType(t);
    if (v->getType() == dty)
      return v;
    switch (t->ty) {
    case TY::Tsarray: {
      llvm::Value *r = llvm::Constant::getNullValue(dty);
      const auto n = toInteger(static_cast<TypeSArray *>(t)->dim);
      for (unsigned i = 0; i < n; i++)
        r = builder.CreateInsertValue(
            r, fromInterface(builder, builder.CreateExtractValue(v, i),
                             t->nextOf()),
            i);
      return r;
    }
    case TY::Tstruct: {
      StructDeclaration *sd = static_cast<TypeStruct *>(t)->sym;
      auto *aggr = getIrType(t)->isAggr();
      llvm::Value *r = llvm::Constant::getNullValue(dty);
      for (unsigned i = 0; i < sd->fields.length; i++) {
        VarDeclaration *field = sd->fields[i];
        r = builder.CreateInsertValue(
            r, fromInterface(builder, builder.CreateExtractValue(v, i),
                             field->type),
            memberIndex(aggr, sd, field));
      }
      return r;
    }
    default:
      llvm_unreachable("an interface type that needs no conversion");
    }
  }

  /// `field`'s index in `sd`'s LLVM type; an overlapping field has none.
  static unsigned memberIndex(IrTypeAggr *aggr, StructDeclaration *sd,
                              VarDeclaration *field) {
    bool isFieldIdx;
    const unsigned index = aggr->getMemberLocation(field, isFieldIdx);
    if (!isFieldIdx) {
      error(field->loc, "shader struct `%s` has overlapping field `%s`",
            sd->toChars(), field->toChars());
      fatal();
    }
    return index;
  }

  /// The argument a parameter of IR type `pt` receives for `value`: the value
  /// itself, or, for an aggregate the ABI passes by reference, a copy of it.
  llvm::Value *asArgument(llvm::IRBuilder<> &builder, llvm::Value *value,
                          llvm::Type *pt) {
    if (!pt->isPointerTy() || value->getType()->isPointerTy())
      return value;
    auto *slot = builder.CreateAlloca(value->getType());
    builder.CreateStore(value, slot);
    return slot;
  }

  /// `llvm.spv.resource.handlefrombinding` for one descriptor.
  llvm::Value *buildResourceHandle(llvm::IRBuilder<> &builder, llvm::Type *handleTy,
                                   unsigned binding, const std::string &name) {
    auto *i32 = getI32Type();
    return buildIntrinsicCall(
        builder, name, "llvm.spv.resource.handlefrombinding", {handleTy},
        {llvm::ConstantInt::get(i32, 0), llvm::ConstantInt::get(i32, binding),
         llvm::ConstantInt::get(i32, 1), llvm::ConstantInt::get(i32, 0),
         _ir->getCachedStringLiteral(name, 0)});
  }

  llvm::Value *buildSharedSamplerHandle(Loc) override {
    llvm::IRBuilder<> &builder = *(_ir->ir.operator->());
    auto *samplerTy = llvm::TargetExtType::get(ctx, "spirv.Sampler");
    return buildResourceHandle(builder, samplerTy, /*binding=*/0, "sampler");
  }

  // ---- blocks ---------------------------------------------------------------
  //
  // A block's LLVM type is a packed struct whose members sit at the offsets
  // std140 (uniform blocks) or std430 (push constants) give them, as
  // gen/dcompute/shaderinterface.d computes them: a spirv.Padding member
  // fills each gap, and an array whose stride exceeds its element is peeled,
  // {[N-1 x <{T, spirv.Padding}>], T}. The SPIR-V backend keeps neither
  // padding as a member; it decorates the offsets and strides. A block is
  // read leaf by leaf through access chains, never as a padded aggregate.

  struct BlockStruct {
    llvm::StructType *type = nullptr;
    llvm::SmallVector<unsigned, 8> members; // a D field's LLVM member index
  };
  // By struct, layout rule, and whether it is a block's own type (decorated
  // `Block`) or a member of one: SPIR-V does not let one block nest in
  // another, so a struct used both ways is two types.
  std::map<std::tuple<StructDeclaration *, int, bool>, BlockStruct> blockStructs;

  llvm::Type *paddingType(unsigned bytes) {
    return llvm::TargetExtType::get(ctx, "spirv.Padding", {}, {bytes});
  }

  /// A packed struct of `types` at `offsets`, `size` bytes long, named
  /// `name` with members named `memberNames`.
  BlockStruct buildBlockStruct(llvm::ArrayRef<Type *> types,
                               llvm::ArrayRef<unsigned> offsets, unsigned size,
                               llvm::StringRef name,
                               llvm::ArrayRef<const char *> memberNames,
                               int rule, Loc loc) {
    const auto &dl = _ir->module.getDataLayout();
    BlockStruct b;
    llvm::SmallVector<llvm::Type *, 16> members;
    uint64_t at = 0;
    for (size_t k = 0; k < types.size(); k++) {
      if (offsets[k] < at) {
        error(loc, "cannot lay out block `%s`: member `%s` would overlap its "
                   "predecessor",
              name.str().c_str(), memberNames[k]);
        fatal();
      }
      if (offsets[k] > at)
        members.push_back(paddingType(offsets[k] - at));
      b.members.push_back(members.size());
      llvm::Type *t = blockMemberType(types[k], rule, loc);
      members.push_back(t);
      at = offsets[k] + dl.getTypeAllocSize(t);
    }
    if (size > at)
      members.push_back(paddingType(size - at));
    // LLVM names a type uniquely, and a struct may be two types (a block, and
    // a member of another); `spirv.TypeNames` gives both the D name.
    b.type = llvm::StructType::create(ctx, members, name, /*isPacked=*/true);
    auto *key = llvm::ConstantAsMetadata::get(llvm::PoisonValue::get(b.type));
    _ir->module.getOrInsertNamedMetadata("spirv.TypeNames")
        ->addOperand(llvm::MDNode::get(ctx, {key, llvm::MDString::get(ctx, name)}));
    llvm::SmallVector<llvm::Metadata *, 16> names;
    names.push_back(key);
    for (const char *n : memberNames)
      names.push_back(llvm::MDString::get(ctx, n));
    _ir->module.getOrInsertNamedMetadata("spirv.MemberNames")
        ->addOperand(llvm::MDNode::get(ctx, names));
    return b;
  }

  const BlockStruct &blockStruct(StructDeclaration *sd, int rule, Loc loc,
                                 bool root = false) {
    auto key = std::make_tuple(sd, rule, root);
    auto it = blockStructs.find(key);
    if (it != blockStructs.end())
      return it->second;
    llvm::SmallVector<Type *, 8> types;
    llvm::SmallVector<unsigned, 8> offsets;
    llvm::SmallVector<const char *, 8> names;
    for (size_t k = 0; k < sd->fields.length; k++) {
      types.push_back(sd->fields[k]->type->toBasetype());
      offsets.push_back(shaderBlockFieldOffset(sd, k, rule));
      names.push_back(sd->fields[k]->ident->toChars());
    }
    return blockStructs[key] =
               buildBlockStruct(types, offsets, shaderBlockSize(sd->type, rule),
                                sd->ident->toChars(), names, rule, loc);
  }

  /// The LLVM type of a block member of D type `t`.
  llvm::Type *blockMemberType(Type *t, int rule, Loc loc) {
    t = t->toBasetype();
    if (t->ty == TY::Tstruct)
      return blockStruct(static_cast<TypeStruct *>(t)->sym, rule, loc).type;
    if (t->ty == TY::Tsarray) {
      Type *et = t->nextOf()->toBasetype();
      const auto n = toInteger(static_cast<TypeSArray *>(t)->dim);
      llvm::Type *e = blockMemberType(et, rule, loc);
      const unsigned stride = shaderBlockArrayStride(et, rule);
      const uint64_t size = _ir->module.getDataLayout().getTypeAllocSize(e);
      if (stride == size)
        return llvm::ArrayType::get(e, n);
      auto *padded = llvm::StructType::get(ctx, {e, paddingType(stride - size)},
                                           /*isPacked=*/true);
      return llvm::StructType::get(
          ctx, {llvm::ArrayType::get(padded, n - 1), e}, /*isPacked=*/true);
    }
    return DtoType(t);
  }

  /// The D value of type `t` a block holds at `ptr`.
  llvm::Value *loadBlockValue(llvm::IRBuilder<> &builder, llvm::Value *ptr,
                              Type *t, int rule, Loc loc) {
    t = t->toBasetype();
    llvm::Type *dty = DtoType(t);
    if (t->ty == TY::Tstruct) {
      StructDeclaration *sd = static_cast<TypeStruct *>(t)->sym;
      const BlockStruct &b = blockStruct(sd, rule, loc);
      auto *aggr = getIrType(t)->isAggr();
      llvm::Value *r = llvm::UndefValue::get(dty);
      for (size_t k = 0; k < sd->fields.length; k++) {
        llvm::Value *p = builder.CreateInBoundsGEP(
            b.type, ptr, {builder.getInt32(0), builder.getInt32(b.members[k])});
        r = builder.CreateInsertValue(
            r, loadBlockValue(builder, p, sd->fields[k]->type, rule, loc),
            memberIndex(aggr, sd, sd->fields[k]));
      }
      return r;
    }
    if (t->ty == TY::Tsarray) {
      Type *et = t->nextOf()->toBasetype();
      const auto n = toInteger(static_cast<TypeSArray *>(t)->dim);
      llvm::Type *arrayTy = blockMemberType(t, rule, loc);
      llvm::Value *r = llvm::UndefValue::get(dty);
      for (unsigned k = 0; k < n; k++) {
        // A peeled array is indexed by its padded element, which the
        // backend reads as the array's element.
        // Element 0 is the array's own address, which the backend reads as
        // its first element.
        llvm::Value *p =
            arrayTy->isArrayTy()
                ? builder.CreateInBoundsGEP(arrayTy, ptr,
                                            {builder.getInt32(0), builder.getInt32(k)})
            : k == 0
                ? ptr
                : builder.CreateInBoundsGEP(
                      llvm::cast<llvm::ArrayType>(arrayTy->getStructElementType(0))
                          ->getElementType(),
                      ptr, {builder.getInt32(k)});
        r = builder.CreateInsertValue(r, loadBlockValue(builder, p, et, rule, loc), k);
      }
      return r;
    }
    return builder.CreateLoad(dty, ptr);
  }

  /// The `T` value of a block variable: a uniform block's, a push-constant
  /// block's, or, on OpenGL, a block's fields as plain uniforms.
  llvm::Value *loadBlock(llvm::IRBuilder<> &builder, const ShaderVariable &v,
                         llvm::StringRef entry) {
    Type *t = v.blockType->toBasetype();
    StructDeclaration *sd = static_cast<TypeStruct *>(t)->sym;
    auto *aggr = getIrType(t)->isAggr();
    llvm::Value *r = llvm::UndefValue::get(DtoType(t));
    Loc loc = v.decl->loc;
    if (v.kind == ShaderVariableKind::looseBlock) {
      for (VarDeclaration *field : sd->fields) {
        Type *ft = field->type->toBasetype();
        llvm::Type *it = interfaceType(ft);
        const char *name = field->ident->toChars();
        llvm::Value *u = builder.CreateLoad(it, buildUniform(it, name), name);
        r = builder.CreateInsertValue(r, fromInterface(builder, u, ft),
                                      memberIndex(aggr, sd, field));
      }
      return r;
    }
    const bool push = v.kind == ShaderVariableKind::pushConstants;
    const int rule = push ? 1 : 0;
    const BlockStruct &b = blockStruct(sd, rule, loc, /*root=*/true);
    llvm::Value *handle = nullptr;
    llvm::Type *handleTy = nullptr;
    if (push) {
      handle = pushConstantVariable(b.type, v.name, entry);
    } else {
      handleTy = llvm::TargetExtType::get(ctx, "spirv.VulkanBuffer", {b.type},
                                          {/*Uniform*/ 2, /*isWritable*/ 0});
      handle = buildResourceHandle(builder, handleTy, v.ordinal, v.name);
    }
    for (size_t k = 0; k < sd->fields.length; k++) {
      llvm::Value *p = memberPointer(builder, handle, handleTy, b, k, push);
      r = builder.CreateInsertValue(
          r, loadBlockValue(builder, p, sd->fields[k]->type, rule, loc),
          memberIndex(aggr, sd, sd->fields[k]));
    }
    return r;
  }

  /// A pointer to member `k` of a block: through
  /// `llvm.spv.resource.getpointer` for a uniform block, by a GEP for a
  /// push-constant block.
  llvm::Value *memberPointer(llvm::IRBuilder<> &builder, llvm::Value *handle,
                             llvm::Type *handleTy, const BlockStruct &b,
                             size_t k, bool push) {
    if (push)
      return builder.CreateInBoundsGEP(
          b.type, handle, {builder.getInt32(0), builder.getInt32(b.members[k])});
    auto *p12 = llvm::PointerType::get(ctx, 12);
    return buildIntrinsicCall(builder, "member", "llvm.spv.resource.getpointer",
                              {p12, handleTy, getI32Type()},
                              {handle, builder.getInt32(b.members[k])});
  }

  /// A push-constant block: a global in the `PushConstant` storage class.
  /// Each entry point's own, so two entry points' blocks of one name but
  /// different types stay two variables; it carries its name in
  /// `spirv.Name`.
  llvm::GlobalVariable *pushConstantVariable(llvm::Type *ty, llvm::StringRef name,
                                             llvm::StringRef entry) {
    const std::string llvmName = (name + "." + entry + ".push").str();
    if (auto *existing = _ir->module.getGlobalVariable(llvmName, true))
      return existing;
    auto *gv = new llvm::GlobalVariable(
        _ir->module, ty, /*isConstant=*/false, llvm::GlobalValue::ExternalLinkage,
        nullptr, llvmName, nullptr, llvm::GlobalValue::NotThreadLocal,
        /*PushConstant*/ 13, /*isExternallyInitialized=*/true);
    gv->setVisibility(llvm::GlobalValue::HiddenVisibility);
    gv->addMetadata("spirv.Name",
                    *llvm::MDNode::get(ctx, {llvm::MDString::get(ctx, name)}));
    return gv;
  }

  /// `UniformBlock!T` or `PushConstants!T`, wrapping `value`, a `T`.
  llvm::Value *wrapBlock(llvm::IRBuilder<> &builder, Type *wrapperTy,
                         llvm::Value *value) {
    StructDeclaration *sd = static_cast<TypeStruct *>(wrapperTy)->sym;
    return builder.CreateInsertValue(
        llvm::UndefValue::get(DtoType(wrapperTy)), value,
        memberIndex(getIrType(wrapperTy)->isAggr(), sd, sd->fields[0]));
  }

  /// An entry point's default uniform block on Vulkan: its `@uniform`
  /// parameters as the members of one std140 block (`SHR3`), built once.
  struct DefaultBlock {
    BlockStruct block;
    llvm::Type *handleTy = nullptr;
    llvm::Value *handle = nullptr;

    llvm::Value *member(TargetVulkan &t, llvm::IRBuilder<> &builder,
                        const ShaderEntry &entry, int index) {
      llvm::SmallVector<const ShaderVariable *, 8> members;
      for (size_t i = 0; i < entry.length; i++)
        if (entry.variables[i].kind == ShaderVariableKind::defaultUniform)
          members.push_back(&entry.variables[i]);
      if (!handle) {
        llvm::SmallVector<Type *, 8> types;
        llvm::SmallVector<unsigned, 8> offsets;
        llvm::SmallVector<const char *, 8> names;
        unsigned at = 0;
        for (const ShaderVariable *v : members) {
          Type *ty = v->decl->type->toBasetype();
          const unsigned a = shaderBlockAlignment(ty, 0);
          at = (at + a - 1) / a * a;
          types.push_back(ty);
          offsets.push_back(at);
          names.push_back(v->name);
          at += shaderBlockSize(ty, 0);
        }
        block = t.buildBlockStruct(types, offsets, (at + 15) / 16 * 16,
                                   entry.defaultBlockTypeName, names, 0,
                                   entry.fd->loc);
        handleTy = llvm::TargetExtType::get(t.ctx, "spirv.VulkanBuffer",
                                            {block.type}, {2, 0});
        handle = t.buildResourceHandle(builder, handleTy, entry.defaultBlockBinding,
                                       entry.defaultBlockName);
      }
      const ShaderVariable *v = members[index];
      llvm::Value *p = t.memberPointer(builder, handle, handleTy, block, index, false);
      return t.loadBlockValue(builder, p, v->decl->type, 0, v->decl->loc);
    }
  };

  void addShaderEntry(FuncDeclaration *fd, llvm::Function *llf,
                      StructLiteralExp *) override {
    // The D function itself becomes an internal helper that the
    // always-inliner folds into the entry point, so no opaque handle ever
    // lives in a Function-storage variable (which Vulkan forbids). An entry
    // point another profile emits stays a helper, which the optimiser drops.
    llf->setLinkage(llvm::GlobalValue::InternalLinkage);
    const ShaderEntry *entry = shaderEntryOf(fd);
    if (!entry)
      return;
    llf->addFnAttr(llvm::Attribute::AlwaysInline);
    const ShaderStage stage = entry->stage;

    // The entry point is named after the D function so a consumer can pick
    // it by `--entry`.
    auto *void_func_void =
        llvm::FunctionType::get(llvm::Type::getVoidTy(ctx), {}, false);
    auto *f = llvm::Function::Create(void_func_void,
                                     llvm::GlobalValue::ExternalLinkage,
                                     fd->ident->toChars(), _ir->module);
    f->addFnAttr("hlsl.shader",
                 stage == ShaderStage::vertex ? "vertex" : "pixel");

    auto bb = llvm::BasicBlock::Create(ctx, "entry", f);
    llvm::IRBuilder<> builder(ctx);
    builder.SetInsertPoint(bb);

    // A struct result comes back through a hidden first parameter (`sret`).
    llvm::FunctionType *tf = llf->getFunctionType();
    const size_t nparams = fd->parameters ? fd->parameters->length : 0;
    const unsigned first =
        tf->getNumParams() == nparams + 1 &&
                llf->hasParamAttribute(0, llvm::Attribute::StructRet)
            ? 1
            : 0;
    if (tf->getNumParams() != nparams + first) {
      error(fd->loc, "%s function parameters cannot be rewritten "
                     "by the ABI; use vector, scalar, or `Sampler2D` parameters",
            stage == ShaderStage::vertex ? "`@vertex`" : "`@fragment`");
      fatal();
    }

    llvm::SmallVector<llvm::Value *, 8> args(nparams + first);
    llvm::AllocaInst *resultSlot = nullptr;
    Type *ret = fd->type->nextOf()->toBasetype();
    if (first) {
      resultSlot = builder.CreateAlloca(DtoType(ret), nullptr, "result");
      args[0] = resultSlot;
    }
    // A field of a `@resources` parameter is inserted into the parameter's
    // aggregate, which the optimiser then takes apart again (`SHF6`).
    llvm::DenseMap<int, llvm::Value *> aggregates;
    DefaultBlock defaults;
    for (size_t i = 0; i < entry->length; i++) {
      const ShaderVariable &v = entry->variables[i];
      if (v.parameter < 0)
        continue;
      VarDeclaration *vd = v.decl;
      Type *dty = vd->type->toBasetype();
      llvm::Type *pt = v.depth ? DtoType(dty) : tf->getParamType(v.parameter + first);
      llvm::Value *value = nullptr;
      switch (v.kind) {
      case ShaderVariableKind::input: {
        llvm::Type *it = DtoType(dty);
        value = builder.CreateLoad(
            it, locationVariable(it, false, stage, v.name, v.ordinal), v.name);
        break;
      }
      case ShaderVariableKind::builtinInput: {
        // A `bool` built-in (`FrontFacing`) is SPIR-V's `OpTypeBool`, which
        // LLVM spells `i1`; D passes a `bool` as a wider integer.
        const bool isBool = dty->ty == TY::Tbool;
        llvm::Type *it = isBool ? llvm::Type::getInt1Ty(ctx) : DtoType(dty);
        value = builder.CreateLoad(
            it, builtinVariable(it, false, v.name, v.ordinal), v.name);
        if (isBool)
          value = builder.CreateZExt(value, pt);
        break;
      }
      case ShaderVariableKind::uniform: {
        llvm::Type *it = interfaceType(dty);
        llvm::Value *u = builder.CreateLoad(it, buildUniform(it, v.name), v.name);
        value = fromInterface(builder, u, dty);
        break;
      }
      case ShaderVariableKind::image:
        value = buildResourceHandle(builder, pt, v.ordinal, v.name);
        break;
      case ShaderVariableKind::uniformBlock:
      case ShaderVariableKind::pushConstants:
      case ShaderVariableKind::looseBlock:
        value = wrapBlock(builder, dty, loadBlock(builder, v, fd->ident->toChars()));
        break;
      case ShaderVariableKind::defaultUniform:
        value = defaults.member(*this, builder, *entry, v.ordinal);
        break;
      default:
        llvm_unreachable("a result variable among the parameters");
      }
      if (!v.depth) {
        args[v.parameter + first] =
            v.kind == ShaderVariableKind::image ? value
                                                : asArgument(builder, value, pt);
        continue;
      }
      // Into the parameter's aggregate, along the field path.
      VarDeclaration *param = (*fd->parameters)[v.parameter];
      Type *pty = param->type->toBasetype();
      llvm::Value *&agg = aggregates[v.parameter];
      if (!agg)
        agg = llvm::UndefValue::get(DtoType(pty));
      llvm::SmallVector<unsigned, 8> indices;
      Type *at = pty;
      for (int k = 0; k < v.depth; k++) {
        StructDeclaration *sd = static_cast<TypeStruct *>(at)->sym;
        VarDeclaration *field = sd->fields[v.path[k]];
        indices.push_back(memberIndex(getIrType(at)->isAggr(), sd, field));
        at = field->type->toBasetype();
      }
      agg = builder.CreateInsertValue(agg, value, indices);
    }
    for (auto &[parameter, agg] : aggregates)
      args[parameter + first] =
          asArgument(builder, agg, tf->getParamType(parameter + first));

    auto *call = builder.CreateCall(tf, llf, args);
    // The helper is SPIR_FUNC; a call with the default convention would be
    // a mismatch LLVM's inliner refuses to fold and the verifier flags.
    call->setCallingConv(llf->getCallingConv());
    if (entry->result) {
      // The result's fields to the stage's outputs.
      llvm::Type *structTy = DtoType(ret);
      llvm::Value *value =
          resultSlot ? static_cast<llvm::Value *>(builder.CreateLoad(structTy, resultSlot))
                     : call;
      auto *aggr = getIrType(ret)->isAggr();
      for (size_t i = 0; i < entry->length; i++) {
        const ShaderVariable &v = entry->variables[i];
        if (v.parameter >= 0)
          continue;
        llvm::Value *field = builder.CreateExtractValue(
            value, memberIndex(aggr, entry->result, v.decl), v.name);
        builder.CreateStore(
            field, v.kind == ShaderVariableKind::builtinOutput
                       ? builtinVariable(field->getType(), true, v.name, v.ordinal)
                       : locationVariable(field->getType(), true, stage, v.name,
                                          v.ordinal));
      }
    } else if (!tf->getReturnType()->isVoidTy()) {
      builder.CreateStore(call, locationVariable(tf->getReturnType(), true,
                                                 ShaderStage::fragment,
                                                 "finalColor", 0));
    }
    builder.CreateRetVoid();
    IF_LOG Logger::cout() << *f << std::endl;
  }
};
} // anonymous namespace.

DComputeTarget *createVulkanTarget(llvm::LLVMContext &c, int ver) {
  return new TargetVulkan(c, ver);
}

#endif // LDC_LLVM_SUPPORTED_TARGET_SPIRV
 
