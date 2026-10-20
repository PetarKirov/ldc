// Every element of a strided block array is read, element 0 included: it is
// the array's own address, one index into the array the backend makes of
// it, at -O0 and at -O2. And a struct that is a uniform block and a
// push-constant block keeps its name in both.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O0 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-resources=blocks -mdcompute-file-prefix=vk_elements0 -output-o %s
// RUN: spirv-val --target-env vulkan1.3 vk_elements0_vulkan130_64.spv
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-resources=blocks -mdcompute-file-prefix=vk_elements2 -output-o %s
// RUN: spirv-val --target-env vulkan1.3 vk_elements2_vulkan130_64.spv
// RUN: spirv-dis vk_elements2_vulkan130_64.spv -o - | FileCheck %s

// CHECK-DAG: OpDecorate %{{[a-zA-Z0-9_]+}} ArrayStride 16
// CHECK-DAG: OpName %{{[a-zA-Z0-9_]+}} "S"
// CHECK-NOT: OpName %{{[a-zA-Z0-9_]+}} "S.

@compute(CompileFor.deviceOnly) module vulkan_resources_array_elements;
import ldc.dcompute;

alias float4 = __vector(float[4]);

struct Light { float[4] weights; float gain; }
struct S { float g; float h; }

@_profiles("vulkan1.3") @fragment float4 f(@input float4 c, UniformBlock!Light light,
    UniformBlock!S u, PushConstants!S p)
    => c * (light.weights[0] + light.weights[1] + light.weights[2] + light.weights[3]
        + light.gain + u.g + p.h);
