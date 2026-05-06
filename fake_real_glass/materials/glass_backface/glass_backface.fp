#version 140

// Fragment stage for the hidden back-face capture pass.
//
// The render script draws the same glass meshes again with front-face culling,
// so only the back side of the volume lands in this texture. The visible front
// shader later samples that texture to reconstruct thickness and the exit
// normal of the refracted ray.

in vec3 var_world_normal;
in float var_view_depth;

out vec4 color_out;

void main()
{
    // The packing is intentionally simple:
    // RGB = back-face world normal
    // A   = back-face view-space depth
    //
    // That keeps the front shader's lookups cheap and makes this texture act
    // like a tiny per-pixel database for "where does the ray leave the glass?"
    color_out = vec4(normalize(var_world_normal), var_view_depth);
}
