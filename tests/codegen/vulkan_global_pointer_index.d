// Indexing a GlobalPointer, optimised: the pointers are buffer device
// addresses, and `p[i]` steps them by `i` elements (an OpPtrAccessChain with
// the invocation's index), never dropping the index.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_gpi -output-o %s
// RUN: spirv-dis vulkan_gpi_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vulkan_gpi_vulkan130_64.spv

// CHECK: OpCapability PhysicalStorageBufferAddresses
// CHECK: OpMemoryModel PhysicalStorageBuffer64 GLSL450
// CHECK: OpDecorate %[[PF:[a-zA-Z0-9_]+]] ArrayStride 4
// CHECK: %[[ID:[0-9]+]] = OpLoad %v3{{u?}}int %{{.*}}GlobalInvocationId
// CHECK: %[[X:[0-9]+]] = OpCompositeExtract %{{u?}}int %[[ID]] 0
// CHECK: %[[I:[0-9]+]] = OpSConvert %{{u?}}long %[[X]]
// CHECK-COUNT-3: OpPtrAccessChain %[[PF]] %{{[0-9]+}} %[[I]]

@compute(CompileFor.deviceOnly) module vulkan_global_pointer_index;
import ldc.dcompute;

pragma(LDC_intrinsic, "llvm.spv.thread.id.i32")
int threadId(int dim) @safe pure nothrow @nogc;

@kernel([64, 1, 1]) void add(GlobalPointer!float a, GlobalPointer!float b,
                             GlobalPointer!float c) {
    const i = threadId(0);
    c[i] = a[i] + b[i];
}
