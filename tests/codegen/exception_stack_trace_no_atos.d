// On Darwin, druntime resolves trace lines through atos. Where atos is
// missing (as in a build sandbox), tracing still works and the program
// is not killed by SIGPIPE.

// REQUIRES: Darwin

// RUN: %ldc -g %s -of=%t%exe
// RUN: env PATH=%t-nonexistent %t%exe | FileCheck %s

void thrower() { throw new Exception("traced"); }

void main()
{
    try
        thrower();
    catch (Exception e)
    {
        import core.stdc.stdio : printf;
        auto s = e.toString();
        printf("%.*s\n", cast(int) s.length, s.ptr);
    }
}

// CHECK: object.Exception@{{.*}}(10): traced
// CHECK: exception_stack_trace_no_atos{{.*}}thrower
