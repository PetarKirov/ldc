// A vertex entry point's built-ins are read and written in their stage, in
// their direction and with their type; it returns a struct with a position.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: split-file %s %t
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/wrongstage.d 2>&1 | FileCheck %t/wrongstage.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/wrongtype.d 2>&1 | FileCheck %t/wrongtype.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/wrongdirection.d 2>&1 | FileCheck %t/wrongdirection.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/noposition.d 2>&1 | FileCheck %t/noposition.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/notastruct.d 2>&1 | FileCheck %t/notastruct.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/twopositions.d 2>&1 | FileCheck %t/twopositions.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/badoutput.d 2>&1 | FileCheck %t/badoutput.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/markedbuiltin.d 2>&1 | FileCheck %t/markedbuiltin.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/badfield.d 2>&1 | FileCheck %t/badfield.d

//--- wrongstage.d
@compute(CompileFor.deviceOnly) module wrongstage;
import ldc.dcompute;
// CHECK: wrongstage.d(4): Error: built-in `vertexIndex` of `@fragment` parameter `v` is a vertex-stage built-in
@fragment __vector(float[4]) f(@builtin(Builtin.vertexIndex) int v) { return __vector(float[4])(cast(float) v); }

//--- wrongtype.d
@compute(CompileFor.deviceOnly) module wrongtype;
import ldc.dcompute;
struct V { @builtin(Builtin.position) __vector(float[4]) position; }
// CHECK: wrongtype.d(5): Error: built-in `vertexIndex` of `@vertex` parameter `v` is `int`, not `float`
@vertex V f(@builtin(Builtin.vertexIndex) float v) { V r; r.position = v; return r; }

//--- wrongdirection.d
@compute(CompileFor.deviceOnly) module wrongdirection;
import ldc.dcompute;
struct V { @builtin(Builtin.position) __vector(float[4]) position; }
// CHECK: wrongdirection.d(5): Error: built-in `position` of `@vertex` parameter `p` is an output, not an input
@vertex V f(@builtin(Builtin.position) __vector(float[4]) p) { V r; r.position = p; return r; }

//--- noposition.d
@compute(CompileFor.deviceOnly) module noposition;
import ldc.dcompute;
struct V { __vector(float[4]) colour; }
// CHECK: noposition.d(5): Error: `@vertex` function `f` returns `V`, which has no field marked `@builtin(Builtin.position)`
@vertex V f() { V r; return r; }

//--- notastruct.d
@compute(CompileFor.deviceOnly) module notastruct;
import ldc.dcompute;
// CHECK: notastruct.d(4): Error: `@vertex` function `f` cannot return `__vector(float[4])`: a vertex entry point returns a struct with a position
@vertex __vector(float[4]) f() { return __vector(float[4])(0.0f); }

//--- twopositions.d
@compute(CompileFor.deviceOnly) module twopositions;
import ldc.dcompute;
// CHECK: twopositions.d(4): Error: `@vertex` result field `b` is a second `@builtin(Builtin.position)`; `a` is the first
struct V { @builtin(Builtin.position) __vector(float[4]) a; @builtin(Builtin.position) __vector(float[4]) b; }
@vertex V f() { V r; return r; }

//--- badoutput.d
@compute(CompileFor.deviceOnly) module badoutput;
import ldc.dcompute;
// CHECK: badoutput.d(4): Error: `@vertex` result field `n` cannot be `int`: an integer cannot be interpolated
struct V { @builtin(Builtin.position) __vector(float[4]) position; int n; }
@vertex V f() { V r; return r; }

//--- markedbuiltin.d
@compute(CompileFor.deviceOnly) module markedbuiltin;
import ldc.dcompute;
struct V { @builtin(Builtin.position) __vector(float[4]) position; }
// CHECK: markedbuiltin.d(5): Error: `@vertex` parameter `v` is marked both `@builtin` and `@input`; it must be one
@vertex V f(@builtin(Builtin.vertexIndex) @input int v) { V r; return r; }

//--- badfield.d
@compute(CompileFor.deviceOnly) module badfield;
import ldc.dcompute;
// CHECK: badfield.d(4): Error: built-in `vertexIndex` of `@vertex` result field `i` is an input, not an output
struct V { @builtin(Builtin.position) __vector(float[4]) position; @builtin(Builtin.vertexIndex) int i; }
@vertex V f() { V r; return r; }
