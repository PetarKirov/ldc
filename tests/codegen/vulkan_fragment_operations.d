// A fragment entry point's stage operations: `@builtin(Builtin.fragCoord)`
// and `@builtin(Builtin.frontFacing)` read the `FragCoord` and `FrontFacing`
// built-ins (a `bool` one is SPIR-V's `OpTypeBool`); the SPIR-V intrinsics
// for derivatives, coarse and fine, ending the invocation and demoting it
// reach the module as their instructions.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_fragment_ops -output-o %s
// RUN: spirv-dis vulkan_fragment_ops_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vulkan_fragment_ops_vulkan130_64.spv

// CHECK-DAG: OpCapability DerivativeControl
// CHECK-DAG: OpCapability DemoteToHelperInvocation
// CHECK-DAG: OpExecutionMode %shade OriginUpperLeft
// CHECK-DAG: OpDecorate %[[FC:[a-zA-Z0-9_.]+]] BuiltIn FragCoord
// CHECK-DAG: OpDecorate %[[FF:[a-zA-Z0-9_.]+]] BuiltIn FrontFacing
// CHECK-DAG: %[[BOOL:[a-zA-Z0-9_]+]] = OpTypeBool
// CHECK-DAG: %[[PBOOL:[a-zA-Z0-9_]+]] = OpTypePointer Input %[[BOOL]]
// CHECK-DAG: %[[FF]] = OpVariable %[[PBOOL]] Input
// CHECK-DAG: %[[FC]] = OpVariable %{{[a-zA-Z0-9_]+}} Input
// CHECK-DAG: OpDPdx
// CHECK-DAG: OpDPdyCoarse
// CHECK-DAG: OpDPdxFine
// CHECK-DAG: OpFwidth
// CHECK-DAG: OpDemoteToHelperInvocation
// CHECK-DAG: OpTerminateInvocation

@compute(CompileFor.deviceOnly) module vulkan_fragment_operations;

import ldc.dcompute;

alias float4 = __vector(float[4]);

pragma(LDC_intrinsic, "llvm.spv.ddx.f32") float ddx(float);
pragma(LDC_intrinsic, "llvm.spv.ddy.coarse.f32") float ddyCoarse(float);
pragma(LDC_intrinsic, "llvm.spv.ddx.fine.f32") float ddxFine(float);
pragma(LDC_intrinsic, "llvm.spv.fwidth.v4f32") float4 fwidth(float4);
pragma(LDC_intrinsic, "llvm.spv.discard") void demote();
pragma(LDC_intrinsic, "llvm.spv.terminate.invocation") void terminate();

@fragment float4 shade(@builtin(Builtin.fragCoord) float4 position,
    @builtin(Builtin.frontFacing) bool front, @input float4 colour)
{
    if (position[0] < 1)
        terminate();
    if (!front)
        demote();
    float4 r = fwidth(colour);
    r[0] = ddx(position[0]) + ddyCoarse(position[1]) + ddxFine(colour[2]);
    return r;
}
