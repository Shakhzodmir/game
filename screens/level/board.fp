#version 140

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;
in highp vec2 var_clip;
in mediump float var_flash;

out vec4 out_fragColor;

uniform mediump sampler2D texture_sampler;

uniform fs_uniforms
{
    mediump vec4 tint;
};

void main()
{
    if (var_clip.x > var_clip.y)
        discard;
    mediump vec4 c = texture(texture_sampler, var_texcoord0.xy);
    // textures are premultiplied: white at the same coverage is vec3(a)
    c.rgb = mix(c.rgb, vec3(c.a), clamp(var_flash, 0.0, 1.0));
    mediump vec4 tint_pm = vec4(tint.xyz * tint.w, tint.w);
    out_fragColor = c * var_color * tint_pm;
}
