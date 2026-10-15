// Entry points that agree on an interface name's location or binding share
// one variable carrying it.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_fragment_shared -output-o %s
// RUN: spirv-dis vulkan_fragment_shared_vulkan130_64.spv -o - | FileCheck %s

@compute(CompileFor.deviceOnly) module vulkan_fragment_shared_interface;
import ldc.dcompute;

alias float2 = __vector(float[2]);
alias float4 = __vector(float[4]);

// CHECK-DAG: OpEntryPoint Fragment %{{[a-z0-9_]+}} "first"
// CHECK-DAG: OpEntryPoint Fragment %{{[a-z0-9_]+}} "second"
// CHECK-DAG: OpDecorate %uv Location 0
// CHECK-DAG: OpDecorate %c Location 1
// CHECK-DAG: OpDecorate %t0 Binding 1
// CHECK-DAG: OpDecorate %t1 Binding 2
// CHECK-DAG: OpDecorate %sampler Binding 0
// CHECK-DAG: OpDecorate %finalColor Location 0

@fragment float4 first(@input float2 uv, @input float4 c, Sampler2D t0, @uniform float a)
{
    return t0.sample(uv) * c * a;
}

@fragment float4 second(@input float2 uv, @input float4 c, Sampler2D t0, Sampler2D t1, @uniform float a)
{
    return t0.sample(uv) * t1.sample(uv) * c * a;
}
