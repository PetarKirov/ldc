// The resource rules of an entry point: one push-constant block of at most
// 128 bytes (std430), no resource at the sampler's binding 0 or two at one
// binding, every lowered interface name distinct, and a `@resources` struct
// of resources only.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: split-file %s %t
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-resources=blocks -I%t %t/twopush.d 2>&1 | FileCheck %t/twopush.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-resources=blocks -I%t %t/bigpush.d 2>&1 | FileCheck %t/bigpush.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-resources=blocks -I%t %t/binding0.d 2>&1 | FileCheck %t/binding0.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-resources=blocks -I%t %t/samebinding.d 2>&1 | FileCheck %t/samebinding.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -I%t %t/clash.d 2>&1 | FileCheck %t/clash.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -mdcompute-resources=blocks -I%t %t/notresource.d 2>&1 | FileCheck %t/notresource.d

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
// CHECK: samebinding.d(5): Error: `@fragment` resources `v` and another are both at binding 2
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
// CHECK: notresource.d(4): Error: `@fragment` resource field `x` must be a resource: `@uniform`, a `Sampler2D`, a block or a `@resources` struct
@resources struct R { float x; }
@_profiles("vulkan1.3") @fragment __vector(float[4]) f(R r) { return __vector(float[4])(r.x); }
