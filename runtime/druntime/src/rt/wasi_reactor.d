/**
 * Starts the D runtime in a WASI reactor.
 *
 * A reactor is a WebAssembly module without `main`, linked with
 * `-mexec-model=reactor`. Its host calls the exported `_initialize` once,
 * which runs the C constructors, before it calls any other export. LDC links
 * this module into a reactor, so that `_initialize` also starts the D runtime
 * and runs the module constructors. A command never links it: its `main`
 * starts the runtime.
 *
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Source: $(DRUNTIMESRC rt/_wasi_reactor.d)
 */
module rt.wasi_reactor;

version (WASI):

private extern (C) int rt_init() nothrow @nogc;

pragma(crt_constructor)
extern (C) void _d_wasi_reactor_init() nothrow @nogc
{
    import core.stdc.stdlib : abort;

    // rt_init reports why it failed before it returns 0.
    if (!rt_init())
        abort();
}
