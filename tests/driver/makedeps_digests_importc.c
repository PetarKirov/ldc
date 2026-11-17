// --makedeps-digests digests an ImportC file and the headers it includes as
// soon as the C preprocessor, which reads them, has finished.

// RUN: %ldc -c -o- -P-I%S/inputs/makedeps_digests %s --makedeps=%t.dep \
// RUN:   --makedeps-digests=%t.digests
// RUN: FileCheck %s < %t.digests

// CHECK:      {{^[0-9a-f]{64} +.*}}makedeps_digests_importc.c{{$}}
// CHECK:      {{^[0-9a-f]{64} +.*}}importc.h{{$}}
// CHECK:      {{^}}b3b4c42bd2be379f9f4fe0f3bff3d7acc04f44b82922bed3908c5a25d0523be4 {{.*}}inputs{{/|\\}}makedeps_digests{{/|\\}}digested.h{{$}}

#include "digested.h"

int digested(void) { return DIGESTED; }
