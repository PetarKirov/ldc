// A `@computeShader` function is a compute-stage entry point beside the
// graphics stages: it carries its workgroup size as `LocalSize`, reads the
// stage's built-ins, and takes descriptor resources -- a read-write and a
// read-only storage buffer (one `StorageBuffer` block of `T`, std430, the
// read-only one `NonWritable`), a storage image, and an integer atomic on a
// buffer element (Device scope, relaxed). No `Int64`, and no
// `PhysicalStorageBufferAddresses`: a compute shader is not a `@kernel`.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-profile=vulkan1.3 -capabilities=shader:shader,computeStage,storageBuffers,storageImages,workgroupMemory,atomics,uniformBlocks,pushConstants,sampledImages -mdcompute-file-prefix=vk_comp -output-o %s
// RUN: spirv-dis vk_comp_vulkan130_64.spv -o - | FileCheck %s
// RUN: spirv-val --target-env vulkan1.3 vk_comp_vulkan130_64.spv
// RUN: %ldc -O2 -c -m64 -mdcompute-targets=vulkan-110 -mdcompute-profile=vulkan1.1 -capabilities=shader:shader,computeStage,storageBuffers,storageImages,workgroupMemory,atomics,uniformBlocks,pushConstants,sampledImages -mdcompute-file-prefix=vk_comp11 -output-o %s
// RUN: spirv-val --target-env vulkan1.1 vk_comp11_vulkan110_64.spv

// CHECK: OpEntryPoint GLCompute %fill "fill"
// CHECK: OpExecutionMode %fill LocalSize 4 1 1
// CHECK-DAG: OpDecorate %{{[a-zA-Z0-9_]+}} BuiltIn GlobalInvocationId
// CHECK-DAG: OpDecorate %output_ Binding 1
// CHECK-DAG: OpDecorate %input_ Binding 2
// CHECK-DAG: OpDecorate %image Binding 3
// CHECK-DAG: OpDecorate %{{[a-zA-Z0-9_]+}} Block
// CHECK: OpImageWrite
// CHECK: OpAtomicIAdd
// CHECK-NOT: OpCapability Int64
// CHECK-NOT: OpCapability PhysicalStorageBufferAddresses

@compute(CompileFor.deviceOnly) module vulkan_compute_storage;
import ldc.dcompute;

struct Words { int[8] words; int count; }

pragma(LDC_atomic_rmw, "add") int atomicAdd_(T)(T* ptr, T val, int ordering) @safe pure nothrow @nogc;
int atomicAdd_(ref int target, int value) => atomicAdd_!int(&target, value, 2);

@_profiles("vulkan1.3,vulkan1.1") @computeShader(4, 1, 1)
void fill(@builtin(Builtin.globalInvocationId) __vector(int[3]) gid,
          StorageBuffer!Words output_, StorageBuffer!(Words, Access.read) input_,
          StorageImage2D image)
{
    const i = gid.array[0];
    (*output_).words[i] = (*input_).words[i] + 1;
    __vector(int[2]) coord; coord.array[0] = i; coord.array[1] = 0;
    __vector(float[4]) px; px.array = [1.0f, 0.5f, 0.25f, 1.0f];
    image.store(coord, px);
    auto prev = atomicAdd_((*output_).count, 1);
}
