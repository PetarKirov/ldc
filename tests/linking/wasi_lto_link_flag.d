// A WASI program links through the C driver, which takes a sysroot's LTO
// builds of libc and libc++ (lib/<triple>/llvm-lto/) only for a link that
// says -flto: an LTO link passes it, in the flavour asked for.

// REQUIRES: target_WebAssembly

// RUN: not %ldc -mtriple=wasm32-unknown-wasip1 -flto=full -defaultlib= -gcc=false -v %s -of=%t-full.wasm | FileCheck --check-prefix=FULL %s
// RUN: not %ldc -mtriple=wasm32-unknown-wasip1 -flto=thin -defaultlib= -gcc=false -v %s -of=%t-thin.wasm | FileCheck --check-prefix=THIN %s
// RUN: not %ldc -mtriple=wasm32-unknown-wasip1 -defaultlib= -gcc=false -v %s -of=%t-none.wasm | FileCheck --check-prefix=NONE %s

// FULL: {{[/\\]}}false {{.*}}-flto=full
// THIN: {{[/\\]}}false {{.*}}-flto=thin
// NONE: {{[/\\]}}false{{ }}
// NONE-NOT: -flto

extern (C) void _start() {}
