// A `@vectorType` struct has exactly one field, a `__vector`.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,fragmentStage,uniformBlocks %s 2>&1 | FileCheck %s

// CHECK: dcompute_vulkan_vector_type.d([[@LINE+4]]): Error: `@vectorType` struct `dcompute_vulkan_vector_type.Two` must have exactly one field, a `__vector`
@compute(CompileFor.deviceOnly) module dcompute_vulkan_vector_type;
import ldc.dcompute;

@vectorType struct Two { __vector(float[4]) v; float w; }

@_profiles("vulkan1.3") @fragment __vector(float[4]) fs(@input Two t) => t.v;
