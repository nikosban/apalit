extends MeshInstance3D
## Combat (migrated from the prototype v0.3): short directional trails of guided ordnance (node
## `OrdnanceTrails`), all drawn in one ImmediateMesh each frame. Each trail is a tapered,
## camera-facing strip of exhaust through the positions its nozzle actually occupied
## while the main engine was lit over the last `trail_time` (so a missile has none during
## ejection and orientation), fading toward the tail. When an
## ordnance ends, its trail is kept and ages out (no new points), then is dropped.

@export var projectiles_path := NodePath("../Projectiles")
## Save the shared resource and restart F6/game to apply; runtime state never writes it.
@export var style: Resource = preload("res://game/presentation/effects/ordnance_trails/ordnance_trail_style.tres")

var _mesh := ImmediateMesh.new()
var _style: Resource
var _fading: Array[Dictionary] = [] # {kind, points, ages, limit, faction}
## v0.4 fog of war: (point, faction) -> whether a trail there may be drawn; unset: all.
var reveal: Callable = Callable()

@onready var _projectiles = get_node(projectiles_path)


func _ready() -> void:
	_style = style.duplicate(true)
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = material


## An ordnance ended: its trail stays and fades out.
func release(node: Node3D) -> void:
	if node.trail.size() >= 2:
		_fading.append({"kind": node.kind, "points": node.trail.duplicate(), "ages": node.trail_ages.duplicate(), "limit": node.config.trail_time, "faction": node.faction})


func trail_count() -> int:
	return _fading.size() + (_projectiles.ordnance.size() if _projectiles != null else 0)


func _process(delta: float) -> void:
	for entry in _fading.duplicate():
		var ages: Array = entry.ages
		for i in ages.size():
			ages[i] += delta
		while not ages.is_empty() and ages[0] > entry.limit:
			ages.remove_at(0)
			(entry.points as Array).remove_at(0)
		if ages.size() < 2:
			_fading.erase(entry)
	_mesh.clear_surfaces()
	var strips := []
	if _projectiles != null:
		for node in _projectiles.ordnance:
			if not reveal.is_valid() or reveal.call(node.global_position, node.faction):
				strips.append([node.kind, node.trail, node.trail_ages, node.config.trail_time])
	for entry in _fading:
		if not reveal.is_valid() or (entry.points as Array).is_empty() or reveal.call(entry.points[-1], entry.faction):
			strips.append([entry.kind, entry.points, entry.ages, entry.limit])
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	var began := false
	for strip: Array in strips:
		var points: Array = strip[1]
		if points.size() < 2:
			continue
		if not began:
			_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
			began = true
		_strip(strip[0], points, strip[2], strip[3], camera)
	if began:
		_mesh.surface_end()


func _strip(kind: StringName, points: Array, ages: Array, limit: float, camera: Camera3D) -> void:
	var width: float = _style.width_for(kind)
	var color: Color = _style.color_for(kind)
	var count := points.size()
	var left: Array[Vector3] = []
	var right: Array[Vector3] = []
	var colors: Array[Color] = []
	for i in count:
		var p: Vector3 = points[i]
		var direction: Vector3 = (points[mini(i + 1, count - 1)] - points[maxi(i - 1, 0)])
		var view := (camera.global_position - p) if camera != null else Vector3.UP
		var side := direction.cross(view)
		side = side.normalized() if side.length() > 0.000001 else Vector3.RIGHT
		var share := 1.0 - clampf(float(ages[i]) / maxf(limit, 0.001), 0.0, 1.0)
		var half: float = width * 0.5 * (_style.tail_width_ratio + (1.0 - _style.tail_width_ratio) * share)
		left.append(p + side * half)
		right.append(p - side * half)
		var c := color
		c.a = _style.opacity * share
		colors.append(c)
	for i in count - 1:
		_vertex(left[i], colors[i]); _vertex(right[i], colors[i]); _vertex(left[i + 1], colors[i + 1])
		_vertex(right[i], colors[i]); _vertex(right[i + 1], colors[i + 1]); _vertex(left[i + 1], colors[i + 1])


func _vertex(point: Vector3, color: Color) -> void:
	_mesh.surface_set_color(color)
	_mesh.surface_add_vertex(point)
