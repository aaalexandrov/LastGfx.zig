#version 450
#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require

layout (location = 0) in vec2 uv;

layout (location = 0) out vec4 color;

layout(push_constant) uniform constants {
	uint inputDataBufferIndex;
} pushData;

struct BufferData {
  vec4 inColor;
  uint texIndex;
  uint samplerIndex;
};

layout(scalar, descriptor_heap) readonly buffer InputData {
  BufferData data;
} heapInputData[];

layout(descriptor_heap) uniform sampler heapSampler[];
layout(descriptor_heap) uniform texture2D heapTexture2D[];

void main()
{
  color = heapInputData[pushData.inputDataBufferIndex].data.inColor;
  uint texIndex = heapInputData[pushData.inputDataBufferIndex].data.texIndex;
  uint samplerIndex = heapInputData[pushData.inputDataBufferIndex].data.samplerIndex;
  color *= texture(sampler2D(heapTexture2D[texIndex], heapSampler[samplerIndex]), uv);
}