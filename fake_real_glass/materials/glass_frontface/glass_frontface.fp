#version 140
#ifndef EDITOR
#extension GL_ARB_shading_language_420pack : require
#endif

#ifdef EDITOR
in vec3 var_preview_normal;
uniform fs_uniforms { vec4 tint_color; };
out vec4 color_out;
void main()
{
    vec3 N = normalize(var_preview_normal);
    float diffuse = max(dot(N, normalize(vec3(-0.4, 0.8, 0.5))), 0.0);
    color_out = vec4(max(tint_color.rgb, vec3(0.45)) * (0.45 + 0.55 * diffuse), 1.0);
}
#else

// Visible glass front-face shader.
//
// Runtime inputs come from the Fake Real Glass render module:
// 1. u_scene_color  : opaque scene captured before drawing the glass
// 2. u_backface_nd  : glass back-face normal/depth capture
// 3. u_probe        : local reflection cubemap
//
// The fragment shader traces a simplified "enter glass -> travel inside ->
// leave glass" path in screen space:
// 1. refract at the front face
// 2. estimate thickness from the back-face pass
// 3. find the exit point/normal
// 4. sample the opaque scene for transmission
// 5. sample the probe for reflection
// 6. mix everything with Fresnel + optional absorption + direct specular

// Per-vertex data from glass_frontface.vp.
// Most of the physical approximation is done in world space, but the editor
// preview path displays the mesh as a solid shape with simple lighting.
in vec3 var_world_pos;
in vec3 var_sphere_center;
in float var_sphere_radius;
in vec3 var_world_normal;
in vec3 var_view_normal;
in vec3 var_view_dir;
in vec2 var_screen_uv;
in float var_view_depth;
in vec2 var_texcoord0;

// Textures supplied by the render script.
uniform sampler2D u_scene_color;
uniform sampler2D u_backface_nd; // RGB = back-face world normal, A = back-face view depth

uniform samplerCube u_probe;

#define MAX_LIGHT_COUNT 8
in mat4 var_view;
#include "/fake_real_glass/materials/lighting.glsl"

// Per-draw constants supplied by the material and the render module.
uniform fs_uniforms
{
    mat4 view_proj;      // current camera view-projection, used for reprojection back to screen UVs
    vec4 camera_position;
    vec4 render_state;   // x = 1 when runtime capture textures are bound, 0 in editor preview
    vec4 tint_color;
    vec4 absorption_color;
    vec4 settings0;      // x = ior, y = refraction_distance, z = depth_thickness_gain, w = constant_thickness
    vec4 settings1;      // x = use_constant_thickness, y = enable_absorption, z = env_reflection_strength, w = specular_strength
    vec4 settings2;      // x = smoothness, y = box projection, z = transmission, w = minimum reflection
    vec4 specular_params; // x = specular power
    vec4 probe_center;   // xyz = local probe center
    vec4 probe_extents;  // xyz = local probe half-extents for box projection
    vec4 probe_params;   // x = 1 / probe_size, y = max blur radius in texels
};

out vec4 color_out;

vec2 project_to_uv(vec3 world_pos)
{
    // Reproject a world-space point into the current camera's scene/back-face
    // captures so we can reuse those textures as lookup tables.
    vec4 clip = view_proj * vec4(world_pos, 1.0);
    vec2 ndc  = clip.xy / max(clip.w, 1e-6);
    return ndc * 0.5 + 0.5;
}

vec3 box_project_probe_dir(vec3 ray_origin, vec3 ray_dir, float box_projection_amount)
{
    // Box projection keeps reflections anchored to the local room volume
    // instead of behaving like an infinitely distant skybox.
    //
    // We intersect the reflection ray against the probe's local box and use
    // the hit position relative to the box center as the reflected direction.
    // If the shaded point is outside the box, the code fades back to the
    // ordinary direction to avoid extreme artifacts.
    vec3 n = normalize(ray_dir);
    vec3 safe_dir = mix(vec3(-1.0), vec3(1.0), step(vec3(0.0), n)) * max(abs(n), vec3(1e-4));
    vec3 center = probe_center.xyz;
    vec3 extents = max(probe_extents.xyz, vec3(1e-4));
    vec3 local_pos = ray_origin - center;

    vec3 inside_mask = step(abs(local_pos), extents);
    float is_inside = inside_mask.x * inside_mask.y * inside_mask.z;
    float use_box_projection = clamp(box_projection_amount, 0.0, 1.0) * is_inside;

    vec3 box_max = center + extents;
    vec3 box_min = center - extents;
    vec3 t_max = (box_max - ray_origin) / safe_dir;
    vec3 t_min = (box_min - ray_origin) / safe_dir;
    vec3 select = step(safe_dir, vec3(0.0));
    vec3 t = mix(t_max, t_min, select);
    float t_hit = max(min(min(t.x, t.y), t.z), 0.0);
    vec3 projected_dir = ray_origin + safe_dir * t_hit - center;

    return normalize(mix(n, projected_dir, use_box_projection));
}

vec3 sample_probe(vec3 dir, vec3 ray_origin, float roughness, float box_projection_amount)
{
    vec3 n = box_project_probe_dir(ray_origin, dir, box_projection_amount);
    // Sample directions on the sphere so roughness taps can cross cube edges.
    vec3 axis = abs(n.y) < 0.99 ? vec3(0, 1, 0) : vec3(1, 0, 0);
    vec3 tangent = normalize(cross(axis, n));
    vec3 bitangent = cross(n, tangent);
    float r = clamp(roughness, 0.0, 1.0);
    if (r < 0.001) return texture(u_probe, n).rgb;

    // Angular blur keeps the same material appearance at any probe resolution.
    // Distributed taps soften reflections without the old cross-shaped ghosts.
    float radius = max(0.35 * r * r, r * probe_params.y * probe_params.x * 2.0);
    vec3 color = texture(u_probe, n).rgb;
    float total_weight = 1.0;
    for (int i = 0; i < 24; ++i)
    {
        float distance_squared = (float(i) + 0.5) / 24.0;
        float angle = float(i) * 2.39996323;
        vec2 offset = vec2(cos(angle), sin(angle)) * sqrt(distance_squared) * radius;
        float weight = exp(-2.0 * distance_squared);
        vec3 sample_direction = n + tangent * offset.x + bitangent * offset.y;
        color += texture(u_probe, sample_direction).rgb * weight;
        total_weight += weight;
    }
    return color / total_weight;
}

float get_reflectance(vec3 i, vec3 t, vec3 n, float ior_a, float ior_b)
{
    // Fresnel reflectance for unpolarized light, using the incoming and
    // transmitted directions that `refract()` produced.
    float cosi = clamp(abs(dot(i, n)), 0.0, 1.0);
    float cost = clamp(abs(dot(t, n)), 0.0, 1.0);

    float spr_num = (cosi / ior_b - cost / ior_a);
    float spr_den = (cosi / ior_b + cost / ior_a);
    float spp_num = (cost / ior_b - cosi / ior_a);
    float spp_den = (cost / ior_b + cosi / ior_a);

    float spr = (abs(spr_den) > 1e-6) ? pow(spr_num / spr_den, 2.0) : 1.0;
    float spp = (abs(spp_den) > 1e-6) ? pow(spp_num / spp_den, 2.0) : 1.0;

    return clamp((spr + spp) * 0.5, 0.0, 1.0);
}

void split_ray(
    vec3 in_dir,
    vec3 normal,
    float ior_a,
    float ior_b,
    out vec3 reflected_dir,
    out vec3 refracted_dir,
    out float reflectance)
{
    // Split the incoming ray into reflection + refraction and report the
    // Fresnel weight that will later blend those two contributions.
    float eta = ior_a / ior_b;
    reflected_dir = reflect(in_dir, normal);
    refracted_dir = refract(in_dir, normal, eta);

    if (length(refracted_dir) < 1e-6)
    {
        reflectance = 1.0;
    }
    else
    {
        reflectance = get_reflectance(in_dir, refracted_dir, normal, ior_a, ior_b);
    }
}

// Editor preview does not depend on scene lights or runtime capture state.
vec4 solid_preview()
{
    vec3 N = normalize(var_view_normal);
    float diffuse = max(dot(N, normalize(vec3(-0.4, 0.8, 0.5))), 0.0);
    vec3 preview_tint = max(tint_color.rgb, vec3(0.45));
    return vec4(preview_tint * (0.45 + 0.55 * diffuse), 1.0);
}

void main()
{
    // Unpack artist/gameplay controls from the material constants.
    float ior                    = settings0.x;
    float refraction_distance    = settings0.y;
    float depth_thickness_gain   = settings0.z;
    float constant_thickness     = settings0.w;

    float use_constant_thickness  = settings1.x;
    float enable_absorption       = settings1.y;
    float env_reflection_strength = settings1.z;
    float specular_strength       = settings1.w;
    float surface_smoothness      = clamp(settings2.x, 0.0, 1.0);
    float box_projection_amount   = settings2.y;
    float reflection_roughness    = 1.0 - surface_smoothness;

    float specular_power = mix(4.0, max(specular_params.x, 4.0), surface_smoothness * surface_smoothness);

    if (render_state.x < 0.5)
    {
        color_out = solid_preview();
        return;
    }

    // Front-surface interaction: split the camera ray into a reflected ray and
    // a refracted ray entering the volume.
    bool sphere = probe_params.z > 0.5;
    vec3 N = sphere ? normalize(var_world_pos - var_sphere_center) : normalize(var_world_normal);
    vec3 I = normalize(var_world_pos - camera_position.xyz);

    vec3 front_reflect;
    vec3 front_refract;
    float front_fresnel;
    split_ray(I, N, 1.0, ior, front_reflect, front_refract, front_fresnel);

    // The center sample gives us the back-face depth directly behind the front
    // fragment, which is enough to estimate thickness for refraction.
    vec4 back_center = texture(u_backface_nd, clamp(var_screen_uv, 0.0, 1.0));

    float thickness;
    if (length(back_center.xyz) < 0.01)
    {
        // No back face was written behind this pixel, so fall back to the
        // author-provided thickness instead of producing undefined refraction.
        thickness = constant_thickness;
    }
    else
    {
        float back_view_depth = back_center.a;
        // Compare front and back depths in view space to estimate how much
        // glass the ray travels through before reaching the opposite side.
        float thickness_from_depth = max((back_view_depth - var_view_depth) * depth_thickness_gain, 0.0);
        thickness = mix(thickness_from_depth, constant_thickness, clamp(use_constant_thickness, 0.0, 1.0));
    }

    // March the refracted ray through the volume, then look up the back face
    // again at the estimated internal hit point to find the exit normal.
    vec3 first_intersection_ws = var_world_pos + front_refract * thickness;
    if (sphere)
    {
        // Exact exit from a sphere, rather than a constant-thickness slab.
        vec3 offset = var_world_pos - var_sphere_center;
        float b = dot(offset, front_refract);
        float c = dot(offset, offset) - var_sphere_radius * var_sphere_radius;
        thickness = max(-b + sqrt(max(b * b - c, 0.0)), 0.0);
        first_intersection_ws = var_world_pos + front_refract * thickness;
    }
    vec2 back_uv = clamp(project_to_uv(first_intersection_ws), 0.0, 1.0);

    vec4 back_sample = texture(u_backface_nd, back_uv);
    vec3 back_normal_ws;
    if (length(back_sample.xyz) < 0.01)
    {
        // If the reprojection misses, approximate the exit surface as the
        // opposite of the front normal. This keeps the result stable.
        back_normal_ws = -N;
    }
    else
    {
        back_normal_ws = normalize(back_sample.xyz);
    }

    if (sphere) back_normal_ws = normalize(first_intersection_ws - var_sphere_center);

    vec3 back_reflect_inside;
    vec3 exit_refract;
    float back_fresnel;
    split_ray(front_refract, -back_normal_ws, ior, 1.0, back_reflect_inside, exit_refract, back_fresnel);

    if (length(exit_refract) < 1e-6)
    {
        // Total internal reflection fallback. Reuse the inside ray rather than
        // letting the transmission path collapse to zero.
        exit_refract = front_refract;
    }

    // Sample the already-rendered opaque scene at the estimated exit point.
    // This is the visible "through the glass" transmission color.
    vec3 second_intersection_ws = first_intersection_ws + exit_refract * refraction_distance;
    vec2 exit_uv = clamp(project_to_uv(second_intersection_ws), 0.0, 1.0);

    vec3 transmitted = texture(u_scene_color, exit_uv).rgb;
    if (sphere)
    {
        // Continue along the outgoing ray in the local environment.
        // A short screen-space offset cannot represent a spherical glass lens.
        transmitted = sample_probe(exit_refract, first_intersection_ws, reflection_roughness, box_projection_amount);
    }

    // Reflections come from the local probe. We evaluate both the internal
    // bounce and the front-surface reflection, then weight them by Fresnel.
    // That gives the "double refraction + reflection" feel from the Unity idea
    // without tracing a full physical path.
    vec3 back_reflection = sample_probe(back_reflect_inside, first_intersection_ws, reflection_roughness, box_projection_amount);
    vec3 front_reflection = sample_probe(front_reflect, var_world_pos, reflection_roughness, box_projection_amount);

    if (sphere)
    {
        // One internal bounce also leaves through the actual sphere surface.
        vec3 offset = first_intersection_ws - var_sphere_center;
        float travel = max(-2.0 * dot(offset, back_reflect_inside), 0.0);
        vec3 bounce_exit = first_intersection_ws + back_reflect_inside * travel;
        vec3 bounce_normal = normalize(bounce_exit - var_sphere_center);
        vec3 bounce_out = refract(back_reflect_inside, -bounce_normal, ior);
        back_reflection = length(bounce_out) > 1e-6
            ? sample_probe(bounce_out, bounce_exit, reflection_roughness, box_projection_amount)
            : vec3(0.0);
    }

    float eff_back_fresnel  = back_fresnel  * env_reflection_strength;
    float eff_front_fresnel = front_fresnel * env_reflection_strength;

    vec3 through_glass = mix(transmitted, back_reflection, eff_back_fresnel);

    vec3 absorption = vec3(1.0);
    if (enable_absorption > 0.5)
    {
        // Beer-Lambert style absorption based on traveled thickness.
        absorption = exp(-absorption_color.rgb * thickness);
    }

    through_glass *= absorption;

    // First tint/absorb the transmitted contribution, then layer the front
    // reflection on top according to the front-face Fresnel term.
    float reflection_weight = clamp(max(eff_front_fresnel, settings2.w), 0.0, 1.0);
    vec3 body_color = through_glass * tint_color.rgb * clamp(settings2.z, 0.0, 1.0);
    // Reduced transmission adds a subtle lit body, rather than an invisible
    // surface when the studio environment is almost black. Fully clear glass
    // (transmission = 1) keeps the original result.
    vec3 view_position = (var_view * vec4(var_world_pos, 1.0)).xyz;
    vec3 view_normal = normalize(mat3(var_view) * N);
    vec3 body_light = ambient_light() + diffuse_lambert(view_normal, view_position);
    body_color += tint_color.rgb * body_light * (1.0 - clamp(settings2.z, 0.0, 1.0)) * 0.2;
    vec3 final_rgb = mix(body_color, front_reflection, reflection_weight);

    // Extra artist-friendly highlight from the scene light components.
    // This is not part of the refraction model, it is a direct lighting term.
    if (specular_strength > 0.001)
    {
        vec3 V = normalize(camera_position.xyz - var_world_pos);
        for (int i = 0; i < MAX_LIGHT_COUNT; ++i)
        {
            if (i >= int(light_info.w)) break;
            int type = int(lights[i].params.x);
            vec3 L;
            float attenuation = 1.0;
            if (type == LIGHT_DIRECTIONAL)
                L = normalize(-lights[i].direction_range.xyz);
            else
            {
                vec3 delta = lights[i].position.xyz - var_world_pos;
                float distance_to_light = length(delta);
                L = delta / max(distance_to_light, 0.0001);
                float range = max(lights[i].direction_range.w, 0.0001);
                attenuation = pow(clamp(1.0 - distance_to_light / range, 0.0, 1.0), 2.0);
                if (type == LIGHT_SPOT)
                {
                    float inner_cos = cos(0.5 * lights[i].params.z - 0.00001);
                    float outer_cos = cos(0.5 * lights[i].params.w);
                    attenuation *= smoothstep(outer_cos, inner_cos,
                        dot(-L, normalize(lights[i].direction_range.xyz)));
                }
            }
            vec3 half_vector = V + L;
            vec3 H = half_vector / max(length(half_vector), 0.0001);
            float spec = pow(max(dot(N, H), 0.0), specular_power) * step(0.0001, dot(N, L));
            final_rgb += lights[i].color.rgb * lights[i].params.y * attenuation * spec * specular_strength;
        }
    }

    color_out = vec4(final_rgb, tint_color.a);
}

#endif
