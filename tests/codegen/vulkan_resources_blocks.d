// On Vulkan (resources lowered to blocks: `uniformBlocks` granted) a `UniformBlock!T` is a uniform
// block whose type is `T`, laid out by std140; a `PushConstants!T` a
// push-constant block laid out by std430; and the `@uniform` parameters the
// members of the entry point's default uniform block, `<entry>Uniforms` of
// type `<entry>UniformsBlock`. Bindings follow parameter order from 1,
// skipping a fixed `@binding`; a `@resources` struct stands for its fields.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -mdcompute-file-prefix=vk_res -output-o %s
// RUN: spirv-dis vk_res_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vk_res_vulkan130_64.spv

// CHECK-NOT: OpTypeInt 8
// CHECK-DAG: OpName %[[LIGHT:[a-zA-Z0-9_]+]] "Light"
// CHECK-DAG: OpDecorate %[[LIGHT]] Block
// CHECK-DAG: OpMemberDecorate %[[LIGHT]] 0 Offset 0
// CHECK-DAG: OpMemberDecorate %[[LIGHT]] 1 Offset 12
// CHECK-DAG: OpMemberDecorate %[[LIGHT]] 2 Offset 16
// CHECK-DAG: OpMemberDecorate %[[LIGHT]] 3 Offset 80
// CHECK-DAG: OpMemberName %[[LIGHT]] 1 "gain"
// CHECK-DAG: OpMemberName %[[LIGHT]] 2 "weights"
// CHECK-DAG: OpDecorate %{{[a-zA-Z0-9_]+}} ArrayStride 16
// CHECK-DAG: OpDecorate %light DescriptorSet 0
// CHECK-DAG: OpDecorate %light Binding 1
// CHECK-DAG: OpDecorate %sceneUniforms Binding 2
// CHECK-DAG: OpDecorate %fog Binding 5
// CHECK-DAG: OpDecorate %tint Binding 3
// CHECK-DAG: OpName %{{[a-zA-Z0-9_]+}} "sceneUniformsBlock"
// CHECK-DAG: OpName %[[PUSH:[a-zA-Z0-9_]+]] "Push"
// CHECK-DAG: OpDecorate %[[PUSH]] Block
// CHECK-DAG: OpMemberDecorate %[[PUSH]] 1 Offset 12
// CHECK-DAG: %pc = OpVariable %{{[a-zA-Z0-9_]+}} PushConstant
// CHECK-DAG: %light = OpVariable %{{[a-zA-Z0-9_]+}} Uniform

@compute(CompileFor.deviceOnly) module vulkan_resources_blocks;
import ldc.dcompute;

alias float2 = __vector(float[2]);
alias float3 = __vector(float[3]);
alias float4 = __vector(float[4]);

struct Light
{
    float3 colour;
    float gain;
    float[4] weights;
    float4 tint;
}

struct Push
{
    float3 offset;
    float scale;
}

struct Fog
{
    float density;
}

@resources struct Material
{
    @binding(5) UniformBlock!Fog fog;
    UniformBlock!Fog tint;
}

@_profiles("vulkan1.3") @fragment float4 scene(@input float2 uv, UniformBlock!Light light,
    @uniform float exposure, PushConstants!Push pc, Material m, @uniform float bias)
{
    const s = light.gain * light.weights[2] * exposure * pc.scale + bias
        + m.fog.density + m.tint.density;
    return light.tint * s + float4(light.colour[0] + pc.offset[1] + uv[0]);
}
