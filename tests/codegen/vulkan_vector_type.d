// A struct marked `@vectorType` -- one `__vector` field -- is its vector at a
// shader's interface: an input, an output, a built-in, a uniform, a member of
// a block, or an element of an array in one, with the vector's type and
// layout. Inside the shader it stays the struct, with its operators. A
// template's data (the struct's `__init`) is internal, so the module needs no
// `Linkage` capability.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -mdcompute-file-prefix=vk_vector_type -output-o %s
// RUN: spirv-dis vk_vector_type_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vk_vector_type_vulkan130_64.spv

// CHECK-NOT: OpCapability Linkage
// CHECK-DAG: OpMemberDecorate %Params 0 Offset 0
// CHECK-DAG: OpMemberDecorate %Params 1 Offset 16
// CHECK-DAG: OpMemberDecorate %Params 2 Offset 32
// CHECK-DAG: OpMemberDecorate %Params 3 Offset 44
// CHECK-DAG: OpMemberDecorate %Params 4 Offset 48
// CHECK-DAG: OpDecorate %{{[a-zA-Z0-9_]+}} ArrayStride 16
// CHECK-DAG: %Params = OpTypeStruct %v4float %v2float %v3float %float %Matrix
// CHECK-DAG: %Matrix = OpTypeStruct %{{[a-zA-Z0-9_]+}}
// CHECK-DAG: %Push = OpTypeStruct %v2float
// CHECK-DAG: %a = OpVariable %_ptr_Input_v2float Input
// CHECK-DAG: %n = OpVariable %_ptr_Input_v3float Input
// CHECK-DAG: %position = OpVariable %_ptr_Output_v4float Output
// CHECK-DAG: %uv = OpVariable %_ptr_Output_v2float Output
// CHECK-DAG: %fragCoord = OpVariable %_ptr_Input_v4float Input
// CHECK-DAG: %finalColor = OpVariable %_ptr_Output_v4float Output
// CHECK-DAG: %fsUniformsBlock = OpTypeStruct %v4float

@compute(CompileFor.deviceOnly) module vulkan_vector_type;

import ldc.dcompute;

@vectorType struct Vector(T, size_t N)
{
    __vector(T[N]) v = 0;
    Vector opBinary(string op)(in Vector r) const => Vector(mixin("v " ~ op ~ " r.v"));
    Vector opBinary(string op : "*")(T s) const { __vector(T[N]) b = s; return Vector(v * b); }
    ref inout(T) x() inout return => v[0];
}
alias float2 = Vector!(float, 2);
alias float3 = Vector!(float, 3);
alias float4 = Vector!(float, 4);

struct Matrix { float4[4] columns; }
float4 mul(in Matrix m, in float4 p)
    => m.columns[0] * p.v[0] + m.columns[1] * p.v[1] + m.columns[2] * p.v[2] + m.columns[3] * p.v[3];

struct Params { float4 tint; float2 scale; float3 dir; float k; Matrix mvp; }
struct Push { float2 offset; }

struct VsOut
{
    @builtin(Builtin.position) float4 pos;
    float2 uv;
    float3 normal;
}

@_profiles("vulkan1.3") @vertex VsOut vs(@input float2 a, @input float3 n, UniformBlock!Params p, PushConstants!Push q)
{
    VsOut o;
    o.pos = mul(p.mvp, p.tint);
    o.pos.x = a.x * p.scale.x + q.offset.x + p.k;
    o.uv = a;
    o.normal = n + p.dir;
    return o;
}

@_profiles("vulkan1.3") @fragment float4 fs(@input float2 uv, @input float3 normal, @uniform float4 colour,
    @builtin(Builtin.fragCoord) float4 frag)
{
    float4 c = colour + frag;
    c.x = uv.x + normal.x;
    return c;
}
