// dcompute's address spaces reach the Vulkan storage classes they name:
// Shared is workgroup memory and Constant is UniformConstant.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_as -output-ll -output-o %s && FileCheck %s < vulkan_as_vulkan130_64.ll

@compute(CompileFor.deviceOnly) module vulkan_addrspaces;
import ldc.dcompute;

// CHECK-LABEL: define{{.*}} @{{.*}}readAll
// CHECK-DAG: load float, ptr addrspace(3)
// CHECK-DAG: load float, ptr addrspace(2)
// CHECK-DAG: load float, ptr addrspace(1)
@kernel() void readAll(GlobalPointer!float output, SharedPointer!float s,
                       ConstantPointer!float c) {
    *output = *s + *c + *output;
}
