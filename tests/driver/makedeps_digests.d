// --makedeps-digests lists each --makedeps dependency once, in order, with the
// BLAKE3 digest of the bytes the compilation read from it.

// RUN: %ldc -o- -I%S/inputs/makedeps_digests -J%S/inputs/makedeps_digests %s \
// RUN:   --makedeps=%t.dep --makedeps-digests=%t.digests
// RUN: FileCheck %s < %t.digests
// RUN: FileCheck %s --check-prefix=ONCE < %t.digests

// This file, then the imported module and the string import, as read:
// CHECK:      {{^[0-9a-f]{64} +.*}}makedeps_digests.d{{$}}
// CHECK:      {{^}}ec1ac081070bdbdc5bbf5e03d9103b90084e6a230f39c5f42247e36b208cebcc {{.*}}inputs{{/|\\}}makedeps_digests{{/|\\}}m.d{{$}}
// CHECK:      {{^}}0923c393dd173e30dfaddcb127d92613a1c7270a927cf834ec6e7355459b0161 {{.*}}inputs{{/|\\}}makedeps_digests{{/|\\}}data.txt{{$}}

// The string import is imported twice and listed once:
// ONCE:     data.txt
// ONCE-NOT: data.txt

// The digests describe the dependencies --makedeps lists, so it is required:
// RUN: not %ldc -o- %s -I%S/inputs/makedeps_digests -J%S/inputs/makedeps_digests \
// RUN:   --makedeps-digests=%t.alone 2>&1 | FileCheck %s --check-prefix=NEEDS
// NEEDS: -makedeps-digests needs -makedeps

import m;

enum data = import("data.txt");
enum again = import("data.txt");
