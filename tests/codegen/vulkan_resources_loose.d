// On OpenGL (`-capabilities=shader:shader,fragmentStage,looseUniforms,sampledImages`, the default) a block is one plain
// uniform per field of its `T`, named after the field, and a `@uniform`
// stays a plain uniform.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -mdcompute-file-prefix=vk_loose -output-o %s
// RUN: spirv-dis vk_loose_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env spv1.6 vk_loose_vulkan130_64.spv

// CHECK-DAG: %gain = OpVariable %{{[a-zA-Z0-9_]+}} UniformConstant
// CHECK-DAG: %scale = OpVariable %{{[a-zA-Z0-9_]+}} UniformConstant
// CHECK-DAG: %exposure = OpVariable %{{[a-zA-Z0-9_]+}} UniformConstant
// CHECK-NOT: Block

@compute(CompileFor.deviceOnly) module vulkan_resources_loose;
import ldc.dcompute;

alias float2 = __vector(float[2]);
alias float4 = __vector(float[4]);

struct Light { float gain; }
struct Push { float scale; }

@fragment float4 scene(@input float2 uv, UniformBlock!Light light, @uniform float exposure,
    PushConstants!Push pc)
{
    return float4(light.gain * exposure * pc.scale * uv[0]);
}
