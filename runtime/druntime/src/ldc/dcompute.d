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

/++
 + A uniform block of `T`: on Vulkan, a block with a binding whose type is `T`,
 + laid out by `std140`; on OpenGL, one uniform per field of `T`, named after
 + the field. A host calls an entry point with one by wrapping a `T`.
 +/
struct UniformBlock(T)
{
    T value; ///
    alias value this;
}

/++
 + A push-constant block of `T`: on Vulkan, one block in the `PushConstant`
 + storage class laid out by `std430`, at most one per entry point; on
 + OpenGL, one uniform per field of `T`. A host calls an entry point with one
 + by wrapping a `T`.
 +/
struct PushConstants(T)
{
    T value; ///
    alias value this;
}

/// Marks a struct as an interface struct: an entry point's parameter of it
/// stands for its fields, each a parameter of the entry point in its place.
struct _resources {}
/// ditto
enum resources = _resources();

/++
 + Marks a struct whose only field is a `__vector` as that vector wherever
 + it crosses a shader's interface: as an input, an output, a built-in, a
 + uniform, or a member of a block, the struct is its vector, with the
 + vector's type, location and layout. Inside a shader it stays the struct,
 + so a vector type can carry operators and named components.
 +/
struct _vectorType {}
/// ditto
enum vectorType = _vectorType();

/// Fixes the binding of a resource on Vulkan: `@binding(3)`. Binding 0 is the
/// shared sampler's.
struct _binding
{
    int index;
}
/// ditto
alias binding = _binding;

/++
 + The vocabulary of the `shader` capability domain: what a shader target may
 + offer. A compilation is granted a set of them on the command line,
 + `-capabilities=shader:<name>,<name>,...`, by the build step that owns the
 + profiles (which target grants what); the compiler checks the names against
 + this enum and enforces what it knows each one to mean:
 +
 + $(UL
 +   $(LI `vertexStage`, `fragmentStage`: an entry point of that stage;)
 +   $(LI `uniformBlocks` without `looseUniforms`: resources lower to Vulkan's
 +        uniform and push-constant blocks, else to plain uniforms;)
 +   $(LI `intVertexInputs`: an integer vertex input;)
 +   $(LI any of them: a function marked `@requires` with it that an emitted
 +        entry point reaches, through the functions it calls.))
 +
 + Without a `shader` grant the compiler checks none of them, and resources
 + lower to plain uniforms. The grant is taken as given: its implications
 + (`vertexStage` implies `shader`) are the build step's to close over.
 +/
enum Capability : int
{
    shader,              /// graphics-stage code at all (SPIR-V `Shader`)
    vertexStage,         /// the vertex stage
    fragmentStage,       /// the fragment stage
    looseUniforms,       /// uniforms outside any block
    uniformBlocks,       /// uniform blocks with a binding
    pushConstants,       /// push-constant blocks
    sampledImages,       /// sampled 2-D images
    intVertexInputs,     /// integer (and integer-vector) vertex inputs
    int64,               /// 64-bit integers
    int16,               /// 16-bit integers
    int8,                /// 8-bit integers
    float64,             /// 64-bit floats
    bufferDeviceAddress, /// buffer device addresses
    derivatives,         /// screen-space derivatives (`OpDPdx`, `OpFwidth`)
    derivativeControl,   /// coarse and fine derivatives (`DerivativeControl`)
    demote,              /// demoting an invocation to a helper (`OpDemoteToHelperInvocation`)
}

/++
 + Marks a function as needing `capabilities`: `@requires(Capability.derivatives)`.
 +
 + In a compilation granted `shader` capabilities, an entry point the
 + compilation emits fails it if it reaches such a function, through the
 + functions it calls, without being granted every capability the function
 + needs; the diagnostic names the chain of calls. An entry point is granted
 + the compilation's capabilities, but, of the stages, only its own: a
 + `@vertex` entry point reaching a function that `@requires(fragmentStage)`
 + fails even where the profile grants both stages. A function no emitted
 + entry point reaches is not checked.
 +/
struct _requires
{
    Capability[] capabilities;
}

/// ditto
_requires requires(Capability[] capabilities...) => _requires(capabilities.dup);

/++
 + What a function compiles to where the compilation lacks `capability`: it
 + returns its first argument, if it has one, so that it stands in for the
 + value the function would compute.
 +
 + The body of every function is analysed in every compilation, including the
 + helpers of entry points built for other targets, so a function that needs
 + a capability selects this rather than failing (`static if`). An emitted
 + entry point that reaches it fails the compilation, naming the chain of
 + calls, like one that reaches a function marked `@requires(capability)`.
 +/
auto unsupported(Capability capability, T...)(T args)
{
    static if (T.length)
        return args[0];
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
    /// The fragment's window position, its centre at `+0.5`, its depth and
    /// `1/w`: a `__vector(float[4])` fragment input. Its origin is the
    /// target's: SPIR-V for Vulkan puts it at the upper left.
    fragCoord = 3,
    /// Whether the fragment's primitive faces the viewer, as the pipeline's
    /// front-face state decides: a `bool` fragment input.
    frontFacing = 4,
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

    /++
     + Samples the image at normalised `uv` through `sampler`, a
     + `SamplerState` parameter of the entry point with a binding of its own:
     + `atlas.sample(nearest, uv)`. An entry point that reads its images with
     + different filtering or addressing takes one sampler per kind.
     +/
    __vector(float[4]) sample(S : Sampler2D)(S s, SamplerState sampler, __vector(float[2]) uv)
        @safe pure nothrow @nogc
    {
        __vector(int[2]) noOffset = 0;
        return __spirv_resource_sample_2d(s, sampler, uv, noOffset);
    }

    // A texture read: pure in the only sense that matters to a shader (the
    // image is immutable for the draw), and never allocates or throws.
    pragma(LDC_intrinsic, "llvm.spv.resource.sample.v4f32.tspirv.Image_f32_1_2_0_0_1_0t.tspirv.Samplert.v2f32.v2i32")
    __vector(float[4]) __spirv_resource_sample_2d(Sampler2D image, SamplerState sampler,
        __vector(float[2]) uv, __vector(int[2]) offset) @safe pure nothrow @nogc;
}
