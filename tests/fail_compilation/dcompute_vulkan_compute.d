// The compute stage's refusals: a `@kernel` under a profile that denies
// buffer device addresses, a compute entry point under a profile that
// denies the stage, a workgroup over the minimum size, a mutable
// module-scope variable, a write through a read-only storage buffer, a
// non-`void` compute entry point, and an `@input` parameter.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: split-file %s %t
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage,storageBuffers,uniformBlocks -I%t %t/kernel.d 2>&1 | FileCheck %t/kernel.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -capabilities=shader:shader,fragmentStage,looseUniforms,sampledImages -I%t %t/gl.d 2>&1 | FileCheck %t/gl.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage -I%t %t/big.d 2>&1 | FileCheck %t/big.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage -I%t %t/mutable.d 2>&1 | FileCheck %t/mutable.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage,storageBuffers,uniformBlocks -I%t %t/readonly.d 2>&1 | FileCheck %t/readonly.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage -I%t %t/nonvoid.d 2>&1 | FileCheck %t/nonvoid.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage -I%t %t/input.d 2>&1 | FileCheck %t/input.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage -I%t %t/product.d 2>&1 | FileCheck %t/product.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage -I%t %t/noprofile.d 2>&1 | FileCheck %t/noprofile.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage,storageBuffers,uniformBlocks -I%t %t/vec3.d 2>&1 | FileCheck %t/vec3.d

//--- kernel.d
@compute(CompileFor.deviceOnly) module kernmod;
import ldc.dcompute;
// CHECK: Error: `@kernel` function `k` packs its arguments into buffer device addresses, which the profile `vulkan1.3` does not grant (`bufferDeviceAddress`)
@kernel([4, 1, 1]) void k(GlobalPointer!float o) { *o = 1.0f; }

//--- gl.d
@compute(CompileFor.deviceOnly) module gl;
import ldc.dcompute;
// CHECK: Error: `@computeShader` entry point `fill` is a compute shader, which the profile `gl330` does not grant (`computeStage`)
@_profiles("gl330") @computeShader(4, 1, 1) void fill() {}

//--- big.d
@compute(CompileFor.deviceOnly) module big;
import ldc.dcompute;
// CHECK: Error: `@computeShader` entry point `fill` has workgroup size (256, 1, 1)
@_profiles("vulkan1.3") @computeShader(256, 1, 1) void fill() {}

//--- mutable.d
@compute(CompileFor.deviceOnly) module mutable;
import ldc.dcompute;
int[4] table = [10, 20, 30, 40];
// CHECK: Error: global variables not allowed in `@compute` code
@_profiles("vulkan1.3") @computeShader(4, 1, 1) void fill() { table[0] = 1; }

//--- readonly.d
@compute(CompileFor.deviceOnly) module readonly;
import ldc.dcompute;
struct Words { int[8] words; int count; }
// CHECK: Error: cannot write through read-only storage buffer parameter `input_` (`Access.read`)
@_profiles("vulkan1.3") @computeShader(4, 1, 1)
void fill(StorageBuffer!(Words, Access.read) input_) { (*input_).words[0] = 1; }

//--- nonvoid.d
@compute(CompileFor.deviceOnly) module nonvoid;
import ldc.dcompute;
// CHECK: Error: `@computeShader` function `fill` cannot return `int`: a compute entry point returns `void`
@_profiles("vulkan1.3") @computeShader(4, 1, 1) int fill() { return 1; }

//--- input.d
@compute(CompileFor.deviceOnly) module inputmod;
import ldc.dcompute;
// CHECK: Error: `@computeShader` parameter `x` is an `@input`; a compute entry point's parameters are resources or built-ins
@_profiles("vulkan1.3") @computeShader(4, 1, 1) void fill(@input int x) {}

//--- product.d
@compute(CompileFor.deviceOnly) module product;
import ldc.dcompute;
// CHECK: Error: `@computeShader` entry point `fill` has workgroup size (16, 16, 1)
@_profiles("vulkan1.3") @computeShader(16, 16, 1) void fill() {}

//--- noprofile.d
@compute(CompileFor.deviceOnly) module noprofile;
import ldc.dcompute;
// CHECK: Error: `@computeShader` entry point `fill` declares no profiles, and no profile grants the compute stage by default
@computeShader(4, 1, 1) void fill() {}

//--- vec3.d
@compute(CompileFor.deviceOnly) module vec3mod;
import ldc.dcompute;
struct P { __vector(float[3])[2] pts; float w; }
// CHECK: Error: `@computeShader` storage buffer field `pts` of `o` holds a vector of three components
@_profiles("vulkan1.3") @computeShader(4, 1, 1) void fill(StorageBuffer!P o) { (*o).w = 1.0f; }
