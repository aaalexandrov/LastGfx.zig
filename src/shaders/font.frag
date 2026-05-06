#version 450

#include "font.glsli"

layout (location = 0) in vec3 uvlayer;

layout (location = 0) out vec4 color;

void main()
{
    color = pushData.inputData.data.inColor;
    uint texIndex = pushData.inputData.data.texIndex;
    uint samplerIndex = pushData.inputData.data.samplerIndex;
    color *= texture(sampler2DArray(heapTexture2DArray[texIndex], heapSampler[samplerIndex]), uvlayer);
}