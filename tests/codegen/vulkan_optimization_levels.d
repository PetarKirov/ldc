// A Vulkan module goes through LLVM's SPIR-V backend, which takes optimised
// IR like any other target: -O runs the default pipeline (here a constant
// loop folds away). At -O0 the floor is the always-inliner plus SROA and
// mem2reg, so the loop stays (vulkan_minimal_kernel.d checks that a helper
// still folds into the entry point).

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -O0 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_o0 -output-o %s
// RUN: spirv-dis vulkan_o0_vulkan130_64.spv -o - | FileCheck --check-prefix=O0 %s
// RUN: %ldc -c -m64 -O2 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_o2 -output-o %s
// RUN: spirv-dis vulkan_o2_vulkan130_64.spv -o - | FileCheck --check-prefix=O2 %s

// O0: OpLoopMerge

// O2-NOT: OpLoopMerge
// O2: %[[SIX:[a-zA-Z0-9_]+]] = OpConstant %{{[a-z]+}} 6
// O2: OpStore %{{[a-zA-Z0-9_]+}} %[[SIX]]

@compute(CompileFor.deviceOnly) module vulkan_optimization_levels;
import ldc.dcompute;

uint triangle(uint n)
{
    uint sum = 0;
    foreach (i; 0 .. n)
        sum += i;
    return sum;
}

@kernel() void store(GlobalPointer!uint output)
{
    *output = triangle(4);
}
