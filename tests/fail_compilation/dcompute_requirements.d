// What an emitted entry point reaches must be granted (`@requires`): every
// function marked `@requires(c)` and every `unsupported!c` that the entry
// point reaches through the calls in its body fails the compilation unless the
// compilation grants `c`, naming the chain of calls. Of the stages, an entry
// point is granted only its own. An entry point the compilation does not emit
// is not checked, and without a grant nothing is.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: split-file %s %t
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -capabilities=shader:shader,fragmentStage,looseUniforms -I%t %t/chain.d 2>&1 | FileCheck %t/chain.d
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -capabilities=shader:shader,fragmentStage,looseUniforms,derivatives -mdcompute-file-prefix=%t/granted -I%t %t/chain.d
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=%t/ungranted -I%t %t/chain.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,derivatives -I%t %t/stage.d 2>&1 | FileCheck %t/stage.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -capabilities=shader:shader,fragmentStage,looseUniforms -I%t %t/standin.d 2>&1 | FileCheck %t/standin.d
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gles100 -capabilities=shader:shader,fragmentStage,looseUniforms -mdcompute-file-prefix=%t/unemitted -I%t %t/unemitted.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -capabilities=shader:shader,fragmentStage,looseUniforms -I%t %t/unemitted.d 2>&1 | FileCheck %t/unemitted.d
// RUN: not %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=gl330 -capabilities=shader:shader,fragmentStage,looseUniforms -I%t %t/own.d 2>&1 | FileCheck %t/own.d

//--- chain.d
@compute(CompileFor.deviceOnly) module chain;
import ldc.dcompute;

@requires(Capability.derivatives) T slope(T)(T v) { return v; }
float helper(float x) { return slope(x) * 2; }
float outer(float x) { return helper(x) + 1; }

// CHECK: chain.d([[@LINE+4]]): Error: entry point `shade` reaches `chain.slope!float`, which requires `derivatives`; the profile `gl330` does not grant it
// CHECK: chain.d([[@LINE+5]]): `chain.shade` calls `chain.outer`
// CHECK: chain.d(6): `chain.outer` calls `chain.helper`
// CHECK: chain.d(5): `chain.helper` calls `chain.slope!float`
@fragment __vector(float[4]) shade(@input __vector(float[4]) c)
{
    return c * outer(c[0]);
}

//--- stage.d
@compute(CompileFor.deviceOnly) module stage;
import ldc.dcompute;

@requires(Capability.fragmentStage) float fragmentOnly(float x) { return x; }
struct V { @builtin(Builtin.position) __vector(float[4]) position; }

// CHECK: stage.d([[@LINE+2]]): Error: entry point `tri` reaches `stage.fragmentOnly`, which requires `fragmentStage`; `@vertex` entry points are not granted `fragmentStage`
// CHECK-NOT: entry point `shade`
@_profiles("vulkan1.3") @vertex V tri()
{
    V v;
    v.position = fragmentOnly(1);
    return v;
}

@_profiles("vulkan1.3") @fragment __vector(float[4]) shade(@input __vector(float[4]) c)
{
    return c * fragmentOnly(2);
}

//--- standin.d
@compute(CompileFor.deviceOnly) module standin;
import ldc.dcompute;

// What a library writes where a capability may be missing: the body that
// needs it, or a stand-in.
float demoteIf(bool granted)(float x)
{
    static if (granted)
        return x;
    else
        return unsupported!(Capability.demote)(x);
}

// CHECK: standin.d([[@LINE+2]]): Error: entry point `shade` reaches `ldc.dcompute.unsupported!(Capability.demote, float)`, which stands in for `demote`; the profile `gl330` does not grant it
// CHECK: standin.d([[@LINE+3]]): `standin.shade` calls `standin.demoteIf!false`
@fragment __vector(float[4]) shade(@input __vector(float[4]) c)
{
    return c * demoteIf!false(1) * demoteIf!true(2);
}

//--- unemitted.d
@compute(CompileFor.deviceOnly) module unemitted;
import ldc.dcompute;

@requires(Capability.derivatives) float slope(float v) { return v; }

// Built for `gl330` only: `gles100` neither emits nor checks it.
// CHECK: unemitted.d([[@LINE+1]]): Error: entry point `onlyGl` reaches `unemitted.slope`, which requires `derivatives`; the profile `gl330` does not grant it
@_profiles("gl330") @fragment __vector(float[4]) onlyGl(@input __vector(float[4]) c)
{
    return c * slope(1);
}

@_profiles("gl330,gles100") @fragment __vector(float[4]) both(@input __vector(float[4]) c)
{
    return c;
}

//--- own.d
@compute(CompileFor.deviceOnly) module own;
import ldc.dcompute;

// CHECK: own.d([[@LINE+1]]): Error: entry point `shade` requires `demote`; the profile `gl330` does not grant it
@requires(Capability.demote) @fragment __vector(float[4]) shade(@input __vector(float[4]) c)
{
    return c;
}
