// The preview-specific WASI triples (LLVM 22+) predefine `WASI`, `Posix`,
// `CRuntime_WASI` and the identifier of their own preview only.

// REQUIRES: target_WebAssembly, atleast_llvm22

// RUN: %ldc -c -o- %S/wasi_versions.d -mtriple=wasm32-wasip1 -d-version=Expect_WASIp1
// RUN: %ldc -c -o- %S/wasi_versions.d -mtriple=wasm32-wasip2 -d-version=Expect_WASIp2
// RUN: %ldc -c -o- %S/wasi_versions.d -mtriple=wasm32-wasip3 -d-version=Expect_WASIp3
