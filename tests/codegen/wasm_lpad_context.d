// Since LLVM 24 (llvm/llvm-project#222747) a Wasm landing pad asks
// `_Unwind_GetWasmLPadContext()` for the address of its context, as libunwind
// exports it. druntime inlines what it needs of libunwind, so it defines that
// function too: without it, every wasm program with a `catch` fails to link.

// REQUIRES: target_WebAssembly, atleast_llvm24

// RUN: %ldc -mtriple=wasm32-unknown-wasip1 -output-s -of=%t.s %s
// RUN: FileCheck %s < %t.s
// RUN: %ldc -mtriple=wasm32-unknown-wasip1 -output-ll -of=%t-rt.ll %runtimedir/src/rt/dwarfeh.d
// RUN: FileCheck --check-prefix=RT %s < %t-rt.ll

void mayThrow();

int caught()
{
    try
        mayThrow();
    catch (Exception e)
        return 1;
    return 0;
}

// CHECK-LABEL: {{^}}_D17wasm_lpad_context6caughtFZi:
// CHECK: call _Unwind_GetWasmLPadContext

// RT: define {{.*}}ptr @_Unwind_GetWasmLPadContext()
// RT-NEXT: ret ptr @__wasm_lpad_context
