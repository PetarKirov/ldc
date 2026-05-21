# Agent Developer Guide: WASI/WebAssembly Dev Environment

This document describes the development environment, repositories, and compilation workflows for porting D compilers (`ldc` and `dmd`) and runtimes to the WebAssembly (`wasm32-wasip2`) target.

---

## 1. Directory Structure & Repositories

All repositories are located under `$REPOS`. When cloning new related repos, use `$REPOS/dlang` for D-ecosystem projects, `$REPOS/wasm` for WebAssembly tooling, or `$REPOS` itself for unrelated dependencies.

* **LDC Compiler & Runtime** (Current Workspace):
  `$REPOS/dlang/ldc`
  * D Runtime (`druntime`) source: `runtime/druntime/src/`
  * Phobos Standard Library (`phobos`) source: `runtime/phobos/`
  * Configuration: `runtime/CMakeLists.txt`
* **DMD Compiler**:
  `$REPOS/dlang/dmd`
* **Rust Compiler & Standard Library Source**:
  `$REPOS/rust/rust`
* **WebAssembly Core Specification**:
  `$REPOS/wasm/spec`
* **WASI specifications & proposals**:
  `$REPOS/wasm/WASI`
* **wasm-component-ld**:
  `$REPOS/wasm/wasm-component-ld`
  * Rust-based WebAssembly Component Model linker wrapper. Linked as a flake input in LDC's `flake.nix`.
* **nix-wasm-d**:
  `$REPOS/wasm/nix-wasm-d`
  * WebAssembly build environment and Nix derivation for D targets.
* **wit-bindgen**:
  `$REPOS/wasm/wit-bindgen`
  * A language binding generator for WebAssembly Interface Types (WIT).

---

## 2. Dev Environment Config & Nix Devshell

The environment relies on a Nix flake shell. All build tools and dependencies can be run through `nix develop`.

If you need to point a flake input to a local repository (e.g. for local linker development/debugging on `wasm-component-ld`), you can override the input using the `--override-input` flag:
```bash
nix develop --override-input wasm-component-ld $REPOS/wasm/wasm-component-ld
```

### Essential Env Variables & Paths
* **WASI Sysroot**: `$WASI_SYSROOT` points to the WASI sysroot directory (set by `flake.nix`).
* **Unwrapped Clang**: `$CLANG_UNWRAPPED` points to the unwrapped `clang` binary (set by `flake.nix`).
* **WASM compiler-rt builtins library**: `$COMPILER_RT_WASM32` points to the compiler-rt builtins library path (set by `flake.nix`).
* **Host compiler-rt base dir**: `$LDC_COMPILER_RT_BASE_DIR` is a tree of host compiler-rt libraries, to be passed to LDC's CMake as `-DCOMPILER_RT_BASE_DIR` (set by `flake.nix`).

### Critical Gotchas
1. **Nix Clang Wrapper Issue**: The default Nix-wrapped `clang` forces host header search paths (like `glibc`), causing host/target conflicts (e.g. `fatal error: 'gnu/stubs-32.h' file not found` when compiling target WebAssembly C files).
   * **Fix**: Use the *unwrapped* Clang compiler binary, which is available in the Nix development shell as `$CLANG_UNWRAPPED`.
2. **Nix Hardening Wrappers**: Nix injects unsupported hardening flags (e.g. `-fzero-call-used-regs=used-gpr`).
   * **Fix**: Disabled at the devshell level in `flake.nix` using `hardeningDisable = [ "all" ];`.

---

## 3. How to Build LDC Compiler

To build the host LDC compiler (`ldc2`):

### Configure the Build
Configure CMake using the Nix devshell. The command is wrapped in `bash -c '...'`
so `$LDC_COMPILER_RT_BASE_DIR` is expanded *inside* the dev shell (otherwise
the outer shell expands it to an empty string before `nix develop` runs):
```bash
nix develop -c bash -c '
  cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCOMPILER_RT_BASE_DIR="$LDC_COMPILER_RT_BASE_DIR"
'
```

### Compile the Compiler and Helper Tools
Run Ninja to build the compiler executable and the `ldc-build-runtime` helper
(used in section 4):
```bash
nix develop -c ninja -C build ldc2 ldc-build-runtime
```

---

## 4. How to Build & Run LDC Runtime

### Build Configuration Command
Configure CMake and compile the D runtime libraries (`druntime` and `phobos`)
using the unwrapped `clang` compiler. `ldc-build-runtime --ninja` invokes both
`cmake` and `ninja all` itself, so this single command does a full build. The
wrapping `bash -c '...'` ensures `$CLANG_UNWRAPPED`, `$WASI_SYSROOT`, etc. are
expanded *inside* the dev shell. The `--reset` flag wipes the existing
`ldc-build-runtime.tmp/` build dir first — drop it for incremental work:
```bash
nix develop -c bash -c '
  build/bin/ldc-build-runtime \
    --ldc build/bin/ldc2 \
    --ldcSrcDir . \
    --ninja \
    --targetSystem "WASI" \
    CMAKE_C_COMPILER="$CLANG_UNWRAPPED" \
    CMAKE_C_FLAGS="-target wasm32-wasip1 --sysroot=$WASI_SYSROOT" \
    --dFlags="-mtriple=wasm32-wasip2" \
    CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    --reset
'
```

### Incremental Rebuild
After editing druntime/phobos sources, you can re-run just `ninja` against the
already-configured build directory (no `--reset` and no re-configure):
```bash
nix develop -c ninja -C ldc-build-runtime.tmp
```

---

## 5. Compiling & Linking Executables

To compile a D source file (`hello.d`) targeting `wasm32-wasip2` and link it
against the compiled static libraries. Note: druntime imports live under
`runtime/druntime/src/` but phobos imports are flat under `runtime/phobos/`
(no `src/` subdirectory). `crt1.o` is wasi-libc's command-style entry stub:
```bash
nix develop -c bash -c '
  build/bin/ldc2 \
    -mtriple=wasm32-wasip2 \
    -Iruntime/druntime/src \
    -Iruntime/phobos \
    -L-Lldc-build-runtime.tmp/lib \
    -L-L"$WASI_SYSROOT/lib" \
    -L-lc \
    -L-lphobos2-ldc \
    -L-ldruntime-ldc \
    -L"$COMPILER_RT_WASM32" \
    --linker=wasm-component-ld \
    "$WASI_SYSROOT/lib/crt1.o" \
    hello.d -of=hello.wasm
'
```

### Running with Wasmtime
Run the produced component model module using `wasmtime`:
```bash
nix develop -c wasmtime hello.wasm
```

---

## 6. Artifacts and Task Tracking

Active task tracking documents and design plans are located in:
`$HOME/.gemini/antigravity-cli/brain/b58c30d8-934c-43c6-8e2f-e14ea9198755/`

* `implementation_plan.md`: Technical architectural decisions and changes.
* `task.md`: Checklist of currently planned tasks.

---

## 7. WebAssembly Target Reference

Rust and LLVM support several `wasm32-*` target profiles. When designing WebAssembly support for D, keep the following distinctions in mind:

| Target | Description | Environment / ABI | Key Characteristics |
| :--- | :--- | :--- | :--- |
| **`wasm32-unknown-unknown`** | Bare WebAssembly | None | Self-contained, makes zero assumptions about host. No entry point by default (`--no-entry`). Most standard library APIs return errors. |
| **`wasm32-unknown-emscripten`**| Emscripten WASM | JS/HTML | Relies on JavaScript/Emscripten glue code to emulate a POSIX environment. |
| **`wasm32-wasip1`** | WASI Preview 1 | WASIp1 API | POSIX-like system calls. Uses entry name `__main_void`. (Historically named `wasm32-wasi`). |
| **`wasm32-wasip1-threads`** | WASI Preview 1 with Threads | WASIp1 + threads | Uses shared linear memory and atomic instructions for thread support. |
| **`wasm32-wasip2`** | WASI Preview 2 | Component Model | Produces a WASIp2 Component. Compiles a core WASM module importing preview1 APIs and wraps it using `wasm-component-ld` with a preview1-to-preview2 adapter. Position-independent code (`relocation_model = Pic`) by default. |
| **`wasm32-wasip3`** | WASI Preview 3 | Component Model (Async) | Early support. Extends WASIp2 to support native async operations in the component model. |
| **`wasm32v1-none`** | Bare WASM v1 | None (bare-metal) | Target for bare-metal/non-OS execution using WASM v1 features. |
| **`wasm32-wali-linux-musl`** | WALI (Wasm on Linux) | Linux syscall translation | Compiles musl libc to WASM and intercepts/translates musl syscalls to host Linux syscalls. |
