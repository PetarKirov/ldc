//===-- gen/dcompute/shaderinterface.d - Shader entry points -----*- D -*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
// The frontend half of dcompute's graphics stages: which functions are shader
// entry points, which profiles each is built for, and what its interface is
// -- every input, output, uniform, image and built-in variable, with its
// location or binding -- checked against the rules a shading language's
// interface obeys. None of it needs LLVM; the Vulkan target's code generator
// reads the description (`shaderEntryOf`) and only emits it.
//
//===----------------------------------------------------------------------===//

module gen.dcompute.shaderinterface;

import core.stdc.string : strcmp, strlen;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.astenums : TY, STC;
import dmd.attrib;
import dmd.common.outbuffer;
import dmd.declaration;
import dmd.dmodule;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.errors;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.location;
import dmd.mtype;
import dmd.expressionsem : toInteger;
import dmd.typesem : toBasetype, nextOf;
import dmd.root.file : File;
import dmd.root.filename : FileName;

// In driver/cl_options.cpp: `-mdcompute-profile`, `-mdcompute-manifest`, and
// whether any dcompute target is given.
extern (C++) const(char)* dcomputeActiveProfile();
extern (C++) const(char)* dcomputeManifestPath();
extern (C++) bool dcomputeHasTargets();
extern (C++) const(char)* dcomputeResourceLowering();
extern (C++) bool dcomputeReportInt64();

extern (C++):

/// A shader stage: `ldc.dcompute.ShaderStage`.
enum ShaderStage : int
{
    fragment = 0,
    vertex = 1,
}

/// What an interface variable is.
enum ShaderVariableKind : int
{
    input,         /// an `@input` parameter: location `ordinal`
    output,        /// a field of a vertex result: location `ordinal`
    uniform,       /// a `@uniform` parameter
    image,         /// a `Sampler2D` parameter: binding `ordinal`
    builtinInput,  /// a `@builtin` parameter: SPIR-V `BuiltIn` `ordinal`
    builtinOutput, /// a `@builtin` result field: SPIR-V `BuiltIn` `ordinal`
    uniformBlock,  /// a `UniformBlock!T` on Vulkan: binding `ordinal`, std140
    pushConstants, /// a `PushConstants!T` on Vulkan: std430
    defaultUniform, /// a `@uniform` on Vulkan: member `ordinal` of the entry's default block
    looseBlock,    /// a block on OpenGL: one uniform per field of its `T`
}

/// One variable of an entry point's interface.
struct ShaderVariable
{
    ShaderVariableKind kind;
    /// The parameter, or the field of a vertex result, that declares it.
    VarDeclaration decl;
    /// The D parameter's index, or -1 for a result field.
    int parameter;
    /// The location, binding or `BuiltIn`, by `kind`; -1 for a uniform.
    int ordinal;
    /// Its name: the declaration's, or a built-in's.
    const(char)* name;
    /// A block's `T`, else null.
    Type blockType;
    /// For a field of a `@resources` parameter, the field indices from the
    /// parameter, `depth` of them.
    int[8] path;
    int depth;
}

/// A shader entry point emitted by this compilation, and its interface.
struct ShaderEntry
{
    FuncDeclaration fd;
    ShaderStage stage;
    /// A vertex entry point's result, else null.
    StructDeclaration result;
    /// Parameters in order, then result fields in field order.
    ShaderVariable* variables;
    size_t length;
    /// On Vulkan, the binding of the default uniform block that holds the
    /// `@uniform` parameters, its variable's name and its type's (`SHR3`,
    /// `SHR8`); -1 if it has none.
    int defaultBlockBinding = -1;
    const(char)* defaultBlockName;
    const(char)* defaultBlockTypeName;
}

/// For the code generator: the size, under `rule` (0 std140, 1 std430), of a
/// block member of D type `t`; the offset of field `index` of `sd`; and the
/// stride of an array of `element`.
uint shaderBlockSize(Type t, int rule) => cast(uint) sizeOf(t, cast(Rule) rule);
/// ditto
uint shaderBlockFieldOffset(StructDeclaration sd, size_t index, int rule)
    => cast(uint) fieldOffset(sd, index, cast(Rule) rule);
/// ditto
uint shaderBlockArrayStride(Type element, int rule) => cast(uint) strideOf(element, cast(Rule) rule);
/// ditto: the alignment of a block member of `t`.
uint shaderBlockAlignment(Type t, int rule) => cast(uint) alignmentOf(t, cast(Rule) rule);

/// The description of `fd` if it is a shader entry point this compilation
/// emits, else null. `analyseShaderEntries` builds them.
const(ShaderEntry)* shaderEntryOf(FuncDeclaration fd)
{
    if (auto p = fd in entries)
        return *p;
    return null;
}

/// Finds the shader entry points of `modules`, resolves their profiles, and
/// checks and describes the interface of each one the active profile emits.
/// Run once every module's semantic analysis is complete.
void analyseShaderEntries(ref Modules modules)
{
    if (!dcomputeHasTargets())
        return;
    foreach (m; modules[])
        foreachEntry(m.members, (FuncDeclaration fd, ShaderStage stage) {
            if (!isEmittedForActiveProfile(fd, stage))
                return;
            if (auto e = describe(fd, stage))
                entries[fd] = e;
        });
    if (dcomputeReportInt64())
        reportInt64(entries.keys);
}

/// With `-mdcompute-manifest=<file>`, writes the unit's shader entry points,
/// with their stages, modules and profiles, as JSON sorted by name, and
/// returns true: the compilation then stops before function bodies are
/// analysed. Called once the declarations of every module are.
bool writeDComputeManifest(ref Modules modules)
{
    const path = dcomputeManifestPath();
    if (!path || !*path)
        return false;
    static struct Item
    {
        const(char)[] name, stage, module_;
        const(char)[][] profiles;
    }
    Item[] items;
    foreach (m; modules[])
        foreachEntry(m.members, (FuncDeclaration fd, ShaderStage stage) {
            items ~= Item(fd.ident.toString(),
                stage == ShaderStage.vertex ? "vertex" : "fragment",
                fd.getModule().toPrettyChars().toDString(), entryProfiles(fd, stage));
        });
    if (global.errors)
        return true;
    sortBy!((ref a, ref b) => a.name < b.name)(items);

    OutBuffer buf;
    buf.writestring(`{"entryPoints":[`);
    foreach (i, ref it; items)
    {
        buf.writestring(i ? `,{"name":` : `{"name":`);
        writeJsonString(buf, it.name);
        buf.writestring(`,"stage":`);
        writeJsonString(buf, it.stage);
        buf.writestring(`,"module":`);
        writeJsonString(buf, it.module_);
        buf.writestring(`,"profiles":[`);
        foreach (j, p; it.profiles)
        {
            if (j)
                buf.writeByte(',');
            writeJsonString(buf, p);
        }
        buf.writestring("]}");
    }
    buf.writestring("]}\n");
    if (!File.write(path.toDString(), buf[]))
        error(Loc.initial, "cannot write the shader manifest `%s`", path);
    return true;
}

private:
extern (D):

__gshared const(ShaderEntry)*[FuncDeclaration] entries;

const(char)[] toDString(const(char)* s) => s ? s[0 .. strlen(s)] : null;

void sortBy(alias less, T)(T[] a)
{
    // Insertion sort: a unit has few entry points.
    foreach (i; 1 .. a.length)
        for (size_t j = i; j > 0 && less(a[j], a[j - 1]); j--)
        {
            auto t = a[j];
            a[j] = a[j - 1];
            a[j - 1] = t;
        }
}

void writeJsonString(ref OutBuffer buf, const(char)[] s)
{
    buf.writeByte('"');
    foreach (c; s)
    {
        if (c == '"' || c == '\\')
            buf.writeByte('\\');
        buf.writeByte(c);
    }
    buf.writeByte('"');
}

// ---- ldc.dcompute's attributes ----------------------------------------------

bool isFromLdcDCompute(Dsymbol s)
{
    auto m = s.getModule();
    if (!m || !m.md)
        return false;
    return m.md.packages.length == 1 && m.md.packages[0] == Id.ldc && m.md.id == Id.dcompute;
}

/// The attribute of `sym` that is a literal of `ldc.dcompute`'s struct `id`,
/// with fields of `fieldTypes`, or null.
StructLiteralExp dcomputeAttribute(Dsymbol sym, Identifier id, Type[] fieldTypes...)
{
    import dmd.attribsem : getAttributes;
    import dmd.dinterpret : ctfeInterpret;
    import dmd.expressionsem : expandTuples;

    if (!sym.userAttribDecl)
        return null;
    auto attrs = getAttributes(sym.userAttribDecl);
    expandTuples(attrs);
    if (!attrs)
        return null;
    foreach (exp; *attrs)
    {
        const gagged = global.startGagging();
        auto e = ctfeInterpret(exp);
        if (global.endGagging(gagged))
            continue;
        auto sle = e.isStructLiteralExp();
        if (!sle || sle.sd.ident != id || !isFromLdcDCompute(sle.sd))
            continue;
        if (sle.elements.length != fieldTypes.length)
        {
            error(sle.loc, "unexpected field count in `%s`; does druntime not match compiler version?",
                sle.sd.toPrettyChars());
            fatal();
        }
        foreach (i, t; fieldTypes)
            if ((*sle.elements)[i].type.toBasetype() != t)
            {
                error(sle.loc, "invalid field type in `%s`; does druntime not match compiler version?",
                    sle.sd.toPrettyChars());
                fatal();
            }
        return sle;
    }
    return null;
}

bool isComputeModule(Module m)
{
    import gen.semantic : hasComputeAttr;
    return m && hasComputeAttr(m) != 0;
}

/// `fd`'s stage, if it is marked `@fragment` or `@vertex`.
bool shaderStageOf(FuncDeclaration fd, out ShaderStage stage)
{
    auto sle = dcomputeAttribute(fd, Id.udaShader, Type.tint32);
    if (!sle)
        return false;
    if (!isComputeModule(fd.getModule()))
    {
        error(fd.loc, "`@ldc.dcompute.fragment` can only be applied to functions in modules marked `@ldc.dcompute.compute`");
        return false;
    }
    const value = (*sle.elements)[0].toInteger();
    if (value != ShaderStage.fragment && value != ShaderStage.vertex)
    {
        error(fd.loc, "unsupported shader stage %d", cast(int) value);
        fatal();
    }
    stage = cast(ShaderStage) value;
    return true;
}

bool hasMarker(Dsymbol s, Identifier id) => dcomputeAttribute(s, id) !is null;

/// The `Builtin` a `@builtin` marks `s` as, or -1.
int builtinOf(Dsymbol s)
{
    auto sle = dcomputeAttribute(s, Id.udaShaderBuiltin, Type.tint32);
    return sle ? cast(int) (*sle.elements)[0].toInteger() : -1;
}

/// The comma-separated profile names of a `@profiles` on `s`, or null.
const(char)[] profilesOf(Dsymbol s)
{
    auto sle = dcomputeAttribute(s, Id.udaShaderProfiles, Type.tstring);
    if (!sle)
        return null;
    auto se = (*sle.elements)[0].isStringExp();
    return se ? se.peekString() : null;
}

void foreachEntry(Dsymbols* members, scope void delegate(FuncDeclaration, ShaderStage) dg)
{
    import dmd.dsymbolsem : include;

    if (!members)
        return;
    foreach (s; *members)
    {
        if (auto ad = s.isAttribDeclaration())
        {
            foreachEntry(include(ad, null), dg);
            continue;
        }
        auto fd = s.isFuncDeclaration();
        ShaderStage stage;
        if (fd && shaderStageOf(fd, stage))
            dg(fd, stage);
    }
}

// ---- profiles ---------------------------------------------------------------

const(char)[][] splitNames(const(char)[] names)
{
    const(char)[][] r;
    size_t start = 0;
    foreach (i; 0 .. names.length + 1)
        if (i == names.length || names[i] == ',')
        {
            auto p = names[start .. i];
            while (p.length && p[0] == ' ')
                p = p[1 .. $];
            while (p.length && p[$ - 1] == ' ')
                p = p[0 .. $ - 1];
            if (p.length)
            {
                bool seen;
                foreach (q; r)
                    seen |= q == p;
                if (!seen)
                    r ~= p;
            }
            start = i + 1;
        }
    sortBy!((ref a, ref b) => a < b)(r);
    return r;
}

/// The names of the profiles `fd` is built for, sorted: its own `@profiles`,
/// else its module's, else, for a fragment entry point, `gl330` and
/// `gles100`. A vertex entry point with neither has no profile, which is an
/// error. A profile is a name here; what it means is the shader library's.
const(char)[][] entryProfiles(FuncDeclaration fd, ShaderStage stage)
{
    if (auto own = profilesOf(fd))
        return splitNames(own);
    if (auto module_ = profilesOf(fd.getModule()))
        return splitNames(module_);
    if (stage == ShaderStage.fragment)
        return ["gl330", "gles100"];
    error(fd.loc, "`@vertex` entry point `%s` declares no profiles, and no profile is the default for the vertex stage; mark it, or its module, `@profiles(...)`",
        fd.ident.toChars());
    fatal();
    assert(0);
}

/// Whether resources lower to Vulkan's blocks (`-mdcompute-resources=blocks`)
/// rather than to OpenGL's plain uniforms, as the build step chooses from the
/// active profile's capabilities.
bool resourcesAsBlocks() => dcomputeResourceLowering().toDString() == "blocks";

bool isEmittedForActiveProfile(FuncDeclaration fd, ShaderStage stage)
{
    const profiles = entryProfiles(fd, stage);
    const active = dcomputeActiveProfile().toDString();
    if (!active.length)
        return true;
    foreach (p; profiles)
        if (p == active)
            return true;
    return false;
}

// ---- built-in variables -----------------------------------------------------

/// A built-in variable of `ldc.dcompute.Builtin`: its stage, direction, D
/// type and SPIR-V `BuiltIn`.
struct BuiltinVariable
{
    string name;
    ShaderStage stage;
    bool output;
    int spirv;
    bool isFloat4; // else `int`
}

immutable BuiltinVariable[] builtins = [
    BuiltinVariable("vertexIndex", ShaderStage.vertex, false, 42, false),
    BuiltinVariable("instanceIndex", ShaderStage.vertex, false, 43, false),
    BuiltinVariable("position", ShaderStage.vertex, true, 0, true),
];

const(char)* stageAttr(ShaderStage s) => s == ShaderStage.vertex ? "`@vertex`" : "`@fragment`";

bool isFloat4(Type t)
{
    t = t.toBasetype();
    auto tv = t.isTypeVector();
    return tv && tv.elementType().ty == TY.Tfloat32
        && (cast(TypeSArray) tv.basetype).dim.toInteger() == 4;
}

/// Checks that `vd`, marked `@builtin(b)` as `what` of a `stage` entry point,
/// reads or writes `b` in its stage, direction and type.
immutable(BuiltinVariable)* checkBuiltin(VarDeclaration vd, int b, const(char)* what,
    ShaderStage stage, bool output)
{
    if (b < 0 || b >= builtins.length)
    {
        error(vd.loc, "%s %s `%s` names an unknown built-in, %d", stageAttr(stage), what,
            vd.ident.toChars(), b);
        fatal();
    }
    auto v = &builtins[b];
    if (v.stage != stage)
    {
        error(vd.loc, "built-in `%s` of %s %s `%s` is a %s-stage built-in", v.name.ptr,
            stageAttr(stage), what, vd.ident.toChars(),
            v.stage == ShaderStage.vertex ? "vertex".ptr : "fragment".ptr);
        fatal();
    }
    if (v.output != output)
    {
        error(vd.loc, "built-in `%s` of %s %s `%s` is an %s, not an %s", v.name.ptr,
            stageAttr(stage), what, vd.ident.toChars(),
            v.output ? "output".ptr : "input".ptr, output ? "output".ptr : "input".ptr);
        fatal();
    }
    auto t = vd.type.toBasetype();
    if (v.isFloat4 ? !isFloat4(t) : t.ty != TY.Tint32)
    {
        error(vd.loc, "built-in `%s` of %s %s `%s` is `%s`, not `%s`", v.name.ptr,
            stageAttr(stage), what, vd.ident.toChars(),
            v.isFloat4 ? "__vector(float[4])".ptr : "int".ptr, vd.type.toChars());
        fatal();
    }
    return v;
}

// ---- interface types --------------------------------------------------------
//
// What crosses a shader's interface is what GLSL can declare there, in a form
// both GLSL dialects the build step emits accept (GLSL 3.30 and GLSL ES 1.00):
//
// - fragment inputs and vertex outputs: `float` and vectors of two to four
//   `float`s (ES 1.00 has no integer varyings, and GLSL 3.30 needs them
//   `flat`);
// - vertex inputs: those, and `int` and vectors of `int`;
// - the fragment output: a vector of four `float`s (ES 1.00 writes
//   `gl_FragData[0]`, which is a `vec4`);
// - uniforms: those, `int` and vectors of `int`, and structs and static arrays
//   of uniform types (ES 1.00 has no `uint`).

enum Crossing
{
    varying,
    vertexInput,
    output,
    uniform,
}

/// Why `t` cannot cross as `crossing`, or null if it can.
const(char)* refusal(Type t, Crossing crossing)
{
    t = t.toBasetype();
    if (crossing == Crossing.output)
        return isFloat4(t) ? null
            : "the output is a vector of four `float`s, as GLSL ES 1.00's `gl_FragData[0]` is".ptr;
    switch (t.ty)
    {
    case TY.Tfloat32:
        return null;
    case TY.Tint32:
        return crossing == Crossing.uniform || crossing == Crossing.vertexInput ? null
            : "an integer cannot be interpolated; pass it as a `@uniform`".ptr;
    case TY.Tvector:
        auto tv = t.isTypeVector();
        const n = (cast(TypeSArray) tv.basetype).dim.toInteger();
        if (n < 2 || n > 4)
            return "a vector must have two to four components";
        return refusal(tv.elementType(), crossing);
    case TY.Tsarray:
        if (crossing != Crossing.uniform)
            return "only a `@uniform` can be an array";
        return refusal(t.nextOf(), crossing);
    case TY.Tstruct:
        if (crossing != Crossing.uniform)
            return "only a `@uniform` can be a struct";
        auto sd = t.isTypeStruct().sym;
        if (sd.fields.length == 0)
            return "a struct must have fields";
        foreach (field; sd.fields)
            if (auto why = refusal(field.type, crossing))
                return why;
        return null;
    case TY.Tuns32:
        return "GLSL ES 1.00 has no unsigned integers";
    default:
        return crossing == Crossing.uniform
            ? "a uniform is a `float`, an `int`, a vector of them, or a struct or static array of uniform types"
            : "an input or output is a `float` or a vector of them";
    }
}

// ---- names ------------------------------------------------------------------

/// The names GLSL reserves: spirv-cross's `CompilerGLSL::replace_illegal_names`
/// list, keywords and built-in functions, which the translation renames.
immutable string[] glslReserved = [
    "abs", "acos", "acosh", "all", "any", "asin", "asinh", "atan", "atanh", "atomicAdd",
    "atomicCompSwap", "atomicCounter", "atomicCounterDecrement",
    "atomicCounterIncrement", "atomicExchange", "atomicMax", "atomicMin",
    "atomicOr", "atomicXor", "bitCount", "bitfieldExtract", "bitfieldInsert",
    "bitfieldReverse", "ceil", "cos", "cosh", "cross", "degrees", "dFdx", "dFdxCoarse",
    "dFdxFine", "dFdy", "dFdyCoarse", "dFdyFine", "distance", "dot",
    "EmitStreamVertex", "EmitVertex", "EndPrimitive", "EndStreamPrimitive", "equal",
    "exp", "exp2", "faceforward", "findLSB", "findMSB", "float16BitsToInt16",
    "float16BitsToUint16", "floatBitsToInt", "floatBitsToUint", "floor", "fma",
    "fract", "frexp", "fwidth", "fwidthCoarse", "fwidthFine", "greaterThan",
    "greaterThanEqual", "groupMemoryBarrier", "imageAtomicAdd", "imageAtomicAnd",
    "imageAtomicCompSwap", "imageAtomicExchange", "imageAtomicMax",
    "imageAtomicMin", "imageAtomicOr", "imageAtomicXor", "imageLoad",
    "imageSamples", "imageSize", "imageStore", "imulExtended", "int16BitsToFloat16",
    "intBitsToFloat", "interpolateAtOffset", "interpolateAtCentroid",
    "interpolateAtSample", "inverse", "inversesqrt", "isinf", "isnan", "ldexp",
    "length", "lessThan", "lessThanEqual", "log", "log2", "matrixCompMult", "max",
    "memoryBarrier", "memoryBarrierAtomicCounter", "memoryBarrierBuffer",
    "memoryBarrierImage", "memoryBarrierShared", "min", "mix", "mod", "modf", "noise",
    "noise1", "noise2", "noise3", "noise4", "normalize", "not", "notEqual",
    "outerProduct", "packDouble2x32", "packHalf2x16", "packInt2x16", "packInt4x16",
    "packSnorm2x16", "packSnorm4x8", "packUint2x16", "packUint4x16",
    "packUnorm2x16", "packUnorm4x8", "pow", "radians", "reflect", "refract", "round",
    "roundEven", "sign", "sin", "sinh", "smoothstep", "sqrt", "step", "tan", "tanh",
    "texelFetch", "texelFetchOffset", "texture", "textureGather",
    "textureGatherOffset", "textureGatherOffsets", "textureGrad",
    "textureGradOffset", "textureLod", "textureLodOffset", "textureOffset",
    "textureProj", "textureProjGrad", "textureProjGradOffset", "textureProjLod",
    "textureProjLodOffset", "textureProjOffset", "textureQueryLevels",
    "textureQueryLod", "textureSamples", "textureSize", "transpose", "trunc",
    "uaddCarry", "uint16BitsToFloat16", "uintBitsToFloat", "umulExtended",
    "unpackDouble2x32", "unpackHalf2x16", "unpackInt2x16", "unpackInt4x16",
    "unpackSnorm2x16", "unpackSnorm4x8", "unpackUint2x16", "unpackUint4x16",
    "unpackUnorm2x16", "unpackUnorm4x8", "usubBorrow", "active", "asm",
    "atomic_uint", "attribute", "bool", "break", "buffer", "bvec2", "bvec3", "bvec4",
    "case", "cast", "centroid", "class", "coherent", "common", "const", "continue",
    "default", "discard", "dmat2", "dmat2x2", "dmat2x3", "dmat2x4", "dmat3", "dmat3x2",
    "dmat3x3", "dmat3x4", "dmat4", "dmat4x2", "dmat4x3", "dmat4x4", "do", "double",
    "dvec2", "dvec3", "dvec4", "else", "enum", "extern", "external", "false", "filter",
    "fixed", "flat", "float", "for", "fvec2", "fvec3", "fvec4", "goto", "half", "highp",
    "hvec2", "hvec3", "hvec4", "if", "iimage1D", "iimage1DArray", "iimage2D",
    "iimage2DArray", "iimage2DMS", "iimage2DMSArray", "iimage2DRect", "iimage3D",
    "iimageBuffer", "iimageCube", "iimageCubeArray", "image1D", "image1DArray",
    "image2D", "image2DArray", "image2DMS", "image2DMSArray", "image2DRect",
    "image3D", "imageBuffer", "imageCube", "imageCubeArray", "in", "inline", "inout",
    "input", "int", "interface", "invariant", "isampler1D", "isampler1DArray",
    "isampler2D", "isampler2DArray", "isampler2DMS", "isampler2DMSArray",
    "isampler2DRect", "isampler3D", "isamplerBuffer", "isamplerCube",
    "isamplerCubeArray", "ivec2", "ivec3", "ivec4", "layout", "long", "lowp", "mat2",
    "mat2x2", "mat2x3", "mat2x4", "mat3", "mat3x2", "mat3x3", "mat3x4", "mat4",
    "mat4x2", "mat4x3", "mat4x4", "mediump", "namespace", "noinline", "noperspective",
    "out", "output", "packed", "partition", "patch", "precise", "precision", "public",
    "readonly", "resource", "restrict", "return", "sample", "sampler1D",
    "sampler1DArray", "sampler1DArrayShadow", "sampler1DShadow", "sampler2D",
    "sampler2DArray", "sampler2DArrayShadow", "sampler2DMS", "sampler2DMSArray",
    "sampler2DRect", "sampler2DRectShadow", "sampler2DShadow", "sampler3D",
    "sampler3DRect", "samplerBuffer", "samplerCube", "samplerCubeArray",
    "samplerCubeArrayShadow", "samplerCubeShadow", "shared", "short", "sizeof",
    "smooth", "static", "struct", "subroutine", "superp", "switch", "template", "this",
    "true", "typedef", "uimage1D", "uimage1DArray", "uimage2D", "uimage2DArray",
    "uimage2DMS", "uimage2DMSArray", "uimage2DRect", "uimage3D", "uimageBuffer",
    "uimageCube", "uimageCubeArray", "uint", "uniform", "union", "unsigned",
    "usampler1D", "usampler1DArray", "usampler2D", "usampler2DArray",
    "usampler2DMS", "usampler2DMSArray", "usampler2DRect", "usampler3D",
    "usamplerBuffer", "usamplerCube", "usamplerCubeArray", "using", "uvec2", "uvec3",
    "uvec4", "varying", "vec2", "vec3", "vec4", "void", "volatile", "while",
    "writeonly",
];

bool isAlnum(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c);
bool isDigit(char c) => c >= '0' && c <= '9';

bool startsWith(const(char)[] s, const(char)[] p) => s.length >= p.length && s[0 .. p.length] == p;

/// Why an interface name (or, with `member`, a uniform struct's field name)
/// would not survive translation to GLSL, or null: a host binding by the D
/// name would then find nothing. These are spirv-cross's rules: it renames a
/// name GLSL reserves, one with the `gl_` or `spv` prefix, the `_<digits>`
/// names it gives temporaries (`_m<digits>` for members), and any character
/// outside ASCII letters, digits and `_`; and it collapses a run of
/// underscores (`spirv_cross_parsed_ir.cpp`).
const(char)* unreservedRefusal(const(char)[] name, bool member)
{
    foreach (r; glslReserved)
        if (r == name)
            return "GLSL reserves it";
    if (name.startsWith("gl_"))
        return "GLSL reserves the `gl_` prefix";
    if (name.startsWith("spv"))
        return "the translation reserves the `spv` prefix";
    foreach (c; name)
        if (!isAlnum(c) && c != '_')
            return "the translation keeps only ASCII letters, digits and `_`";
    foreach (i; 1 .. name.length)
        if (name[i] == '_' && name[i - 1] == '_')
            return "the translation collapses a run of underscores";
    // `_<digits>` and `_<digits>_...` name the translation's temporaries;
    // `_m<digits>` its unnamed members.
    const prefix = member ? "_m" : "_";
    if (name.startsWith(prefix))
    {
        auto digitsFrom = name[prefix.length .. $];
        if (digitsFrom.length && isDigit(digitsFrom[0]))
        {
            size_t i = 0;
            while (i < digitsFrom.length && isDigit(digitsFrom[i]))
                i++;
            auto rest = digitsFrom[i .. $];
            if (!rest.length || (!member && rest[0] == '_'))
                return "the translation names its own temporaries so";
        }
    }
    return null;
}

/// Rejects an interface name, or a uniform struct's field name, that the
/// translation would not keep.
void checkTranslatable(Dsymbol s, const(char)* what, Type t = null)
{
    const member = strcmp(what, "uniform struct field") == 0;
    if (auto why = unreservedRefusal(s.ident.toString(), member))
    {
        error(s.loc, "%s `%s` cannot keep its name in GLSL: %s", what, s.ident.toChars(), why);
        fatal();
    }
    if (!t)
        return;
    t = t.toBasetype();
    while (t.ty == TY.Tsarray)
        t = t.nextOf().toBasetype();
    if (auto ts = t.isTypeStruct())
        foreach (field; ts.sym.fields)
            checkTranslatable(field, "uniform struct field", field.type);
}

// ---- one variable per name ----------------------------------------------------

/// What an interface name is across the module's entry points of one stage:
/// its kind and location or binding are the stage's, not one entry point's,
/// so every entry naming it must agree, or one of them would read through a
/// decoration it did not ask for.
struct InterfaceUse
{
    const(char)* kind; // "input", "output", "uniform" or "image"
    int ordinal;       // the location or binding; -1 for a uniform
    const(char)* type; // the D type, unqualified and fully qualified by module
    const(char)* entry;
}

__gshared InterfaceUse[string] interfaceUses;
__gshared FuncDeclaration[string] entryNames;

const(char)* article(const(char)* kind) => kind[0] == 'i' || kind[0] == 'o' ? "an" : "a";

void recordInterfaceUse(ShaderStage stage, VarDeclaration vd, const(char)* entry,
    const(char)* kind, int ordinal)
{
    import dmd.typesem : mutableOf, unSharedOf;

    const name = vd.ident.toChars();
    // One variable per name and stage: a vertex output and the fragment input
    // it feeds share their name.
    const key = (stage == ShaderStage.vertex ? "vertex " : "") ~ vd.ident.toString().idup;
    // `in float` and `float` are one interface type; two structs of one name
    // from two modules are not.
    const type = unSharedOf(mutableOf(vd.type.toBasetype())).toPrettyChars(true);
    auto first = key in interfaceUses;
    if (!first)
    {
        interfaceUses[key] = InterfaceUse(kind, ordinal, type, entry);
        return;
    }
    if (strcmp(first.kind, kind) != 0)
    {
        error(vd.loc, "shader interface name `%s` is %s %s in `%s` but %s %s in `%s`; an interface name is one variable across the module",
            name, article(kind), kind, entry, article(first.kind), first.kind, first.entry);
        fatal();
    }
    if (strcmp(first.type, type) != 0)
    {
        error(vd.loc, "shader %s `%s` is `%s` in `%s` but `%s` in `%s`; an interface name is one variable across the module, so every entry point must give it the same type",
            kind, name, type, entry, first.type, first.entry);
        fatal();
    }
    if (first.ordinal != ordinal)
    {
        const what = strcmp(kind, "image") == 0 ? "binding" : "location";
        error(vd.loc, "shader %s `%s` is at %s %d in `%s` but %s %d in `%s`; an interface name is one variable across the module, so every entry point must give it the same %s",
            kind, name, what.ptr, ordinal, entry, what.ptr, first.ordinal, first.entry, what.ptr);
        fatal();
    }
}

// ---- 64-bit integers -------------------------------------------------------------

/**
With `-mdcompute-report-int64`, names the D source line of every 64-bit
integer operation in code the entry points reach (`SHM6`). The build step
asks for it when a profile that denies `int64` meets a module that declares
`Int64`: the module says that something computes in 64 bits, this says
where. Arithmetic on `size_t` (a `foreach` index, `cast(size_t) i + 1`) is
the usual source; an `int` index widened only to address an array is not
reported, as it reaches the module in 32 bits.
*/
void reportInt64(FuncDeclaration[] roots)
{
    import dmd.visitor : SemanticTimeTransitiveVisitor;

    static bool is64(Type t)
    {
        if (!t)
            return false;
        const ty = t.toBasetype().ty;
        return ty == TY.Tint64 || ty == TY.Tuns64;
    }

    extern (C++) final class Reporter : SemanticTimeTransitiveVisitor
    {
        alias visit = SemanticTimeTransitiveVisitor.visit;
        FuncDeclaration[] queue;
        bool[void*] seen;

        void enqueue(FuncDeclaration fd)
        {
            if (fd && fd.fbody && cast(void*) fd !in seen)
            {
                seen[cast(void*) fd] = true;
                queue ~= fd;
            }
        }

        void report(Expression e)
        {
            message(e.loc, "64-bit integer operation `%s` (`%s`); the profile denies `int64`",
                e.toChars(), e.type.toChars());
        }

        override void visit(BinExp e)
        {
            const constant = e.e1.isIntegerExp() && e.e2.isIntegerExp();
            const move = e.isAssignExp() || e.isConstructExp() || e.isBlitExp();
            if (!constant && !move && (is64(e.e1.type) || is64(e.e2.type)))
                report(e);
            super.visit(e);
        }

        override void visit(NegExp e)
        {
            if (is64(e.type))
                report(e);
            super.visit(e);
        }

        override void visit(ComExp e)
        {
            if (is64(e.type))
                report(e);
            super.visit(e);
        }

        override void visit(CallExp e)
        {
            enqueue(e.f);
            super.visit(e);
        }
    }

    auto r = new Reporter();
    foreach (fd; roots)
        r.enqueue(fd);
    for (size_t i = 0; i < r.queue.length; i++)
        r.queue[i].fbody.accept(r);
}

// ---- resources ---------------------------------------------------------------

enum ItemKind
{
    input,
    builtin,
    uniform,
    image,
    uniformBlock,
    pushConstants,
}

/// One parameter of an entry point, or a field of a `@resources` struct that
/// stands for one.
struct Item
{
    ItemKind kind;
    VarDeclaration decl;
    int parameter;
    int[] path;         // the field indices from the parameter, if flattened
    int fixedBinding = -1;
    Type blockType;     // a block's `T`
    int builtinSpirv;
    const(char)* builtinName;
}

/// `ldc.dcompute`'s `UniformBlock!T` or `PushConstants!T`, and its `T`.
Type blockOf(Type t, out bool push)
{
    auto ts = t.toBasetype().isTypeStruct();
    if (!ts || !isFromLdcDCompute(ts.sym) || ts.sym.fields.length != 1)
        return null;
    if (ts.sym.ident == Id.dcUniformBlock)
        push = false;
    else if (ts.sym.ident == Id.dcPushConstants)
        push = true;
    else
        return null;
    return ts.sym.fields[0].type.toBasetype();
}

void collectItems(VarDeclaration vd, int parameter, int[] path, const(char)* attr,
    ShaderStage stage, ref Item[] items)
{
    const name = vd.ident.toChars();
    auto dty = vd.type.toBasetype();
    auto ts = dty.isTypeStruct();
    const isInput = hasMarker(vd, Id.udaShaderInput);
    const isUniform = hasMarker(vd, Id.udaShaderUniform);
    const builtinId = builtinOf(vd);
    const isBuiltin = builtinId >= 0;
    const isImage = ts && ts.sym.ident == Id.dcSampler2D && isFromLdcDCompute(ts.sym);
    bool push;
    auto blockType = blockOf(dty, push);
    const isResources = ts && dcomputeAttribute(ts.sym, Id.udaShaderResources) !is null;
    const what = path.length ? "resource field".ptr : "parameter".ptr;
    auto bindingAttr = dcomputeAttribute(vd, Id.udaShaderBinding, Type.tint32);
    const fixed = bindingAttr ? cast(int) (*bindingAttr.elements)[0].toInteger() : -1;

    if (isBuiltin && (isInput || isUniform))
    {
        error(vd.loc, "%s parameter `%s` is marked both `@builtin` and `%s`; it must be one",
            attr, name, isInput ? "@input".ptr : "@uniform".ptr);
        fatal();
    }
    if (isInput && isUniform)
    {
        error(vd.loc, "%s parameter `%s` is marked both `@input` and `@uniform`; it must be one", attr, name);
        fatal();
    }
    if ((isInput || isUniform) && (isImage || blockType || isResources))
    {
        error(vd.loc, isImage
            ? "%s parameter `%s` is a `Sampler2D`, which takes no `@input` or `@uniform` marker"
            : "%s parameter `%s` is a resource, which takes no `@input` or `@uniform` marker",
            attr, name);
        fatal();
    }
    if (path.length && (isInput || isBuiltin))
    {
        error(vd.loc, "%s resource field `%s` is marked `%s`; a `@resources` struct holds only resources",
            attr, name, isInput ? "@input".ptr : "@builtin".ptr);
        fatal();
    }

    Item it;
    it.decl = vd;
    it.parameter = parameter;
    it.path = path;
    it.fixedBinding = fixed;
    if (isResources)
    {
        foreach (k, field; ts.sym.fields)
            collectItems(field, parameter, path ~ cast(int) k, attr, stage, items);
        return;
    }
    if (isBuiltin)
    {
        auto b = checkBuiltin(vd, builtinId, what, stage, false);
        it.kind = ItemKind.builtin;
        it.builtinSpirv = b.spirv;
        it.builtinName = b.name.ptr;
        items ~= it;
        return;
    }
    if (blockType)
    {
        if (!blockType.isTypeStruct())
        {
            error(vd.loc, "%s %s `%s` cannot be `%s`: a block is a struct of uniform types",
                attr, what, name, vd.type.toChars());
            fatal();
        }
        if (auto why = refusal(blockType, Crossing.uniform))
        {
            error(vd.loc, "%s %s `%s` cannot be `%s`: %s", attr, what, name, vd.type.toChars(), why);
            fatal();
        }
        checkTranslatable(vd, stage == ShaderStage.vertex ? "`@vertex` parameter" : "`@fragment` parameter",
            blockType);
        it.kind = push ? ItemKind.pushConstants : ItemKind.uniformBlock;
        it.blockType = blockType;
        items ~= it;
        return;
    }
    if (isInput || isUniform)
    {
        const crossing = isUniform ? Crossing.uniform
            : stage == ShaderStage.vertex ? Crossing.vertexInput : Crossing.varying;
        if (auto why = refusal(dty, crossing))
        {
            error(vd.loc, "%s parameter `%s` cannot be `%s`: %s", attr, name, vd.type.toChars(), why);
            fatal();
        }
    }
    else if (!isImage)
    {
        error(vd.loc, path.length
            ? "%s resource field `%s` must be a resource: `@uniform`, a `Sampler2D`, a block or a `@resources` struct"
            : "%s parameter `%s` must be marked `@input`, `@uniform` or `@builtin`, or be a `Sampler2D`",
            attr, name);
        fatal();
    }
    checkTranslatable(vd, stage == ShaderStage.vertex ? "`@vertex` parameter" : "`@fragment` parameter",
        isUniform ? dty : null);
    it.kind = isInput ? ItemKind.input : isUniform ? ItemKind.uniform : ItemKind.image;
    items ~= it;
}

// ---- block layout -------------------------------------------------------------
//
// std140 and std430, as the OpenGL 4.6 specification defines them in
// §7.6.2.2: what `sparkles.shaders.layout` computes for the host, so that the
// host and the device agree on every byte.

enum Rule : int
{
    std140 = 0,
    std430 = 1,
}

size_t roundUp(size_t n, size_t to) => (n + to - 1) / to * to;

size_t vectorLengthOf(Type t)
{
    auto tv = t.isTypeVector();
    return tv ? cast(size_t) (cast(TypeSArray) tv.basetype).dim.toInteger() : 0;
}

size_t alignmentOf(Type t, Rule rule)
{
    t = t.toBasetype();
    if (auto n = vectorLengthOf(t))
        return n == 2 ? 8 : 16;
    if (auto sa = t.isTypeSArray())
    {
        const element = alignmentOf(sa.nextOf(), rule);
        return rule == Rule.std140 ? roundUp(element, 16) : element;
    }
    if (auto ts = t.isTypeStruct())
    {
        size_t a = 4;
        foreach (field; ts.sym.fields)
            if (alignmentOf(field.type, rule) > a)
                a = alignmentOf(field.type, rule);
        return rule == Rule.std140 ? roundUp(a, 16) : a;
    }
    return 4;
}

size_t strideOf(Type element, Rule rule)
    => roundUp(sizeOf(element, rule),
        rule == Rule.std140 ? roundUp(alignmentOf(element, rule), 16) : alignmentOf(element, rule));

size_t sizeOf(Type t, Rule rule)
{
    t = t.toBasetype();
    if (auto n = vectorLengthOf(t))
        return 4 * n;
    if (auto sa = t.isTypeSArray())
        return strideOf(sa.nextOf(), rule) * cast(size_t) sa.dim.toInteger();
    if (auto ts = t.isTypeStruct())
    {
        size_t at = 0;
        foreach (field; ts.sym.fields)
            at = roundUp(at, alignmentOf(field.type, rule)) + sizeOf(field.type, rule);
        return roundUp(at, alignmentOf(t, rule));
    }
    return 4;
}

size_t fieldOffset(StructDeclaration sd, size_t index, Rule rule)
{
    size_t at = 0;
    foreach (k, field; sd.fields)
    {
        at = roundUp(at, alignmentOf(field.type, rule));
        if (k == index)
            return at;
        at += sizeOf(field.type, rule);
    }
    assert(0, "no such field");
}

// ---- an entry point's interface -------------------------------------------------

const(ShaderEntry)* describe(FuncDeclaration fd, ShaderStage stage)
{
    const attr = stageAttr(stage);
    const entry = fd.ident.toChars();

    // A SPIR-V entry point's name is the module's, and a second one would be
    // renamed (`tint.1`), not linked.
    const entryName = fd.ident.toString().idup;
    if (auto prior = entryName in entryNames)
    {
        error(fd.loc, "%s entry point `%s` is defined by both `%s` and `%s`; an entry point's name must be unique across the module",
            attr, entry, prior.toPrettyChars(), fd.toPrettyChars());
        fatal();
    }
    entryNames[entryName] = fd;

    auto e = new ShaderEntry(fd, stage);
    ShaderVariable[] vars;

    auto ret = fd.type.nextOf().toBasetype();
    if (stage == ShaderStage.vertex)
    {
        auto ts = ret.isTypeStruct();
        if (!ts)
        {
            error(fd.loc, "%s function `%s` cannot return `%s`: a vertex entry point returns a struct with a position",
                attr, entry, ret.toChars());
            fatal();
        }
        e.result = ts.sym;
    }
    else if (ret.ty != TY.Tvoid)
    {
        if (auto why = refusal(ret, Crossing.output))
        {
            error(fd.loc, "%s function `%s` cannot return `%s`: %s", attr, entry, ret.toChars(), why);
            fatal();
        }
    }

    // The parameters, with every `@resources` struct flattened into its
    // fields (`SHR2`), each a resource of the entry point in its place.
    Item[] items;
    const nparams = fd.parameters ? fd.parameters.length : 0;
    foreach (i; 0 .. nparams)
        collectItems((*fd.parameters)[i], cast(int) i, null, attr, stage, items);

    const blocks = resourcesAsBlocks();
    int nextLocation = 0;

    // Bindings (`SHR7`). OpenGL: the shared sampler at 0, the images from 1
    // in order. Vulkan: the sampler's 0 is reserved, a `@binding` fixes one,
    // and the rest take the next free binding in order, the default uniform
    // block at the place of the first `@uniform`.
    bool[int] taken;
    foreach (ref it; items)
        if (it.fixedBinding >= 0)
        {
            if (it.fixedBinding == 0)
            {
                error(it.decl.loc, "%s resource `%s` cannot be at binding 0, which is the shared sampler's",
                    attr, it.decl.ident.toChars());
                fatal();
            }
            if (auto other = it.fixedBinding in taken)
            {
                error(it.decl.loc, "%s resources `%s` and another are both at binding %d", attr,
                    it.decl.ident.toChars(), it.fixedBinding);
                fatal();
            }
            taken[it.fixedBinding] = true;
        }
    int nextBinding = 1;
    int nextFreeBinding()
    {
        while (nextBinding in taken)
            nextBinding++;
        taken[nextBinding] = true;
        return nextBinding++;
    }

    // Every interface name of the entry point, as lowered, is distinct
    // (`SHF2`).
    VarDeclaration[string] names;
    void claim(const(char)[] name, VarDeclaration vd, VarDeclaration at = null)
    {
        if (auto prior = name in names)
        {
            error((at ? at : vd).loc, "%s entry point `%s` has two interface variables named `%.*s`: `%s` and `%s`",
                attr, entry, cast(int) name.length, name.ptr, prior.toPrettyChars(), vd.toPrettyChars());
            fatal();
        }
        names[name.idup] = vd;
    }

    int defaultMembers = 0;
    bool pushConstantsSeen;
    foreach (ref it; items)
    {
        auto vd = it.decl;
        const name = vd.ident.toChars();
        ShaderVariable v;
        v.decl = vd;
        v.parameter = it.parameter;
        v.name = name;
        v.depth = cast(int) it.path.length;
        foreach (k, p; it.path)
            v.path[k] = p;
        final switch (it.kind)
        {
        case ItemKind.builtin:
            v.kind = ShaderVariableKind.builtinInput;
            v.ordinal = it.builtinSpirv;
            v.name = it.builtinName;
            break;
        case ItemKind.input:
            claim(vd.ident.toString(), vd);
            recordInterfaceUse(stage, vd, entry, "input", nextLocation);
            v.kind = ShaderVariableKind.input;
            v.ordinal = nextLocation++;
            break;
        case ItemKind.uniform:
            if (blocks)
            {
                // A member of the entry point's default uniform block
                // (`SHR3`), its own variable, so not an interface name of
                // the stage.
                if (e.defaultBlockBinding < 0)
                    e.defaultBlockBinding = nextFreeBinding();
                v.kind = ShaderVariableKind.defaultUniform;
                v.ordinal = defaultMembers++;
            }
            else
            {
                claim(vd.ident.toString(), vd);
                recordInterfaceUse(stage, vd, entry, "uniform", -1);
                v.kind = ShaderVariableKind.uniform;
                v.ordinal = -1;
            }
            break;
        case ItemKind.image:
            claim(vd.ident.toString(), vd);
            const binding = it.fixedBinding >= 0 && blocks ? it.fixedBinding
                : blocks ? nextFreeBinding() : nextBinding++;
            recordInterfaceUse(stage, vd, entry, "image", binding);
            v.kind = ShaderVariableKind.image;
            v.ordinal = binding;
            break;
        case ItemKind.uniformBlock:
        case ItemKind.pushConstants:
            const push = it.kind == ItemKind.pushConstants;
            if (push)
            {
                if (pushConstantsSeen)
                {
                    error(vd.loc, "%s entry point `%s` declares a second push-constant block, `%s`; it may declare one",
                        attr, entry, name);
                    fatal();
                }
                pushConstantsSeen = true;
                const size = sizeOf(it.blockType, Rule.std430);
                if (size > 128)
                {
                    error(vd.loc, "%s push-constant block `%s` is %u bytes (std430), over the 128 every Vulkan implementation offers",
                        attr, name, cast(uint) size);
                    fatal();
                }
            }
            v.blockType = it.blockType;
            if (blocks)
            {
                claim(vd.ident.toString(), vd);
                v.kind = push ? ShaderVariableKind.pushConstants : ShaderVariableKind.uniformBlock;
                v.ordinal = push ? -1 : it.fixedBinding >= 0 ? it.fixedBinding : nextFreeBinding();
                recordInterfaceUse(stage, vd, entry, push ? "push-constant block" : "uniform block",
                    v.ordinal);
            }
            else
            {
                // One uniform per field, named after the field.
                foreach (field; it.blockType.isTypeStruct().sym.fields)
                {
                    claim(field.ident.toString(), field, vd);
                    recordInterfaceUse(stage, field, entry, "uniform", -1);
                }
                v.kind = ShaderVariableKind.looseBlock;
                v.ordinal = -1;
            }
            break;
        }
        vars ~= v;
    }
    if (e.defaultBlockBinding >= 0)
    {
        e.defaultBlockName = (entry.toDString() ~ "Uniforms\0").ptr;
        e.defaultBlockTypeName = (entry.toDString() ~ "UniformsBlock\0").ptr;
    }

    if (e.result)
        describeVertexResult(fd, e.result, vars);

    e.variables = vars.ptr;
    e.length = vars.length;
    return e;
}

/// A `@vertex` result's fields: the `@builtin(Builtin.position)` field is the
/// position, and every other field an output named after it, at locations in
/// field order.
void describeVertexResult(FuncDeclaration fd, StructDeclaration sd, ref ShaderVariable[] vars)
{
    const entry = fd.ident.toChars();
    VarDeclaration position;
    int nextLocation = 0;
    foreach (field; sd.fields)
    {
        const name = field.ident.toChars();
        const builtinId = builtinOf(field);
        if (builtinId >= 0)
        {
            auto b = checkBuiltin(field, builtinId, "result field", ShaderStage.vertex, true);
            if (position)
            {
                error(field.loc, "`@vertex` result field `%s` is a second `@builtin(Builtin.position)`; `%s` is the first",
                    name, position.ident.toChars());
                fatal();
            }
            position = field;
            vars ~= ShaderVariable(ShaderVariableKind.builtinOutput, field, -1, b.spirv, b.name.ptr);
            continue;
        }
        if (auto why = refusal(field.type, Crossing.varying))
        {
            error(field.loc, "`@vertex` result field `%s` cannot be `%s`: %s", name, field.type.toChars(), why);
            fatal();
        }
        checkTranslatable(field, "`@vertex` result field");
        recordInterfaceUse(ShaderStage.vertex, field, entry, "output", nextLocation);
        vars ~= ShaderVariable(ShaderVariableKind.output, field, -1, nextLocation++, name);
    }
    if (!position)
    {
        error(fd.loc, "`@vertex` function `%s` returns `%s`, which has no field marked `@builtin(Builtin.position)`",
            entry, sd.toChars());
        fatal();
    }
}
