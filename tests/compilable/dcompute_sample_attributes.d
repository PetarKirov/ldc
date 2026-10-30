// Sampling an image is `@safe pure nothrow @nogc`: a texture read never
// allocates or throws, and the image is immutable for the draw. Shader
// helpers with those attributes may sample.

// RUN: %ldc -o- %s

@compute(CompileFor.deviceOnly) module dcompute_sample_attributes;
import ldc.dcompute;

alias float4 = __vector(float[4]);
alias float2 = __vector(float[2]);

float4 blend(Sampler2D image, SamplerState sampler, float2 uv) @safe pure nothrow @nogc
    => image.sample(uv) + image.sample(sampler, uv);
