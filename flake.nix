{
  description = "LDC development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?rev=549bd84d6279f9852cae6225e372cc67fb91a4c1";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/triplet";
    wasm-component-ld = {
      url = "github:bytecodealliance/wasm-component-ld/v0.5.22";
      flake = false;
    };
  };
  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      perSystem =
        { config, pkgs, ... }:
        let
          # WASI sysroot: merge wasilibc libs and headers into a single tree
          wasi-sysroot = pkgs.symlinkJoin {
            name = "wasi-sysroot";
            paths = [
              pkgs.pkgsCross.wasi32.wasilibc
              pkgs.pkgsCross.wasi32.wasilibc.dev
            ];
          };

          # wasm-component-ld: linker wrapper that produces WASI components
          wasm-component-ld = pkgs.rustPlatform.buildRustPackage {
            pname = "wasm-component-ld";
            version = "0.5.22";
            src = inputs.wasm-component-ld;
            cargoLock.lockFile = "${inputs.wasm-component-ld}/Cargo.lock";
            doCheck = false; # tests require a full wasm toolchain
          };

          # compiler-rt static library for wasm32
          compiler-rt-wasm32 = pkgs.pkgsCross.wasi32.llvmPackages_22.compiler-rt;

          # Host compiler-rt, re-laid out as <root>/<major>/lib/linux/... so LDC's
          # CMakeLists.txt (which expects ${LLVM_LIBRARY_DIRS}/clang/<major>/lib/<os>)
          # can locate the builtins/sanitizer libraries when COMPILER_RT_BASE_DIR
          # is set to this tree.
          compiler-rt-host = pkgs.runCommand "ldc-compiler-rt-host" { } ''
            major=${pkgs.lib.versions.major pkgs.llvmPackages_22.compiler-rt.version}
            mkdir -p "$out/$major"
            ln -s ${pkgs.llvmPackages_22.compiler-rt}/lib "$out/$major/lib"
          '';
        in
        {
          devShells.default = pkgs.mkShell {
            hardeningDisable = [ "all" ];
            nativeBuildInputs = [
              # D bootstrap compiler and tools
              pkgs.ldc
              pkgs.dub
              pkgs.dtools

              # Build tools
              pkgs.cmake
              pkgs.ninja
              pkgs.git

              # LLVM and Clang tools
              pkgs.llvmPackages_22.llvm
              pkgs.llvmPackages_22.clang
              pkgs.llvmPackages_22.clang-unwrapped
              pkgs.llvmPackages_22.lld

              # Testing
              pkgs.python3
              pkgs.python3Packages.lit

              # WASI cross-compilation tooling
              wasm-component-ld
              pkgs.wasmtime
              pkgs.wasm-tools
              compiler-rt-wasm32
            ];

            buildInputs = [
              # Libraries and dependencies
              pkgs.llvmPackages_22.libllvm
              pkgs.zlib
              pkgs.zstd
              pkgs.libxml2
              pkgs.curl
            ];

            shellHook = ''
              export WASI_SYSROOT="${wasi-sysroot}"
              export CLANG_UNWRAPPED="${pkgs.llvmPackages_22.clang-unwrapped}/bin/clang"
              export COMPILER_RT_WASM32="${compiler-rt-wasm32}/lib/wasi/libclang_rt.builtins-wasm32.a"
              export LDC_COMPILER_RT_BASE_DIR="${compiler-rt-host}"
            '';
          };
        };
    };
}
