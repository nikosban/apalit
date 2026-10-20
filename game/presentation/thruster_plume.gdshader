// UX round (P9, T25) main engine plume: a unit cone (CylinderMesh, height 1, wide end at
// -Y on the nozzle, closing at +Y), scaled by ThrusterView. Unshaded and additive; fades
// along its length, soft at the edges (by the view angle), with a slight flow down it.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 color = vec3(1.0);
uniform float intensity = 1.0;
uniform float edge_power = 1.5;

varying float along;

void vertex() {
	along = VERTEX.y + 0.5; // 0 at the nozzle, 1 at the tip
}

void fragment() {
	float fade = pow(1.0 - along, 1.4);
	float edge = pow(abs(dot(normalize(NORMAL), normalize(VIEW))), edge_power);
	float flow = 0.92 + 0.08 * sin((along * 6.0 - TIME * 3.0) * 6.2832);
	ALBEDO = color;
	ALPHA = clamp(intensity * fade * edge * flow, 0.0, 1.0);
}
