#version 450

#include "flat.glsl"

layout (location = 0) in vec3 normal;
layout (location = 1) in vec3 worldPosition;

layout (location = 0) out vec4 color;

void main()
{
    MaterialProperties material = pushData.inputData.data.material;
    DirectionalLight light = pushData.inputData.data.light;
    vec3 environmentColor = pushData.inputData.data.environmentColor;

    //vec3 cameraPos = pushData.inputData.data.cameraPos;
    //vec3 V = normalize(worldPosition - cameraPos);

    float nd = dot(normal, light.direction);

    color.rgb = (light.color * max(0, nd) + environmentColor) * material.color;
    color.a = 1;
}