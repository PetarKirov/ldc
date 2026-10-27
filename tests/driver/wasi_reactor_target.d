// `-mexec-model=reactor` selects a WASI program's execution model, so other
// targets reject it at link time.

// RUN: not %ldc -mexec-model=reactor %s -of=%t%exe 2>&1 | FileCheck %s
// CHECK: Error: `-mexec-model=reactor` is for WASI targets only

void main() {}
