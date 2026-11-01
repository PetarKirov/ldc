// -fmacro-prefix-map (and -ffile-prefix-map) rewrite `__FILE__` in C code,
// headers included, as in D code: the C preprocessor gets the maps.

// UNSUPPORTED: Windows

// RUN: %ldc -fmacro-prefix-map=%S=/src -output-ll -of=%t.ll %s
// RUN: FileCheck %s < %t.ll
// RUN: FileCheck %s --check-prefix=NODIR -DDIR=%S < %t.ll

// CHECK-DAG: c"/src{{/|\\}}file_prefix_map_importc.c\00"
// CHECK-DAG: c"/src{{/|\\}}inputs{{/|\\}}file_prefix_map_importc.h\00"
// NODIR-NOT: c"[[DIR]]

#include "inputs/file_prefix_map_importc.h"

const char *file(void) { return __FILE__; }
