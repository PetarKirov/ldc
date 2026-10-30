// A Vulkan target emits the newest SPIR-V its Vulkan version consumes, not
// the backend's default (1.4): Vulkan 1.0 takes SPIR-V 1.0, 1.1 takes 1.3,
// 1.2 takes 1.5, and 1.3 and later take 1.6.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_version -output-o %s
// RUN: spirv-dis vulkan_version_vulkan130_64.spv -o - | FileCheck --check-prefix=V13 %s
// RUN: spirv-val --target-env spv1.6 vulkan_version_vulkan130_64.spv
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-120 -mdcompute-file-prefix=vulkan_version -output-o %s
// RUN: spirv-dis vulkan_version_vulkan120_64.spv -o - | FileCheck --check-prefix=V12 %s
// RUN: spirv-val --target-env vulkan1.2 vulkan_version_vulkan120_64.spv
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-110 -mdcompute-file-prefix=vulkan_version -output-o %s
// RUN: spirv-dis vulkan_version_vulkan110_64.spv -o - | FileCheck --check-prefix=V11 %s
// RUN: spirv-val --target-env vulkan1.1 vulkan_version_vulkan110_64.spv
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-100 -mdcompute-file-prefix=vulkan_version -d-version=NoBuffers -output-o %s
// RUN: spirv-dis vulkan_version_vulkan100_64.spv -o - | FileCheck --check-prefix=V10 %s
// RUN: spirv-val --target-env vulkan1.0 vulkan_version_vulkan100_64.spv

// V13: ; Version: 1.6
// V12: ; Version: 1.5
// V11: ; Version: 1.3
// V10: ; Version: 1.0

@compute(CompileFor.deviceOnly) module vulkan_spirv_version;
import ldc.dcompute;

// Vulkan 1.0 has no physical storage buffers, which a buffer pointer needs.
version (NoBuffers)
    @kernel() void store() {}
else
    @kernel() void store(GlobalPointer!float output) {
        *output = 1.0f;
    }
