// A uniform's SPIR-V type carries what its D type means to the host that sets
// it: an `int` is a signed integer, and a struct's members are named after its
// fields.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_uniform_types -output-o %s
// RUN: spirv-dis vulkan_uniform_types_vulkan130_64.spv -o - | FileCheck %s

@compute(CompileFor.deviceOnly) module vulkan_fragment_uniform_types;
import ldc.dcompute;

alias float3 = __vector(float[3]);
alias float4 = __vector(float[4]);
alias int2 = __vector(int[2]);

// CHECK-DAG: OpMemberName %Light 0 "gain"
// CHECK-DAG: OpMemberName %Light 1 "count"
// CHECK-DAG: OpMemberName %Light 2 "colour"
// CHECK-DAG: OpMemberName %Light 3 "cell"
// CHECK-DAG: OpMemberName %Light 4 "weights"
// CHECK-DAG: [[sint:%[a-zA-Z0-9_]+]] = OpTypeInt 32 1
// CHECK-NOT: OpTypeInt 32 0
// CHECK-DAG: [[sint2:%[a-zA-Z0-9_]+]] = OpTypeVector [[sint]] 2
// CHECK-DAG: %Light = OpTypeStruct %float [[sint]] %v3float [[sint2]] %{{[a-zA-Z0-9_]+}}
// CHECK-DAG: %n = OpVariable %{{[a-zA-Z0-9_]+}} UniformConstant
// CHECK-DAG: %light = OpVariable %{{[a-zA-Z0-9_]+}} UniformConstant
// CHECK-DAG: %colour = OpVariable %{{[a-zA-Z0-9_]+}} Input

struct Light
{
    float gain;
    int count;
    float3 colour;
    int2 cell;
    float[3] weights;
}

@fragment float4 tint(@input float3 colour, @uniform int n, @uniform Light light)
{
    const s = light.gain * cast(float) (light.count + light.cell[1] + n) + light.weights[2];
    return float4(colour[0] * s + light.colour[1]);
}
