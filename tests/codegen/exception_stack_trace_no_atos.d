// On Darwin, druntime resolves trace lines from the executable's .dSYM,
// which the driver gathers after a link with debug info, and needs no atos.
// Without a .dSYM it falls back to atos; where atos is missing too (as in a
// build sandbox), tracing still works and the program is not killed by
// SIGPIPE.

// REQUIRES: Darwin

// RUN: rm -rf %t.dSYM
// RUN: %ldc -g %s -of=%t%exe
// RUN: test -d %t.dSYM
// RUN: env PATH=%t-nonexistent %t%exe | FileCheck --check-prefixes=CHECK,DSYM %s
// RUN: rm -rf %t.dSYM
// RUN: env PATH=%t-nonexistent %t%exe | FileCheck --check-prefixes=CHECK,BARE %s

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

// CHECK: object.Exception@{{.*}}(16): traced
// DSYM: exception_stack_trace_no_atos.d:16 {{.*}}thrower
// DSYM: exception_stack_trace_no_atos.d:21 _Dmain
// BARE: ??:? {{.*}}exception_stack_trace_no_atos{{.*}}thrower
