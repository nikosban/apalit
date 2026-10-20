extends Node
## Stage 3 static navigation: one NavigationServer2D map per planning radius,
## baked once from the obstacle meshes under the Obstacles node and in the
## `static_obstacle` group (cylinders and
## spheres as circles of their horizontal radius, boxes; X/Z plane). Plans routes
## and answers clearance questions; it never moves ships.

const MAP_HALF_SIZE := 150.0 # Navigable square, matches the 300 × 300 ground.
const CELL_SIZE := 0.25 # Navigation vertex snapping (u); map and polygons must match.
const CIRCLE_SEGMENTS := 32 # Cylinder outlines (circumscribed, never smaller than the cylinder).
const STRAIGHT_TOLERANCE := 0.0005 # sin of the direction change below which a route point is dropped (~0.03°).
const DUPLICATE_DISTANCE := 0.001 # u; route points closer than this to the previous one are dropped.
const OBSTACLE_GROUP := &"static_obstacle" # Phase 2 Stage 3: obstacle meshes outside the Obstacles node (station bodies and arms).

@export var obstacles_path := NodePath("../Obstacles")

var _maps := {} # planning radius -> map RID
var _regions: Array[RID] = []
var _boundaries := {} # planning radius -> PackedVector2Array of segment pairs (debug)
# Obstacle shapes for line and clearance checks: {circle: bool, center, radius | half, x_axis, bounds}.
var _obstacles: Array[Dictionary] = []


func _ready() -> void:
	for child in get_node(obstacles_path).get_children() + get_tree().get_nodes_in_group(OBSTACLE_GROUP):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null:
			continue
		var basis := mesh_instance.global_basis
		var center := Vector2(mesh_instance.global_position.x, mesh_instance.global_position.z)
		var x_axis := Vector2(basis.x.x, basis.x.z)
		var scale := x_axis.length()
		x_axis /= scale
		if mesh_instance.mesh is CylinderMesh or mesh_instance.mesh is SphereMesh:
			var radius := round_radius(mesh_instance.mesh) * scale
			_obstacles.append({"circle": true, "center": center, "radius": radius,
				"bounds": Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)})
		elif mesh_instance.mesh is BoxMesh:
			var size := (mesh_instance.mesh as BoxMesh).size
			var half := Vector2(size.x, size.z) * 0.5 * scale
			var reach := Vector2(absf(x_axis.x) * half.x + absf(x_axis.y) * half.y, absf(x_axis.y) * half.x + absf(x_axis.x) * half.y)
			_obstacles.append({"circle": false, "center": center, "half": half, "x_axis": x_axis,
				"bounds": Rect2(center - reach, reach * 2.0)})


## Horizontal radius of a round obstacle mesh (cylinder: its larger end; sphere:
## its widest circle, used whatever the ship plane's height, so never smaller).
static func round_radius(mesh: Mesh) -> float:
	if mesh is SphereMesh:
		return (mesh as SphereMesh).radius
	var cylinder := mesh as CylinderMesh
	return maxf(cylinder.top_radius, cylinder.bottom_radius)


func _exit_tree() -> void:
	for region in _regions:
		NavigationServer2D.free_rid(region)
	for map: RID in _maps.values():
		NavigationServer2D.free_rid(map)


## Bakes the map for a planning radius (ship radius + margin) once.
func add_radius(radius: float) -> void:
	if _maps.has(radius):
		return
	var polygon := NavigationPolygon.new()
	polygon.cell_size = CELL_SIZE
	polygon.agent_radius = radius
	var source := NavigationMeshSourceGeometryData2D.new()
	var h := MAP_HALF_SIZE
	source.add_traversable_outline(PackedVector2Array([Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)]))
	for obstacle in _obstacles:
		source.add_obstruction_outline(_outline(obstacle))
	NavigationServer2D.bake_from_source_geometry_data(polygon, source)
	var map := NavigationServer2D.map_create()
	NavigationServer2D.map_set_cell_size(map, CELL_SIZE)
	var region := NavigationServer2D.region_create()
	NavigationServer2D.region_set_map(region, map)
	NavigationServer2D.region_set_navigation_polygon(region, polygon)
	NavigationServer2D.map_set_active(map, true)
	_maps[radius] = map
	_regions.append(region)
	_boundaries[radius] = _boundary_segments(polygon)


## True once the map answers queries (a few physics frames after baking). The
## first map sync can still be empty, so after it an actual query is checked.
func is_ready(radius: float) -> bool:
	if not _maps.has(radius) or NavigationServer2D.map_get_iteration_id(_maps[radius]) == 0:
		return false
	return NavigationServer2D.map_get_closest_point(_maps[radius], Vector2(2.0 * MAP_HALF_SIZE, 0.0)).x > 0.0


## Shortest route for a planning radius; the last point is the resolved destination
## (the closest reachable point when the request is not reachable). Empty: no route.
## Points without a real change of direction (polygon-edge crossings) and
## near-duplicate points are dropped.
func plan(radius: float, from: Vector2, to: Vector2) -> PackedVector2Array:
	var path := NavigationServer2D.map_get_path(_maps[radius], from, to, true)
	if path.size() < 3:
		return path
	var route := PackedVector2Array([path[0]])
	for i in range(1, path.size() - 1):
		if path[i].distance_to(route[route.size() - 1]) < DUPLICATE_DISTANCE:
			continue
		var into := (path[i] - route[route.size() - 1]).normalized()
		var out := (path[i + 1] - path[i]).normalized()
		if absf(into.cross(out)) > STRAIGHT_TOLERANCE or into.dot(out) < 0.0:
			route.append(path[i])
	route.append(path[path.size() - 1])
	return route


## Closest point of a planning radius' navigable area to a point (the point itself
## when a ship of that planning radius fits there). Says nothing about reachability.
func closest_point(radius: float, point: Vector2) -> Vector2:
	return NavigationServer2D.map_get_closest_point(_maps[radius], point)


## Navigable-area boundary of a planning radius as segment pairs (debug drawing).
func boundary_segments(radius: float) -> PackedVector2Array:
	return _boundaries.get(radius, PackedVector2Array())


## True if a ship of the given radius moving straight from a to b keeps clear of
## every obstacle and inside the map. Only obstacles near the segment are tested.
func segment_clear(a: Vector2, b: Vector2, radius: float) -> bool:
	var limit := MAP_HALF_SIZE - radius
	if absf(a.x) > limit or absf(a.y) > limit or absf(b.x) > limit or absf(b.y) > limit:
		return false
	var span := Rect2(a, Vector2.ZERO).expand(b).grow(radius)
	for obstacle in _obstacles:
		if not span.intersects(obstacle.bounds):
			continue
		if obstacle.circle:
			if Geometry2D.get_closest_point_to_segment(obstacle.center, a, b).distance_to(obstacle.center) < obstacle.radius + radius:
				return false
		elif _segment_box_distance(_to_box(obstacle, a), _to_box(obstacle, b), obstacle.half) < radius:
			return false
	return true


## Distance from a point to the nearest obstacle surface (negative inside).
func surface_distance(point: Vector2) -> float:
	var nearest := INF
	for obstacle in _obstacles:
		if obstacle.circle:
			nearest = minf(nearest, point.distance_to(obstacle.center) - obstacle.radius)
		else:
			nearest = minf(nearest, _point_box_distance(_to_box(obstacle, point), obstacle.half))
	return nearest


func _outline(obstacle: Dictionary) -> PackedVector2Array:
	var points := PackedVector2Array()
	if obstacle.circle:
		var vertex_radius: float = obstacle.radius / cos(PI / CIRCLE_SEGMENTS)
		for i in CIRCLE_SEGMENTS:
			points.append(obstacle.center + Vector2.from_angle(TAU * i / CIRCLE_SEGMENTS) * vertex_radius)
	else:
		var x_axis: Vector2 = obstacle.x_axis
		var z_axis := Vector2(-x_axis.y, x_axis.x)
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			points.append(obstacle.center + x_axis * corner.x * obstacle.half.x + z_axis * corner.y * obstacle.half.y)
	return points


# Edges used by exactly one navigation polygon: the navigable-area boundary.
func _boundary_segments(polygon: NavigationPolygon) -> PackedVector2Array:
	var vertices := polygon.get_vertices()
	var counts := {}
	for p in polygon.get_polygon_count():
		var indices := polygon.get_polygon(p)
		for i in indices.size():
			var a := indices[i]
			var b := indices[(i + 1) % indices.size()]
			var key := Vector2i(mini(a, b), maxi(a, b))
			counts[key] = counts.get(key, 0) + 1
	var segments := PackedVector2Array()
	for key: Vector2i in counts:
		if counts[key] == 1:
			segments.append(vertices[key.x])
			segments.append(vertices[key.y])
	return segments


# Point in the box's own frame (x along x_axis, y along the box's Z).
func _to_box(obstacle: Dictionary, point: Vector2) -> Vector2:
	var offset: Vector2 = point - obstacle.center
	var x_axis: Vector2 = obstacle.x_axis
	return Vector2(offset.dot(x_axis), offset.dot(Vector2(-x_axis.y, x_axis.x)))


func _point_box_distance(local: Vector2, half: Vector2) -> float:
	var d := local.abs() - half
	return Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() + minf(maxf(d.x, d.y), 0.0)


# Distance between a segment and a box, both in the box frame (0 if they touch).
func _segment_box_distance(a: Vector2, b: Vector2, half: Vector2) -> float:
	var corners := [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]
	if _point_box_distance(a, half) <= 0.0 or _point_box_distance(b, half) <= 0.0:
		return 0.0
	var nearest := minf(_point_box_distance(a, half), _point_box_distance(b, half))
	for i in 4:
		if Geometry2D.segment_intersects_segment(a, b, corners[i], corners[(i + 1) % 4]) != null:
			return 0.0
		nearest = minf(nearest, Geometry2D.get_closest_point_to_segment(corners[i], a, b).distance_to(corners[i]))
	return nearest
