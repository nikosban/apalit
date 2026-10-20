shader_type spatial;
// UX round (P8) object highlight, pass 2 (next pass of the fill): each mesh grown outward
// from its centre by `thickness` world units, drawn only where the fill did not mark the
// stencil: the silhouette of the whole object. WorldHighlight sets `thickness` every
// frame from the camera distance so the outline keeps its width on screen.
render_mode unshaded, cull_back, depth_draw_never, blend_mix;
stencil_mode read, compare_not_equal, 1;

uniform vec4 outline_color : source_color = vec4(0.30, 0.75, 0.90, 0.9);
uniform float thickness = 0.12;

void vertex() {
	float s = max(length(MODEL_MATRIX[0].xyz), 0.0001);
	VERTEX += normalize(VERTEX) * thickness / s;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
