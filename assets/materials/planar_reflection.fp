#version 140
#ifndef EDITOR
#extension GL_ARB_shading_language_420pack : require
#endif
in vec4 var_position;
in vec3 var_normal;
in vec2 var_texcoord0;
in mat4 var_view;
in vec3 var_world_pos;
in vec4 var_reflection_clip;
uniform sampler2D planar_reflection;
#define MAX_LIGHT_COUNT 8
#include "/fake_real_glass/materials/lighting.glsl"
uniform fs_uniforms { vec4 tint; vec4 reflection_params; vec4 reflection_surface; vec4 reflection_fade; };
out vec4 out_fragColor;
void main()
{
    vec3 N = normalize(var_normal);
    vec3 base = tint.rgb * (ambient_light() + diffuse_lambert(N, var_position.xyz));
    if (reflection_params.w > 0.5 && var_reflection_clip.w > 0.0)
    {
        vec2 uv = var_reflection_clip.xy / var_reflection_clip.w * 0.5 + 0.5;
        vec2 pixel = reflection_params.xy * reflection_surface.x;
        vec3 reflection = texture(planar_reflection, uv).rgb * 0.4;
        reflection += texture(planar_reflection, uv + vec2(pixel.x, 0)).rgb * 0.15;
        reflection += texture(planar_reflection, uv - vec2(pixel.x, 0)).rgb * 0.15;
        reflection += texture(planar_reflection, uv + vec2(0, pixel.y)).rgb * 0.15;
        reflection += texture(planar_reflection, uv - vec2(0, pixel.y)).rgb * 0.15;
        float facing = max(dot(N, normalize(-var_position.xyz)), 0.0);
        float fresnel = reflection_surface.y + (1.0 - reflection_surface.y) * pow(1.0 - facing, 5.0);
        float fade = 1.0 - smoothstep(reflection_surface.z, max(reflection_surface.w, reflection_surface.z + 0.001), length(var_world_pos - reflection_fade.xyz));
        base += reflection * reflection_params.z * fresnel * fade;
    }
    out_fragColor = vec4(base, 1.0);
}
