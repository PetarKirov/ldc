// A vector occupies what LLVM allocates for it: a 12-byte `__vector(float[3])`
// takes 16 bytes as a value, a struct field and an array element, and still
// converts to and from its three elements.

// RUN: %ldc -c %s

alias float3 = __vector(float[3]);

static assert(float3.sizeof == 16 && float3.alignof == 16);

struct S { float3 c; float n; }
static assert(S.sizeof == 32 && S.n.offsetof == 16);

static assert((float3[2]).sizeof == 32);

float3 fromArray(float a, float b, float c)
{
    float[3] x = [a, b, c];
    return cast(float3) x;
}

float[3] toArray(float3 v) { return cast(float[3]) v; }

float second(S s) { return s.c[1]; }
