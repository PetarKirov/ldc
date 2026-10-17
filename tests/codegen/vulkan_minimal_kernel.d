// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_out -output-o %s
// RUN: spirv-dis vulkan_out_vulkan130_64.spv -o - | FileCheck %s

@compute(CompileFor.deviceOnly) module vulkan_minimal_kernel;
import ldc.dcompute;

// The kernel's body folds into its entry point: Vulkan SPIR-V has no linkage,
// so every helper is internal and always inlined.
// CHECK: OpEntryPoint GLCompute %[[WRAPPER:[a-zA-Z0-9_]+]] "{{.*}}minimal_kernel{{.*}}"
// CHECK-NOT: OpFunctionCall
// CHECK: %[[WRAPPER]] = OpFunction %void
// CHECK: OpStore
// CHECK: OpReturn
// CHECK: OpFunctionEnd

@kernel() void minimal_kernel(GlobalPointer!float output) {
    *output = 67.36f;
}
