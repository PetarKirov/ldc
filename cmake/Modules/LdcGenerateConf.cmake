# cmake/Modules/LdcGenerateConf.cmake
# Shared module to generate the LDC configuration fragments (ldc2.conf/).
# Expected to be included by the root CMakeLists.txt and runtime/CMakeLists.txt.
#
# Caller must provide the following variables:
# - LDC_SRC_DRUNTIME_DIR
# - LDC_SRC_PHOBOS_DIR
# - LDC_SRC_JIT_RT_DIR
# - LDC_BIN_IMPORT_DIR
# - INCLUDE_INSTALL_DIR
# - COMPILER_RT_LIBDIR_CONFIG (optional)

set(switches)
list(APPEND switches "-defaultlib=phobos2-ldc,druntime-ldc")

makeConfSection(NAME "30-compiler" SECTION "default"
    BUILD
    SWITCHES ${switches}
    # -defaultlib is configured in runtime/CMakeLists.txt
    POST_SWITCHES
        "-I${LDC_SRC_DRUNTIME_DIR}"
        "-I${LDC_BIN_IMPORT_DIR}"
        "-I${LDC_SRC_PHOBOS_DIR}"
        "-I${LDC_SRC_JIT_RT_DIR}"

    INSTALL
    SWITCHES ${switches}
    POST_SWITCHES "-I${INCLUDE_INSTALL_DIR}"
)

set(wasm_switches)
# Default wasm stack is only 64kb, this is rather small, let's bump it to 1mb
list(APPEND wasm_switches -L-z -Lstack-size=1048576)
# Protect from stack overflow overwriting global memory
list(APPEND wasm_switches -L--stack-first)
if(LDC_WITH_LLD)
    list(APPEND wasm_switches -link-internally)
endif()
# LLD 8+ requires (new) `--export-dynamic` for WebAssembly (https://github.com/ldc-developers/ldc/issues/3023).
list(APPEND wasm_switches -L--export-dynamic)

set(wasm_baremetal_switches -defaultlib= ${wasm_switches})

# Bare WebAssembly and Emscripten
makeConfSection(NAME "55-target-wasm-baremetal"
    SECTION "^wasm(32|64)-unknown-(unknown|emscripten)($|-)"
    SWITCHES ${wasm_baremetal_switches}
    LIB_DIRS OVERRIDE
)

# WASI (wasip1, wasip2, etc.)
makeConfSection(NAME "56-target-wasi"
    SECTION "^wasm(32|64)-.*wasi"
    SWITCHES ${wasm_switches}
)

if(DEFINED COMPILER_RT_LIBDIR_CONFIG)
    message(STATUS "Adding ${COMPILER_RT_LIBDIR_CONFIG} to lib-dirs in configuration file")

    makeConfSection(NAME "70-compiler-rt" SECTION "default"
        BUILD
        LIB_DIRS ${COMPILER_RT_LIBDIR_CONFIG}

        INSTALL
        LIB_DIRS ${COMPILER_RT_LIBDIR_CONFIG}
    )
endif()
