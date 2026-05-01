#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require

layout(push_constant) uniform constants {
	uint inputDataBufferIndex;
} pushData;

struct CharData {
    vec2 coordinates;
    uint layer;
};

struct BufferData {
    vec4 inColor;
    uint texIndex;
    uint samplerIndex;
    vec2 quadSize;
    uint numCharacters;
    CharData characters[1024 * 4];
};

layout(scalar, descriptor_heap) readonly buffer InputData {
  BufferData data;
} heapInputData[];

layout(descriptor_heap) uniform sampler heapSampler[];
layout(descriptor_heap) uniform texture2DArray heapTexture2DArray[];

