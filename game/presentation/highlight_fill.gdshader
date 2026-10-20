shader_type spatial;
// UX round (P8) object highlight, pass 1 (material_overlay of every mesh of a selected
// or hovered ship / station): a low-opacity fill on the visible surface that marks it
// in the stencil, so the outline pass draws only around the whole object.
render_mode unshaded, cull_back, depth_draw_never, blend_mix;
stencil_mode write, compare_always, 1;

uniform vec4 fill_color : source_color = vec4(0.30, 0.75, 0.90, 0.08);

void fragment() {
	ALBEDO = fill_color.rgb;
	ALPHA = fill_color.a;
}
