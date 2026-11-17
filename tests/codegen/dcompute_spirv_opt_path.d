// An optimised Vulkan compilation runs the spirv-opt -mdcompute-spirv-opt
// names, and with it empty, none: a build that names its tools runs no
// spirv-opt from PATH. A recording spirv-opt stands in for the real one.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: rm -rf %t && mkdir -p %t/named %t/searched %t/none
// RUN: printf '#!/bin/sh\necho "$@" > %t/named/called\n' > %t/named/spirv-opt
// RUN: printf '#!/bin/sh\necho "$@" > %t/searched/called-$$\n' > %t/searched/spirv-opt
// RUN: chmod +x %t/named/spirv-opt %t/searched/spirv-opt

// Named: that one runs, and the one on PATH does not.
// RUN: env PATH=%t/searched %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 \
// RUN:   -mdcompute-file-prefix=named -od=%t/named -output-o %s \
// RUN:   -mdcompute-spirv-opt=%t/named/spirv-opt
// RUN: FileCheck %s --check-prefix=NAMED < %t/named/called
// RUN: ls %t/searched | FileCheck %s --check-prefix=UNCALLED
// NAMED: -O {{.*}}named_vulkan130_64.spv -o {{.*}}named_vulkan130_64.spv

// Empty: none runs.
// RUN: env PATH=%t/searched %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 \
// RUN:   -mdcompute-file-prefix=none -od=%t/none -output-o %s -mdcompute-spirv-opt=
// RUN: ls %t/searched | FileCheck %s --check-prefix=UNCALLED
// UNCALLED-NOT: called

// Not given: the one on PATH, as before.
// RUN: env PATH=%t/searched %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 \
// RUN:   -mdcompute-file-prefix=searched -od=%t/searched -output-o %s
// RUN: cat %t/searched/called-* | FileCheck %s --check-prefix=SEARCHED
// SEARCHED: -O {{.*}}searched_vulkan130_64.spv

@compute(CompileFor.deviceOnly) module dcompute_spirv_opt_path;
import ldc.dcompute;

@kernel void k(GlobalPointer!float p) { *p = 1.0f; }
