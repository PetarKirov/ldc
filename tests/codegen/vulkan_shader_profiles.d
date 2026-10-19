// A compilation for a shader profile (`-mdcompute-profile`) emits only the
// entry points whose profiles list it: their own `@profiles`, else their
// module's, else, for a fragment entry point, `gl330` and `gles100`. The
// profile is a compile-time fact, `__traits(getTargetInfo, "shaderProfile")`.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-file-prefix=vk_profiles_vk -output-o %s
// RUN: spirv-dis vk_profiles_vk_vulkan130_64.spv -o - | FileCheck %s --check-prefix=VK
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -mdcompute-file-prefix=vk_profiles_gl -output-o %s
// RUN: spirv-dis vk_profiles_gl_vulkan130_64.spv -o - | FileCheck %s --check-prefix=GL
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vk_profiles_all -output-o %s
// RUN: spirv-dis vk_profiles_all_vulkan130_64.spv -o - | FileCheck %s --check-prefix=ALL

// VK-DAG: OpEntryPoint Vertex %vs "vs"
// VK-DAG: OpEntryPoint Fragment %both "both"
// VK-NOT: OpEntryPoint Fragment %legacy
// VK: %float_2 = OpConstant %float 2

// GL-DAG: OpEntryPoint Fragment %legacy "legacy"
// GL-DAG: OpEntryPoint Fragment %both "both"
// GL-NOT: OpEntryPoint Vertex
// GL: %float_3 = OpConstant %float 3

// ALL-DAG: OpEntryPoint Vertex %vs "vs"
// ALL-DAG: OpEntryPoint Fragment %legacy "legacy"
// ALL-DAG: OpEntryPoint Fragment %both "both"

@compute(CompileFor.deviceOnly) module vulkan_shader_profiles;
import ldc.dcompute;

alias float4 = __vector(float[4]);

struct V { @builtin(Builtin.position) float4 position; }

enum profile = __traits(getTargetInfo, "shaderProfile");

@_profiles("vulkan1.3") @vertex V vs() { V v; v.position = 0.0f; return v; }

@fragment float4 legacy() { return float4(1.0f); }

@_profiles("gl330,vulkan1.3") @fragment float4 both()
{
    static if (profile == "vulkan1.3")
        return float4(2.0f);
    else
        return float4(3.0f);
}
