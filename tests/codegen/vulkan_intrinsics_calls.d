// Device code may call `ldc.intrinsics` directly: LLVM intrinsics are
// target-neutral (`llvm.floor` lowers to GLSL.std.450 Floor on SPIR-V as it
// lowers to `roundss` on x86), so they are exempt from the rule that `@compute`
// code calls only functions of other `@compute` modules.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_intrinsics -output-o %s
// RUN: spirv-dis vulkan_intrinsics_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vulkan_intrinsics_vulkan130_64.spv

// CHECK-DAG: %[[GLSL:[a-zA-Z0-9_]+]] = OpExtInstImport "GLSL.std.450"
// CHECK-DAG: OpExtInst %{{[a-zA-Z0-9_]+}} %[[GLSL]] Floor
// CHECK-DAG: OpExtInst %{{[a-zA-Z0-9_]+}} %[[GLSL]] Sqrt

@compute(CompileFor.deviceOnly) module vulkan_intrinsics_calls;
import ldc.dcompute;
import ldc.intrinsics : llvm_floor, llvm_sqrt;

@kernel() void roundRoot(GlobalPointer!float io)
{
    *io = llvm_floor(*io) + llvm_sqrt(*io);
}
