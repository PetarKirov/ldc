// The resource rules of an entry point: one push-constant block of at most
// 128 bytes (std430), no resource at the sampler's binding 0 or two at one
// binding, every lowered interface name distinct (the compiler's own among
// them), a `@resources` struct of resources only, nested no deeper than the
// compiler supports; and `@binding` ignored by the OpenGL profiles.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: split-file %s %t
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/twopush.d 2>&1 | FileCheck %t/twopush.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/bigpush.d 2>&1 | FileCheck %t/bigpush.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/binding0.d 2>&1 | FileCheck %t/binding0.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/samebinding.d 2>&1 | FileCheck %t/samebinding.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -I%t %t/clash.d 2>&1 | FileCheck %t/clash.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/notresource.d 2>&1 | FileCheck %t/notresource.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/colour.d 2>&1 | FileCheck %t/colour.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/defaultblock.d 2>&1 | FileCheck %t/defaultblock.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/deep.d 2>&1 | FileCheck %t/deep.d
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -mdcompute-file-prefix=%t/glbinding -I%t %t/glbinding.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/dupuniform.d 2>&1 | FileCheck %t/dupuniform.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -I%t %t/vertexclash.d 2>&1 | FileCheck %t/vertexclash.d

//--- twopush.d
@compute(CompileFor.deviceOnly) module twopush;
import ldc.dcompute;
struct P { float a; }
// CHECK: twopush.d(5): Error: `@fragment` entry point `f` declares a second push-constant block, `q`; it may declare one
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(PushConstants!P p, PushConstants!P q) { return __vector(float[4])(p.a + q.a); }

//--- bigpush.d
@compute(CompileFor.deviceOnly) module bigpush;
import ldc.dcompute;
struct P { __vector(float[4])[9] a; }
// CHECK: bigpush.d(5): Error: `@fragment` push-constant block `p` is 144 bytes (std430), over the 128 every Vulkan implementation offers
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(PushConstants!P p) { return p.a[0]; }

//--- binding0.d
@compute(CompileFor.deviceOnly) module binding0;
import ldc.dcompute;
struct U { float a; }
// CHECK: binding0.d(5): Error: `@fragment` resource `u` cannot be at binding 0, which is the shared sampler's
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(@binding(0) UniformBlock!U u) { return __vector(float[4])(u.a); }

//--- samebinding.d
@compute(CompileFor.deviceOnly) module samebinding;
import ldc.dcompute;
struct U { float a; }
// CHECK: samebinding.d(5): Error: `@fragment` resources `samebinding.f.u` and `samebinding.f.v` are both at binding 2
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(@binding(2) UniformBlock!U u, @binding(2) UniformBlock!U v) { return __vector(float[4])(u.a + v.a); }

//--- clash.d
@compute(CompileFor.deviceOnly) module clash;
import ldc.dcompute;
struct U { float gain; }
// CHECK: clash.d(5): Error: `@fragment` entry point `f` has two interface variables named `gain`: `clash.f.gain` and `clash.U.gain`
@fragment __vector(float[4]) f(@uniform float gain, UniformBlock!U u) { return __vector(float[4])(gain + u.gain); }

//--- notresource.d
@compute(CompileFor.deviceOnly) module notresource;
import ldc.dcompute;
// CHECK: notresource.d(4): Error: `@fragment` resource field `x` must be a resource: `@uniform`, a `Sampler2D`, a `SamplerState`, a block or a `@resources` struct
@resources struct R { float x; }
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(R r) { return __vector(float[4])(r.x); }

//--- colour.d
@compute(CompileFor.deviceOnly) module colour;
import ldc.dcompute;
// CHECK: colour.d(4): Error: `@fragment` entry point `f` has two interface variables named `finalColor`: the colour output and `colour.f.finalColor`
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(@input __vector(float[4]) finalColor) { return finalColor; }

//--- defaultblock.d
@compute(CompileFor.deviceOnly) module defaultblock;
import ldc.dcompute;
struct U { float a; }
// CHECK: defaultblock.d(5): Error: `@fragment` entry point `lit` has two interface variables named `litUniforms`: the default uniform block and `defaultblock.lit.litUniforms`
@_profiles("vulkan1.3") @fragment __vector(float[4]) lit(@uniform float x, UniformBlock!U litUniforms) { return __vector(float[4])(x + litUniforms.a); }

//--- deep.d
@compute(CompileFor.deviceOnly) module deep;
import ldc.dcompute;
@resources struct R0 { @uniform float x; }
@resources struct R1 { R0 r; }
@resources struct R2 { R1 r; }
@resources struct R3 { R2 r; }
@resources struct R4 { R3 r; }
@resources struct R5 { R4 r; }
@resources struct R6 { R5 r; }
@resources struct R7 { R6 r; }
// CHECK: deep.d(4): Error: `@fragment` resource field `r` nests `@resources` structs 9 deep, more than the 8 the compiler supports
@resources struct R8 { R7 r; }
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(R8 r) { return __vector(float[4])(r.r.r.r.r.r.r.r.r.x); }

//--- glbinding.d
// Under OpenGL a block is its fields as uniforms, and `@binding` is ignored,
// so two blocks at one fixed binding are not a clash.
@compute(CompileFor.deviceOnly) module glbinding;
import ldc.dcompute;
struct A { float a; }
struct B { float b; }
@fragment __vector(float[4]) f(@binding(2) UniformBlock!A u, @binding(2) UniformBlock!B v) { return __vector(float[4])(u.a + v.b); }

//--- dupuniform.d
// The members of the default uniform block are interface names too.
@compute(CompileFor.deviceOnly) module dupuniform;
import ldc.dcompute;
@resources struct R1 { @uniform float gain; }
// CHECK: dupuniform.d(6): Error: `@fragment` entry point `f` has two interface variables named `gain`: `dupuniform.R1.gain` and `dupuniform.R2.gain`
@resources struct R2 { @uniform float gain; }
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(R1 a, R2 b) { return __vector(float[4])(a.gain + b.gain); }

//--- vertexclash.d
// So are a vertex entry point's outputs.
@compute(CompileFor.deviceOnly) module vertexclash;
import ldc.dcompute;
struct P { float s; }
// CHECK: vertexclash.d(9): Error: `@vertex` entry point `v` has two interface variables named `pc`: `vertexclash.v.pc` and `vertexclash.Out.pc`
struct Out
{
    @builtin(Builtin.position) __vector(float[4]) position;
    __vector(float[4]) pc;
}
@_profiles("vulkan1.3") @vertex Out v(PushConstants!P pc) { Out o; o.position = __vector(float[4])(pc.s); o.pc = o.position; return o; }
