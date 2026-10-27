// A static library of link-time-optimization objects takes its archive
// format from the target, not from the host: wasm-ld misreads a Darwin
// archive's padded members.

// REQUIRES: target_WebAssembly, target_X86

// RUN: %ldc -lib -flto=full -mtriple=wasm32-unknown-wasi %s -of=%t-wasm.a
// RUN: %ldc -lib -flto=full -mtriple=x86_64-apple-macos %s -of=%t-darwin.a
// RUN: not grep -q __.SYMDEF %t-wasm.a
// RUN: grep -q __.SYMDEF %t-darwin.a

extern (C) int answer() { return 42; }
