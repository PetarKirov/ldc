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
#include "llvm/ADT/StringSet.h"
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

    // D's plain integers are signed, and a shader's `int` must reach GLSL as
    // `int`: ask the SPIR-V backend for signed integer types, since LLVM's
    // integers carry no sign of their own.
    _ir->module.addModuleFlag(llvm::Module::Error, "spirv.signed-integers", 1);
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
    std::string type; // the D type, unqualified and fully qualified by module
    std::string entry;
  };
  llvm::StringMap<InterfaceUse> interfaceUses;

  void recordInterfaceUse(VarDeclaration *vd, const char *entry,
                          const char *kind, int ordinal) {
    const char *name = vd->ident->toChars();
    // `in float` and `float` are one interface type; two structs of one name
    // from two modules are not.
    const char *type =
        unSharedOf(mutableOf(vd->type->toBasetype()))->toPrettyChars(true);
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
  // The host binds a uniform struct's members by name, and LLVM struct members
  // have none, so a uniform struct's SPIR-V type is its own: the fields'
  // interface types in declaration order, without the padding or overlap the D
  // struct's LLVM type may carry, and named by `spirv.MemberNames`.
  // `fromInterface` converts a loaded value back to the D type. (Integers are
  // signed module-wide, by the `spirv.signed-integers` flag.)

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

  /// The entry points so far, by name: a SPIR-V entry point's name is the
  /// module's, and a second one would be renamed (`tint.1`), not linked.
  llvm::StringMap<FuncDeclaration *> entryPoints;

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

  /// Why an interface name would not survive translation to GLSL, or null.
  /// spirv-cross renames a name that GLSL reserves (a keyword or a built-in
  /// function) and collapses a run of underscores, and GLSL reserves the
  /// `gl_` prefix; a host binding by the D name would then find nothing. The
  /// list is spirv-cross's own (`CompilerGLSL::replace_illegal_names`).
  static const char *unreservedRefusal(llvm::StringRef name) {
    static const llvm::StringSet<> reserved = {
      "abs", "acos", "acosh", "all", "any", "asin", "asinh", "atan", "atanh", "atomicAdd",
      "atomicCompSwap", "atomicCounter", "atomicCounterDecrement",
      "atomicCounterIncrement", "atomicExchange", "atomicMax", "atomicMin",
      "atomicOr", "atomicXor", "bitCount", "bitfieldExtract", "bitfieldInsert",
      "bitfieldReverse", "ceil", "cos", "cosh", "cross", "degrees", "dFdx", "dFdxCoarse",
      "dFdxFine", "dFdy", "dFdyCoarse", "dFdyFine", "distance", "dot",
      "EmitStreamVertex", "EmitVertex", "EndPrimitive", "EndStreamPrimitive", "equal",
      "exp", "exp2", "faceforward", "findLSB", "findMSB", "float16BitsToInt16",
      "float16BitsToUint16", "floatBitsToInt", "floatBitsToUint", "floor", "fma",
      "fract", "frexp", "fwidth", "fwidthCoarse", "fwidthFine", "greaterThan",
      "greaterThanEqual", "groupMemoryBarrier", "imageAtomicAdd", "imageAtomicAnd",
      "imageAtomicCompSwap", "imageAtomicExchange", "imageAtomicMax",
      "imageAtomicMin", "imageAtomicOr", "imageAtomicXor", "imageLoad",
      "imageSamples", "imageSize", "imageStore", "imulExtended", "int16BitsToFloat16",
      "intBitsToFloat", "interpolateAtOffset", "interpolateAtCentroid",
      "interpolateAtSample", "inverse", "inversesqrt", "isinf", "isnan", "ldexp",
      "length", "lessThan", "lessThanEqual", "log", "log2", "matrixCompMult", "max",
      "memoryBarrier", "memoryBarrierAtomicCounter", "memoryBarrierBuffer",
      "memoryBarrierImage", "memoryBarrierShared", "min", "mix", "mod", "modf", "noise",
      "noise1", "noise2", "noise3", "noise4", "normalize", "not", "notEqual",
      "outerProduct", "packDouble2x32", "packHalf2x16", "packInt2x16", "packInt4x16",
      "packSnorm2x16", "packSnorm4x8", "packUint2x16", "packUint4x16",
      "packUnorm2x16", "packUnorm4x8", "pow", "radians", "reflect", "refract", "round",
      "roundEven", "sign", "sin", "sinh", "smoothstep", "sqrt", "step", "tan", "tanh",
      "texelFetch", "texelFetchOffset", "texture", "textureGather",
      "textureGatherOffset", "textureGatherOffsets", "textureGrad",
      "textureGradOffset", "textureLod", "textureLodOffset", "textureOffset",
      "textureProj", "textureProjGrad", "textureProjGradOffset", "textureProjLod",
      "textureProjLodOffset", "textureProjOffset", "textureQueryLevels",
      "textureQueryLod", "textureSamples", "textureSize", "transpose", "trunc",
      "uaddCarry", "uint16BitsToFloat16", "uintBitsToFloat", "umulExtended",
      "unpackDouble2x32", "unpackHalf2x16", "unpackInt2x16", "unpackInt4x16",
      "unpackSnorm2x16", "unpackSnorm4x8", "unpackUint2x16", "unpackUint4x16",
      "unpackUnorm2x16", "unpackUnorm4x8", "usubBorrow", "active", "asm",
      "atomic_uint", "attribute", "bool", "break", "buffer", "bvec2", "bvec3", "bvec4",
      "case", "cast", "centroid", "class", "coherent", "common", "const", "continue",
      "default", "discard", "dmat2", "dmat2x2", "dmat2x3", "dmat2x4", "dmat3", "dmat3x2",
      "dmat3x3", "dmat3x4", "dmat4", "dmat4x2", "dmat4x3", "dmat4x4", "do", "double",
      "dvec2", "dvec3", "dvec4", "else", "enum", "extern", "external", "false", "filter",
      "fixed", "flat", "float", "for", "fvec2", "fvec3", "fvec4", "goto", "half", "highp",
      "hvec2", "hvec3", "hvec4", "if", "iimage1D", "iimage1DArray", "iimage2D",
      "iimage2DArray", "iimage2DMS", "iimage2DMSArray", "iimage2DRect", "iimage3D",
      "iimageBuffer", "iimageCube", "iimageCubeArray", "image1D", "image1DArray",
      "image2D", "image2DArray", "image2DMS", "image2DMSArray", "image2DRect",
      "image3D", "imageBuffer", "imageCube", "imageCubeArray", "in", "inline", "inout",
      "input", "int", "interface", "invariant", "isampler1D", "isampler1DArray",
      "isampler2D", "isampler2DArray", "isampler2DMS", "isampler2DMSArray",
      "isampler2DRect", "isampler3D", "isamplerBuffer", "isamplerCube",
      "isamplerCubeArray", "ivec2", "ivec3", "ivec4", "layout", "long", "lowp", "mat2",
      "mat2x2", "mat2x3", "mat2x4", "mat3", "mat3x2", "mat3x3", "mat3x4", "mat4",
      "mat4x2", "mat4x3", "mat4x4", "mediump", "namespace", "noinline", "noperspective",
      "out", "output", "packed", "partition", "patch", "precise", "precision", "public",
      "readonly", "resource", "restrict", "return", "sample", "sampler1D",
      "sampler1DArray", "sampler1DArrayShadow", "sampler1DShadow", "sampler2D",
      "sampler2DArray", "sampler2DArrayShadow", "sampler2DMS", "sampler2DMSArray",
      "sampler2DRect", "sampler2DRectShadow", "sampler2DShadow", "sampler3D",
      "sampler3DRect", "samplerBuffer", "samplerCube", "samplerCubeArray",
      "samplerCubeArrayShadow", "samplerCubeShadow", "shared", "short", "sizeof",
      "smooth", "static", "struct", "subroutine", "superp", "switch", "template", "this",
      "true", "typedef", "uimage1D", "uimage1DArray", "uimage2D", "uimage2DArray",
      "uimage2DMS", "uimage2DMSArray", "uimage2DRect", "uimage3D", "uimageBuffer",
      "uimageCube", "uimageCubeArray", "uint", "uniform", "union", "unsigned",
      "usampler1D", "usampler1DArray", "usampler2D", "usampler2DArray",
      "usampler2DMS", "usampler2DMSArray", "usampler2DRect", "usampler3D",
      "usamplerBuffer", "usamplerCube", "usamplerCubeArray", "using", "uvec2", "uvec3",
      "uvec4", "varying", "vec2", "vec3", "vec4", "void", "volatile", "while",
      "writeonly",
    };
    if (reserved.contains(name))
      return "GLSL reserves it";
    if (name.starts_with("gl_"))
      return "GLSL reserves the `gl_` prefix";
    if (name.contains("__"))
      return "the translation collapses a run of underscores";
    return nullptr;
  }

  /// Rejects an interface name, or a uniform struct's field name, that the
  /// translation would not keep.
  void checkTranslatable(Dsymbol *s, const char *what, Type *t = nullptr) {
    if (const char *why = unreservedRefusal(s->ident->toChars())) {
      error(s->loc, "%s `%s` cannot keep its name in GLSL: %s", what,
            s->ident->toChars(), why);
      fatal();
    }
    if (!t)
      return;
    t = t->toBasetype();
    while (t->ty == TY::Tsarray)
      t = t->nextOf()->toBasetype();
    if (t->ty == TY::Tstruct)
      for (VarDeclaration *field : static_cast<TypeStruct *>(t)->sym->fields)
        checkTranslatable(field, "uniform struct field", field->type);
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
    auto prior = entryPoints.try_emplace(fd->ident->toChars(), fd);
    if (!prior.second) {
      error(fd->loc,
            "`@fragment` entry point `%s` is defined by both `%s` and `%s`; an "
            "entry point's name must be unique across the module",
            fd->ident->toChars(), prior.first->second->toPrettyChars(),
            fd->toPrettyChars());
      fatal();
    }
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
      const bool isImage =
          sd && sd->ident == Id::dcSampler2D && isFromLDC_DCompute(sd);
      if (isInput && isUniform) {
        error(vd->loc,
              "`@fragment` parameter `%s` is marked both `@input` and "
              "`@uniform`; it must be one",
              name);
        fatal();
      }
      if ((isInput || isUniform) && isImage) {
        error(vd->loc,
              "`@fragment` parameter `%s` is a `Sampler2D`, which takes no "
              "`@input` or `@uniform` marker",
              name);
        fatal();
      }
      checkTranslatable(vd, "`@fragment` parameter", isUniform ? dty : nullptr);
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
      } else if (isImage) {
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
 
