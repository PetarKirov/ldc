// Since LLVM 24, a wasm module selects Wasm exception handling with the
// "exception-model" module flag (llvm/llvm-project#232977).

// REQUIRES: target_WebAssembly, atleast_llvm24

// RUN: %ldc -mtriple=wasm32-unknown-wasip1 -output-ll -of=%t.ll %s
// RUN: FileCheck %s < %t.ll

void foo() {}

// CHECK: !{i32 1, !"exception-model", !"wasm"}
