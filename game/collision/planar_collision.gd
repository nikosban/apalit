extends Node
## Stage 6 collision enforcement prototype: a read-only service on the X/Z plane.
## Locomotion asks it, at its _apply_motion() boundary, how much of a proposed
## displacement its ship may make; it never changes any ship's state.
##
## Shapes: every ship's bounding circle (RouteFollower.ship_radius, without the
## navigation or avoidance margins) at its current committed position (ships that
## already moved this tick are at their new positions: sequential, scene order);
## static obstacles read once from the Obstacles meshes and the `static_obstacle`
## group (cylinders and spheres:
## circles, boxes: rotated rectangles, same transforms and radii as StaticNavigation);
## the sector edge: four static rectangles just outside StaticNavigation.map_half_size
## (a footprint stops with its centre at map_half_size - radius and slides along it).
##
## resolve(): objects already within `contact_skin` (touching or overlapping) are
## constraints from the start: the motion and velocity lose their components into
## them (a convex shape is then never approached, so an overlap never deepens; it is
## never pushed apart either). The rest of the motion is swept continuously: up to
## the earliest contact (backed off by half the skin), then the velocity and the remaining
## motion lose their components into it and the remainder is tried again, at most
## MAX_CONTACTS times per tick (then the rest is dropped and the limit recorded).
## Components are only removed, never added: no bounce, no push, no new speed.

const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const MAX_CONTACTS := 3
const EPSILON := 0.000001

@export var contact_skin := 0.01 # u; gap counted as touching; a stop at a contact keeps half of it (provisional).
@export var ships_path := NodePath("../Ships")
@export var obstacles_path := NodePath("../Obstacles")
@export var navigation_path := NodePath("../StaticNavigation") # Sector size (map_half_size).

# Static obstacles: {node, circle: bool, center, radius | half, x_axis, bounds}.
var _obstacles: Array[Dictionary] = []
# Sector edge, same box form; blockers are the SectorEdge* children (contact bookkeeping).
var _edges: Array[Dictionary] = []

@onready var _ships := get_node(ships_path)


func _ready() -> void:
	for child in get_node(obstacles_path).get_children() + get_tree().get_nodes_in_group(StaticNavigation.OBSTACLE_GROUP):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null:
			continue
		var basis := mesh_instance.global_basis
		var center := Vector2(mesh_instance.global_position.x, mesh_instance.global_position.z)
		var x_axis := Vector2(basis.x.x, basis.x.z)
		var scale := x_axis.length()
		x_axis /= scale
		if mesh_instance.mesh is CylinderMesh or mesh_instance.mesh is SphereMesh:
			var radius := StaticNavigation.round_radius(mesh_instance.mesh) * scale
			_obstacles.append({"node": mesh_instance, "circle": true, "center": center, "radius": radius,
				"bounds": Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)})
		elif mesh_instance.mesh is BoxMesh:
			var size := (mesh_instance.mesh as BoxMesh).size
			var half := Vector2(size.x, size.z) * 0.5 * scale
			var reach := Vector2(absf(x_axis.x) * half.x + absf(x_axis.y) * half.y, absf(x_axis.y) * half.x + absf(x_axis.x) * half.y)
			_obstacles.append({"node": mesh_instance, "circle": false, "center": center, "half": half, "x_axis": x_axis,
				"bounds": Rect2(center - reach, reach * 2.0)})
	_add_edges((get_node(navigation_path) as StaticNavigation).map_half_size)


# Each edge: inner side on the sector line, a sector width thick (a centre found beyond
# the line, by placement, is still nearest the inner side, so it may only move back in),
# long enough to close the corners.
func _add_edges(h: float) -> void:
	for side: Array in [["East", Vector2.RIGHT], ["West", Vector2.LEFT], ["South", Vector2.DOWN], ["North", Vector2.UP]]:
		var edge := Node.new()
		edge.name = "SectorEdge" + side[0]
		add_child(edge)
		var outward: Vector2 = side[1]
		var center := outward * 2.0 * h
		var half := Vector2(h, 3.0 * h) if outward.x != 0.0 else Vector2(3.0 * h, h)
		_edges.append({"node": edge, "circle": false, "center": center, "half": half, "x_axis": Vector2.RIGHT,
			"bounds": Rect2(center - half, half * 2.0)})


## Collision radius of a ship (its bounding circle).
static func radius_of(ship: Node) -> float:
	return ship.get_node("RouteFollower").ship_radius


## Permitted part of `ship`'s proposed `motion` from `from` this tick, with `velocity`
## constrained the same way. Returns {motion, velocity, contacts: [{blocker, normal,
## point, gap, swept}], exhausted, overlap}. `swept` = found by the sweep this tick
## (false: already within the skin or overlapping at the start); normals point from
## the blocker toward the ship.
func resolve(ship: Node, from: Vector2, motion: Vector2, velocity: Vector2) -> Dictionary:
	var radius := radius_of(ship)
	var result := {"motion": motion, "velocity": velocity, "contacts": [], "exhausted": false, "overlap": false}
	var blockers := _nearby(ship, from, motion, radius)
	if blockers.is_empty():
		return result
	var normals: Array[Vector2] = []
	var engaged := {}
	for i in blockers.size():
		var contact := _contact(blockers[i], from, radius)
		if contact.gap < contact_skin:
			engaged[i] = true
			normals.append(contact.normal)
			contact.swept = false
			result.contacts.append(contact)
			result.overlap = result.overlap or contact.gap < 0.0
	var remaining := _constrain(motion, normals)
	var constrained := _constrain(velocity, normals)
	var moved := Vector2.ZERO
	var resolutions := 0
	while remaining.length_squared() > EPSILON * EPSILON:
		var hit := INF
		var hit_index := -1
		for i in blockers.size():
			if not engaged.has(i):
				var t := _sweep(blockers[i], from + moved, remaining, radius)
				if t < hit:
					hit = t
					hit_index = i
		if hit_index < 0:
			moved += remaining
			break
		if resolutions == MAX_CONTACTS:
			result.exhausted = true
			break
		resolutions += 1
		# Half the skin short of contact: inside the touching band, so the next tick
		# starts engaged instead of creeping up to the skin boundary.
		var stop := maxf(0.0, hit - 0.5 * contact_skin / remaining.length())
		moved += remaining * stop
		engaged[hit_index] = true
		var contact := _contact(blockers[hit_index], from + moved, radius)
		contact.swept = true
		result.contacts.append(contact)
		normals.append(contact.normal)
		remaining = _constrain(remaining * (1.0 - stop), normals)
		constrained = _constrain(constrained, normals)
	result.motion = moved
	result.velocity = constrained
	return result


# Ships and obstacles whose shape the swept circle (plus the skin) can reach this tick.
func _nearby(ship: Node, from: Vector2, motion: Vector2, radius: float) -> Array:
	var swept := Rect2(from, Vector2.ZERO).expand(from + motion).grow(radius + contact_skin)
	var nearby := []
	for other: Node in _ships.get_children():
		var locomotion := other.get_node_or_null("Locomotion")
		if other == ship or locomotion == null:
			continue
		var other_radius := radius_of(other)
		var center: Vector2 = locomotion.planar_position
		if swept.intersects(Rect2(center - Vector2(other_radius, other_radius), Vector2(other_radius, other_radius) * 2.0)):
			nearby.append({"node": other, "circle": true, "center": center, "radius": other_radius})
	for obstacle in _obstacles + _edges:
		if swept.intersects(obstacle.bounds):
			nearby.append(obstacle)
	return nearby


# Removes the components into each contact normal (never adds any); zero if the
# constraints oppose each other (wedged).
static func _constrain(vector: Vector2, normals: Array[Vector2]) -> Vector2:
	for normal in normals:
		var into := vector.dot(normal)
		if into < 0.0:
			vector -= normal * into
	for normal in normals:
		if vector.dot(normal) < -EPSILON:
			return Vector2.ZERO
	return vector


# Gap between the ship's circle at `at` and the shape (negative: overlap), the normal
# from the shape toward the ship and the shape's nearest point.
static func _contact(shape: Dictionary, at: Vector2, radius: float) -> Dictionary:
	var normal := Vector2.RIGHT
	var distance := 0.0
	var point := at
	if shape.circle:
		var offset: Vector2 = at - shape.center
		distance = offset.length()
		if distance > EPSILON:
			normal = offset / distance
		distance -= shape.radius
		point = shape.center + normal * shape.radius
	else:
		var x_axis: Vector2 = shape.x_axis
		var z_axis := Vector2(-x_axis.y, x_axis.x)
		var offset: Vector2 = at - shape.center
		var local := Vector2(offset.dot(x_axis), offset.dot(z_axis))
		var half: Vector2 = shape.half
		var nearest := local.clamp(-half, half)
		var local_normal := Vector2.RIGHT
		if nearest == local:
			# Centre inside the rectangle: the nearest side.
			var room := half - local.abs()
			if room.x < room.y:
				local_normal = Vector2(signf(local.x) if local.x != 0.0 else 1.0, 0.0)
				distance = -room.x
				nearest = Vector2(half.x * local_normal.x, local.y)
			else:
				local_normal = Vector2(0.0, signf(local.y) if local.y != 0.0 else 1.0)
				distance = -room.y
				nearest = Vector2(local.x, half.y * local_normal.y)
		else:
			distance = (local - nearest).length()
			local_normal = (local - nearest) / distance
		normal = x_axis * local_normal.x + z_axis * local_normal.y
		point = shape.center + x_axis * nearest.x + z_axis * nearest.y
	return {"blocker": shape.node, "normal": normal, "point": point, "gap": distance - radius}


# First fraction t in [0, 1] at which the circle moving from p by m touches the shape
# (INF if it does not); the circle starts clear of it.
static func _sweep(shape: Dictionary, p: Vector2, m: Vector2, radius: float) -> float:
	if shape.circle:
		return _circle_entry(p - shape.center, m, shape.radius + radius)
	var x_axis: Vector2 = shape.x_axis
	var z_axis := Vector2(-x_axis.y, x_axis.x)
	var offset: Vector2 = p - shape.center
	var local := Vector2(offset.dot(x_axis), offset.dot(z_axis))
	var local_motion := Vector2(m.dot(x_axis), m.dot(z_axis))
	var half: Vector2 = shape.half
	# Rectangle grown by the radius = two crossing slabs plus four corner circles.
	var t := minf(_box_entry(local, local_motion, Vector2(half.x + radius, half.y)),
		_box_entry(local, local_motion, Vector2(half.x, half.y + radius)))
	for corner: Vector2 in [half, Vector2(-half.x, half.y), -half, Vector2(half.x, -half.y)]:
		t = minf(t, _circle_entry(local - corner, local_motion, radius))
	return t


# First t in [0, 1] with |p + mÂ·t| <= distance (p outside), else INF.
static func _circle_entry(p: Vector2, m: Vector2, distance: float) -> float:
	var a := m.length_squared()
	var b := p.dot(m)
	var c := p.length_squared() - distance * distance
	if c <= 0.0:
		return 0.0
	if a < EPSILON * EPSILON or b >= 0.0:
		return INF
	var disc := b * b - a * c
	if disc < 0.0:
		return INF
	var t := (-b - sqrt(disc)) / a
	return t if t <= 1.0 else INF


# First t in [0, 1] at which p + mÂ·t enters the axis-aligned box [-half, half]
# (p outside), else INF.
static func _box_entry(p: Vector2, m: Vector2, half: Vector2) -> float:
	var enter := 0.0
	var leave := 1.0
	for axis in 2:
		if absf(m[axis]) < EPSILON:
			if absf(p[axis]) > half[axis]:
				return INF
			continue
		var t1: float = (-half[axis] - p[axis]) / m[axis]
		var t2: float = (half[axis] - p[axis]) / m[axis]
		enter = maxf(enter, minf(t1, t2))
		leave = minf(leave, maxf(t1, t2))
		if enter > leave:
			return INF
	return enter
