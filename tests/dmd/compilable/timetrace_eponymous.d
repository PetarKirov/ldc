// REQUIRED_ARGS: -o- -ftime-trace -ftime-trace-granularity=0 -ftime-trace-file=${RESULTS_DIR}/compilable/timetrace_eponymous.json
// The time trace names every template instance it times. Naming one whose
// argument is an enum still being initialized (here the eponymous
// `hasPointers` inside its own initializer, as druntime's
// `core.lifetime.hasContextPointers` does) must not expand that enum: doing
// so reported "recursive initialization of constant".

template anySatisfy(alias F, Ts...)
{
    static if (Ts.length == 0)
        enum anySatisfy = false;
    else
        enum anySatisfy = F!(Ts[0]) || anySatisfy!(F, Ts[1 .. $]);
}

enum bool hasPointers(T) = {
    static if (is(T == struct))
        return anySatisfy!(hasPointers, typeof(T.tupleof));
    else
        return is(T == U*, U);
}();

struct Inner { int* p; }
struct Outer { int n; Inner inner; }

static assert(hasPointers!Outer);
static assert(!hasPointers!int);
