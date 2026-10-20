// The `shader` capability domain: a grant names members of
// `ldc.dcompute.Capability` (any other name, or another domain, is an error
// listing them), and the compiler enforces what it knows a capability to
// mean: an entry point's stage (`vertexStage`, `fragmentStage`) and an
// integer vertex input (`intVertexInputs`).

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: split-file %s %t
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -capabilities=shader:shader,vertexStag -I%t %t/badname.d 2>&1 | FileCheck %t/badname.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -capabilities=cpu:avx2 -I%t %t/baddomain.d 2>&1 | FileCheck %t/baddomain.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -capabilities=shader:shader,fragmentStage,looseUniforms -I%t %t/stage.d 2>&1 | FileCheck %t/stage.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=narrow -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks -I%t %t/intinput.d 2>&1 | FileCheck %t/intinput.d
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=narrow -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,intVertexInputs -mdcompute-file-prefix=%t/granted -I%t %t/intinput.d

//--- badname.d
@compute(CompileFor.deviceOnly) module badname;
import ldc.dcompute;
// CHECK: Error: `vertexStag` is not a shader capability; the capabilities are the members of `ldc.dcompute.Capability`: `shader`, `vertexStage`,
@fragment __vector(float[4]) f(@input __vector(float[4]) c) { return c; }

//--- baddomain.d
@compute(CompileFor.deviceOnly) module baddomain;
import ldc.dcompute;
// CHECK: Error: `-capabilities=cpu:avx2`: `cpu` is not a capability domain; the domains are `shader`
@fragment __vector(float[4]) f(@input __vector(float[4]) c) { return c; }

//--- stage.d
@compute(CompileFor.deviceOnly) module stage;
import ldc.dcompute;
struct V { @builtin(Builtin.position) __vector(float[4]) position; }
// CHECK: stage.d(5): Error: `@vertex` entry point `tri` is a vertex shader, which the profile `gl330` does not grant (`vertexStage`)
@_profiles("gl330") @vertex V tri() { V v; return v; }

//--- intinput.d
@compute(CompileFor.deviceOnly) module intinput;
import ldc.dcompute;
struct V { @builtin(Builtin.position) __vector(float[4]) position; }
// CHECK: intinput.d(5): Error: `@vertex` parameter `cell` is an integer vertex input, which the profile `narrow` does not grant (`intVertexInputs`)
@_profiles("narrow") @vertex V tri(@input int cell) { V v; v.position = __vector(float[4])(cast(float) cell); return v; }
