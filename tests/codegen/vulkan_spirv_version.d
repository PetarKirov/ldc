// The Vulkan target emits the SPIR-V version its triple names (1.6), not the
// backend's default (1.4).

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_version -output-o %s
// RUN: spirv-dis vulkan_version_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env spv1.6 vulkan_version_vulkan130_64.spv

// CHECK: ; Version: 1.6

@compute(CompileFor.deviceOnly) module vulkan_spirv_version;
import ldc.dcompute;

@kernel() void store(GlobalPointer!float output) {
    *output = 1.0f;
}
