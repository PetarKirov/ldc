// A vertex entry point has no default profile: with no `@profiles` of its own
// or its module's, it fails.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 %s 2>&1 | FileCheck %s

// CHECK: dcompute_vulkan_vertex_profiles.d(13): Error: `@vertex` entry point `v` declares no profiles, and no profile is the default for the vertex stage; mark it, or its module, `@profiles(...)`

@compute(CompileFor.deviceOnly) module dcompute_vulkan_vertex_profiles;
import ldc.dcompute;
struct V { @builtin(Builtin.position) __vector(float[4]) position; }

@vertex V v() { V r; return r; }
