// Logical SPIR-V has no bytes: a struct or a static array is zeroed or
// copied whole as one typed value, never by a memset or a memcpy that the
// host's layout would size -- a three-wide vector is 16 bytes to the host
// and 12 to the device's layout. A struct's padding is not cleared at all.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,sampledImages,intVertexInputs -mdcompute-file-prefix=vk_typed_copies -output-ll -output-o %s
// RUN: FileCheck %s < vk_typed_copies_vulkan130_64.ll
// RUN: spirv-val --target-env vulkan1.3 vk_typed_copies_vulkan130_64.spv

// CHECK-NOT: llvm.memset
// CHECK-NOT: llvm.memcpy

@compute(CompileFor.deviceOnly) module vulkan_typed_copies;

import ldc.dcompute;

@vectorType struct V3
{
    align(16) __vector(float[3]) v = 0;
    this(float x, float y, float z) { v[0] = x; v[1] = y; v[2] = z; }
}

struct Pair { V3 a; float b; }

struct Out
{
    @builtin(Builtin.position) __vector(float[4]) pos;
    V3 colour;
}

@_profiles("vulkan1.3") @vertex Out vs(@builtin(Builtin.vertexIndex) int index)
{
    V3[3] colour;
    colour[1] = V3(1, 2, 3);
    V3[3] copy = colour;
    Pair p;
    p.b = 4;
    Pair q = p;
    Out o;
    o.pos[3] = q.b;
    o.colour = copy[index];
    return o;
}
