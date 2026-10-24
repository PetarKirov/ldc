// The Wasm personality's prototype is the one LLVM 24's WasmEHPrepare calls
// it with (llvm/llvm-project#209282): `int personality(void* exception)`.

// REQUIRES: target_WebAssembly

// RUN: %ldc -mtriple=wasm32-unknown-wasip1 -output-ll -of=%t.ll %s
// RUN: FileCheck %s < %t.ll

void mayThrow();

// CHECK: define {{.*}}@{{.*}}catches{{.*}} personality ptr @__gxx_wasm_personality_v0
int catches()
{
    try
        mayThrow();
    catch (Exception)
        return 1;
    return 0;
}

// CHECK: declare i32 @__gxx_wasm_personality_v0(ptr)
