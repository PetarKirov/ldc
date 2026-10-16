// An interface name is one variable across the module, so the entry points
// naming it must agree on its kind, location and binding; and only what both
// GLSL dialects can declare there may cross a fragment shader's interface.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: split-file %s %t
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/location.d 2>&1 | FileCheck %t/location.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/binding.d 2>&1 | FileCheck %t/binding.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/kind.d 2>&1 | FileCheck %t/kind.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/type.d 2>&1 | FileCheck %t/type.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/samename.d %t/lighta.d %t/lightb.d 2>&1 | FileCheck %t/samename.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/intinput.d 2>&1 | FileCheck %t/intinput.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/dupentry.d %t/dupother.d 2>&1 | FileCheck %t/dupentry.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/keyword.d 2>&1 | FileCheck %t/keyword.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/glprefix.d 2>&1 | FileCheck %t/glprefix.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/underscores.d 2>&1 | FileCheck %t/underscores.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/field.d 2>&1 | FileCheck %t/field.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/twomarkers.d 2>&1 | FileCheck %t/twomarkers.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/markedimage.d 2>&1 | FileCheck %t/markedimage.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/uint.d 2>&1 | FileCheck %t/uint.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/arrayinput.d 2>&1 | FileCheck %t/arrayinput.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -I%t %t/result.d 2>&1 | FileCheck %t/result.d

//--- location.d
@compute(CompileFor.deviceOnly) module location;
import ldc.dcompute;
alias float2 = __vector(float[2]);
alias float4 = __vector(float[4]);
@fragment float4 first(@input float4 fragColor) { return fragColor; }
// CHECK: location.d([[@LINE+1]]): Error: shader input `fragColor` is at location 1 in `second` but location 0 in `first`
@fragment float4 second(@input float2 uv, @input float4 fragColor) { return fragColor; }

//--- binding.d
@compute(CompileFor.deviceOnly) module binding;
import ldc.dcompute;
alias float2 = __vector(float[2]);
alias float4 = __vector(float[4]);
@fragment float4 first(Sampler2D texB) { return texB.sample(float2(0.5f)); }
// CHECK: binding.d([[@LINE+1]]): Error: shader image `texB` is at binding 2 in `second` but binding 1 in `first`
@fragment float4 second(Sampler2D texA, Sampler2D texB) { return texB.sample(float2(0.5f)); }

//--- kind.d
@compute(CompileFor.deviceOnly) module kind;
import ldc.dcompute;
alias float4 = __vector(float[4]);
@fragment float4 first(@uniform float u) { return float4(u); }
// CHECK: kind.d([[@LINE+1]]): Error: shader interface name `u` is an input in `second` but a uniform in `first`
@fragment float4 second(@input float u) { return float4(u); }

//--- type.d
@compute(CompileFor.deviceOnly) module type;
import ldc.dcompute;
alias float2 = __vector(float[2]);
alias float4 = __vector(float[4]);
@fragment float4 first(@uniform float scale) { return float4(scale); }
// CHECK: type.d([[@LINE+1]]): Error: shader uniform `scale` is `__vector(float[2])` in `second` but `float` in `first`
@fragment float4 second(@uniform float2 scale) { return float4(scale[0]); }

//--- samename.d
@compute(CompileFor.deviceOnly) module samename;
import ldc.dcompute;
static import lighta, lightb;
alias float4 = __vector(float[4]);
@fragment float4 first(@uniform lighta.Light light) { return float4(light.gain); }
// CHECK: samename.d([[@LINE+1]]): Error: shader uniform `light` is `lightb.Light` in `second` but `lighta.Light` in `first`
@fragment float4 second(@uniform lightb.Light light) { return float4(light.gain); }

//--- lighta.d
@compute(CompileFor.hostAndDevice) module lighta;
import ldc.dcompute;
struct Light { float gain; }

//--- lightb.d
@compute(CompileFor.hostAndDevice) module lightb;
import ldc.dcompute;
struct Light { float gain; float bias; }

//--- dupentry.d
@compute(CompileFor.deviceOnly) module dupentry;
import ldc.dcompute;
alias float4 = __vector(float[4]);
@fragment float4 tint(@input float4 c) { return c; }
// CHECK: Error: `@fragment` entry point `tint` is defined by both `{{dupentry|dupother}}.tint` and `{{dupentry|dupother}}.tint`; an entry point's name must be unique across the module

//--- dupother.d
@compute(CompileFor.deviceOnly) module dupother;
import ldc.dcompute;
alias float4 = __vector(float[4]);
@fragment float4 tint(@input float4 c) { return c; }

//--- keyword.d
@compute(CompileFor.deviceOnly) module keyword;
import ldc.dcompute;
alias float4 = __vector(float[4]);
// CHECK: keyword.d([[@LINE+1]]): Error: `@fragment` parameter `smooth` cannot keep its name in GLSL: GLSL reserves it
@fragment float4 first(@uniform float smooth) { return float4(smooth); }

//--- glprefix.d
@compute(CompileFor.deviceOnly) module glprefix;
import ldc.dcompute;
alias float4 = __vector(float[4]);
// CHECK: glprefix.d([[@LINE+1]]): Error: `@fragment` parameter `gl_tint` cannot keep its name in GLSL: GLSL reserves the `gl_` prefix
@fragment float4 first(@input float4 gl_tint) { return gl_tint; }

//--- underscores.d
@compute(CompileFor.deviceOnly) module underscores;
import ldc.dcompute;
alias float4 = __vector(float[4]);
// CHECK: underscores.d([[@LINE+1]]): Error: `@fragment` parameter `a__b` cannot keep its name in GLSL: the translation collapses a run of underscores
@fragment float4 first(@uniform float a__b) { return float4(a__b); }

//--- field.d
@compute(CompileFor.deviceOnly) module field;
import ldc.dcompute;
alias float4 = __vector(float[4]);
// CHECK: field.d([[@LINE+1]]): Error: uniform struct field `filter` cannot keep its name in GLSL: GLSL reserves it
struct Light { float filter; }
@fragment float4 first(@uniform Light light) { return float4(light.filter); }

//--- twomarkers.d
@compute(CompileFor.deviceOnly) module twomarkers;
import ldc.dcompute;
alias float2 = __vector(float[2]);
alias float4 = __vector(float[4]);
// CHECK: twomarkers.d([[@LINE+1]]): Error: `@fragment` parameter `uv` is marked both `@input` and `@uniform`; it must be one
@fragment float4 first(@input @uniform float2 uv) { return float4(uv[0]); }

//--- markedimage.d
@compute(CompileFor.deviceOnly) module markedimage;
import ldc.dcompute;
alias float2 = __vector(float[2]);
alias float4 = __vector(float[4]);
// CHECK: markedimage.d([[@LINE+1]]): Error: `@fragment` parameter `t` is a `Sampler2D`, which takes no `@input` or `@uniform` marker
@fragment float4 first(@uniform Sampler2D t) { return t.sample(float2(0.5f)); }

//--- intinput.d
@compute(CompileFor.deviceOnly) module intinput;
import ldc.dcompute;
alias float4 = __vector(float[4]);
// CHECK: intinput.d([[@LINE+1]]): Error: `@fragment` parameter `n` cannot be `int`: an integer cannot be interpolated; pass it as a `@uniform`
@fragment float4 first(@input int n) { return float4(cast(float) n); }

//--- uint.d
@compute(CompileFor.deviceOnly) module uint_;
import ldc.dcompute;
alias float4 = __vector(float[4]);
// CHECK: uint.d([[@LINE+1]]): Error: `@fragment` parameter `n` cannot be `uint`: GLSL ES 1.00 has no unsigned integers
@fragment float4 first(@uniform uint n) { return float4(cast(float) n); }

//--- arrayinput.d
@compute(CompileFor.deviceOnly) module arrayinput;
import ldc.dcompute;
alias float4 = __vector(float[4]);
// CHECK: arrayinput.d([[@LINE+1]]): Error: `@fragment` parameter `n` cannot be `float[2]`: only a `@uniform` can be an array
@fragment float4 first(@input float[2] n) { return float4(n[0]); }

//--- result.d
@compute(CompileFor.deviceOnly) module result;
import ldc.dcompute;
alias float3 = __vector(float[3]);
// CHECK: result.d([[@LINE+1]]): Error: `@fragment` function `first` cannot return `__vector(float[3])`: the output is a vector of four `float`s, as GLSL ES 1.00's `gl_FragData[0]` is
@fragment float3 first(@input float3 c) { return c; }
