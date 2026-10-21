// A `?:` between two structs whose addresses calls still take -- a vector
// type's constructor and its `ref` component accessors -- selects values, not
// the locals' addresses: every helper is inlined before the optimiser's first
// InstCombine, which would otherwise merge the two loads into one through a
// phi of the addresses, which logical SPIR-V does not have.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,fragmentStage,uniformBlocks -mdcompute-file-prefix=vk_struct_conditional -output-o %s
// RUN: spirv-val --target-env vulkan1.3 vk_struct_conditional_vulkan130_64.spv
// RUN: spirv-dis vk_struct_conditional_vulkan130_64.spv -o - | FileCheck %s

// CHECK-NOT: OpCapability VariablePointers
// CHECK: OpEntryPoint Fragment %fs "fs"

@compute(CompileFor.deviceOnly) module vulkan_struct_conditional;

import ldc.dcompute;

@vectorType struct V4
{
    __vector(float[4]) v = 0;
    this(float s) { v = s; }
    ref inout(float) x() inout return => v[0];
    ref inout(float) w() inout return => v[3];
}

@_profiles("vulkan1.3") @fragment __vector(float[4]) fs(@input __vector(float[4]) uv)
{
    V4 c;
    c.v = uv;
    c.x = uv[1] + 1;
    c.w = uv[0] * uv[0];
    return (c.x == 0 ? V4(1) : c).v;
}
