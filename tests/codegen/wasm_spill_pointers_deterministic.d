// The pass that spills pointers to the stack for the GC on wasm
// (gen/passes/WasmPointersSpill.cpp) is deterministic: the order of its
// spill slots and of the edges it splits does not follow the addresses of
// the values involved, so compiling the same module twice gives the same
// object. Phobos' gammafunction (many `real` temporaries stored and
// reloaded) differed between compiles before, whenever the compiler's
// allocator (mimalloc in the Nix builds) placed its values differently.

// REQUIRES: target_WebAssembly

// RUN: %ldc -mtriple=wasm32-unknown-wasip2 -O3 -release -c -of=%t-1.o %runtimedir/../phobos/std/internal/math/gammafunction.d
// RUN: %ldc -mtriple=wasm32-unknown-wasip2 -O3 -release -c -of=%t-2.o %runtimedir/../phobos/std/internal/math/gammafunction.d
// RUN: %ldc -mtriple=wasm32-unknown-wasip2 -O3 -release -c -of=%t-3.o %runtimedir/../phobos/std/internal/math/gammafunction.d
// RUN: %ldc -mtriple=wasm32-unknown-wasip2 -O3 -release -c -of=%t-4.o %runtimedir/../phobos/std/internal/math/gammafunction.d
// RUN: %ldc -mtriple=wasm32-unknown-wasip2 -O3 -release -c -of=%t-5.o %runtimedir/../phobos/std/internal/math/gammafunction.d
// RUN: cmp %t-1.o %t-2.o
// RUN: cmp %t-1.o %t-3.o
// RUN: cmp %t-1.o %t-4.o
// RUN: cmp %t-1.o %t-5.o
