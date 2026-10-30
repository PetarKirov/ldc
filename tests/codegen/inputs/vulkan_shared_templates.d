@compute(CompileFor.hostAndDevice) module inputs.vulkan_shared_templates;
import ldc.dcompute;

T twice(T)(T x) => x + x;
