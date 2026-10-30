// A host module and a device-only module compiled together share template
// instances, which the frontend may hand to either module's object. The host
// object keeps none that only device code asked for (one owned by the
// device-only module, or an `ldc.dcompute` helper such as `sample`, whose body
// names a SPIR-V intrinsic), and the device module, which no linker
// completes, defines every instance it references, wherever the frontend put
// it.

// REQUIRES: target_SPIRV && atleast_llvm23
// RUN: %ldc -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=vulkan_host_device -output-ll -output-o -I%S %s %S/inputs/vulkan_device_templates.d
// RUN: FileCheck --check-prefix=HOST %s < vulkan_host_device_templates.ll
// RUN: spirv-dis vulkan_host_device_vulkan130_64.spv -o - | FileCheck --check-prefix=DEVICE %s
// RUN: spirv-val --target-env vulkan1.3 vulkan_host_device_vulkan130_64.spv

// HOST: define {{.*}}@_D6inputs23vulkan_shared_templates__T5twiceTfZQjF
// HOST-NOT: thrice
// HOST-NOT: sample

// DEVICE-NOT: LinkageAttributes
// DEVICE: OpEntryPoint GLCompute %{{[a-zA-Z0-9_]+}} "{{.*}}scale{{.*}}"

import inputs.vulkan_shared_templates : twice;

float hostTwice(float x) => twice(x);
