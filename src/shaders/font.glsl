#include "common.glsl"

struct CharData {
    vec2 coordinates;
    uint layer;
};

layout(scalar, buffer_reference, buffer_reference_align = 16) readonly buffer InputData {
    vec4 inColor;
    TextureHandle tex;
    SamplerHandle texSampler;
    vec2 quadSize;
    uint numCharacters;
    CharData characters[];
};

layout(push_constant) uniform constants {
    InputData inputData;
} pushData;


