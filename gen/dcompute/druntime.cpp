//===-- gen/dcompute/druntime.cpp -----------------------------------------===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//

#include "gen/dcompute/druntime.h"

#include "dmd/aggregate.h"
#include "dmd/declaration.h"
#include "dmd/dsymbol.h"
#include "dmd/expression.h"
#include "dmd/id.h"
#include "dmd/identifier.h"
#include "dmd/module.h"
#include "dmd/template.h"

using namespace dmd;

bool isFromLDC_Mod(Dsymbol *sym, Identifier* id) {
  auto mod = sym->getModule();
  if (!mod)
    return false;
  auto moduleDecl = mod->md;
  if (!moduleDecl)
    return false;

  if (moduleDecl->packages.length != 1)
    return false;
  if (moduleDecl->packages.ptr[0] != Id::ldc)
    return false;

  return moduleDecl->id == id;
}

bool isFromLDC_DCompute(Dsymbol *sym) {
  return isFromLDC_Mod(sym,Id::dcompute);
}
bool isFromLDC_OpenCL(Dsymbol *sym) {
  return isFromLDC_Mod(sym,Id::opencl);
}
bool isFromLDC_Intrinsics(Dsymbol *sym) {
  return isFromLDC_Mod(sym,Id::intrinsics);
}

llvm::Type *toDcomputeOpaqueHandleType(StructDeclaration *sd) {
  if (!isFromLDC_DCompute(sd))
    return nullptr;
  auto &ctx = gIR->context();
  if (sd->ident == Id::dcSampler2D) {
    // OpTypeImage %float 2D depth=unknown arrayed=0 ms=0 sampled=1 Unknown
    return llvm::TargetExtType::get(ctx, "spirv.Image",
                                    {llvm::Type::getFloatTy(ctx)},
                                    {1, 2, 0, 0, 1, 0});
  }
  if (sd->ident == Id::dcSampler)
    return llvm::TargetExtType::get(ctx, "spirv.Sampler");
  if (sd->ident == Id::dcStorageImage2D) {
    // OpTypeImage %float 2D depth=unknown arrayed=0 ms=0 sampled=2 (storage)
    // Rgba32f (1)
    return llvm::TargetExtType::get(ctx, "spirv.Image",
                                    {llvm::Type::getFloatTy(ctx)},
                                    {1, 2, 0, 0, 2, 1});
  }
  return nullptr;
}

std::optional<DcomputePointer> toDcomputePointer(StructDeclaration *sd) {
  if (sd->ident != Id::dcPointer || !isFromLDC_DCompute(sd)) {
    return std::optional<DcomputePointer>(std::nullopt);
  }

  TemplateInstance *ti = sd->isInstantiated();
  int addrspace = toInteger(isExpression((*ti->tiargs)[0]));
  Type *type = isType((*ti->tiargs)[1]);
  return std::optional<DcomputePointer>(DcomputePointer(addrspace, type));
}
