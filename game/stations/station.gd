extends Node3D
## Phase 2 Stage 3 station (static; root of `station.tscn`). Its body and arm meshes
## are in the `static_obstacle` group, so StaticNavigation and PlanarCollision read
## them as boxes; the docking heads are visual only. It owns:
## - its berths (Phase 2.5 stage 2b): one Berth child per docking slot (in scene
##   order; BerthEast = slot 0, BerthWest = slot 1 on the exposed-arm station),
##   shared by every ship class. The Berth nodes are the only source of docking
##   positions, headings and maneuver points (parking rectangle, parking pose,
##   handover point, entry and exit legs);
## - three separate states per berth: the reservation (`slots[i].ship`, `leaving`),
##   physical occupancy (berth_occupants(): collision circles overlapping the
##   rectangle) and corridor clearance (corridor_clear());
## - a first-in-first-out queue (one entry per ship) and holding positions (Hold*
##   markers). A berth is granted only to the first queued ship allowed there, and
##   only while it is unreserved, its rectangle is empty and that ship's corridor is
##   clear; nobody skips ahead. A leaving ship keeps its reservation until its whole
##   collision circle is outside the rectangle;
## - the guided-maneuver limits (capped by each ship's own in Locomotion), and the
##   ships leaving under station control (their remaining exit paths are the corridor
##   test);
## - its storage Inventory and transfer rate;
## - (Stage 4) a separate fuel stock, one abstract resource with no production,
##   taken by docked ships' Fuel nodes at `refuel_rate`.
## It never orders or moves ships; each ship's Docking node requests, steers its
## maneuvers through Locomotion and releases. `show_berths` draws the berths (debug).

const Inventory := preload("res://game/cargo/inventory.gd")
const Berth := preload("res://game/stations/berth.gd")
const DisplayName := preload("res://game/ui/display_name.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const BERTH_FREE := Color(0.95, 0.85, 0.2)
const BERTH_RESERVED := Color(0.95, 0.55, 0.15)
const BERTH_OCCUPIED := Color(0.9, 0.2, 0.15)
const EXIT_PATH := Color(0.3, 0.8, 0.95)
const GROUP := &"station" # Every station (set in station.tscn); how miners find their bases.

@export var storage_capacity := 5000 # Abstract units (provisional).
@export var transfer_rate := 50.0 # Units per second (provisional).
@export var fuel_capacity := 2000.0 # Fuel units (provisional).
@export var fuel_stock := 1000.0 # Fuel units at start (provisional); only docked ships change it.
@export var refuel_rate := 20.0 # Fuel units per second to each docked ship (provisional).
@export var guide_speed := 1.5 # u/s, guided entry and exit (capped by each ship's own limits).
@export var guide_accel := 1.0 # u/s²
@export var guide_turn_rate_deg := 30.0 # °/s
@export var guide_turn_accel_deg := 30.0 # °/s²
@export var corridor_margin := 1.0 # u kept between footprints along a waiting ship's route and remaining exit paths.
@export var show_berths := false # Debug: draw the berths (yellow free, orange reserved, red occupied) and exit paths.
@export var berth_ships_path := NodePath("../../Ships") # Ships considered for occupancy and exit sides.
@export var navigation_path := NodePath("../../StaticNavigation")

var storage := Inventory.new()
var berths: Array[Berth] = [] # Berth children in scene order (slot i = berths[i]).
var slots: Array[Dictionary] = [] # {end, axis, ship (or null), leaving}; from the berths.
var queue: Array[Dictionary] = [] # {ship, allowed: slot indices}, first in first out
var holds: Array[Dictionary] = [] # {point, ship (or null)}
var _exiting: Array[Node3D] = [] # Ships leaving this station under station control.
var _berth_lines: MeshInstance3D = null # Debug drawing, only with show_berths.

@onready var _navigation := get_node_or_null(navigation_path) as StaticNavigation


func _ready() -> void:
	process_physics_priority = 2 # After the ships' Docking nodes (1).
	storage.capacity = storage_capacity
	fuel_stock = clampf(fuel_stock, 0.0, fuel_capacity)
	var markers: Array[Node3D] = []
	for child in get_children():
		if child is Berth:
			berths.append(child)
			slots.append({"end": _planar((child as Node3D).global_position), "axis": (child as Berth).axis(), "ship": null, "leaving": false})
		elif child is Marker3D and String(child.name).begins_with("Hold"):
			markers.append(child)
	markers.sort_custom(func(a: Node3D, b: Node3D) -> bool: return String(a.name).naturalnocasecmp_to(String(b.name)) < 0)
	for marker in markers:
		holds.append({"point": _planar(marker.global_position), "ship": null})
	if show_berths:
		_berth_lines = MeshInstance3D.new()
		_berth_lines.top_level = true
		_berth_lines.mesh = ImmediateMesh.new()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		_berth_lines.material_override = material
		add_child(_berth_lines)


## Ships whose collision circle overlaps the berth's parking rectangle (physical
## occupancy; independent of reservations).
func berth_occupants(index: int) -> Array[Node3D]:
	var found: Array[Node3D] = []
	var ships := get_node_or_null(berth_ships_path)
	if ships == null:
		return found
	for ship: Node in ships.get_children():
		var follower := ship.get_node_or_null("RouteFollower")
		if follower != null and berths[index].overlaps(_planar((ship as Node3D).global_position), follower.ship_radius):
			found.append(ship)
	return found


## A berth for a ship (only among `allowed`), or -1 when it has to wait: then it is
## queued once. A ship that already holds a berth keeps it. The ship at the front
## gets the available berth whose handover point is nearest.
func request(ship: Node3D, allowed: Array) -> int:
	var own := slot_of(ship)
	if own >= 0:
		return own
	if queue.is_empty() or queue[0].ship == ship:
		var radius := _radius(ship)
		var best := -1
		for i: int in allowed:
			if _available(i, ship) and (best < 0 or _closer(ship, berths[i].handover_point(radius), berths[best].handover_point(radius))):
				best = i
		if best >= 0:
			_dequeue(ship)
			slots[best].ship = ship
			return best
	if queue_position(ship) < 0:
		queue.append({"ship": ship, "allowed": allowed})
	return -1


func slot_of(ship: Node3D) -> int:
	for i in slots.size():
		if slots[i].ship == ship and not slots[i].leaving:
			return i
	return -1


func queue_position(ship: Node3D) -> int:
	for i in queue.size():
		if queue[i].ship == ship:
			return i
	return -1


## The ship leaves (undock, blocked transfer, a released request): out of the queue
## and its holding position; its reservation ends once its collision circle is
## outside the rectangle.
func depart(ship: Node3D) -> void:
	for slot in slots:
		if slot.ship == ship:
			slot.leaving = true
	_dequeue(ship)
	release_hold(ship)


## The ship gives up a berth it never approached (unreachable): released at once.
func withdraw(ship: Node3D) -> void:
	for slot in slots:
		if slot.ship == ship:
			slot.ship = null
			slot.leaving = false
	_dequeue(ship)


## Exit sides (+1 ExitA, -1 ExitB) whose back-out and departure legs are clear of
## static obstacles for this hull; a side not listed is never used.
func exit_sides(index: int, ship_radius: float) -> Array[int]:
	var sides: Array[int] = []
	for side: int in [1, -1]:
		var legs := berths[index].exit_legs(ship_radius, side)
		var park := berths[index].park_point(ship_radius)
		if _navigation == null or (_navigation.segment_clear(park, legs[0].move, ship_radius) and _navigation.segment_clear(legs[0].move, legs[2].move, ship_radius)):
			sides.append(side)
	return sides


## The valid exit side for a leaving ship whose departure leg keeps the larger
## footprint gap from the route of the first ship waiting for this berth and from
## every other ship (where it is and where it is heading); +1 on a tie; 0 if none.
func choose_exit_side(index: int, ship: Node3D) -> int:
	var radius := _radius(ship)
	var waiting := _first_waiting(index)
	var best := 0
	var best_gap := -INF
	for side: int in exit_sides(index, radius):
		var legs := berths[index].exit_legs(radius, side)
		var leg := PackedVector2Array([legs[0].move, legs[2].move])
		var gap := 1000.0
		if waiting != null:
			var route := corridor(index, waiting)
			route.resize(route.size() - 1) # Up to the handover point (the berth's own lane is the rectangle's).
			gap = minf(gap, _polyline_distance(leg, route) - radius - _radius(waiting))
		var ships := get_node_or_null(berth_ships_path)
		if ships != null:
			for other: Node in ships.get_children():
				if other == ship or other == waiting or other.get_node_or_null("Locomotion") == null:
					continue
				var locomotion: Node = other.get_node("Locomotion")
				var spots := PackedVector2Array([locomotion.planar_position])
				if locomotion.has_destination:
					spots.append(locomotion.destination)
				for spot: Vector2 in spots:
					gap = minf(gap, Geometry2D.get_closest_point_to_segment(spot, leg[0], leg[1]).distance_to(spot) - radius - _radius(other))
		if gap > best_gap + 0.001:
			best_gap = gap
			best = side
	return best


func begin_exit(ship: Node3D) -> void:
	if not _exiting.has(ship):
		_exiting.append(ship)


func end_exit(ship: Node3D) -> void:
	_exiting.erase(ship)


## Expected route of a ship to a berth: its position, the planned route to the
## handover point, the parking point.
func corridor(index: int, ship: Node3D) -> PackedVector2Array:
	var radius := _radius(ship)
	var from := _planar(ship.global_position)
	var handover := berths[index].handover_point(radius)
	var route := PackedVector2Array()
	if _navigation != null:
		route = _navigation.plan(ship.get_node("RouteFollower").planning_radius(), from, handover)
	if route.is_empty():
		route = PackedVector2Array([from, handover])
	route.append(berths[index].park_point(radius))
	return route


## The ship's expected route to the berth keeps the corridor margin from every ship
## still flying its exit from this station under station control.
func corridor_clear(index: int, ship: Node3D) -> bool:
	var path := corridor(index, ship)
	for other: Node3D in _exiting:
		if other == ship:
			continue
		var remaining: PackedVector2Array = other.get_node("Locomotion").remaining_points()
		if remaining.size() == 1:
			remaining.append(remaining[0])
		if _polyline_distance(path, remaining) - _radius(ship) - _radius(other) < corridor_margin:
			return false
	return true


func hold_of(ship: Node3D) -> int:
	for i in holds.size():
		if holds[i].ship == ship:
			return i
	return -1


func reserve_hold(ship: Node3D, index: int) -> void:
	release_hold(ship)
	holds[index].ship = ship


func release_hold(ship: Node3D) -> void:
	for hold in holds:
		if hold.ship == ship:
			hold.ship = null


func _physics_process(_delta: float) -> void:
	for i in slots.size():
		var slot: Dictionary = slots[i]
		if slot.ship != null and slot.leaving and not berths[i].overlaps(_planar((slot.ship as Node3D).global_position), _radius(slot.ship)):
			slot.ship = null
			slot.leaving = false
	for i in slots.size():
		if slots[i].ship != null:
			continue
		for entry: Dictionary in queue:
			if entry.allowed.has(i):
				# First in, first out: the first ship allowed here waits until it can enter.
				if _available(i, entry.ship):
					slots[i].ship = entry.ship
					queue.erase(entry)
				break


func _process(_delta: float) -> void:
	if _berth_lines == null:
		return
	var mesh := _berth_lines.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in berths.size():
		var color := BERTH_FREE
		if not berth_occupants(i).is_empty():
			color = BERTH_OCCUPIED
		elif slots[i].ship != null:
			color = BERTH_RESERVED
		var corners := berths[i].corners()
		for k in 4:
			_line(mesh, corners[k], corners[(k + 1) % 4], color)
	for ship: Node3D in _exiting:
		var points: PackedVector2Array = ship.get_node("Locomotion").remaining_points()
		for k in points.size() - 1:
			_line(mesh, points[k], points[k + 1], EXIT_PATH)
	mesh.surface_end()


## Distance along a camera ray to the station's meshes (body, arms, heads), or INF.
func pick(origin: Vector3, direction: Vector3) -> float:
	var to_station := global_transform.affine_inverse()
	var local_origin := to_station * origin
	var local_direction := to_station.basis * direction
	var best := INF
	for part: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		if part == _berth_lines:
			continue # Debug drawing, not part of the station.
		var box: AABB = (to_station * part.global_transform) * part.get_aabb()
		var hit: Variant = box.intersects_ray(local_origin, local_direction)
		if hit != null:
			best = minf(best, local_origin.distance_to(hit))
	return best


## Hover text: storage by resource, fuel stock and docking use.
func describe() -> String:
	var lines: Array[String] = [DisplayName.of(self), "Fuel: %d / %d" % [floori(fuel_stock), roundi(fuel_capacity)],
		"Storage: %d / %d" % [storage.quantity(), storage.capacity]]
	for resource in Inventory.RESOURCES:
		if storage.quantity_of(resource) > 0:
			lines.append("%s %d" % [Inventory.display_name(resource), storage.quantity_of(resource)])
	var used := slots.filter(func(slot: Dictionary) -> bool: return slot.ship != null).size()
	lines.append("Docks in use: %d / %d, waiting: %d" % [used, slots.size(), queue.size()])
	return "\n".join(lines)


# Unreserved, physically empty, and the ship's corridor clear of every exit in progress.
func _available(index: int, ship: Node3D) -> bool:
	return slots[index].ship == null and berth_occupants(index).is_empty() and corridor_clear(index, ship)


func _first_waiting(index: int) -> Node3D:
	for entry: Dictionary in queue:
		if entry.allowed.has(index):
			return entry.ship
	return null


func _line(mesh: ImmediateMesh, a: Vector2, b: Vector2, color: Color) -> void:
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(Vector3(a.x, 0.05, a.y))
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(Vector3(b.x, 0.05, b.y))


func _dequeue(ship: Node3D) -> void:
	for entry: Dictionary in queue.duplicate():
		if entry.ship == ship:
			queue.erase(entry)


static func _radius(ship: Node) -> float:
	return ship.get_node("RouteFollower").ship_radius


static func _polyline_distance(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var best := INF
	for i in a.size() - 1:
		for j in b.size() - 1:
			var points := Geometry2D.get_closest_points_between_segments(a[i], a[i + 1], b[j], b[j + 1])
			best = minf(best, points[0].distance_to(points[1]))
	return best


static func _closer(ship: Node3D, a: Vector2, b: Vector2) -> bool:
	var at := _planar(ship.global_position)
	return at.distance_to(a) < at.distance_to(b)


static func _planar(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)
