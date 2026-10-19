/**
 * Contains compiler-recognized special symbols for dcompute.
 *
 * Copyright: Authors 2017
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors:   Nicholas Wilson
 */

module ldc.dcompute;

enum ReflectTarget : uint
{
    // These numbers MUST match DcomputeTarget::target in LDC.
    Host = 0,
    OpenCL = 1,
    CUDA = 2,
    Vulkan = 3,
}
/**
 * The pseudo conditional compilation function.
 * returns true if t and _version match the target and it's version.
 * think __ctfe but per target, codegen time conditional compilation.
 * as oppsed to compiletime/runtime.
 * arguments MUST be compiletime constants
 * valid values of _version are for OpenCL 100 110 120 200 210
 * and for CUDA are x*100 + y*10 for x any valid values of sm x.y
 * use 0 as a wildcard to match any version.
 
 * This is mostly used for selecting the correct intrinsic for the
 * given target and version, but could also be used to tailor for
 * performance characteristics. See dcompute.std.index for an example
 * of how to select intrinsics.
 */
pure nothrow @nogc
extern(C) bool __dcompute_reflect(ReflectTarget t, uint _version = 0);

///Readability aliases for compute
enum CompileFor : int
{
    deviceOnly = 0,
    hostAndDevice = 1
}

/++
+ When applied to a module, specifies that the module should be compiled for
+ dcompute (-mdcompute-targets=<...>) using the NVPTX and/or SPIRV backends of
+ LLVM.
+
+ Examples:
+ ---
+ @compute(CompileFor.deviceOnly) module foo;
+ import ldc.dcompute;
+ ---
+/
struct compute
{
    CompileFor codeProduction = CompileFor.deviceOnly;
}

/++
+ Mark a function as a 'kernel', a compute API (CUDA, OpenCL) entry point.
+ Equivalent to __kernel__ in OpenCL and __global__ in CUDA.
+
+ Examples:
+ ---
+ @compute(CompileFor.deviceOnly) module foo;
+ import ldc.dcompute;
+
+ @kernel() void bar()
+ {
+     //...
+ }
+ ---
+/
private struct _kernel {
    size_t[3] bounds;
}
_kernel kernel(size_t[3] a = [1,1,1]) => _kernel(a);

/++
 + DCompute has the notion of adress spaces, provide by the magic structs below.
 + The numbers are for the DCompute virtual addess space and are translated into
 + the correct address space for each DCompute backend (SPIRV, NVPTX).
 + The table below shows the equivalent annotation between DCompute OpenCL and CUDA.
 + | DCompute   | OpenCL       | Cuda             |
 + | :--------- | :----------- | :--------------- |
 + | `Global`   | `__global`   | `__device__`     |
 + | `Shared`   | `__local`    | `__shared__`     |
 + | `Constant` | `__constant` | `__constant__`   |
 + | `Private`  | `__private`  | `__local__`      |
 + | `Generic`  | `__generic`  | `(no qualifier)` |
 +/
struct Pointer(AddrSpace as, T)
{
    T* ptr;
    alias ptr this;
}

struct Variable(AddrSpace as, T)
{
    T val;
    alias val this;
}

enum AddrSpace : uint
{
    Private  = 0,
    Global   = 1,
    Shared   = 2,
    Constant = 3,
    Generic  = 4,
}

alias PrivatePointer(T)  = Pointer!(AddrSpace.Private,  T);
alias GlobalPointer(T)   = Pointer!(AddrSpace.Global,   T);
alias SharedPointer(T)   = Pointer!(AddrSpace.Shared,   T);
alias ConstantPointer(T) = Pointer!(AddrSpace.Constant, immutable(T));
alias GenericPointer(T)  = Pointer!(AddrSpace.Generic,  T);

// N.B private variables are declared on the stack and so cannot be declared
// at module scope.
// No variables exist in the generic address space, it is purely for generalised
// pointers to point to.
//
// The __gshared below does not work. It is kludged into place in `DtoResolveVariable`

alias Global(T)   = /*__gshared*/ Variable!(AddrSpace.Global,   T);
alias Shared(T)   = shared        Variable!(AddrSpace.Shared,   T);
alias Constant(T) = immutable     Variable!(AddrSpace.Constant, T);

/++
 + Graphics shader stages (Vulkan/SPIR-V target only).
 +
 + `@fragment` marks a function in a `@compute` module as a fragment (pixel)
 + shader entry point. The function itself stays an ordinary D function; the
 + compiler synthesises the shader interface around it from its signature:
 +
 + $(UL
 +   $(LI each `@input` parameter becomes an `Input` interface variable named
 +        after the parameter, at the next location (a GLSL `in`/varying),)
 +   $(LI each `@uniform` parameter becomes a plain uniform named after the
 +        parameter (a GLSL `uniform`),)
 +   $(LI each `Sampler2D` parameter becomes a combined image + sampler pair at
 +        the next descriptor binding (a GLSL `sampler2D`), and)
 +   $(LI the return value is stored to the fragment's colour output at
 +        location 0.)
 + )
 +
 + Examples:
 + ---
 + @compute(CompileFor.deviceOnly) module foo;
 + import ldc.dcompute;
 +
 + @fragment __vector(float[4]) tint(@input __vector(float[2]) fragTexCoord,
 +     @input __vector(float[4]) fragColor, Sampler2D texture0,
 +     @uniform float uAmount)
 + {
 +     return texture0.sample(fragTexCoord) * fragColor * uAmount;
 + }
 + ---
 +/
enum ShaderStage : int
{
    fragment = 0,
    vertex = 1,
}

/// ditto
private struct _shader
{
    ShaderStage stage;
}

/// ditto
enum fragment = _shader(ShaderStage.fragment);

/++
 + `@vertex` marks a function in a `@compute` module as a vertex shader entry
 + point. Its `@input` parameters are its vertex attributes, at locations in
 + parameter order, and its `@builtin` parameters the stage's built-in inputs.
 + It returns a struct: the field marked `@builtin(Builtin.position)` is the
 + clip-space position, and every other field an output named after it, at
 + locations in field order, which a fragment entry point reads as the
 + `@input` of the same name.
 +
 + Examples:
 + ---
 + struct Varyings
 + {
 +     @builtin(Builtin.position) __vector(float[4]) position;
 +     __vector(float[4]) colour;
 + }
 +
 + @vertex Varyings tri(@builtin(Builtin.vertexIndex) int index,
 +     @input __vector(float[2]) corner)
 + {
 +     Varyings v;
 +     v.position = __vector(float[4])(1.0f);
 +     v.position[0] = corner[0];
 +     v.position[1] = corner[1];
 +     v.colour = __vector(float[4])(cast(float) index);
 +     return v;
 + }
 + ---
 +/
enum vertex = _shader(ShaderStage.vertex);

/// The shader profiles an entry point, or every entry point of a module
/// (`@profiles(...) module m;`), is built for: profile names, comma-separated.
/// A shader library provides the constructor that names them (its
/// `profiles(...)`); the compiler only emits, in a compilation for a profile
/// (`-mdcompute-profile`), the entry points that list it.
struct _profiles
{
    string names;
}

/// The built-in variables a stage reads or writes (SPIR-V `BuiltIn`).
enum Builtin : int
{
    /// The index of the vertex being processed: an `int` vertex input.
    vertexIndex = 0,
    /// The index of the instance being drawn: an `int` vertex input.
    instanceIndex = 1,
    /// The clip-space position: a `__vector(float[4])` vertex output.
    position = 2,
}

/// Marks a parameter, or a field of a `@vertex` result, as the built-in
/// variable `variable`: `@builtin(Builtin.vertexIndex)`.
struct _builtin
{
    Builtin variable;
}

/// ditto
alias builtin = _builtin;

/// Marks a `@fragment` parameter as an interface input (a varying).
private struct _input {}
/// ditto
enum input = _input();

/// Marks a `@fragment` parameter as a uniform.
private struct _uniform {}
/// ditto
enum uniform = _uniform();

// The handles below are opaque `spirv.Image` / `spirv.Sampler` values in
// device code; the pointer-sized field only gives the frontend a size that
// matches the backend's layout type. They are scalars to the backend, never
// members of anything: Vulkan forbids an opaque handle inside a composite or
// in a Function-storage variable, so a "combined" image + sampler pair cannot
// be a struct. GLSL's `sampler2D` is therefore modelled as the image handle
// alone, and every image is sampled through one shared sampler at binding 0.

/// A sampled 2-D image: GLSL's `sampler2D`. As a `@fragment` parameter it
/// becomes a descriptor at the next image binding, named after the parameter.
struct Sampler2D
{
    const(void)* handle;
}

/// An opaque sampler handle (`OpTypeSampler`). Named for HLSL's sampler
/// without an image, and so as not to clash with `ldc.opencl.Sampler`.
struct SamplerState
{
    const(void)* handle;
}

/// The one sampler every image is read through: set 0, binding 0. The
/// compiler materialises the handle at each call.
SamplerState __spirv_shared_sampler() @safe pure nothrow @nogc;

static if (__traits(compiles, { __vector(float[2]) a; __vector(float[4]) b; __vector(int[2]) c; }))
{
    /++
     + Samples the image at normalised `uv`: GLSL's `texture(s, uv)`.
     +
     + A template so that druntime's own host build never compiles it — the
     + intrinsic's signature only holds on the device. UFCS keeps the call
     + site as `texture0.sample(uv)`.
     +/
    __vector(float[4]) sample(S : Sampler2D)(S s, __vector(float[2]) uv)
        @safe pure nothrow @nogc
    {
        __vector(int[2]) noOffset = 0;
        return __spirv_resource_sample_2d(s, __spirv_shared_sampler(), uv, noOffset);
    }

    // A texture read: pure in the only sense that matters to a shader (the
    // image is immutable for the draw), and never allocates or throws.
    pragma(LDC_intrinsic, "llvm.spv.resource.sample.v4f32.tspirv.Image_f32_1_2_0_0_1_0t.tspirv.Samplert.v2f32.v2i32")
    __vector(float[4]) __spirv_resource_sample_2d(Sampler2D image, SamplerState sampler,
        __vector(float[2]) uv, __vector(int[2]) offset) @safe pure nothrow @nogc;
}
