// `-mdcompute-report-int64` names the source line of every 64-bit integer
// operation the entry points reach, through the functions they call; an
// `int` index widened only to address an array is not one.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-report-int64 -mdcompute-file-prefix=vk_int64 -output-o %s 2>&1 | FileCheck %s --implicit-check-not="64-bit integer operation"

// CHECK-DAG: vulkan_report_int64.d(20): 64-bit integer operation `i % 3LU` (`ulong`)
// CHECK-DAG: vulkan_report_int64.d(25): 64-bit integer operation `cast(ulong)idx + 1LU` (`ulong`)
// CHECK-DAG: vulkan_report_int64.d(34): 64-bit integer operation `cast(long)x` (`long`)
// CHECK-DAG: vulkan_report_int64.d(34): 64-bit integer operation `cast(float)cast(long)x` (`long`)

@compute(CompileFor.deviceOnly) module vulkan_report_int64;
import ldc.dcompute;

alias float4 = __vector(float[4]);

size_t wrap(size_t i)
{
    return i % 3;
}

float4 pick(int idx)
{
    size_t i = cast(size_t) idx + 1;
    float4[3] t;
    t[idx] = float4(1.0f);
    return t[wrap(i)];
}

// A conversion through a 64-bit integer computes in 64 bits too.
float whole(float x)
{
    return cast(float) cast(long) x;
}

@fragment float4 f(@uniform int idx, @uniform float x) { return pick(idx) * whole(x); }
