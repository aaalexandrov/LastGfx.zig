#include "common.glsl"

struct DirectionalLight {
    vec3 direction;
    vec3 color;
};

struct MaterialProperties {
    vec3 color;
    float roughness;
    float metallic;
    TextureHandle albedo;
    SamplerHandle textureSampler;
};

layout(scalar, buffer_reference, buffer_reference_align = 16) readonly buffer InputData {
    mat4 world;
    mat4 view;
    mat4 proj;

    PositionData positions;
    IndexData triangles;

    vec3 cameraPos;
    uint numTriangles;

    MaterialProperties material;
    DirectionalLight light;
    vec3 environmentColor;
};

layout(push_constant) uniform constants {
    InputData inputData;
} pushData;


