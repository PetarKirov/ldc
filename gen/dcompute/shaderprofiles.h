//===-- gen/dcompute/shaderprofiles.h - Shader profiles --------*- C++ -*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
// The profiles a shader entry point is built for, and the manifest that lists
// a unit's entry points with their stages and profiles. A profile is a name to
// the compiler; what it means (its stages and capabilities) is the shader
// library's table.
//
//===----------------------------------------------------------------------===//

#pragma once

#include "dmd/globals.h"
#include <string>
#include <vector>

class FuncDeclaration;

/// The names of the profiles `fd`, a shader entry point of `stage` (0 for
/// fragment, 1 for vertex), is built for, sorted: its own `@profiles`, else
/// its module's, else, for a fragment entry point, `gl330` and `gles100`. A
/// vertex entry point with neither has no profile, which is an error.
std::vector<std::string> shaderEntryProfiles(FuncDeclaration *fd,
                                             int stage);

/// Whether the compilation emits `fd`, of `stage`: always without
/// `-mdcompute-profile`, else only if its profiles include the active one.
bool isEmittedForActiveProfile(FuncDeclaration *fd, int stage);
