// Thruster plasma, shared by the exhaust particles of both thruster effects and the main
// engine's core and nozzle glow: a soft quad, unshaded and additive. Camera-facing disc
// by default; with `streak` on, a streak stretched along the node's Y axis (a particle's
// velocity with the process material's align_y; the core's exhaust axis) and turned about
// it to face the camera, so the exhaust reads as directed flow. Brightness = the particle
// colour (the process material's gradient; white for meshes) x emission_color x
// emission_energy x the instance's intensity; above 1 it reaches the scene's glow. A
// custom shader because per-instance brightness and size must not touch the shared
// material: instance uniforms, set by the effect script.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 emission_color : source_color = vec3(1.0);
uniform float emission_energy : hint_range(0.0, 8.0) = 1.0;
uniform float softness : hint_range(0.5, 6.0) = 2.0; // Edge falloff exponent
uniform bool streak = false;
uniform float stretch : hint_range(1.0, 12.0) = 1.0; // Streak length / width
uniform float head : hint_range(0.0, 1.0) = 0.0; // Brightness bias toward the leading end (+Y)

instance uniform float intensity = 1.0;
instance uniform float size = 1.0;

void vertex() {
	vec3 center = MODEL_MATRIX[3].xyz;
	if (streak) {
		float width = length(MODEL_MATRIX[0].xyz) * size;
		vec3 axis = MODEL_MATRIX[1].xyz;
		float along = length(axis) * size * stretch;
		axis = axis / max(length(axis), 1e-5);
		vec3 side = cross(axis, CAMERA_POSITION_WORLD - center);
		// Seen straight down the axis there is no side: fall back to the camera's right.
		side = length(side) > 1e-4 ? normalize(side) : INV_VIEW_MATRIX[0].xyz;
		VERTEX = center + side * VERTEX.x * width + axis * VERTEX.y * along;
		MODELVIEW_MATRIX = VIEW_MATRIX;
	} else {
		mat4 facing = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
		MODELVIEW_MATRIX = VIEW_MATRIX * facing * mat4(
			vec4(length(MODEL_MATRIX[0].xyz) * size, 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz) * size, 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz) * size, 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	}
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0; // UV.y 0 is the quad's +Y end
	float disc = pow(clamp(1.0 - length(p), 0.0, 1.0), softness);
	float bias = mix(1.0, 1.0 - UV.y, head) * (1.0 + head);
	ALBEDO = COLOR.rgb * emission_color * emission_energy * intensity * bias;
	ALPHA = COLOR.a * disc;
}
