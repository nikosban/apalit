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
##   camera-facing quads, unshaded, faded where they meet other geometry), placed from the
##   asteroids' ids, so placement is stable. Sector Showcase round: dust and part of the
##   fine debris describe formations (asteroids whose surfaces lie within `formation_gap`
##   of each other), not single rocks: rocks stay close to each asteroid, fine debris also
##   fills the gaps between neighbours, and dust gathers in broad, uneven pockets around a
##   formation (some left out), brighter on the formation's sunward side and dimmer on its
##   shaded side, with some random variation (an artistic stand-in for scattering, not a
##   volumetric simulation). Tactical emphasis (TacticalMarkers) reduces
##   it: fine debris shrinks away, dust thins out. The Strategic camera does not render
##   it (StrategicView draws its own density and dust).
##   Sky (one scene-wide setting, every view; the scene's `environment_experiment`, F8 in
##   development): `sky_mode` A (0) the profile's flat background, colour ambient and
##   background reflections (the Test Arena); B (1) the HDR_galactic_plane_1 panorama as
##   the visible sky (the Sector Showcase); C (2) the same sky with ambient and reflections
##   sampled from it (kept for comparison only: the panorama is too dark to light). The
##   panorama (200 MB) loads on first use only.
##   Environment lighting (with B; the scene's `lighting_experiment_d`, F7 to disable while
##   troubleshooting): the same panorama drawn by a sky shader whose lighting pass
##   (AT_CUBEMAP_PASS) is a designed distribution: a cool fill (the profile's ambient
##   colour, dimmer away from the star) and a warm lobe (the profile's key colour) toward
##   the DirectionalLight3D's direction, used for ambient light and reflections. Static
##   uniforms: the radiance is baked once, not per frame. The sun, materials, exposure and
##   post-processing are never touched.
##   God rays (the scene's `god_rays_enabled`, F9): GodRays, a bounded set of light shafts
##   in the largest formations.

const SectorProfile := preload("res://game/presentation/sector_profile.gd")
const GodRays := preload("res://game/presentation/god_rays.gd")
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
@export var formation_gap := 28.0 # u between asteroid surfaces that still joins them in one formation

var rock_count := 0
var fine_count := 0
var dust_count := 0

var _rocks: MultiMeshInstance3D
var _fine: MultiMeshInstance3D
var _dust: MultiMeshInstance3D
var _rock_material := ShaderMaterial.new()
var _fine_material := ShaderMaterial.new()
var _dust_material := StandardMaterial3D.new()

const SKY_PANORAMA := "res://assets/textures/skybox/HDR_galactic_plane_1.hdr"
const SKY_MODE_NAMES := ["A baseline", "B visible HDR sky", "C HDR sky with environment lighting"]
const LIGHTING_SKY_SHADER := """
shader_type sky;
uniform sampler2D source_panorama : filter_linear, source_color, hint_default_black;
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0); // toward the star, in the sky's frame
uniform vec4 fill_color : source_color = vec4(0.42, 0.5, 0.66, 1.0);
uniform float fill_energy = 0.45;
uniform float away_share = 0.5; // fill left on the side facing away from the star
uniform vec4 key_color : source_color = vec4(1.0, 0.9, 0.78, 1.0);
uniform float key_energy = 0.6;
uniform float key_power = 3.0; // lobe tightness
void sky() {
	if (AT_CUBEMAP_PASS) {
		float facing = dot(EYEDIR, sun_dir);
		vec3 fill = fill_color.rgb * fill_energy * mix(away_share, 1.0, 0.5 + 0.5 * facing);
		COLOR = fill + key_color.rgb * key_energy * pow(max(facing, 0.0), key_power);
	} else {
		COLOR = texture(source_panorama, SKY_COORDS).rgb; // As PanoramaSkyMaterial (energy 1).
	}
}
"""

## Panorama orientation: X 90 degrees turns the galactic band (the panorama's horizon)
## into a great circle passing under the gameplay plane, where the cameras look.
var sky_rotation_degrees := Vector3(90.0, 0.0, 0.0)
var sky_mode := 0
var lighting_d := false # Designed environment lighting (applies with B).
## The designed lighting distribution (integration values).
var d_fill_energy := 0.45
var d_away_share := 0.5
var d_key_energy := 0.6
var d_key_power := 3.0
var _d_sky: Sky = null
var god_rays: Node3D = null # GodRays, while enabled.
var _baseline := {} # The environment's A settings, captured after apply_lighting().
var _sky: Sky = null

@onready var _arena := get_parent()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for child in _arena.get_children(): # An own copy: the scene's sub-resource is shared by every instance.
		if child is WorldEnvironment and child.environment != null:
			child.environment = child.environment.duplicate()
	apply_lighting()
	var environment := world_environment()
	if environment != null:
		for key in ["background_mode", "sky", "sky_rotation", "ambient_light_source", "ambient_light_energy", "ambient_light_sky_contribution", "reflected_light_source"]:
			_baseline[key] = environment.get(key)
	lighting_d = bool(_arena.get("lighting_experiment_d")) if _arena.get("lighting_experiment_d") != null else false
	set_sky_mode(int(_arena.get("environment_experiment")) if _arena.get("environment_experiment") != null else 0)
	if _arena.get("god_rays_enabled"):
		set_god_rays.call_deferred(true) # After the asteroid field is complete.
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


## The scene's Environment (its WorldEnvironment's), or null.
func world_environment() -> Environment:
	for child in _arena.get_children():
		if child is WorldEnvironment:
			return child.environment
	return null


## Applies sky configuration A (0), B (1) or C (2); see the header.
func set_sky_mode(mode: int) -> void:
	var environment := world_environment()
	if environment == null:
		return
	sky_mode = clampi(mode, 0, 2)
	for key in _baseline:
		environment.set(key, _baseline[key])
	if sky_mode != 0:
		_apply_sky(environment)


## God rays on or off (off frees them: no node, no GPU work).
func set_god_rays(on: bool) -> void:
	if on and god_rays == null:
		god_rays = GodRays.new()
		god_rays.name = "GodRays"
		add_child(god_rays)
	elif not on and god_rays != null:
		god_rays.queue_free()
		god_rays = null


func _apply_sky(environment: Environment) -> void:
	if _sky == null:
		var material := PanoramaSkyMaterial.new()
		material.panorama = load(SKY_PANORAMA)
		_sky = Sky.new()
		_sky.sky_material = material
		_sky.process_mode = Sky.PROCESS_MODE_QUALITY # Static: the radiance is computed once.
	environment.sky = _sky
	environment.sky_rotation = sky_rotation_degrees * PI / 180.0
	environment.background_mode = Environment.BG_SKY
	if sky_mode == 1 and lighting_d:
		environment.sky = _lighting_sky()
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		environment.ambient_light_energy = 1.0
		environment.ambient_light_sky_contribution = 1.0
		environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	elif sky_mode == 1:
		environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	else:
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		environment.ambient_light_energy = 1.0
		environment.ambient_light_sky_contribution = 1.0
		environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY


## Designed environment lighting on or off (it changes the scene only in configuration B).
func set_environment_lighting(on: bool) -> void:
	lighting_d = on
	set_sky_mode(sky_mode)


# D's sky: the same panorama for the background, the designed distribution for lighting.
func _lighting_sky() -> Sky:
	if _d_sky == null:
		var material := ShaderMaterial.new()
		var shader := Shader.new()
		shader.code = LIGHTING_SKY_SHADER
		material.shader = shader
		material.set_shader_parameter("source_panorama", (_sky.sky_material as PanoramaSkyMaterial).panorama)
		_d_sky = Sky.new()
		_d_sky.sky_material = material
		_d_sky.process_mode = Sky.PROCESS_MODE_QUALITY # Static uniforms: baked once.
	var material := _d_sky.sky_material as ShaderMaterial
	var light := sun()
	var toward_sun := light.global_basis.z if light != null else Vector3.UP
	# World space: measured with the sun hidden, EYEDIR in the lighting pass is not turned
	# by Environment.sky_rotation (the sunward side lit, 0.163 vs 0.084 on the far side).
	material.set_shader_parameter("sun_dir", toward_sun.normalized())
	material.set_shader_parameter("fill_color", profile.ambient_color)
	material.set_shader_parameter("key_color", profile.key_color)
	material.set_shader_parameter("fill_energy", d_fill_energy)
	material.set_shader_parameter("away_share", d_away_share)
	material.set_shader_parameter("key_energy", d_key_energy)
	material.set_shader_parameter("key_power", d_key_power)
	return _d_sky


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
		for i in clampi(roundi(3.0 + r * 2.5), 3, 24):
			rocks.append(_scatter(rng, c, r, 0.9 + r * 0.5, rng.randf_range(0.12, 0.3) * clampf(r / 2.5, 0.6, 2.0)))
		for i in clampi(roundi(r * 5.0), 3, 40):
			fine.append(_scatter(rng, c, r, 2.0 + r * 0.8, rng.randf_range(0.03, 0.08)))
	for formation: Array in formations(field):
		# Fine debris in the gaps between neighbouring members.
		for i in formation.size():
			for j in range(i + 1, formation.size()):
				var a: int = formation[i]
				var b: int = formation[j]
				var ca: Vector3 = field.center(a)
				var cb: Vector3 = field.center(b)
				var gap: float = Vector2(ca.x - cb.x, ca.z - cb.z).length() - field.radius(a) - field.radius(b)
				if gap > formation_gap:
					continue
				var rng := RandomNumberGenerator.new()
				rng.seed = hash(Vector2i(a, b))
				var side := Vector3(cb.z - ca.z, 0.0, ca.x - cb.x).normalized()
				for k in clampi(roundi(gap * 0.8), 2, 12):
					var at := ca.lerp(cb, rng.randf_range(0.2, 0.8)) + side * rng.randf_range(-1.0, 1.0) * minf(field.radius(a), field.radius(b)) + Vector3(0, rng.randf_range(-0.6, 0.6), 0)
					if _inside(field, formation, at):
						continue
					var basis := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)).scaled(Vector3.ONE * rng.randf_range(0.03, 0.08))
					fine.append(Transform3D(basis, at))
		# Dust: broad, uneven pockets around the formation, not one cloud per rock.
		var total := 0.0
		var centroid := Vector3.ZERO
		for id: int in formation:
			total += field.radius(id)
			centroid += field.center(id) * field.radius(id)
		centroid /= maxf(total, 0.001)
		if total < 3.0:
			continue # Too small to gather dust.
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(formation[0] * 7919 + formation.size())
		for i in clampi(roundi(total / 2.5), 1, 24):
			if rng.randf() < 0.3:
				continue # Leave gaps: dust is not uniform.
			var member: int = _weighted_member(field, formation, rng)
			var c: Vector3 = field.center(member)
			var r: float = field.radius(member)
			var offset := Vector2.from_angle(rng.randf() * TAU) * (r * rng.randf_range(0.5, 1.4) + rng.randf_range(0.0, 8.0))
			var size := rng.randf_range(9.0, 16.0) + r * 1.4
			var at := Vector3(c.x + offset.x, c.y + rng.randf_range(-1.0, 1.5), c.z + offset.y)
			var away := Vector2(at.x - centroid.x, at.z - centroid.z)
			var facing := away.normalized().dot(toward_sun) if toward_sun != Vector2.ZERO and away.length() > 0.1 else 0.0
			var lit := clampf(0.55 + 0.35 * facing + rng.randf_range(-0.1, 0.1), 0.2, 1.0)
			dust.append([Transform3D(Basis.IDENTITY.scaled(Vector3(size, size, size)), at), Color(lit, lit, lit, rng.randf_range(0.5, 1.0))])
	return {"rocks": rocks, "fine": fine, "dust": dust}


## Asteroid formations: groups of asteroids whose surfaces lie within `formation_gap` of
## a neighbour (union-find over the field's ids, ascending; each group ascending).
func formations(field: Node) -> Array:
	var ids: Array = field.ids()
	var parent := {}
	for id: int in ids:
		parent[id] = id
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: int = ids[i]
			var b: int = ids[j]
			var ca: Vector3 = field.center(a)
			var cb: Vector3 = field.center(b)
			if Vector2(ca.x - cb.x, ca.z - cb.z).length() - field.radius(a) - field.radius(b) <= formation_gap:
				parent[_root(parent, a)] = _root(parent, b)
	var groups := {}
	for id: int in ids:
		var root := _root(parent, id)
		if not groups.has(root):
			groups[root] = []
		groups[root].append(id)
	return groups.values()


static func _root(parent: Dictionary, id: int) -> int:
	while parent[id] != id:
		parent[id] = parent[parent[id]]
		id = parent[id]
	return id


# A member chosen with probability by its area (dust gathers around the large masses).
func _weighted_member(field: Node, formation: Array, rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for id: int in formation:
		total += field.radius(id) * field.radius(id)
	var pick := rng.randf() * total
	for id: int in formation:
		pick -= field.radius(id) * field.radius(id)
		if pick <= 0.0:
			return id
	return formation[-1]


func _inside(field: Node, members: Array, point: Vector3) -> bool:
	for id: int in members:
		var c: Vector3 = field.center(id)
		if Vector2(point.x - c.x, point.z - c.z).length() < field.radius(id):
			return true
	return false


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
