shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;
// Surface-analysis overlay (material_overlay of an asteroid being analyzed):
// latitude / longitude grid lines revealed from the top of the sphere down to the
// scan line at `progress`, a bright band at the scan line, all scaled by `fade`.

uniform float progress = 0.0;
uniform float fade = 1.0;
uniform vec4 color : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform float meridians = 24.0;
uniform float parallels = 12.0;

varying float height; // -1 (bottom) to 1 (top) of the sphere

void vertex() {
	height = normalize(VERTEX).y;
}

float grid_line(float x) {
	float d = abs(fract(x - 0.5) - 0.5) / max(fwidth(x), 0.0001);
	return 1.0 - clamp(d - 0.5, 0.0, 1.0);
}

void fragment() {
	float scan_line = 1.0 - 2.0 * progress;
	float scanned = step(scan_line, height);
	float lines = max(grid_line(UV.x * meridians), grid_line((1.0 - (height * 0.5 + 0.5)) * parallels));
	float band = progress < 1.0 ? exp(-pow((height - scan_line) / 0.08, 2.0)) : 0.0;
	ALBEDO = color.rgb;
	ALPHA = clamp(fade * (scanned * (0.6 * lines + 0.08) + 0.9 * band), 0.0, 1.0);
}
