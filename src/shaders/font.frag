#version 450

#include "font.glsl"

layout (location = 0) in vec3 uvlayer;

layout (location = 0) out vec4 color;

void main()
{
    color = pushData.inputData.inColor;
    uint texIndex = pushData.inputData.tex.index;
    uint samplerIndex = pushData.inputData.texSampler.index;
    color *= texture(sampler2DArray(heapTexture2DArray[texIndex], heapSampler[samplerIndex]), uvlayer);
}