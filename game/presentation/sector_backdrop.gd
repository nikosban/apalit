extends MultiMeshInstance3D
## Sector Showcase round: depth backdrop (a node `Backdrop` authored in a scene;
## presentation only). Distant rock silhouettes below the gameplay plane, so the planar
## battlefield reads as a layer inside a deeper space. One MultiMesh of low-poly rocks
## placed around authored `anchors` (x, depth below the plane, z, spread), stable from
## `placement_seed`. Lit by the scene's sun, and the deeper a rock lies the more it fades
## into the environment's background colour (`haze_depth`). Not under Asteroids, Ships,
## Stations or Obstacles and in no obstacle group, so it is never navigation, collision,
## sensor occlusion, picking or a command target; casts no shadow; on the default render
## layer, so the Strategic camera (its own layer only) does not draw it. Seen through
## the fog quad on the plane, like the rest of the space beyond it.

const SHADER := """
shader_type spatial;
uniform vec4 albedo : source_color = vec4(0.2, 0.19, 0.18, 1.0);
uniform vec4 background : source_color = vec4(0.03, 0.035, 0.048, 1.0);
uniform float haze_depth = 170.0; // u below the plane where a rock is all background
varying float haze;
void vertex() { haze = clamp(-(MODEL_MATRIX * vec4(VERTEX, 1.0)).y / haze_depth, 0.0, 0.95); }
void fragment() {
	ALBEDO = albedo.rgb * (1.0 - haze);
	EMISSION = background.rgb * haze;
	ROUGHNESS = 1.0;
}
"""

@export var anchors := PackedVector4Array() # x, depth below the plane (u), z, spread (u)
@export var rocks_per_anchor := 22
@export var placement_seed := 1
@export var haze_depth := 170.0

var _material := ShaderMaterial.new()


func _ready() -> void:
	var shader := Shader.new()
	shader.code = SHADER
	_material.shader = shader
	_material.set_shader_parameter("haze_depth", haze_depth)
	_use_profile.call_deferred() # The arena creates its SectorEnvironment after its children are ready.
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rock := SphereMesh.new()
	rock.radial_segments = 7
	rock.rings = 4
	var transforms := placement()
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = rock
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])


func _use_profile() -> void:
	var environment = get_parent().get("environment")
	if environment != null:
		_material.set_shader_parameter("background", environment.profile.background_color)


## The silhouettes' transforms: per anchor, a loose group (a few large rocks, more small
## ones) spread over `spread` u, deeper rocks larger. Stable for the same anchors and seed.
func placement() -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = placement_seed
	for anchor: Vector4 in anchors:
		for i in rocks_per_anchor:
			var small := rng.randf()
			var depth := anchor.y + rng.randf_range(-0.25, 0.25) * anchor.y
			var radius := lerpf(2.0, 16.0, pow(1.0 - small, 3.0)) * (0.6 + depth / 250.0)
			var offset := Vector2.from_angle(rng.randf() * TAU) * anchor.w * sqrt(rng.randf())
			var basis := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU))
			basis = basis.scaled(Vector3(radius * rng.randf_range(0.8, 1.3), radius * rng.randf_range(0.6, 1.0), radius * rng.randf_range(0.8, 1.3)))
			result.append(Transform3D(basis, Vector3(anchor.x + offset.x, -depth, anchor.z + offset.y)))
	return result
