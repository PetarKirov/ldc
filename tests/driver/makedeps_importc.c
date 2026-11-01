// --makedeps lists the headers an ImportC file includes, nested ones too,
// after the file itself.

// RUN: %ldc -c -o- -P-I%S/inputs/makedeps_importc %s --makedeps=%t.dep
// RUN: FileCheck %s < %t.dep

// CHECK:      makedeps_importc.c \
// CHECK-NEXT: {{.*}}importc.h \
// CHECK-NEXT: {{.*}}inputs{{/|\\}}makedeps_importc{{/|\\}}outer.h \
// CHECK-NEXT: {{.*}}inputs{{/|\\}}makedeps_importc{{/|\\}}sub{{/|\\}}inner\ spaced.h \

#include "outer.h"

int sum(void) { return OUTER + INNER; }
