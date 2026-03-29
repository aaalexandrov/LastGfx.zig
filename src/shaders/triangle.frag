#version 450

layout (location = 0) out vec4 color;

layout(push_constant) uniform constants {
	vec4 inColor;
} PushConstants;


void main()
{
  color = PushConstants.inColor;
}