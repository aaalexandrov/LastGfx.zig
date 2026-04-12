#version 450
#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require

layout (location = 0) in vec2 uv;

layout (location = 0) out vec4 color;

layout(push_constant) uniform constants {
	uint inputDataBufferIndex;
} PushConstants;

layout(descriptor_heap) buffer InputData {
  vec4 inColor;
} heapInputData[];

layout(descriptor_heap) uniform sampler heapSampler[];
layout(descriptor_heap) uniform texture2D heapTexture2D[];


void main()
{
  //color = PushConstants.inColor;
  color = heapInputData[PushConstants.inputDataBufferIndex].inColor;
  color *= texture(sampler2D(heapTexture2D[0], heapSampler[0]), uv);
  //color.xyz *= vec3(uv, 1);
}