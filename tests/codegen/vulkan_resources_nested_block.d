// A struct that is both a uniform block and a member of another is two
// types: SPIR-V does not let a `Block` nest in another. The block keeps the
// struct's name; the member's type is a copy without the decoration.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-resources=blocks -mdcompute-file-prefix=vk_nested -output-o %s
// RUN: spirv-dis vk_nested_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vk_nested_vulkan130_64.spv

// CHECK-DAG: OpName %[[INNER:[a-zA-Z0-9_]+]] "Inner"
// CHECK-DAG: OpDecorate %[[INNER]] Block
// CHECK-DAG: OpName %[[OUTER:[a-zA-Z0-9_]+]] "Outer"
// CHECK-DAG: OpDecorate %[[OUTER]] Block
// CHECK-DAG: %[[OUTER]] = OpTypeStruct %[[MEMBER:[a-zA-Z0-9_]+]] %float
// CHECK-NOT: OpDecorate %[[MEMBER]] Block

@compute(CompileFor.deviceOnly) module vulkan_resources_nested_block;
import ldc.dcompute;

alias float4 = __vector(float[4]);

struct Inner { float gain; }
struct Outer { Inner inner; float k; }

@_profiles("vulkan1.3") @fragment float4 f(@input float4 c, UniformBlock!Inner a, UniformBlock!Outer b)
    => c * (a.gain + b.inner.gain + b.k);
