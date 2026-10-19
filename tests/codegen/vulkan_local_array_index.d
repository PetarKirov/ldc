// A local table indexed by an `int` computes in 32 bits on Vulkan, optimised
// or not: Vulkan grants 64-bit integers only with the shaderInt64 feature, so
// neither the array's default initialisation (a loop the compiler emits) nor
// the index (a `size_t` in D) may bring the Int64 capability in.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O0 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_lai_O0 -output-o %s
// RUN: spirv-dis vulkan_lai_O0_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env spv1.6 vulkan_lai_O0_vulkan130_64.spv
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_lai_O2 -output-o %s
// RUN: spirv-dis vulkan_lai_O2_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env spv1.6 vulkan_lai_O2_vulkan130_64.spv

// CHECK-NOT: OpCapability Int64
// CHECK-NOT: OpTypeInt 64
// CHECK: OpFunction

@compute(CompileFor.deviceOnly) module vulkan_local_array_index;
import ldc.dcompute;

alias float4 = __vector(float[4]);

// Default-initialised (to NaN, so not by a memset), then filled.
@fragment float4 pick(@uniform int idx)
{
    float4[3] t;
    t[0] = float4(1.0f);
    t[1] = float4(2.0f);
    t[2] = float4(3.0f);
    return t[idx];
}

// Zero-initialised, which is a memset.
@fragment float4 count(@uniform int idx)
{
    int[4] n;
    n[idx & 3] = 1;
    return float4(cast(float) n[1]);
}
