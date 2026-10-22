// Module-scope device data has exactly two forms: an `immutable` table,
// lowered to a `Private` variable holding its initializer (the one array
// literal device code allows), and a `Workgroup!T`, lowered to a
// `Workgroup` variable with no initializer. A workgroup barrier is
// `OpControlBarrier` at Workgroup scope with `AcquireRelease |
// WorkgroupMemory` semantics.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage,storageBuffers,workgroupMemory,atomics,uniformBlocks -mdcompute-file-prefix=vk_wg -output-o %s
// RUN: spirv-dis vk_wg_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vk_wg_vulkan130_64.spv

// CHECK-DAG: %{{[a-zA-Z0-9_]+}} = OpVariable %{{[a-zA-Z0-9_]+}} Private
// CHECK-DAG: %{{[a-zA-Z0-9_]+}} = OpVariable %{{[a-zA-Z0-9_]+}} Workgroup
// CHECK: OpControlBarrier %int_2 %int_2 %int_264

@compute(CompileFor.deviceOnly) module vulkan_compute_workgroup;
import ldc.dcompute;

immutable int[4] table = [10, 20, 30, 40];
Workgroup!(int[4]) scratch;

pragma(LDC_intrinsic, "llvm.spv.group.memory.barrier.with.group.sync")
void spvBarrier() @safe pure nothrow @nogc;

pragma(LDC_atomic_rmw, "add") int atomicAdd_(T)(T* ptr, T val, int ordering) @safe pure nothrow @nogc;

@_profiles("vulkan1.3") @computeShader(4, 1, 1)
void fill(@builtin(Builtin.localInvocationIndex) int li)
{
    scratch[li] = table[li];
    spvBarrier();
    auto prev = atomicAdd_!int(&scratch[3 - li], 1, 2);
}
