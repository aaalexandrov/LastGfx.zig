#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require

struct TextureHandle {
    uint index;
};

struct SamplerHandle {
    uint index;
};

layout(scalar, buffer_reference, buffer_reference_align = 16) readonly buffer PositionData {
    vec3 positions[];
};

layout(scalar, buffer_reference, buffer_reference_align = 4) readonly buffer IndexData {
    uint indices[];
};

layout(descriptor_heap) uniform sampler heapSampler[];
layout(descriptor_heap) uniform texture2D heapTexture2D[];
layout(descriptor_heap) uniform texture2DArray heapTexture2DArray[];

