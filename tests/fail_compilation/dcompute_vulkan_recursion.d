// A shader has no call stack: recursion in device code is an error at the
// first function on the cycle, naming every function on it.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: split-file %s %t
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/self.d 2>&1 | FileCheck %t/self.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/mutual.d 2>&1 | FileCheck %t/mutual.d
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=%t/acyclic -I%t %t/acyclic.d

//--- self.d
@compute(CompileFor.deviceOnly) module self;
import ldc.dcompute;
// CHECK: self.d(4): Error: device code may not recurse: `self.fact` calls itself
int fact(int n) => n < 2 ? 1 : n * fact(n - 1);
@kernel() void entry(GlobalPointer!int output) { *output = fact(*output); }

//--- mutual.d
@compute(CompileFor.deviceOnly) module mutual;
import ldc.dcompute;
// CHECK: Error: device code may not recurse: `mutual.{{even|odd}}`, `mutual.{{even|odd}}` call each other
bool even(int n) => n == 0 ? true : odd(n - 1);
bool odd(int n) => n == 0 ? false : even(n - 1);
@kernel() void entry(GlobalPointer!int output) { *output = even(*output); }

//--- acyclic.d
@compute(CompileFor.deviceOnly) module acyclic;
import ldc.dcompute;
int twice(int n) => n * 2;
int quad(int n) => twice(twice(n));
@kernel() void entry(GlobalPointer!int output) { *output = quad(*output); }
