extends MeshInstance3D
## Ship sensor grid overlay (node `SensorGridOverlay`, added by the arena in scenes with
## Sensors; always processing, presentation only). One flat quad under the first selected
## ship (`selection().selected[0]`, as the weapon envelopes), hidden while nothing is
## selected. It follows the ship's position on the plane; the quad stays aligned to the world
## axes and the shader turns the grid with the ship's heading (`grid_axis`, the ship's X axis,
## set every frame). The radius is the scene's `Sensors.sensor_range`, read every frame; the quad's
## size and the shader's `sensor_radius` instance parameter change only when it does.
## Everything visual is in the shared `sensor_grid_material.tres` (sensor_grid.gdshader
## uniforms). The overlay draws with its own copy of it, made at start, because the
## obstacle cutouts are uniform arrays written every frame; the shared file is never
## written.
## Obstacle cutouts (line of sight): every frame, each static obstacle footprint
## PlanarCollision collides with (circles, rotated boxes; at their nodes' current positions)
## that, grown by `cutout_clearance`, reaches the overlay casts a shadow from the ship: the
## grown footprint plus the region behind it between the two tangent rays from the ship,
## out past the quad. Circles go to the shader as centre and radius (it computes the shadow
## exactly); boxes as a convex polygon built here. The shader subtracts the union of the
## shadows from the sensor circle. Ships are never obstacles here. Reads selection, sensors and collision data only; no collision, no
## picking.

const HEIGHT := 0.04 # u above the ground plane, below ship hulls
const MAX_SHADOWS := 64 # sensor_grid.gdshader array sizes
const MAX_POLYGONS := 8
const MAX_POLYGON_POINTS := 128
const CORNER_SAMPLES := 8 # points per rounded box corner in a box shadow

@export var bounds_margin := 4.0 # u past the outer outline, so its pixel width never clips

var ship: Node3D = null # The ship drawn for (null while hidden).
var radius := -1.0 # The radius applied last.
var cutouts := 0 # Obstacle shadows drawn in the last frame (diagnostics).

var _material: ShaderMaterial

@onready var _arena := get_parent()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_material = material_override.duplicate()
	material_override = _material


func _process(_delta: float) -> void:
	var selected: Array = _arena.selection().selected
	ship = selected[0] if not selected.is_empty() and is_instance_valid(selected[0]) else null
	visible = ship != null and _arena.sensors != null
	if not visible:
		return
	var sensor_range: float = _arena.sensors.sensor_range
	if sensor_range != radius:
		radius = sensor_range
		var offset: float = _material.get_shader_parameter("outer_offset")
		var half := radius + offset + bounds_margin
		scale = Vector3(half, 1.0, half) # The quad is 2 × 2 u.
		set_instance_shader_parameter("sensor_radius", radius)
	global_position = Vector3(ship.global_position.x, HEIGHT, ship.global_position.z)
	var x_axis := Vector2(ship.global_basis.x.x, ship.global_basis.x.z)
	set_instance_shader_parameter("grid_axis", x_axis.normalized() if x_axis.length() > 0.001 else Vector2.RIGHT)
	_update_cutouts(Vector2(ship.global_position.x, ship.global_position.z))


func _update_cutouts(origin: Vector2) -> void:
	var collision := _arena.get_node_or_null("PlanarCollision")
	var clearance: float = _material.get_shader_parameter("cutout_clearance")
	var outer: float = radius + _material.get_shader_parameter("outer_offset")
	var reach := outer + bounds_margin # a box shadow's far edge lies past the quad
	# Obstacles reaching the overlay, nearest the ship first (their shadows are the widest,
	# kept first when the shader's arrays are full).
	var found: Array[Dictionary] = []
	for obstacle: Dictionary in (collision.obstacles() if collision != null else []):
		var node := obstacle.node as Node3D
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		var center := Vector2(node.global_position.x, node.global_position.z) - origin
		if obstacle.circle:
			var grown: float = obstacle.radius + clearance
			# No tangents from inside the grown footprint: such an obstacle casts no shadow.
			if center.length() - grown < reach and center.length() > grown + 0.01:
				found.append({"distance": center.length() - grown, "center": center, "grown": grown})
		else:
			var x_axis := Vector2(node.global_basis.x.x, node.global_basis.x.z).normalized()
			var half: Vector2 = obstacle.half
			var distance := _box_distance(-center, x_axis, half) - clearance
			if distance < reach and distance > 0.01:
				found.append({"distance": distance, "center": center, "x_axis": x_axis, "half": half})
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance < b.distance)
	var centers := PackedVector2Array()
	var radii := PackedFloat32Array()
	var points := PackedVector2Array()
	var polygon_first := PackedInt32Array()
	var polygon_sizes := PackedInt32Array()
	cutouts = 0
	for entry: Dictionary in found:
		if entry.has("grown"):
			if centers.size() >= MAX_SHADOWS:
				continue
			centers.append(entry.center)
			radii.append(entry.grown)
		else:
			# The box grown by the clearance (its rounded corners sampled from outside) and every
			# sample pushed away from the ship past the quad: their convex hull is the shadow.
			var center: Vector2 = entry.center
			var x_axis: Vector2 = entry.x_axis
			var half: Vector2 = entry.half
			var hull_input := PackedVector2Array()
			for corner_sign: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				var corner := center + x_axis * half.x * corner_sign.x + Vector2(-x_axis.y, x_axis.x) * half.y * corner_sign.y
				for i in CORNER_SAMPLES:
					var point := corner + Vector2.from_angle(TAU * i / CORNER_SAMPLES) * clearance / cos(PI / CORNER_SAMPLES)
					hull_input.append(point)
					hull_input.append(point.normalized() * (point.length() + reach))
			var hull := Geometry2D.convex_hull(hull_input)
			hull.remove_at(hull.size() - 1) # convex_hull() closes the loop
			if polygon_first.size() >= MAX_POLYGONS or points.size() + hull.size() > MAX_POLYGON_POINTS:
				continue
			polygon_first.append(points.size())
			polygon_sizes.append(hull.size())
			points.append_array(hull)
		cutouts += 1
	var shadow_count := centers.size()
	var polygon_count := polygon_first.size()
	centers.resize(MAX_SHADOWS)
	radii.resize(MAX_SHADOWS)
	points.resize(MAX_POLYGON_POINTS)
	polygon_first.resize(MAX_POLYGONS)
	polygon_sizes.resize(MAX_POLYGONS)
	_material.set_shader_parameter("shadow_centers", centers)
	_material.set_shader_parameter("shadow_radii", radii)
	_material.set_shader_parameter("shadow_count", shadow_count)
	_material.set_shader_parameter("polygon_points", points)
	_material.set_shader_parameter("polygon_first", polygon_first)
	_material.set_shader_parameter("polygon_sizes", polygon_sizes)
	_material.set_shader_parameter("polygon_count", polygon_count)


## Distance from `point` (relative to the box centre) to a rotated box of half size `half`.
static func _box_distance(point: Vector2, x_axis: Vector2, half: Vector2) -> float:
	var local := Vector2(point.dot(x_axis), point.dot(Vector2(-x_axis.y, x_axis.x)))
	var outside := (local.abs() - half).max(Vector2.ZERO)
	return outside.length()
