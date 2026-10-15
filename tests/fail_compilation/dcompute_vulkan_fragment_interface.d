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
