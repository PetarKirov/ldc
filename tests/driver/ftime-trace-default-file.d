// Without --ftime-trace-file, the trace is named after the object file, a
// library's objects included.

// RUN: %ldc -c --ftime-trace -of=%t.o %s && FileCheck %s < %t.o.time-trace
// RUN: rm -rf %t.dir && mkdir %t.dir
// RUN: %ldc -lib --ftime-trace -od=%t.dir -of=%t.dir/lib.a %s
// RUN: FileCheck %s < %t.dir/ftime-trace-default-file.o.time-trace

// CHECK: traceEvents

module ftime_trace_default_file;

int f() { return 1; }
