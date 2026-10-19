// A `@vertex` function is a vertex-stage entry point. Its `@builtin`
// parameters read the stage's built-in inputs, its `@input` parameters are its
// vertex attributes, and it returns a struct whose `@builtin(Builtin.position)`
// field is the clip-space position and whose other fields are its outputs, at
// locations in field order. A vertex output and the fragment input it feeds
// share their name in one module: they are two variables, one of each
// direction.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_vertex -output-o %s
// RUN: spirv-dis vulkan_vertex_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vulkan_vertex_vulkan130_64.spv

// CHECK-DAG: OpEntryPoint Vertex %tri "tri"
// CHECK-DAG: OpEntryPoint Fragment %shade "shade"
// CHECK-DAG: OpDecorate %[[VI:[a-zA-Z0-9_]+]] BuiltIn VertexIndex
// CHECK-DAG: OpDecorate %[[II:[a-zA-Z0-9_]+]] BuiltIn InstanceIndex
// CHECK-DAG: OpDecorate %[[POS:[a-zA-Z0-9_]+]] BuiltIn Position
// CHECK-DAG: %[[VI]] = OpVariable %{{[a-zA-Z0-9_]+}} Input
// CHECK-DAG: %[[II]] = OpVariable %{{[a-zA-Z0-9_]+}} Input
// CHECK-DAG: %[[POS]] = OpVariable %{{[a-zA-Z0-9_]+}} Output
// CHECK-DAG: OpName %[[CO:[a-zA-Z0-9_]+]] "colour"
// CHECK-DAG: OpName %[[CI:[a-zA-Z0-9_]+]] "colour"
// CHECK-DAG: OpName %[[UO:[a-zA-Z0-9_]+]] "uv"
// CHECK-DAG: OpName %[[UI:[a-zA-Z0-9_]+]] "uv"
// CHECK-DAG: OpName %[[AT:[a-zA-Z0-9_]+]] "corner"
// CHECK-DAG: %[[CO]] = OpVariable %{{[a-zA-Z0-9_]+}} Output
// CHECK-DAG: %[[CI]] = OpVariable %{{[a-zA-Z0-9_]+}} Input
// CHECK-DAG: %[[UO]] = OpVariable %{{[a-zA-Z0-9_]+}} Output
// CHECK-DAG: %[[UI]] = OpVariable %{{[a-zA-Z0-9_]+}} Input
// CHECK-DAG: OpDecorate %[[CO]] Location 0
// CHECK-DAG: OpDecorate %[[UO]] Location 1
// CHECK-DAG: OpDecorate %[[CI]] Location 0
// CHECK-DAG: OpDecorate %[[UI]] Location 1
// CHECK-DAG: OpDecorate %[[AT]] Location 0
// CHECK-DAG: %[[SINT:[a-zA-Z0-9_]+]] = OpTypeInt 32 1
// CHECK-DAG: %[[SINT2:[a-zA-Z0-9_]+]] = OpTypeVector %[[SINT]] 2
// CHECK-DAG: OpName %[[CELL:[a-zA-Z0-9_]+]] "cell"
// CHECK-DAG: OpDecorate %[[CELL]] Location 1

@compute(CompileFor.deviceOnly) module vulkan_vertex_stage;
import ldc.dcompute;

alias float2 = __vector(float[2]);
alias float4 = __vector(float[4]);
alias int2 = __vector(int[2]);

struct Varyings
{
    @builtin(Builtin.position) float4 position;
    float4 colour;
    float2 uv;
}

@_profiles("vulkan1.3") @vertex Varyings tri(@builtin(Builtin.vertexIndex) int vertex,
                     @builtin(Builtin.instanceIndex) int instance,
                     @input float2 corner, @input int2 cell)
{
    Varyings v;
    float4 p = 1.0f;
    p[0] = corner[0] + cast(float) (instance + cell[0]);
    p[1] = corner[1] + cast(float) cell[1];
    v.position = p;
    v.colour = float4(cast(float) vertex);
    v.uv = corner;
    return v;
}

@_profiles("vulkan1.3") @fragment float4 shade(@input float4 colour, @input float2 uv)
{
    return colour * uv[0];
}
