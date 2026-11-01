// --makedeps-absent lists the paths the import and string import searches
// probed and found missing: those ahead of the path an import resolved to,
// and all of those of a failed (speculative) import, in probing order, each
// once.

// RUN: %ldc -o- -I%S/inputs/makedeps_absent/a -I%S/inputs/makedeps_absent/b \
// RUN:   -J%S/inputs/makedeps_absent/j1 -J%S/inputs/makedeps_absent/j2 %s \
// RUN:   --makedeps=%t.dep --makedeps-absent=%t.absent
// RUN: FileCheck %s < %t.absent
// RUN: FileCheck %s --check-prefix=RESOLVED < %t.dep

// The module `m`, found in b/ after every candidate in a/ and b/m.di:
// CHECK:      makedeps_absent{{.*}}: \
// CHECK:      {{^  .*}}a{{/|\\}}m.di \
// CHECK-NEXT: {{^  .*}}a{{/|\\}}m.d \
// CHECK-NEXT: {{^  .*}}a{{/|\\}}m{{/|\\}}package.di \
// CHECK-NEXT: {{^  .*}}a{{/|\\}}m{{/|\\}}package.d \
// CHECK-NEXT: {{^  .*}}a{{/|\\}}m.i \
// CHECK-NEXT: {{^  .*}}a{{/|\\}}m.h \
// CHECK-NEXT: {{^  .*}}a{{/|\\}}m.c \
// CHECK-NEXT: {{^  .*}}b{{/|\\}}m.di \
// CHECK-NOT:  {{[/\\]}}m.d{{( \\)?$}}

// The speculative import of the missing `opt`, in every import path and then
// in the working directory:
// CHECK:      {{^  .*}}a{{/|\\}}opt.di \
// CHECK-NEXT: {{^  .*}}a{{/|\\}}opt.d \
// CHECK:      {{^  .*}}b{{/|\\}}opt.c \
// CHECK:      {{^  }}opt.di \
// CHECK-NEXT: {{^  }}opt.d \
// CHECK-NEXT: {{^  }}opt{{/|\\}}package.di \
// CHECK-NEXT: {{^  }}opt{{/|\\}}package.d \
// CHECK-NEXT: {{^  }}opt.i \
// CHECK-NEXT: {{^  }}opt.h \
// CHECK-NEXT: {{^  }}opt.c \

// The string import, found in j2/:
// CHECK-NEXT: {{^  .*}}j1{{/|\\}}data.txt{{$}}

// Each path once, though `opt` is looked for twice:
// RUN: grep -c "a.opt\.di" %t.absent | FileCheck %s --check-prefix=ONCE
// ONCE: {{^1$}}

// --makedeps lists only what was read.
// RESOLVED:     {{^  .*}}b{{/|\\}}m.d \
// RESOLVED-NOT: opt.
// RESOLVED:     {{^  .*}}j2{{/|\\}}data.txt{{$}}

import m;

static if (__traits(compiles, { import opt; }))
    enum hasOpt = true;
else
    enum hasOpt = false;

static if (__traits(compiles, { import opt; }))
    enum hasOptAgain = true;

enum data = import("data.txt");
static assert(!hasOpt && m.x == 1 && data == "data\n");
