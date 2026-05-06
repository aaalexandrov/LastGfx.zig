#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require

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
};

layout(scalar, buffer_reference, buffer_reference_align = 8) readonly buffer InputData {
    BufferData data;
    CharData characters[];
};

layout(push_constant) uniform constants {
    InputData inputData;
} pushData;

layout(descriptor_heap) uniform sampler heapSampler[];
layout(descriptor_heap) uniform texture2DArray heapTexture2DArray[];

