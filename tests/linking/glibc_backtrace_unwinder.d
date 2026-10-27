// On glibc, druntime records stack traces with the program's own
// _Unwind_Backtrace(), not glibc's backtrace(), which loads libgcc_s: a second
// unwinder in a program linked against LLVM's libunwind.

// REQUIRES: Linux

// RUN: %ldc -link-defaultlib-shared=false %s -of=%t%exe
// RUN: nm %t%exe | FileCheck %s
// RUN: nm %t%exe | FileCheck %s --check-prefix=NOGLIBC
// RUN: %t%exe

// CHECK: _Unwind_Backtrace
// NOGLIBC-NOT: {{ }}backtrace{{@|$}}

void main()
{
    try
        throw new Exception("traced");
    catch (Exception e)
        assert(e.info !is null);
}
