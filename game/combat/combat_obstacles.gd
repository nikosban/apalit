extends RefCounted
## Production-world obstacles for combat beyond the asteroid spheres: the station meshes
## (the `static_obstacle` group, the same set StaticNavigation and PlanarCollision read).
## Physical projectile and ordnance obstruction, weapon line of fire and Behavior's firing
## positions use them; sensors do not (asteroid occlusion only, unchanged). A station takes
## damage only when it has a compatible hull component (hull_of(): a child with
## `take_hit(amount, projectile_id)`); the production stations have none, so they stop
## shots without damage.

const GROUP := &"static_obstacle"
const STATION_GROUP := &"station"


## First obstacle part the segment from -> to enters: {fraction (0-1), part, station (or
## null)}, or {} when the segment is clear.
static func first_hit(tree: SceneTree, from: Vector3, to: Vector3) -> Dictionary:
	var best := {}
	var best_fraction := INF
	for node in tree.get_nodes_in_group(GROUP):
		var part := node as MeshInstance3D
		if part == null or part.mesh == null or not part.is_inside_tree():
			continue
		var fraction := _segment_fraction(part, from, to)
		if fraction >= 0.0 and fraction < best_fraction:
			best_fraction = fraction
			best = {"fraction": fraction, "part": part, "station": station_of(part)}
	return best


## Whether the segment crosses any obstacle part.
static func blocked(tree: SceneTree, from: Vector3, to: Vector3) -> bool:
	return not first_hit(tree, from, to).is_empty()


## Planar footprint test: whether a circle of `radius` at `point` (on the plane at height
## `y`) stays clear of every obstacle part.
static func footprint_clear(tree: SceneTree, point: Vector2, y: float, radius: float) -> bool:
	var at := Vector3(point.x, y, point.y)
	for node in tree.get_nodes_in_group(GROUP):
		var part := node as MeshInstance3D
		if part == null or part.mesh == null or not part.is_inside_tree():
			continue
		var local := part.global_transform.affine_inverse() * at
		var box := part.get_aabb()
		var closest := local.clamp(box.position, box.end)
		if (part.global_transform * closest).distance_to(at) < radius:
			return false
	return true


## The station a part belongs to (an ancestor in the `station` group), or null.
static func station_of(part: Node) -> Node3D:
	var node := part.get_parent()
	while node != null:
		if node.is_in_group(STATION_GROUP):
			return node as Node3D
		node = node.get_parent()
	return null


## A station's compatible hull component (a child with take_hit()), or null.
static func hull_of(station: Node) -> Node:
	if station == null:
		return null
	for child in station.get_children():
		if child.has_method("take_hit"):
			return child
	return null


# Fraction along from -> to where the segment first enters the part's box (in its own
# frame, so rotation and scale are exact), or -1.
static func _segment_fraction(part: MeshInstance3D, from: Vector3, to: Vector3) -> float:
	var inverse := part.global_transform.affine_inverse()
	var a := inverse * from
	var b := inverse * to
	var box := part.get_aabb()
	if box.has_point(a):
		return 0.0
	var hit: Variant = box.intersects_segment(a, b)
	if hit == null:
		return -1.0
	var length := a.distance_to(b)
	return 0.0 if length <= 0.0 else a.distance_to(hit) / length
