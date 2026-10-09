#version 140
#ifndef EDITOR
#extension GL_ARB_shading_language_420pack : require
#endif
in vec3 var_direction;
uniform samplerCube skybox;
out vec4 color_out;

// Match Defold's built-in light buffer layout, even though the sky uses
// only its accumulated ambient color (color * intensity).
#ifdef EDITOR
uniform Light
#else
struct Light
#endif
{
    vec4 position;
    vec4 color;
    vec4 direction_range;
    vec4 params;
}
#ifdef EDITOR
lights[8];
#else
;
#endif

#ifndef EDITOR
layout(binding = 8)
#endif
uniform LightBuffer
{
    vec4 light_info;
#ifndef EDITOR
    Light lights[8];
#endif
};

uniform skybox_uniforms { vec4 skybox_rotation; };

void main()
{
    // Rotate the lookup, so all screen and reflection captures share the sky.
    vec3 direction = vec3(
        skybox_rotation.x * var_direction.x - skybox_rotation.y * var_direction.z,
        var_direction.y,
        skybox_rotation.y * var_direction.x + skybox_rotation.x * var_direction.z
    );
    vec3 sky_color = texture(skybox, direction).rgb;
    color_out = vec4(sky_color * light_info.xyz, 1.0);
}
