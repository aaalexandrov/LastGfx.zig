#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require

struct DirectionalLight {
    vec3 direction;
    vec3 color;
};

struct MaterialProperties {
    vec3 color;
    float roughness;
    float metallic;
};

layout(scalar, buffer_reference, buffer_reference_align = 8) readonly buffer IndexData {
    uint indices[];
};

layout(scalar, buffer_reference, buffer_reference_align = 8) readonly buffer PositionData {
    vec3 positions[];
};

struct BufferData {
    mat4 world;
    mat4 view;
    mat4 proj;

    PositionData meshPositions;
    IndexData meshTriangles;

    vec3 cameraPos;
    uint numTriangles;

    MaterialProperties material;
    DirectionalLight light;
    vec3 environmentColor;
};

layout(scalar, buffer_reference, buffer_reference_align = 8) readonly buffer InputData {
    BufferData data;
};

layout(push_constant) uniform constants {
    InputData inputData;
} pushData;

//layout(descriptor_heap) uniform sampler heapSampler[];
//layout(descriptor_heap) uniform texture2D heapTexture2D[];

