extends Node3D
## Environmental lighting prototype (node `SectorEnvironment`, added by the arena's combat
## layer, always processing; presentation only). Applies the sector's environmental
## profile (`profile`, a SectorProfile) and draws the asteroid environment.
##   Lighting: the scene's DirectionalLight3D (the prototype sun: its direction is kept)
##   takes the profile's key colour and energy; the WorldEnvironment its ambient fill and
##   background; the arena ground its albedo. FogView and StrategicView read the profile's
##   fog, shadow and dust values.
##   Asteroid environment, built once from the asteroid field (positions and radii only;
##   no collision, navigation, resource or mining data is touched): small rocks and fine
##   debris (two lit MultiMeshes, no shadows cast) and soft dust clouds (one MultiMesh of
##   camera-facing quads, unshaded, faded where they meet other geometry), all placed
##   around each asteroid from its id, so placement is stable. Dust is brighter on the
##   sunward side of its asteroid and dimmer on the shaded side (an artistic stand-in for
##   scattering, not a volumetric simulation). Tactical emphasis (TacticalMarkers) reduces
##   it: fine debris shrinks away, dust thins out. The Strategic camera does not render
##   it (StrategicView draws its own density and dust).

const SectorProfile := preload("res://game/presentation/sector_profile.gd")
const DEBRIS_SHADER := """
shader_type spatial;
uniform vec4 albedo : source_color = vec4(0.33, 0.31, 0.29, 1.0);
uniform float detail = 1.0; // 0-1: scales every instance down to nothing
void vertex() { VERTEX *= detail; }
void fragment() {
	ALBEDO = albedo.rgb * COLOR.rgb;
	ROUGHNESS = 1.0;
}
"""

@export var profile: Resource = preload("res://game/presentation/warm_sector.tres")
@export var dust_tactical_fade := 0.65 # share of the dust removed at full Tactical emphasis

var rock_count := 0
var fine_count := 0
var dust_count := 0

var _rocks: MultiMeshInstance3D
var _fine: MultiMeshInstance3D
var _dust: MultiMeshInstance3D
var _rock_material := ShaderMaterial.new()
var _fine_material := ShaderMaterial.new()
var _dust_material := StandardMaterial3D.new()

@onready var _arena := get_parent()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	apply_lighting()
	_build.call_deferred() # After any asteroid added during the scene's setup.


## The profile's stellar light, ambient fill, background and ground.
func apply_lighting() -> void:
	var light := sun()
	if light != null:
		light.light_color = profile.key_color
		light.light_energy = profile.key_energy
	for child in _arena.get_children():
		if child is WorldEnvironment and child.environment != null:
			child.environment.background_color = profile.background_color
			child.environment.ambient_light_color = profile.ambient_color
			child.environment.ambient_light_energy = profile.ambient_energy
	var ground := _arena.get_node_or_null("Ground") as MeshInstance3D
	if ground != null and ground.mesh != null and ground.mesh.material is StandardMaterial3D:
		(ground.mesh.material as StandardMaterial3D).albedo_color = profile.ground_color


## The scene's DirectionalLight3D (the prototype sun), or null.
func sun() -> DirectionalLight3D:
	for child in _arena.get_children():
		if child is DirectionalLight3D:
			return child
	return null


## The planar direction sunlight travels (zero without a light or straight overhead).
func light_direction() -> Vector2:
	var light := sun()
	if light == null:
		return Vector2.ZERO
	var travel := -light.global_basis.z
	var planar := Vector2(travel.x, travel.z)
	return planar.normalized() if planar.length() > 0.05 else Vector2.ZERO


func _build() -> void:
	var field := _arena.get_node_or_null("Asteroids")
	if field == null or not field.has_method("ids"):
		return
	var placed := placement(field)
	_rocks = _instances(placed.rocks, _rock_mesh(5, 3), _rock_material)
	_fine = _instances(placed.fine, _rock_mesh(4, 2), _fine_material)
	_dust = _dust_instances(placed.dust)
	rock_count = placed.rocks.size()
	fine_count = placed.fine.size()
	dust_count = placed.dust.size()


## Where the asteroid environment goes (from the field's centres and radii and each
## asteroid's id only): {rocks, fine: Array[Transform3D], dust: [[Transform3D, Color]]}.
func placement(field: Node) -> Dictionary:
	var rocks: Array[Transform3D] = []
	var fine: Array[Transform3D] = []
	var dust: Array = [] # [Transform3D, Color]
	var toward_sun := -light_direction()
	for id: int in field.ids():
		var c: Vector3 = field.center(id)
		var r: float = field.radius(id)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(id) # Stable placement per asteroid.
		for i in clampi(roundi(3.0 + r * 2.5), 3, 20):
			rocks.append(_scatter(rng, c, r, 0.9 + r * 0.8, rng.randf_range(0.12, 0.3) * clampf(r / 2.5, 0.6, 1.6)))
		for i in clampi(roundi(r * 8.0), 4, 48):
			fine.append(_scatter(rng, c, r, 2.0 + r * 1.4, rng.randf_range(0.03, 0.08)))
		if r < 1.5:
			continue
		for i in clampi(int(r / 1.5), 1, 4):
			var angle := rng.randf() * TAU
			var offset := Vector2.from_angle(angle) * r * rng.randf_range(0.3, 1.2)
			var size := r * rng.randf_range(2.4, 3.4)
			var basis := Basis.IDENTITY.scaled(Vector3(size, size, size))
			var at := Vector3(c.x + offset.x, c.y + rng.randf_range(-0.3, 0.6), c.z + offset.y)
			# Sunward clouds are lit, clouds behind the asteroid are in its shade.
			var facing := offset.normalized().dot(toward_sun) if toward_sun != Vector2.ZERO else 0.0
			var lit := 0.55 + 0.45 * facing
			dust.append([Transform3D(basis, at), Color(lit, lit, lit, rng.randf_range(0.7, 1.0))])
	return {"rocks": rocks, "fine": fine, "dust": dust}


# A random fragment around an asteroid: outside its surface, within `spread` of it, near
# its height, randomly rotated and flattened.
func _scatter(rng: RandomNumberGenerator, c: Vector3, r: float, spread: float, size: float) -> Transform3D:
	var angle := rng.randf() * TAU
	var distance := r * 1.05 + spread * rng.randf() * rng.randf() # Denser close in.
	var basis := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU))
	basis = basis.scaled(Vector3(size * rng.randf_range(0.7, 1.3), size * rng.randf_range(0.5, 1.0), size * rng.randf_range(0.7, 1.3)))
	var at := Vector3(c.x + cos(angle) * distance, c.y + rng.randf_range(-0.5, 0.5) * minf(r, 2.0), c.z + sin(angle) * distance)
	return Transform3D(basis, at)


func _rock_mesh(segments: int, rings: int) -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = segments
	mesh.rings = rings
	return mesh


func _instances(transforms: Array[Transform3D], mesh: Mesh, material: ShaderMaterial) -> MultiMeshInstance3D:
	var shader := Shader.new()
	shader.code = DEBRIS_SHADER
	material.shader = shader
	material.set_shader_parameter("albedo", profile.debris_color)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = multimesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func _dust_instances(dust: Array) -> MultiMeshInstance3D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	gradient.add_point(0.45, Color(1, 1, 1, 0.45))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 64
	texture.height = 64
	_dust_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dust_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dust_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_dust_material.billboard_keep_scale = true
	_dust_material.vertex_color_use_as_albedo = true
	_dust_material.albedo_texture = texture
	_dust_material.albedo_color = Color(profile.dust_color, profile.dust_strength)
	_dust_material.proximity_fade_enabled = true # No hard line where a cloud meets the ground.
	_dust_material.proximity_fade_distance = 3.0
	_dust_material.disable_receive_shadows = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = quad
	multimesh.instance_count = dust.size()
	for i in dust.size():
		multimesh.set_instance_transform(i, dust[i][0])
		multimesh.set_instance_color(i, dust[i][1])
	var node := MultiMeshInstance3D.new()
	node.multimesh = multimesh
	node.material_override = _dust_material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func _process(_delta: float) -> void:
	if _rocks == null:
		return
	var emphasis: float = _arena.markers.emphasis() if _arena.markers != null else 0.0
	var fine_detail := 1.0 - smoothstep(0.0, 0.6, emphasis)
	_fine_material.set_shader_parameter("detail", fine_detail)
	_fine.visible = fine_detail > 0.0
	_dust_material.albedo_color.a = profile.dust_strength * (1.0 - dust_tactical_fade * emphasis)
