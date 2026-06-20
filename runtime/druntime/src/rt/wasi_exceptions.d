module rt.wasi_exceptions;

// Exception handling is currently stubbed out for WebAssembly/WASI.
// WASI-only: on other targets dwarfeh.d provides _d_eh_personality etc., so
// guard the whole module to avoid multiple-definition errors in the host build.
version (WASI):

extern(C) void _d_throw_exception(Throwable o)
{
    import core.stdc.stdlib : abort;
    abort();
}

extern(C) int _d_eh_personality(int version_, ...)
{
    return 0; // _URC_NO_REASON
}

extern(C) void _Unwind_Resume(void* exception_object)
{
    import core.stdc.stdlib : abort;
    abort();
}
