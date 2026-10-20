// Entry points of every stage share one module, where a vertex stage's
// push-constant block and a fragment stage's input may have one name: they
// are two variables, each named so in SPIR-V.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -mdcompute-file-prefix=vk_names -output-o %s
// RUN: spirv-val --target-env vulkan1.3 vk_names_vulkan130_64.spv
// RUN: spirv-dis vk_names_vulkan130_64.spv -o - | FileCheck %s

// CHECK-DAG: OpName %[[PUSH:[a-zA-Z0-9_]+]] "view"
// CHECK-DAG: OpName %[[INPUT:[a-zA-Z0-9_]+]] "view"
// CHECK-DAG: %[[PUSH]] = OpVariable %{{[a-zA-Z0-9_]+}} PushConstant
// CHECK-DAG: %[[INPUT]] = OpVariable %{{[a-zA-Z0-9_]+}} Input

@compute(CompileFor.deviceOnly) module vulkan_interface_names_by_stage;
import ldc.dcompute;

alias float4 = __vector(float[4]);

struct P { float s; }
struct Out { @builtin(Builtin.position) float4 position; }

@_profiles("vulkan1.3") @vertex Out v(PushConstants!P view)
{
    Out o;
    o.position = float4(view.s);
    return o;
}

@_profiles("vulkan1.3") @fragment float4 f(@input float4 view) => view;
