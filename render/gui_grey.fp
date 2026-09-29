#version 140

// GUI material "grey" (town.gui): district items that are not restored yet
// are drawn grey and light, not dark (art-direction.md, "Фоны"): the texture
// colour becomes its luminance, lifted halfway to white. The node colour
// (premultiplied by gui.vp) still sets the tint and the transparency.

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

uniform mediump sampler2D texture_sampler;

void main()
{
    mediump vec4 t = texture(texture_sampler, var_texcoord0.xy); // premultiplied
    mediump float lum = dot(t.rgb, vec3(0.299, 0.587, 0.114));   // premultiplied luminance
    mediump vec3 grey = mix(vec3(lum), vec3(t.a), 0.5);            // halfway to white (x alpha)
    out_fragColor = vec4(grey, t.a) * var_color;
}
