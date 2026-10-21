/*
DISABLED: freebsd32 openbsd32 linux32 osx32 win32 hurd32
*/

// https://github.com/dlang/dmd/issues/21823
// Use of SIMD (`core.simd`) during CTFE can crash the frontend

import core.simd;

// The examples of the report
static immutable float4 x = [1, 2, 3, 4];
static immutable float y = x[0];
static assert(y == 1);

enum float4 e = [1, 2, 3, 4];
static immutable float ey = e[0];
static assert(ey == 1);

static immutable float4 sum = x + x;
static assert(sum[3] == 8);
static assert(x.array[2] == 3);
static assert(sum.array == [2, 4, 6, 8]);

// Arithmetic, compound assignment and unary operations
float4 make(float a, float b, float c, float d)
{
    float4 v;
    v[0] = a;
    v[1] = b;
    v[2] = c;
    v[3] = d;
    return v;
}

float[4] arithmetic()
{
    float4 a = make(1, 2, 3, 4);
    float4 c = a * a - 1 + a / 2;
    c = -c;
    c *= 2;
    return c.array;
}
static assert(arithmetic() == [-1, -8, -19, -34]);

int[4] bitwise(int4 a, int4 b)
{
    int4 c = (a & b) | (b ^ ~a);
    c += b;
    c -= a;
    return c.array;
}
enum int4 three = 3;
enum int4 powers = [1, 2, 4, 8];
static assert(bitwise(three, powers) == [((3 & 1) | (1 ^ ~3)) + 1 - 3,
    ((3 & 2) | (2 ^ ~3)) + 2 - 3, ((3 & 4) | (4 ^ ~3)) + 4 - 3,
    ((3 & 8) | (8 ^ ~3)) + 8 - 3]);

// A vector field initialized by an array initializer
struct S
{
    float4 v = [1, 2, 3, 4];
}

float[4] field()
{
    S s;
    s.v[0] = 10;
    float4 w = s.v;
    w += s.v;
    return (-w).array;
}
static assert(field() == [-20, -4, -6, -8]);

float fieldRead()
{
    S s;
    return s.v.array[3] + s.v[2];
}
static assert(fieldRead() == 7);

// A copy of a vector is a vector of its own, even where the original
// broadcasts its default value
struct Z
{
    float4 v = 0;
}

float[2] copies()
{
    Z a;
    a.v[0] = 5;
    Z b = a;
    b.v[0] = 1;
    return [a.v[0], b.v[0]];
}
static assert(copies() == [5, 1]);

float[2] fieldCopies()
{
    S a;
    S b = a;
    b.v[1] = 9;
    return [a.v[1], b.v[1]];
}
static assert(fieldCopies() == [2, 9]);

// A struct whose only field is a vector, the way a vector type wraps one
struct V
{
    float4 v = 0;
    this(float a, float b, float c, float d)
    {
        v[0] = a;
        v[1] = b;
        v[2] = c;
        v[3] = d;
    }
    this(float4 w) { v = w; }
    V opBinary(string op)(V rhs) const => V(mixin("v " ~ op ~ " rhs.v"));
}

static assert((V(1, 2, 3, 4) + V(1, 1, 1, 1)).v.array == [2, 3, 4, 5]);

enum V k = V(make(1, 2, 3, 4)) + V(make(4, 3, 2, 1));
static assert(k.v.array == [5, 5, 5, 5]);
static immutable V ik = k * V(make(1, 2, 3, 4));

void main()
{
    // Values computed at compile time reach run time intact
    assert(sum.array == [2, 4, 6, 8]);
    assert(ik.v.array == [5, 10, 15, 20]);
}
