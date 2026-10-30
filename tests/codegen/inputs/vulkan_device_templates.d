@compute(CompileFor.deviceOnly) module inputs.vulkan_device_templates;
import ldc.dcompute;
import inputs.vulkan_shared_templates : twice;

T thrice(T)(T x) => x + x + x;

alias float4 = __vector(float[4]);
alias float2 = __vector(float[2]);

// The host module compiled alongside instantiates `twice!float` too;
// `thrice!float` and `sample` are instantiated only here.
@kernel() void scale(GlobalPointer!float io)
{
    *io = twice(*io) + thrice(*io);
}

@fragment float4 shade(@input float2 uv, Sampler2D image) => image.sample(uv);
