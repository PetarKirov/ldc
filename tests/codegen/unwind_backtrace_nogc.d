// Where druntime defines backtrace() over _Unwind_Backtrace() (LDC on Darwin
// and glibc), DefaultTraceInfo's `@nogc` constructor calls it only if the
// call compiles there. backtrace() and the unwinder declarations it calls
// are `@nogc`, so traces come from the unwinder, not from the frame-pointer
// fallback, which finds one frame in an optimized druntime.

// REQUIRES: target_AArch64, target_X86

// RUN: %ldc -mtriple=arm64-apple-macos -output-ll -of=%t-darwin.ll %runtimedir/src/core/runtime.d
// RUN: FileCheck %s < %t-darwin.ll
// RUN: %ldc -mtriple=x86_64-unknown-linux-gnu -output-ll -of=%t-glibc.ll %runtimedir/src/core/runtime.d
// RUN: FileCheck %s < %t-glibc.ll

// CHECK-LABEL: define {{.*}}@_D4core7runtime16DefaultTraceInfo6__ctorM
// CHECK-NOT: {{^}}}
// CHECK: call {{.*}}@_D4core7runtime9backtraceF
