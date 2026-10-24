// Each WASI triple predefines `WASI`, `Posix`, `CRuntime_WASI` and the
// identifier of its own preview, and none of the others.

// REQUIRES: target_WebAssembly

// RUN: %ldc -c -o- %s -mtriple=wasm32-wasi -d-version=Expect_WASIp1
// RUN: %ldc -c -o- %s -mtriple=wasm32-unknown-wasi -d-version=Expect_WASIp1

version (WASI) {} else static assert(0);
version (Posix) {} else static assert(0);
version (CRuntime_WASI) {} else static assert(0);

version (Expect_WASIp1) { version (WASIp1) {} else static assert(0); }
else version (WASIp1) static assert(0);

version (Expect_WASIp2) { version (WASIp2) {} else static assert(0); }
else version (WASIp2) static assert(0);

version (Expect_WASIp3) { version (WASIp3) {} else static assert(0); }
else version (WASIp3) static assert(0);
