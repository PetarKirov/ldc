// druntime's `getStackBottom` takes the address of `__stack_high`, a symbol
// wasm-ld synthesizes in linear memory. It must be a plain global: a
// thread-local reference survives on the cooperatively threaded wasm32-wasip3
// (and with `+atomics`) as an `R_WASM_MEMORY_ADDR_TLS_SLEB` relocation, which
// wasm-ld rejects.

// REQUIRES: target_WebAssembly, atleast_llvm22

// RUN: %ldc -mtriple=wasm32-wasip3 -output-ll -of=%t.ll %runtimedir/src/core/thread/osthread.d
// RUN: FileCheck %s < %t.ll

// CHECK: @__stack_high = external {{(dso_local )?}}global i8
