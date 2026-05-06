#version 450
#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require

layout (location = 0) in vec2 uv;

layout (location = 0) out vec4 color;

struct BufferData {
  vec4 inColor;
  uint texIndex;
  uint samplerIndex;
};

layout(scalar, buffer_reference, buffer_reference_align = 8) readonly buffer InputData {
  BufferData data;
};

layout(push_constant) uniform constants {
	InputData inputData;
} pushData;

layout(descriptor_heap) uniform sampler heapSampler[];
layout(descriptor_heap) uniform texture2D heapTexture2D[];

void main()
{
  color = pushData.inputData.data.inColor;
  uint texIndex = pushData.inputData.data.texIndex;
  uint samplerIndex = pushData.inputData.data.samplerIndex;
  color *= texture(sampler2D(heapTexture2D[texIndex], heapSampler[samplerIndex]), uv);
}