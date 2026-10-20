// A `SamplerState` parameter is a sampler of its own: a descriptor at the next
// binding in parameter order (or its `@binding`), as an image is, which
// `image.sample(sampler, uv)` reads through. `image.sample(uv)` keeps the
// shared sampler at binding 0. In a `@resources` struct it is flattened like
// any resource.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,fragmentStage,uniformBlocks,sampledImages -mdcompute-file-prefix=vulkan_samplers -output-o %s
// RUN: spirv-dis vulkan_samplers_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vulkan_samplers_vulkan130_64.spv

// CHECK-DAG: OpDecorate %atlas Binding 1
// CHECK-DAG: OpDecorate %photo Binding 2
// CHECK-DAG: OpDecorate %nearest Binding 3
// CHECK-DAG: OpDecorate %linear Binding 6
// CHECK-DAG: OpDecorate %sampler Binding 0
// CHECK-DAG: OpDecorate %clamp Binding 1
// CHECK-DAG: %[[S:[a-zA-Z0-9_]+]] = OpTypeSampler
// CHECK-DAG: %nearest = OpVariable %{{[a-zA-Z0-9_]+}} UniformConstant
// CHECK-DAG: %linear = OpVariable %{{[a-zA-Z0-9_]+}} UniformConstant
// CHECK-DAG: OpEntryPoint Fragment %canvas "canvas"
// CHECK-DAG: OpEntryPoint Fragment %material "material"

@compute(CompileFor.deviceOnly) module vulkan_sampler_states;

import ldc.dcompute;

alias float4 = __vector(float[4]);
alias float2 = __vector(float[2]);

@_profiles("vulkan1.3") @fragment float4 canvas(@input float2 uv, Sampler2D atlas,
    Sampler2D photo, SamplerState nearest, @binding(6) SamplerState linear)
    => atlas.sample(nearest, uv) * photo.sample(linear, uv) + atlas.sample(uv);

@resources struct Material
{
    SamplerState clamp;
    Sampler2D albedo;
}

@_profiles("vulkan1.3") @fragment float4 material(@input float2 uv, Material m)
    => m.albedo.sample(m.clamp, uv);
