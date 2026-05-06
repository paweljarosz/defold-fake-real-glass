#version 140

// Visible glass front-face shader.
//
// Runtime inputs come from the Fake Real Glass render module:
// 1. u_scene_color  : opaque scene captured before drawing the glass
// 2. u_backface_nd  : glass back-face normal/depth capture
// 3. u_probe_*      : optional six-face local reflection probe
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
// preview path also keeps a lightweight set of view-space values around.
// Otherwise the editor preview would not be faked. If it's not an issue, you can remove it.
in vec3 var_world_pos;
in vec3 var_world_normal;
in vec3 var_view_normal;
in vec3 var_view_dir;
in vec2 var_screen_uv;
in float var_view_depth;
in vec2 var_texcoord0;

// Textures supplied by the render script.
uniform sampler2D u_scene_color;
uniform sampler2D u_backface_nd; // RGB = back-face world normal, A = back-face view depth
uniform sampler2D u_probe_px;
uniform sampler2D u_probe_nx;
uniform sampler2D u_probe_py;
uniform sampler2D u_probe_ny;
uniform sampler2D u_probe_pz;
uniform sampler2D u_probe_nz;

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
    vec4 settings2;      // x = surface_smoothness, y = box_projection_amount
    vec4 light;          // xyz = world position, w = specular_power
    vec4 probe_center;   // xyz = local probe center
    vec4 probe_extents;  // xyz = local probe half-extents for box projection
    vec4 probe_params;   // x = 1 / probe_size, y = max blur radius in texels
};

out vec4 color_out;

// Editor preview fallback used when the render script has not yet bound the
// live scene/back-face textures. It gives the material a readable glass look
// in the editor without affecting the runtime path.
vec3 sample_preview_environment(vec3 dir)
{
    vec3 n = normalize(dir);
    float up = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);

    vec3 ground = vec3(0.15, 0.14, 0.13);
    vec3 horizon = vec3(0.58, 0.64, 0.72);
    vec3 sky = vec3(0.82, 0.90, 0.98);

    vec3 env = mix(ground, horizon, smoothstep(0.05, 0.45, up));
    env = mix(env, sky, smoothstep(0.55, 1.0, up));

    float highlight = smoothstep(0.9, 1.0, 1.0 - abs(n.x)) * smoothstep(0.25, 0.95, up);
    env += vec3(0.10, 0.09, 0.07) * highlight;

    return env;
}

vec2 project_to_uv(vec3 world_pos)
{
    // Reproject a world-space point into the current camera's scene/back-face
    // captures so we can reuse those textures as lookup tables.
    vec4 clip = view_proj * vec4(world_pos, 1.0);
    vec2 ndc  = clip.xy / max(clip.w, 1e-6);
    return ndc * 0.5 + 0.5;
}

vec3 sample_probe_face(sampler2D face_tex, vec3 dir, vec3 forward, vec3 right, vec3 up, float roughness)
{
    // The probe is stored as six 2D render targets. Project the direction onto
    // the selected face using that face's basis vectors, then apply a small
    // gather blur so rough surfaces do not look mirror-sharp.
    float denom = max(dot(dir, forward), 1e-6);
    vec2 uv = vec2(dot(dir, right), dot(dir, up)) / denom;
    uv = clamp(uv * 0.5 + 0.5, 0.001, 0.999);

    float blur_radius = clamp(roughness, 0.0, 1.0) * probe_params.y;
    if (blur_radius < 0.01)
    {
        return texture(face_tex, uv).rgb;
    }

    vec2 texel = vec2(probe_params.x * blur_radius);
    vec3 color = texture(face_tex, uv).rgb * 0.28;
    color += texture(face_tex, clamp(uv + vec2( texel.x, 0.0), 0.001, 0.999)).rgb * 0.12;
    color += texture(face_tex, clamp(uv + vec2(-texel.x, 0.0), 0.001, 0.999)).rgb * 0.12;
    color += texture(face_tex, clamp(uv + vec2(0.0,  texel.y), 0.001, 0.999)).rgb * 0.12;
    color += texture(face_tex, clamp(uv + vec2(0.0, -texel.y), 0.001, 0.999)).rgb * 0.12;
    color += texture(face_tex, clamp(uv + vec2( texel.x,  texel.y), 0.001, 0.999)).rgb * 0.06;
    color += texture(face_tex, clamp(uv + vec2( texel.x, -texel.y), 0.001, 0.999)).rgb * 0.06;
    color += texture(face_tex, clamp(uv + vec2(-texel.x,  texel.y), 0.001, 0.999)).rgb * 0.06;
    color += texture(face_tex, clamp(uv + vec2(-texel.x, -texel.y), 0.001, 0.999)).rgb * 0.06;
    return color;
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
    vec3 safe_dir = sign(n) * max(abs(n), vec3(1e-4));
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
    // Pick the dominant cube face after optional box projection.
    // This is the "manual cubemap lookup" part of the effect.
    vec3 n = box_project_probe_dir(ray_origin, dir, box_projection_amount);
    vec3 a = abs(n);

    if (a.x >= a.y && a.x >= a.z)
    {
        if (n.x > 0.0)
        {
            return sample_probe_face(u_probe_px, n, vec3(1.0, 0.0, 0.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 1.0, 0.0), roughness);
        }
        return sample_probe_face(u_probe_nx, n, vec3(-1.0, 0.0, 0.0), vec3(0.0, 0.0, -1.0), vec3(0.0, 1.0, 0.0), roughness);
    }

    if (a.y >= a.x && a.y >= a.z)
    {
        if (n.y > 0.0)
        {
            return sample_probe_face(u_probe_py, n, vec3(0.0, 1.0, 0.0), vec3(-1.0, 0.0, 0.0), vec3(0.0, 0.0, -1.0), roughness);
        }
        return sample_probe_face(u_probe_ny, n, vec3(0.0, -1.0, 0.0), vec3(-1.0, 0.0, 0.0), vec3(0.0, 0.0, 1.0), roughness);
    }

    if (n.z > 0.0)
    {
        return sample_probe_face(u_probe_pz, n, vec3(0.0, 0.0, 1.0), vec3(-1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), roughness);
    }
    return sample_probe_face(u_probe_nz, n, vec3(0.0, 0.0, -1.0), vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), roughness);
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

    float specular_power = max(light.w, 1.0);

    if (render_state.x < 0.5)
    {
        // Defold Editor preview path: no scene capture, no back-face pass,
        // just a compact approximation that keeps the model readable while the
        // real render pipeline is not running inside the editor preview.
        vec3 N_preview = normalize(var_view_normal);
        vec3 I_preview = -normalize(var_view_dir);

        vec3 preview_reflect;
        vec3 preview_refract;
        float preview_fresnel;
        split_ray(I_preview, N_preview, 1.0, ior, preview_reflect, preview_refract, preview_fresnel);

        if (length(preview_refract) < 1e-6)
        {
            preview_refract = -I_preview;
        }

        vec3 transmitted_preview = sample_preview_environment(preview_refract);
        vec3 reflected_preview = sample_preview_environment(preview_reflect);

        if (enable_absorption > 0.5)
        {
            transmitted_preview *= exp(-absorption_color.rgb * max(constant_thickness, 0.001));
        }

        float preview_reflection_strength = mix(0.2, 1.0, clamp(env_reflection_strength, 0.0, 1.0));
        vec3 final_preview = mix(
            transmitted_preview * tint_color.rgb,
            reflected_preview,
            preview_fresnel * preview_reflection_strength
        );

        if (specular_strength > 0.001)
        {
            vec3 V_preview = normalize(var_view_dir);
            vec3 L_preview = normalize(vec3(-0.4, 0.8, 0.5));
            vec3 H_preview = normalize(V_preview + L_preview);
            float spec = pow(max(dot(N_preview, H_preview), 0.0), specular_power);
            final_preview += vec3(spec * specular_strength);
        }

        color_out = vec4(final_preview, tint_color.a);
        return;
    }

    // Front-surface interaction: split the camera ray into a reflected ray and
    // a refracted ray entering the volume.
    vec3 N = normalize(var_world_normal);
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

    // Reflections come from the local probe. We evaluate both the internal
    // bounce and the front-surface reflection, then weight them by Fresnel.
    // That gives the "double refraction + reflection" feel from the Unity idea
    // without tracing a full physical path.
    vec3 back_reflection = sample_probe(back_reflect_inside, first_intersection_ws, reflection_roughness, box_projection_amount);
    vec3 front_reflection = sample_probe(front_reflect, var_world_pos, reflection_roughness, box_projection_amount);

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
    vec3 final_rgb = mix(through_glass * tint_color.rgb, front_reflection, eff_front_fresnel);

    // Extra artist-friendly highlight from the provided light position.
    // This is not part of the refraction model, it is a direct lighting term.
    if (specular_strength > 0.001)
    {
        vec3 V = normalize(camera_position.xyz - var_world_pos);
        vec3 L = normalize(light.xyz - var_world_pos);
        vec3 H = normalize(V + L);
        float spec = pow(max(dot(N, H), 0.0), specular_power);
        final_rgb += vec3(spec * specular_strength);
    }

    color_out = vec4(final_rgb, tint_color.a);
}
