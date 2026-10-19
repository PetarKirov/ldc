//===-- gen/dcompute/shaderprofiles.cpp - Shader profiles ------*- C++ -*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//

#include "gen/dcompute/shaderprofiles.h"

#include "dmd/attrib.h"
#include "dmd/declaration.h"
#include "dmd/module.h"
#include "dmd/errors.h"
#include "dmd/expression.h"
#include "dmd/identifier.h"
#include "driver/cl_options.h"
#include "gen/uda.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/raw_ostream.h"
#include <algorithm>

using namespace dmd;


static std::vector<std::string> splitNames(const char *names) {
  std::vector<std::string> r;
  llvm::SmallVector<llvm::StringRef, 4> parts;
  llvm::StringRef(names).split(parts, ',', -1, /*KeepEmpty=*/false);
  for (llvm::StringRef p : parts)
    r.push_back(p.trim().str());
  std::sort(r.begin(), r.end());
  r.erase(std::unique(r.begin(), r.end()), r.end());
  return r;
}

std::vector<std::string> shaderEntryProfiles(FuncDeclaration *fd, int stage) {
  if (const char *own = getShaderProfilesUDA(fd))
    return splitNames(own);
  if (const char *module = getShaderProfilesUDA(fd->getModule()))
    return splitNames(module);
  if (stage == 0)
    return {"gl330", "gles100"};
  error(fd->loc,
        "`@vertex` entry point `%s` declares no profiles, and no profile is "
        "the default for the vertex stage; mark it, or its module, "
        "`@profiles(...)`",
        fd->ident->toChars());
  fatal();
}

bool isEmittedForActiveProfile(FuncDeclaration *fd, int stage) {
#if LDC_LLVM_SUPPORTED_TARGET_SPIRV
  const auto profiles = shaderEntryProfiles(fd, stage);
  if (opts::dcomputeProfile.empty())
    return true;
  return std::find(profiles.begin(), profiles.end(),
                   opts::dcomputeProfile.getValue()) != profiles.end();
#else
  return true;
#endif
}

// ---- the manifest -----------------------------------------------------------

namespace {
struct ManifestEntry {
  std::string name, stage, module;
  std::vector<std::string> profiles;
};

void collect(Dsymbols *members, std::vector<ManifestEntry> &out) {
  if (!members)
    return;
  for (Dsymbol *s : *members) {
    if (auto *ad = s->isAttribDeclaration()) {
      collect(include(ad, nullptr), out);
      continue;
    }
    auto *fd = s->isFuncDeclaration();
    if (!fd)
      continue;
    StructLiteralExp *attr = getShaderAttr(fd);
    if (!attr)
      continue;
    const int stage = static_cast<int>(toInteger((*attr->elements)[0]));
    out.push_back({fd->ident->toChars(), stage == 1 ? "vertex" : "fragment",
                   fd->getModule()->toPrettyChars(),
                   shaderEntryProfiles(fd, stage)});
  }
}

void writeString(llvm::raw_ostream &os, llvm::StringRef s) {
  os << '"';
  for (char c : s) {
    if (c == '"' || c == '\\')
      os << '\\';
    os << c;
  }
  os << '"';
}
} // namespace

/// With `-mdcompute-manifest=<file>`, writes the unit's shader entry points,
/// with their stages, modules and profiles, as JSON sorted by name, and
/// returns true: the compilation then stops before function bodies are
/// analysed. Called once the declarations of every module are.
extern "C++" bool writeDComputeManifest(Modules &modules) {
#if LDC_LLVM_SUPPORTED_TARGET_SPIRV
  if (opts::dcomputeManifest.empty())
    return false;
  std::vector<ManifestEntry> entries;
  for (Module *m : modules)
    collect(m->members, entries);
  if (global.errors)
    return true;
  std::sort(entries.begin(), entries.end(),
            [](const ManifestEntry &a, const ManifestEntry &b) {
              return a.name < b.name;
            });
  std::error_code ec;
  llvm::raw_fd_ostream os(opts::dcomputeManifest, ec);
  if (ec) {
    error(Loc(), "cannot write the shader manifest `%s`: %s",
          opts::dcomputeManifest.c_str(), ec.message().c_str());
    return true;
  }
  os << "{\"entryPoints\":[";
  for (size_t i = 0; i < entries.size(); i++) {
    const ManifestEntry &e = entries[i];
    os << (i ? "," : "") << "{\"name\":";
    writeString(os, e.name);
    os << ",\"stage\":";
    writeString(os, e.stage);
    os << ",\"module\":";
    writeString(os, e.module);
    os << ",\"profiles\":[";
    for (size_t j = 0; j < e.profiles.size(); j++) {
      os << (j ? "," : "");
      writeString(os, e.profiles[j]);
    }
    os << "]}";
  }
  os << "]}\n";
  return true;
#else
  return false;
#endif
}
