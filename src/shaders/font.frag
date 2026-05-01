#version 450

#include "font.h"

layout (location = 0) in vec3 uvlayer;

layout (location = 0) out vec4 color;

void main()
{
    color = heapInputData[pushData.inputDataBufferIndex].data.inColor;
    uint texIndex = heapInputData[pushData.inputDataBufferIndex].data.texIndex;
    uint samplerIndex = heapInputData[pushData.inputDataBufferIndex].data.samplerIndex;
    color *= texture(sampler2DArray(heapTexture2DArray[texIndex], heapSampler[samplerIndex]), uvlayer);
}