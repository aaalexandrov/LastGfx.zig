#version 450

#include "flat.glsl"

layout (location = 0) in vec3 normal;
layout (location = 1) in vec2 uv;
layout (location = 2) in vec3 worldPosition;

layout (location = 0) out vec4 color;

void main()
{
    MaterialProperties material = pushData.inputData.material;
    DirectionalLight light = pushData.inputData.light;
    vec3 environmentColor = pushData.inputData.environmentColor;

    float NL = clamp(dot(normal, light.direction), 0, 1);

    vec4 albedo = texture(sampler2D(heapTexture2D[material.albedo.index], heapSampler[material.textureSampler.index]), uv); 

    vec3 cameraPos = pushData.inputData.cameraPos;
    vec3 V = normalize(cameraPos - worldPosition);
    vec3 R = reflect(-light.direction, normal);
    float RV = clamp(dot(R, V), 0, 1);

    vec3 diffuseColor = material.color * albedo.rgb;
    vec3 specularColor = mix(vec3(0.04), diffuseColor, material.metallic);

    vec3 ambient = environmentColor * diffuseColor;
    vec3 diffuse = light.color * diffuseColor * NL;
    vec3 specular = light.color * specularColor * pow(RV, 180);

    color.rgb = ambient + diffuse + specular;
    color.a = albedo.a;
}