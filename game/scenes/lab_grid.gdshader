shader_type spatial;

// Ground grid for the movement lab: minor and major lines on the X/Z plane, in world units.

uniform vec4 base_color : source_color = vec4(0.11, 0.115, 0.12, 1.0);
uniform vec4 minor_color : source_color = vec4(0.2, 0.205, 0.215, 1.0);
uniform vec4 major_color : source_color = vec4(0.26, 0.27, 0.285, 1.0);
uniform float minor_spacing = 1.0;
uniform float major_spacing = 10.0;
uniform float line_width = 1.0; // pixels

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

// 1 on a line, 0 between lines, antialiased over line_width pixels.
float grid_line(vec2 cell) {
	vec2 width = fwidth(cell);
	vec2 dist = abs(fract(cell - 0.5) - 0.5) / max(width, vec2(1e-5));
	return 1.0 - clamp(min(dist.x, dist.y) / line_width, 0.0, 1.0);
}

void fragment() {
	vec2 minor_cell = world_xz / minor_spacing;
	// Fade minor lines out where they would be closer than a few pixels apart.
	float minor_fade = 1.0 - clamp(max(fwidth(minor_cell).x, fwidth(minor_cell).y) * 4.0 - 1.0, 0.0, 1.0);
	vec3 color = mix(base_color.rgb, minor_color.rgb, grid_line(minor_cell) * minor_fade);
	color = mix(color, major_color.rgb, grid_line(world_xz / major_spacing));
	ALBEDO = color;
	ROUGHNESS = 0.95;
}
