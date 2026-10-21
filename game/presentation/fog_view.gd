extends MeshInstance3D
## Combat (migrated from the prototype v0.4): fog of war presentation for the player (node `FogView`, added by
## the arena when the scene has Sensors; always processing, presentation only).
##   Shading: one world-aligned quad over the ground; a shader tints every point outside
##   the player's sensor coverage (no friendly ship within sensor range with a clear line;
##   asteroid circles cast the gaps). The sensor positions are the Sensors' last evaluation
##   (uniforms, no textures rebuilt); the asteroid circles are set once.
##   Environmental prototype: the tint is the sector profile's cool fog colour, blended
##   (lower contrast and saturation, environmental colour kept) instead of black; the quad
##   reaches well past the arena, so the fog has no edge; coverage edges are softened only
##   on the covered side (a sensor-range fade and an occlusion penumbra that widens behind
##   each asteroid), so no uncovered point is ever drawn as covered. A
##   per-instance strength lets StrategicView show the same material more lightly.
##   Information: hostile projectiles, guided ordnance and their trails are shown only while
##   they are inside the coverage; effects (muzzle flashes, impacts, explosions) only where
##   covered, so a hidden ship's shot or loss reveals nothing. Ship models, markers, bars,
##   picking and labels follow the arena's player_sees().

const MAX_SOURCES := 16
const MAX_ASTEROIDS := 64
const FOG_SIZE := 3000.0 # u: far past the arena, so the fog has no visible edge
const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 sources[16];
uniform int source_count = 0;
uniform vec3 asteroids[64];
uniform int asteroid_count = 0;
uniform float sensor_range = 100.0;
uniform vec4 fog_color : source_color = vec4(0.1, 0.12, 0.16, 1.0);
uniform float strength = 0.6;
uniform float range_fade = 8.0; // u inside the range edge
uniform float penumbra = 0.12; // occlusion softening per u behind the asteroid
uniform float max_penumbra = 6.0; // u
instance uniform float view_strength = 1.0;
varying vec2 world;
void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz; }
// 1 clear, 0 blocked (the hard rule), in between only on the clear side of an edge.
float clear_line(vec2 a, vec2 b) {
	vec2 ab = b - a;
	float len = max(length(ab), 1e-3);
	float clear = 1.0;
	for (int i = 0; i < asteroid_count; i++) {
		vec2 c = asteroids[i].xy;
		float r = asteroids[i].z;
		float along = dot(c - a, ab) / len;
		float t = clamp(along / len, 0.0, 1.0);
		float d = distance(a + ab * t, c);
		if (d <= r) { return 0.0; }
		float behind = len - along; // how far past the asteroid the point lies
		if (along > 0.0 && behind > 0.0 && d < r + max_penumbra) {
			clear = min(clear, smoothstep(r, r + min(max_penumbra, behind * penumbra) + 1e-3, d));
		}
	}
	return clear;
}
void fragment() {
	float seen = 0.0;
	for (int i = 0; i < source_count; i++) {
		vec2 s = sources[i].xy;
		float d = distance(s, world);
		if (d <= sensor_range) {
			seen = max(seen, clear_line(s, world) * (1.0 - smoothstep(sensor_range - range_fade, sensor_range, d)));
			if (seen >= 1.0) { break; }
		}
	}
	ALBEDO = fog_color.rgb;
	ALPHA = strength * view_strength * (1.0 - seen);
}
"""

var player_faction := 0
var _material := ShaderMaterial.new()

@onready var _arena := get_parent()
@onready var _sensors: Node = _arena.get_node("Sensors")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var plane := PlaneMesh.new()
	plane.size = Vector2(FOG_SIZE, FOG_SIZE)
	mesh = plane
	position = Vector3(0, 0.03, 0)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = SHADER
	_material.shader = shader
	_material.render_priority = -1
	material_override = _material
	var environment = _arena.get("environment")
	if environment != null:
		_material.set_shader_parameter("fog_color", environment.profile.fog_color)
		_material.set_shader_parameter("strength", environment.profile.fog_strength)
	var circles := PackedVector3Array()
	var asteroids := _arena.get_node_or_null("Asteroids")
	if asteroids != null and asteroids.has_method("ids"):
		for id: int in asteroids.ids():
			if circles.size() < MAX_ASTEROIDS:
				var c: Vector3 = asteroids.center(id)
				circles.append(Vector3(c.x, c.z, asteroids.radius(id)))
	circles.resize(MAX_ASTEROIDS)
	_material.set_shader_parameter("asteroids", circles)
	_material.set_shader_parameter("asteroid_count", mini(MAX_ASTEROIDS, asteroids.ids().size()) if asteroids != null else 0)
	var trails := _arena.get_node_or_null("OrdnanceTrails")
	if trails != null:
		trails.reveal = func(point: Vector3, faction: int) -> bool: return faction == player_faction or covered(point)


## Whether the player's sensors cover a point (Sensors' last evaluation).
func covered(point: Vector3) -> bool:
	return _arena.fog_reveal or _sensors.covered(player_faction, point)


func _process(_delta: float) -> void:
	var points: Array = _sensors.sources(player_faction)
	var packed := PackedVector4Array()
	for p: Vector3 in points.slice(0, MAX_SOURCES):
		packed.append(Vector4(p.x, p.z, 0, 0))
	var count := packed.size()
	packed.resize(MAX_SOURCES)
	_material.set_shader_parameter("sources", packed)
	_material.set_shader_parameter("source_count", count)
	_material.set_shader_parameter("sensor_range", _sensors.sensor_range)
	visible = not _arena.fog_reveal
	var projectiles = _arena.get_node("Projectiles")
	for record: Dictionary in projectiles.active:
		(record.node as Node3D).visible = record.faction == player_faction or covered(record.node.global_position)
	for node: Node3D in projectiles.ordnance:
		node.visible = node.faction == player_faction or covered(node.global_position)
	for node in _arena.get_node("Effects").get_children():
		if node is Node3D:
			node.visible = covered(node.global_position)
