#version 450

#include "flat.glsl"

layout (location = 0) in vec3 normal;
layout (location = 1) in vec2 uv;
layout (location = 2) in vec3 worldPosition;

layout (location = 0) out vec4 color;

void main()
{
    MaterialProperties material = pushData.inputData.data.material;
    DirectionalLight light = pushData.inputData.data.light;
    vec3 environmentColor = pushData.inputData.data.environmentColor;

    float nd = dot(normal, light.direction);

    uint albedoIndex = pushData.inputData.data.material.albedoIndex;
    uint samplerIndex = pushData.inputData.data.material.samplerIndex;
    vec4 albedo = texture(sampler2D(heapTexture2D[albedoIndex], heapSampler[samplerIndex]), uv);

    /*
    vec3 cameraPos = pushData.inputData.data.cameraPos;
    vec3 V = normalize(cameraPos - worldPosition);
    vec3 H = normalize(V + light.direction);
    float nh = dot(normal, H);
    */

    color.rgb = (light.color * float(nd >= 0) * (nd /*+ pow(max(0, nh), 180)*/) + environmentColor) * material.color * albedo.rgb;
    color.a = albedo.a;
}