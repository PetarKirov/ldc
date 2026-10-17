// Device code's control flow reaches SPIR-V structured: early returns and
// breaks out of nested conditions and loops, which leave regions with several
// exits, at every optimisation level.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O0 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_scf0 -output-o %s
// RUN: spirv-val --target-env vulkan1.3 vulkan_scf0_vulkan130_64.spv
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_scf2 -output-o %s
// RUN: spirv-val --target-env vulkan1.3 vulkan_scf2_vulkan130_64.spv
// RUN: spirv-dis vulkan_scf2_vulkan130_64.spv -o - | FileCheck %s

// CHECK: OpSelectionMerge
// CHECK: OpLoopMerge

@compute(CompileFor.deviceOnly) module vulkan_structured_control_flow;
import ldc.dcompute;

pragma(LDC_intrinsic, "llvm.spv.thread.id.i32")
int threadId(int dim) @safe pure nothrow @nogc;

float mask(float x, float y)
{
    if (x < 0 || y < 0) return 0;
    if (x > 1 && y > 1) return 1;
    return 0.5f;
}

float find(float x, float y, int n)
{
    float acc = 0;
    foreach (i; 0 .. n)
    {
        acc += x;
        if (acc > 1 && y > 0.5f) return acc;
        if (acc > 2) break;
        if (y < 0.1f) continue;
        acc *= 0.5f;
    }
    return -acc;
}

float grid(float x, float y)
{
    float s = 0;
    foreach (i; 0 .. 4)
        foreach (j; 0 .. 4)
        {
            if (i == j) continue;
            if (s > x && s > y) return s;
            s += 0.1f * i + 0.01f * j;
        }
    return s;
}

float sel(int k, float x, float y)
{
    switch (k)
    {
    case 0: return x;
    case 1: if (y > 0.5f) return y; goto case 2;
    case 2: return x * y;
    default: break;
    }
    return 0;
}

@kernel([64, 1, 1]) void run(GlobalPointer!float a, GlobalPointer!float b,
                             GlobalPointer!float c, int n) {
    const i = threadId(0);
    const x = a[i], y = b[i];
    c[i] = mask(x, y) + find(x, y, n) + grid(x, y) + sel(n, x, y);
}
