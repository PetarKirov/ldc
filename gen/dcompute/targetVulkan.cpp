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
#include "gen/logger.h"
#include "gen/optimizer.h"
#include "gen/uda.h"
#include "dmd/errors.h"
#include "driver/targetmachine.h"
#include "llvm/Transforms/Scalar.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/IR/IntrinsicsSPIRV.h"
#include "llvm/ADT/StringMap.h"
#include "dmd/mtype.h"
#include "dmd/aggregate.h"
#include "gen/tollvm.h"
#include "ir/irtype.h"
#include "ir/irtypeaggr.h"
#include "llvm/ADT/DenseMap.h"
#include <cstring>
#include <string>

using namespace dmd;

namespace {
class TargetVulkan : public DComputeTarget {
public:
  TargetVulkan(llvm::LLVMContext &c, int ver)
      : DComputeTarget(c, ver, ID::Vulkan, "vulkan", "spv", createSPIRVVulkanABI(),
                       {{0, 1, 2, 3, 4}}) {

    _ir = new IRState("dcomputeTargetVulkan", ctx);
    // "spirv-vulkan-foo"? foo = library, pixel, etc
    std::string targTriple = "spirv1.6-unknown-vulkan1.3-compute";
    _ir->module.setTargetTriple(llvm::Triple(targTriple));

    auto floatABI = ::FloatABI::Hard;
    targetMachine = createTargetMachine(
            targTriple, "spirv", "", {},
            ExplicitBitness::None, floatABI,
            llvm::Reloc::Static, llvm::CodeModel::Medium, llvm::CodeGenOptLevel::None, false);

    _ir->module.setDataLayout(targetMachine->createDataLayout());
     
    _ir->dcomputetarget = this;
  }

  void addMetadata() override {
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

  /// Attaches a `spirv.Decorations` node carrying one `Location N` decoration.
  void decorateLocation(llvm::GlobalVariable *gv, unsigned location) {
    auto *i32 = getI32Type();
    llvm::Metadata *pair[] = {
        llvm::ConstantAsMetadata::get(llvm::ConstantInt::get(i32, 30)), // Location
        llvm::ConstantAsMetadata::get(llvm::ConstantInt::get(i32, location))};
    gv->addMetadata("spirv.Decorations",
                    *llvm::MDNode::get(ctx, {llvm::MDNode::get(ctx, pair)}));
  }

  /// An interface variable (`Input`/`Output` storage class): thread-local,
  /// externally initialised, no initializer -- the shape the HLSL frontend
  /// emits, which the backend recognises as needing no Linkage capability.
  llvm::GlobalVariable *buildInterfaceVariable(llvm::Type *ty, unsigned addrSpace,
                                               bool isConstant, llvm::StringRef name,
                                               unsigned location) {
    // Two entry points in one module naming the same varying share one
    // variable: the name is the contract with the vertex stage (GLSL links
    // `in`/`out` by name), and an LLVM-renamed duplicate would break it.
    if (auto *existing = _ir->module.getGlobalVariable(name, true)) {
      if (existing->getValueType() == ty &&
          existing->getAddressSpace() == addrSpace)
        return existing;
      error(Loc(), "shader interface variable `%s` declared with two types",
            name.str().c_str());
      fatal();
    }
    auto *gv = new llvm::GlobalVariable(
        _ir->module, ty, isConstant, llvm::GlobalValue::ExternalLinkage, nullptr,
        name, nullptr, llvm::GlobalValue::GeneralDynamicTLSModel, addrSpace,
        /*isExternallyInitialized=*/true);
    gv->setVisibility(llvm::GlobalValue::HiddenVisibility);
    decorateLocation(gv, location);
    return gv;
  }

  /// A plain (non-block) uniform: `UniformConstant` storage, no initializer.
  llvm::GlobalVariable *buildUniform(llvm::Type *ty, llvm::StringRef name) {
    if (auto *existing = _ir->module.getGlobalVariable(name, true)) {
      if (existing->getValueType() == ty && existing->getAddressSpace() == 2)
        return existing;
      error(Loc(), "shader uniform `%s` declared with two types",
            name.str().c_str());
      fatal();
    }
    auto *gv = new llvm::GlobalVariable(
        _ir->module, ty, /*isConstant=*/false, llvm::GlobalValue::ExternalLinkage,
        llvm::PoisonValue::get(ty), name, nullptr,
        llvm::GlobalValue::NotThreadLocal, /*UniformConstant*/ 2);
    gv->setVisibility(llvm::GlobalValue::HiddenVisibility);
    return gv;
  }

  /// What an interface name is across the module. An entry point's interface
  /// variable is shared by name with every other entry point in the module
  /// (see `buildInterfaceVariable`), so its kind and its location or binding
  /// are the module's, not the entry point's: every entry naming it must
  /// agree, or one of them would read through a decoration it did not ask for.
  struct InterfaceUse {
    const char *kind; // "input", "uniform" or "image"
    int ordinal;      // the location or binding; -1 for a uniform
    std::string type; // the D type, as written
    std::string entry;
  };
  llvm::StringMap<InterfaceUse> interfaceUses;

  void recordInterfaceUse(VarDeclaration *vd, const char *entry,
                          const char *kind, int ordinal) {
    const char *name = vd->ident->toChars();
    const char *type = vd->type->toBasetype()->toChars();
    auto inserted = interfaceUses.try_emplace(
        name, InterfaceUse{kind, ordinal, type, entry});
    if (inserted.second)
      return;
    const InterfaceUse &first = inserted.first->second;
    if (std::strcmp(first.kind, kind) != 0) {
      error(vd->loc,
            "shader interface name `%s` is %s %s in `%s` but %s %s in `%s`; "
            "an interface name is one variable across the module",
            name, article(kind), kind, entry, article(first.kind), first.kind,
            first.entry.c_str());
      fatal();
    }
    if (first.type != type) {
      error(vd->loc,
            "shader %s `%s` is `%s` in `%s` but `%s` in `%s`; an interface "
            "name is one variable across the module, so every entry point "
            "must give it the same type",
            kind, name, type, entry, first.type.c_str(), first.entry.c_str());
      fatal();
    }
    if (first.ordinal != ordinal) {
      const char *what = std::strcmp(kind, "image") == 0 ? "binding" : "location";
      error(vd->loc,
            "shader %s `%s` is at %s %d in `%s` but %s %d in `%s`; an "
            "interface name is one variable across the module, so every entry "
            "point must give it the same %s",
            kind, name, what, ordinal, entry, what, first.ordinal,
            first.entry.c_str(), what);
      fatal();
    }
  }

  static const char *article(const char *kind) {
    return kind[0] == 'i' ? "an" : "a";
  }

  // ---- interface types ----------------------------------------------------
  //
  // What crosses a shader's interface is what GLSL can declare there, in a
  // form both GLSL dialects the build step emits accept (GLSL 3.30 and GLSL
  // ES 1.00):
  //
  // - inputs: `float` and vectors of two to four `float`s (ES 1.00 has no
  //   integer varyings, and GLSL 3.30 needs them `flat`);
  // - the output: a vector of four `float`s (ES 1.00 writes `gl_FragData[0]`,
  //   which is a `vec4`);
  // - uniforms: those, `int` and vectors of `int`, and structs and static
  //   arrays of uniform types (ES 1.00 has no `uint`).
  //
  // LLVM's integers carry no sign and its struct members no names, both of
  // which the host binds by, so a uniform's SPIR-V type is not its D type's
  // LLVM type: an `int` is an inline signed `OpTypeInt`, and a struct is a
  // struct of such types whose members are named by `spirv.MemberNames`.
  // `fromInterface` converts a loaded value back to the D type.

  enum class Crossing { varying, output, uniform };

  /// Why `t` cannot cross as `crossing`, or null if it can.
  static const char *refusal(Type *t, Crossing crossing) {
    t = t->toBasetype();
    if (crossing == Crossing::output) {
      auto *tv = t->ty == TY::Tvector ? static_cast<TypeVector *>(t) : nullptr;
      return tv && tv->elementType()->ty == TY::Tfloat32 &&
                     toInteger(static_cast<TypeSArray *>(tv->basetype)->dim) == 4
                 ? nullptr
                 : "the output is a vector of four `float`s, as GLSL ES 1.00's "
                   "`gl_FragData[0]` is";
    }
    switch (t->ty) {
    case TY::Tfloat32:
      return nullptr;
    case TY::Tint32:
      return crossing == Crossing::uniform
                 ? nullptr
                 : "an integer cannot be interpolated; pass it as a `@uniform`";
    case TY::Tvector: {
      auto *tv = static_cast<TypeVector *>(t);
      const auto n = toInteger(static_cast<TypeSArray *>(tv->basetype)->dim);
      if (n < 2 || n > 4)
        return "a vector must have two to four components";
      return refusal(tv->elementType(), crossing);
    }
    case TY::Tsarray:
      if (crossing != Crossing::uniform)
        return "only a `@uniform` can be an array";
      return refusal(t->nextOf(), crossing);
    case TY::Tstruct: {
      if (crossing != Crossing::uniform)
        return "only a `@uniform` can be a struct";
      StructDeclaration *sd = static_cast<TypeStruct *>(t)->sym;
      if (sd->fields.length == 0)
        return "a struct must have fields";
      for (VarDeclaration *field : sd->fields)
        if (const char *why = refusal(field->type, crossing))
          return why;
      return nullptr;
    }
    case TY::Tuns32:
      return "GLSL ES 1.00 has no unsigned integers";
    default:
      return crossing == Crossing::uniform
                 ? "a uniform is a `float`, an `int`, a vector of them, or a "
                   "struct or static array of uniform types"
                 : "an input or output is a `float` or a vector of them";
    }
  }

  llvm::DenseMap<StructDeclaration *, llvm::StructType *> interfaceStructs;

  /// `spirv.Type` for an inline SPIR-V type: `params` are its operands,
  /// `opcode` its SPIR-V opcode, sized and aligned like `like`.
  llvm::Type *inlineSpirvType(llvm::ArrayRef<llvm::Type *> params,
                              unsigned opcode, llvm::Type *like) {
    const auto &dl = _ir->module.getDataLayout();
    return llvm::TargetExtType::get(
        ctx, "spirv.Type", params,
        {opcode, static_cast<unsigned>(dl.getTypeAllocSize(like)),
         static_cast<unsigned>(dl.getABITypeAlign(like).value())});
  }

  llvm::Type *literal(unsigned v) {
    return llvm::TargetExtType::get(ctx, "spirv.Literal", {}, {v});
  }

  /// The SPIR-V-facing type of an interface variable of D type `t`.
  llvm::Type *interfaceType(Type *t) {
    t = t->toBasetype();
    switch (t->ty) {
    case TY::Tint32:
      return inlineSpirvType({literal(32), literal(1)}, /*OpTypeInt*/ 21,
                             getI32Type());
    case TY::Tvector: {
      auto *tv = static_cast<TypeVector *>(t);
      if (tv->elementType()->ty != TY::Tint32)
        return DtoType(t);
      const auto n = toInteger(static_cast<TypeSArray *>(tv->basetype)->dim);
      return inlineSpirvType({interfaceType(tv->elementType()), literal(n)},
                             /*OpTypeVector*/ 23, DtoType(t));
    }
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
    case TY::Tint32:
    case TY::Tvector:
      return buildIntrinsicCall(builder, "", "llvm.spv.bitcast",
                                {dty, v->getType()}, {v});
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
        bool isFieldIdx;
        const unsigned index = aggr->getMemberLocation(field, isFieldIdx);
        if (!isFieldIdx) {
          error(field->loc,
                "shader uniform struct `%s` has overlapping field `%s`",
                sd->toChars(), field->toChars());
          fatal();
        }
        r = builder.CreateInsertValue(
            r, fromInterface(builder, builder.CreateExtractValue(v, i),
                             field->type),
            index);
      }
      return r;
    }
    default:
      llvm_unreachable("an interface type that needs no conversion");
    }
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

  void addShaderEntry(FuncDeclaration *fd, llvm::Function *llf,
                      StructLiteralExp *shaderAttr) override {
    const auto stage = toInteger((*shaderAttr->elements)[0]);
    if (stage != 0) {
      error(fd->loc, "unsupported shader stage %d", static_cast<int>(stage));
      fatal();
    }

    // The entry point is named after the D function so a consumer can pick
    // it by `--entry`; the D function itself becomes an internal helper that
    // the always-inliner folds into it, so no opaque handle ever lives in a
    // Function-storage variable (which Vulkan forbids).
    auto *void_func_void =
        llvm::FunctionType::get(llvm::Type::getVoidTy(ctx), {}, false);
    auto *f = llvm::Function::Create(void_func_void,
                                     llvm::GlobalValue::ExternalLinkage,
                                     fd->ident->toChars(), _ir->module);
    f->addFnAttr("hlsl.shader", "pixel");
    llf->setLinkage(llvm::GlobalValue::InternalLinkage);
    llf->addFnAttr(llvm::Attribute::AlwaysInline);

    auto bb = llvm::BasicBlock::Create(ctx, "entry", f);
    llvm::IRBuilder<> builder(ctx);
    builder.SetInsertPoint(bb);

    llvm::FunctionType *tf = llf->getFunctionType();
    const size_t nparams = fd->parameters ? fd->parameters->length : 0;
    if (tf->getNumParams() != nparams) {
      error(fd->loc, "`@fragment` function parameters cannot be rewritten "
                     "by the ABI; use vector, scalar, or `Sampler2D` parameters");
      fatal();
    }

    const char *entry = fd->ident->toChars();
    Type *ret = fd->type->nextOf()->toBasetype();
    if (ret->ty != TY::Tvoid) {
      if (const char *why = refusal(ret, Crossing::output)) {
        error(fd->loc, "`@fragment` function `%s` cannot return `%s`: %s",
              entry, ret->toChars(), why);
        fatal();
      }
    }

    unsigned nextLocation = 0;
    unsigned nextImageBinding = 1;
    llvm::SmallVector<llvm::Value *, 8> args(nparams);
    for (size_t i = 0; i < nparams; i++) {
      VarDeclaration *vd = (*fd->parameters)[i];
      llvm::Type *pt = tf->getParamType(i);
      const char *name = vd->ident->toChars();
      Type *dty = vd->type->toBasetype();
      StructDeclaration *sd =
          dty->ty == TY::Tstruct ? static_cast<TypeStruct *>(dty)->sym : nullptr;
      const bool isInput = hasShaderInputUDA(vd);
      const bool isUniform = hasShaderUniformUDA(vd);
      if (isInput || isUniform) {
        const auto crossing = isInput ? Crossing::varying : Crossing::uniform;
        if (const char *why = refusal(dty, crossing)) {
          error(vd->loc, "`@fragment` parameter `%s` cannot be `%s`: %s", name,
                vd->type->toChars(), why);
          fatal();
        }
      }

      if (isInput) {
        recordInterfaceUse(vd, entry, "input", nextLocation);
        llvm::Type *it = DtoType(dty);
        auto *gv = buildInterfaceVariable(it, /*Input*/ 7, /*isConstant=*/true,
                                          name, nextLocation++);
        args[i] = builder.CreateLoad(it, gv, name);
      } else if (isUniform) {
        recordInterfaceUse(vd, entry, "uniform", -1);
        llvm::Type *it = interfaceType(dty);
        llvm::Value *v = builder.CreateLoad(it, buildUniform(it, name), name);
        args[i] = asArgument(builder, fromInterface(builder, v, dty), pt);
      } else if (sd && sd->ident == Id::dcSampler2D && isFromLDC_DCompute(sd)) {
        // Binding 0 is the shared sampler; images take the bindings after it.
        recordInterfaceUse(vd, entry, "image", nextImageBinding);
        args[i] = buildResourceHandle(builder, pt, nextImageBinding++, name);
      } else {
        error(vd->loc,
              "`@fragment` parameter `%s` must be marked `@input` or "
              "`@uniform`, or be a `Sampler2D`",
              name);
        fatal();
      }
    }

    auto *call = builder.CreateCall(tf, llf, args);
    // The helper is SPIR_FUNC; a call with the default convention would be
    // a mismatch LLVM's inliner refuses to fold and the verifier flags.
    call->setCallingConv(llf->getCallingConv());
    llvm::Value *result = call;
    if (!tf->getReturnType()->isVoidTy()) {
      auto *out = buildInterfaceVariable(tf->getReturnType(), /*Output*/ 8,
                                         /*isConstant=*/false, "finalColor",
                                         /*location=*/0);
      builder.CreateStore(result, out);
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
 
