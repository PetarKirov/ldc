// `-mdcompute-manifest` writes the unit's shader entry points, sorted by
// name, with their stages, modules and profiles, once declarations are
// analysed, and stops: function bodies are never analysed, so one that only
// a real profile's compilation could compile does not stop it.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-manifest=%t.json %s
// RUN: FileCheck %s < %t.json

// CHECK: {"entryPoints":[{"name":"a","stage":"fragment","module":"vulkan_shader_manifest","profiles":["gl330","gles100"]},{"name":"m","stage":"fragment","module":"vulkan_shader_manifest","profiles":["gl330","vulkan1.3"]},{"name":"z","stage":"vertex","module":"vulkan_shader_manifest","profiles":["vulkan1.3"]}]}

@compute(CompileFor.deviceOnly) module vulkan_shader_manifest;
import ldc.dcompute;

alias float4 = __vector(float[4]);

struct V { @builtin(Builtin.position) float4 position; }

static assert(__traits(getTargetInfo, "shaderProfile") == "manifest");

@_profiles("vulkan1.3") @vertex V z() { V v; return v; }

@_profiles("vulkan1.3, gl330") @fragment float4 m()
{
    static assert(0, "a body is analysed only for a profile");
}

@fragment float4 a() { return float4(0.0f); }
