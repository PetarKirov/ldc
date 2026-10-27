// -fmacro-prefix-map rewrites the file names a program sees: `__FILE__`,
// `__FILE_FULL_PATH__`, and those passed to the runtime's error functions.
// -ffile-prefix-map also rewrites the debug info's.

// RUN: %ldc -fmacro-prefix-map=%S=/src -output-ll -of=%t.macro.ll %s
// RUN: FileCheck %s --check-prefix=MACRO < %t.macro.ll
// RUN: FileCheck %s --check-prefix=NODIR -DDIR=%S < %t.macro.ll

// RUN: %ldc -g -ffile-prefix-map=%S=/src -output-ll -of=%t.file.ll %s
// RUN: FileCheck %s --check-prefixes=MACRO,DEBUG < %t.file.ll
// RUN: FileCheck %s --check-prefix=NODIR -DDIR=%S < %t.file.ll

// The last matching map wins, as for -fdebug-prefix-map.
// RUN: %ldc -fmacro-prefix-map=%S=/first -fmacro-prefix-map=%S=/second -output-ll -of=%t.last.ll %s
// RUN: FileCheck %s --check-prefix=LAST < %t.last.ll

// RUN: not %ldc -ffile-prefix-map=nothing -o- %s 2>&1 | FileCheck %s --check-prefix=INVALID
// INVALID: invalid prefix map: nothing

// MACRO: c"/src{{/|\\\\}}file_prefix_map.d\00"
// DEBUG: !DIFile({{.*}}"/src
// No string constant keeps the directory (the module ID and `source_filename`
// name the source as given).
// NODIR-NOT: c"[[DIR]]
// LAST: c"/second{{/|\\\\}}file_prefix_map.d\00"

string file() { return __FILE__; }
string fullPath() { return __FILE_FULL_PATH__; }

void outOfBounds(int[] a, size_t i) { a[i] = 0; }
