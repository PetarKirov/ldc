//===-- gen/dcompute/shaderinterface.h - Shader entry points ---*- C++ -*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
// The description of a shader entry point's interface that
// gen/dcompute/shaderinterface.d builds during semantic analysis, which the
// Vulkan target's code generator emits. The layouts mirror the D ones.
//
//===----------------------------------------------------------------------===//

#pragma once

#include <cstddef>

class FuncDeclaration;
class StructDeclaration;
class VarDeclaration;

enum class ShaderStage : int { fragment = 0, vertex = 1 };

enum class ShaderVariableKind : int {
  input,        // an `@input` parameter: location `ordinal`
  output,       // a field of a vertex result: location `ordinal`
  uniform,      // a `@uniform` parameter
  image,        // a `Sampler2D` parameter: binding `ordinal`
  builtinInput, // a `@builtin` parameter: SPIR-V `BuiltIn` `ordinal`
  builtinOutput // a `@builtin` result field: SPIR-V `BuiltIn` `ordinal`
};

struct ShaderVariable {
  ShaderVariableKind kind;
  /// The parameter, or the field of a vertex result, that declares it.
  VarDeclaration *decl;
  /// The D parameter's index, or -1 for a result field.
  int parameter;
  /// The location, binding or `BuiltIn`, by `kind`; -1 for a uniform.
  int ordinal;
  /// Its name: the declaration's, or a built-in's.
  const char *name;
};

struct ShaderEntry {
  FuncDeclaration *fd;
  ShaderStage stage;
  /// A vertex entry point's result, else null.
  StructDeclaration *result;
  /// Parameters in order, then result fields in field order.
  ShaderVariable *variables;
  size_t length;
};

/// The description of `fd` if it is a shader entry point this compilation
/// emits, else null.
const ShaderEntry *shaderEntryOf(FuncDeclaration *fd);
