extends MultiMeshInstance3D
## God rays (node `GodRays`, created by SectorEnvironment when enabled; presentation only):
## soft, tapered light shafts where sunlight passing between and around the asteroid masses
## meets the formations' suspended dust, set against faint shadow bands behind the large
## masses, so light reads against shade. Physical dust lit by the star, not fog of war: it
## reads no sensor data and changes no gameplay rule.
##   Placement (built once, deterministic, from the asteroid field and the scene's
##   DirectionalLight3D; nothing is rebuilt per frame): in each of the largest formations,
##   candidate light shafts are the gaps between neighbouring asteroids that light can pass
##   through (scored by their opening across the light direction) and the limbs of large
##   masses (light grazing past them). Only strong candidates are kept (at least
##   `keep_share` of the formation's best score), at most `per_formation` per formation and
##   `max_shafts` in all. A shaft starts just upstream of its gap or limb, is brightest
##   there and widens and fades downstream along the light's travel; shadow bands start at a
##   large asteroid's downstream side and fade the same way. Every band is cut short
##   wherever another asteroid would block it, so no light shaft starts on a surface or
##   passes through rock. Length, width and brightness vary per band (stable).
##   Rendering: two MultiMeshes of quads (this node: light, additive and warm in the
##   profile's dust colour; child `Shadows`: shade, a soft darkening in the profile's shadow
##   colour), each quad turned about its own axis to face the camera, soft across, faded
##   where it meets geometry and where it is seen end-on. Fainter with the Tactical
##   emphasis; on the default render layer, so the Strategic camera does not draw it.

const VERTEX_AND_SHAPE := """
uniform float strength = 1.0; // Tactical fade
uniform float taper = 2.0; // far end width relative to the start
uniform sampler2D noise : repeat_enable, filter_linear;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
varying float along;
varying float across;
varying float grazing;
varying float variation;
varying vec3 view_pos;
void vertex() {
	// Quad x in [-0.5, 0.5] across, y in [-0.5, 0.5] along; the instance sits at the band's
	// midpoint, its basis holds the axis (y, with its length) and the width (x).
	along = VERTEX.y + 0.5;
	across = VERTEX.x + 0.5;
	vec3 axis = MODEL_MATRIX[1].xyz;
	float width = length(MODEL_MATRIX[0].xyz);
	vec3 point = MODEL_MATRIX[3].xyz + axis * VERTEX.y;
	vec3 eye = INV_VIEW_MATRIX[3].xyz;
	vec3 side = normalize(cross(normalize(axis), point - eye));
	vec3 world = point + side * VERTEX.x * width * mix(1.0, taper, along);
	grazing = 1.0 - abs(dot(normalize(axis), normalize(point - eye)));
	variation = INSTANCE_CUSTOM.r;
	view_pos = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}
"""
# Fragment statements shared by both shaders (built-ins are only available in fragment()):
# `shape`, brightest near the start (the gap or the occluder), widening and fading
# downstream, soft across, faded where it meets geometry and where it is seen end-on.
const SHAPE := """
	float soft = sin(3.14159 * across);
	float body = smoothstep(0.0, 0.06, along) * pow(1.0 - along, 1.2);
	float n = texture(noise, vec2(across * 0.6 + variation, along * 2.5 + variation * 3.0)).r;
	float scene = texture(depth_texture, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float fade = clamp((-view.z / view.w + view_pos.z) / 4.0, 0.0, 1.0);
	float shape = soft * soft * body * (0.5 + 0.5 * n) * fade * smoothstep(0.1, 0.5, grazing) * strength;
"""
const LIGHT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_add;
uniform vec4 color : source_color = vec4(0.78, 0.64, 0.5, 1.0);
uniform float intensity = 0.22;
""" + VERTEX_AND_SHAPE + """
void fragment() {""" + SHAPE + """
	ALBEDO = color.rgb * intensity * mix(0.35, 1.0, variation) * shape;
}
"""
const SHADE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;
uniform vec4 color : source_color = vec4(0.02, 0.025, 0.045, 1.0);
uniform float opacity = 0.4;
""" + VERTEX_AND_SHAPE + """
void fragment() {""" + SHAPE + """
	ALBEDO = color.rgb;
	ALPHA = opacity * mix(0.6, 1.0, variation) * shape;
}
"""

@export var formation_count := 3 # the largest formations get shafts
@export var per_formation := 3
@export var max_shafts := 8
@export var keep_share := 0.45 # least score, as a share of the formation's best, a shaft needs
@export var min_opening := 4.0 # u of gap across the light that a shaft needs
@export var length := 70.0 # u along the light (varied per band)
@export var upstream := 0.08 # share of a light shaft before its gap or limb
@export var shadow_min_radius := 5.0 # u: asteroids this large cast a shadow band
@export var max_shadows := 4
@export var tactical_fade := 0.65 # share removed at full Tactical emphasis

var shafts: Array = [] # light: {start, end, width, kind ("gap" / "limb"), variation}
var shadows: Array = [] # shade: the same, kind "shadow"
var _light_material := ShaderMaterial.new()
var _shade_material := ShaderMaterial.new()
var _shade: MultiMeshInstance3D

@onready var _environment_node := get_parent() # SectorEnvironment
@onready var _arena := _environment_node.get_parent()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var field := _arena.get_node_or_null("Asteroids")
	var light: DirectionalLight3D = _environment_node.sun()
	if field == null or light == null:
		return
	var travel := -light.global_basis.z.normalized()
	shafts = placement(field, travel)
	shadows = shadow_placement(field, travel)
	var noise := FastNoiseLite.new()
	noise.seed = 3
	noise.frequency = 0.03
	var texture := NoiseTexture2D.new()
	texture.width = 128
	texture.height = 128
	texture.seamless = true
	texture.noise = noise
	for pair in [[_light_material, LIGHT_SHADER, _environment_node.profile.dust_color], [_shade_material, SHADE_SHADER, _environment_node.profile.shadow_color]]:
		var shader := Shader.new()
		shader.code = pair[1]
		pair[0].shader = shader
		pair[0].set_shader_parameter("noise", texture)
		pair[0].set_shader_parameter("color", pair[2])
	_shade_material.set_shader_parameter("taper", 1.3) # A shadow widens less than scattered light.
	_fill(self, shafts, _light_material)
	_shade = MultiMeshInstance3D.new()
	_shade.name = "Shadows"
	_shade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shade)
	_fill(_shade, shadows, _shade_material)


# One quad per band; the custom AABB covers the camera-facing turn.
func _fill(node: MultiMeshInstance3D, bands: Array, material: ShaderMaterial) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	node.material_override = material
	node.multimesh = MultiMesh.new()
	node.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	node.multimesh.use_custom_data = true
	node.multimesh.mesh = quad
	node.multimesh.instance_count = bands.size()
	var bounds := AABB()
	for i in bands.size():
		var band: Dictionary = bands[i]
		var axis: Vector3 = band.end - band.start
		var basis := Basis(Vector3.RIGHT * band.width, axis, Vector3.FORWARD) # x: width, y: axis
		node.multimesh.set_instance_transform(i, Transform3D(basis, (band.start + band.end) * 0.5))
		node.multimesh.set_instance_custom_data(i, Color(band.variation, 0, 0, 0))
		var reach := AABB(band.start, Vector3.ZERO).expand(band.end).grow(band.width * 2.0)
		bounds = reach if i == 0 else bounds.merge(reach)
	node.custom_aabb = bounds


func _process(_delta: float) -> void:
	var markers = _arena.get("markers")
	var emphasis: float = markers.emphasis() if markers != null else 0.0
	for material in [_light_material, _shade_material]:
		material.set_shader_parameter("strength", 1.0 - tactical_fade * emphasis)


## The light shafts for a light travelling along `travel` (see the header).
func placement(field: Node, travel: Vector3) -> Array:
	var planar := Vector2(travel.x, travel.z)
	if planar.length() < 0.05:
		return [] # Light straight down: no sideways shafts to show.
	planar = planar.normalized()
	var across := Vector2(-planar.y, planar.x)
	var result := []
	for formation: Array in _largest(field):
		var candidates := []
		for i in formation.size():
			var a: int = formation[i]
			var ca: Vector3 = field.center(a)
			var ra: float = field.radius(a)
			if ra >= 6.0: # Limbs of a large mass: light grazing past both sides.
				for side: float in [-1.0, 1.0]:
					var at := ca + Vector3(across.x, 0, across.y) * side * (ra + 2.5)
					candidates.append({"at": at, "width": clampf(ra * 0.4, 5.0, 8.0), "score": ra * 1.6, "kind": "limb", "seed": a * 2 + int(side > 0.0)})
			for j in range(i + 1, formation.size()):
				var b: int = formation[j]
				var cb: Vector3 = field.center(b)
				var rb: float = field.radius(b)
				var offset := Vector2(cb.x - ca.x, cb.z - ca.z)
				var gap: float = offset.length() - ra - rb
				var opening: float = gap * absf(offset.normalized().dot(across)) # The gap as the light sees it.
				if gap < 2.0 or gap > 28.0 or opening < min_opening:
					continue
				var mid := ca.lerp(cb, (ra + gap * 0.5) / offset.length())
				candidates.append({"at": mid, "width": clampf(opening * 0.6, 3.0, 12.0), "score": opening * sqrt(ra + rb), "kind": "gap", "seed": a * 7919 + b})
		candidates.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return p.score > q.score)
		var taken := 0
		for candidate: Dictionary in candidates:
			if taken >= per_formation or result.size() >= max_shafts or candidate.score < keep_share * candidates[0].score:
				break
			var rng := RandomNumberGenerator.new()
			rng.seed = candidate.seed
			var total := length * rng.randf_range(0.6, 1.3)
			var start: Vector3 = candidate.at - travel * total * upstream
			var end: Vector3 = candidate.at + travel * total * (1.0 - upstream)
			var clipped := _clip(field, start, end, candidate.at)
			if clipped.is_empty() or clipped[0].distance_to(clipped[1]) < total * 0.4:
				continue
			result.append({"start": clipped[0], "end": clipped[1], "width": candidate.width * rng.randf_range(0.6, 1.4), "kind": candidate.kind, "variation": rng.randf()})
			taken += 1
	return result


## The shadow bands: behind the largest masses of the same formations, from the
## asteroid's downstream side along the light's travel, as wide as the asteroid.
func shadow_placement(field: Node, travel: Vector3) -> Array:
	var casters := []
	for formation: Array in _largest(field):
		for id: int in formation:
			if field.radius(id) >= shadow_min_radius:
				casters.append(id)
	casters.sort_custom(func(a: int, b: int) -> bool: return field.radius(a) > field.radius(b))
	var result := []
	for id: int in casters.slice(0, max_shadows):
		var c: Vector3 = field.center(id)
		var r: float = field.radius(id)
		var rng := RandomNumberGenerator.new()
		rng.seed = id * 104729
		var start := c + travel * (r + 1.5)
		var end := start + travel * length * rng.randf_range(0.8, 1.2)
		var clipped := _clip(field, start, end, start)
		if clipped.is_empty():
			continue
		result.append({"start": clipped[0], "end": clipped[1], "width": r * 1.7, "kind": "shadow", "variation": rng.randf()})
	return result


# The largest formations (by total area), largest first.
func _largest(field: Node) -> Array:
	var groups: Array = _environment_node.formations(field)
	groups.sort_custom(func(a: Array, b: Array) -> bool: return _mass(field, a) > _mass(field, b))
	return groups.slice(0, formation_count)


# The segment start-end kept clear of every asteroid (1 u margin): an asteroid upstream of
# `through` moves the start past it, one downstream ends the band before it. Empty when
# `through` itself is blocked.
func _clip(field: Node, start: Vector3, end: Vector3, through: Vector3) -> Array:
	var axis := end - start
	var span := axis.length()
	var dir := axis / span
	var lo := 0.0
	var hi := span
	var mid := (through - start).dot(dir)
	for id: int in field.ids():
		var c: Vector3 = field.center(id)
		var r: float = field.radius(id) + 1.0
		var t := (c - start).dot(dir)
		var miss := (start + dir * t).distance_to(c)
		if miss >= r:
			continue
		var half := sqrt(r * r - miss * miss)
		if t + half <= mid:
			lo = maxf(lo, t + half)
		elif t - half >= mid:
			hi = minf(hi, t - half)
		else:
			return []
	if hi - lo <= 0.0:
		return []
	return [start + dir * lo, start + dir * hi]


func _mass(field: Node, formation: Array) -> float:
	var total := 0.0
	for id: int in formation:
		total += field.radius(id) * field.radius(id)
	return total
