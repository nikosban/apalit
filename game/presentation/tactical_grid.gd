extends MeshInstance3D
## Combat (migrated from the prototype v0.4): tactical grid (node `TacticalGrid`, added by the arena, always
## processing). A world-aligned grid on the X/Z plane just above the ground: minor lines
## every `minor` u, major every `major` u (provisional 10 / 50). Visual only: no collision,
## not pickable, no snapping. Its strength follows the camera zoom: suppressed close in,
## minor lines faint from mid zoom, major lines clearer with the Tactical emphasis (the
## tactical markers' emphasis(), Phase B). Lines are
## anti-aliased in the shader (constant screen width), one quad, no per-frame rebuild.
## Sector Showcase round: the quad covers the scene's sector (`sector_half_size()`; the
## Test Arena's 300 × 300) and needs no ground under it; it draws before the fog, so the
## fog of war tints it like the space around it; lines are dimmer and cooler, the major
## lines' Tactical boost is small, and a line family fades out when its spacing on screen
## falls below a share of the screen height (no dense line carpet from far away).

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform float minor = 10.0;
uniform float major = 50.0;
uniform float minor_alpha = 0.0;
uniform float major_alpha = 0.0;
uniform vec3 tint = vec3(0.55, 0.6, 0.68);
uniform vec2 sparse = vec2(0.035, 0.07); // screen-height shares of line spacing: hidden below, full above
varying vec2 world;
void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz; }
float lines(vec2 p, float spacing, float width_px, float screen_height) {
	vec2 cell = p / spacing;
	vec2 w = fwidth(cell);
	vec2 d = abs(fract(cell - 0.5) - 0.5) / max(w, vec2(1e-5));
	float on_screen = 1.0 / max(max(w.x, w.y), 1e-5) / screen_height; // spacing as a share of the screen height
	return (1.0 - clamp(min(d.x, d.y) - (width_px - 1.0) * 0.5, 0.0, 1.0)) * smoothstep(sparse.x, sparse.y, on_screen);
}
void fragment() {
	float a = max(lines(world, minor, 1.0, VIEWPORT_SIZE.y) * minor_alpha, lines(world, major, 1.4, VIEWPORT_SIZE.y) * major_alpha);
	ALBEDO = tint;
	ALPHA = a;
}
"""

@export var minor := 10.0
@export var major := 50.0

var _material := ShaderMaterial.new()

@onready var _arena := get_parent()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var plane := PlaneMesh.new()
	var half: float = _arena.sector_half_size() if _arena.has_method("sector_half_size") else 150.0
	plane.size = Vector2(2.0 * half, 2.0 * half)
	mesh = plane
	position = Vector3(0, 0.015, 0)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = SHADER
	_material.shader = shader
	_material.render_priority = -2 # Before the fog (FogView, -1): the fog tints the grid too.
	_material.set_shader_parameter("minor", minor)
	_material.set_shader_parameter("major", major)
	material_override = _material


## Line strengths for a camera zoom distance and Tactical emphasis (0-1): [minor alpha,
## major alpha].
static func strengths(zoom: float, emphasis: float) -> Vector2:
	var minor_alpha := 0.05 * clampf((zoom - 22.0) / 20.0, 0.0, 1.0)
	var major_alpha := 0.035 * clampf((zoom - 16.0) / 14.0, 0.0, 1.0) + 0.02 * clampf(emphasis, 0.0, 1.0)
	return Vector2(minor_alpha, major_alpha)


func _process(_delta: float) -> void:
	if not visible:
		return
	var s := strengths(_arena.get_node("CameraRig").zoom_distance, _arena.markers.emphasis())
	_material.set_shader_parameter("minor_alpha", s.x)
	_material.set_shader_parameter("major_alpha", s.y)
