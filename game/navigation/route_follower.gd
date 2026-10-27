extends Node
## Stage 3 route following for its ship: one route per command, continuous
## lookahead along it, and a route speed profile planned once per order (slow
## down before difficult turns, "wheel-over" style), fed to the ship's Locomotion
## through steer() every physics tick (before Locomotion steps). Never moves the
## ship itself; no recovery or cross-track correction, and no replanning except
## replan() after an avoidance pass that left the ship far off its path.

enum RouteStatus { NONE, WAITING, DIRECT, ROUTE, NO_ROUTE } # NO_ROUTE: no longer set (Phase 2.5: a refused order changes nothing).

const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const SEARCH_STEPS := 8 # Bisection steps for the farthest clear point on a blocked segment.
const START_TOLERANCE := 0.01 # u; a route starting farther from the ship was snapped onto the map.
const AIM_CATCH_UP := 2.0 # Stage 6B.2: the aim anchor gains at most this x speed (+ 1 u/s) on the progress per second.

signal notice(text: String)

@export var ship_radius := 1.6 # Bounding-circle radius of the hull (u).
@export var clearance_margin := 1.0 # Provisional extra planning clearance (u).
@export var lookahead_reserve := 0.5 # Share of the margin the lookahead line keeps clear (provisional).
@export var turn_brake_share := 0.65 # Share of reverse acceleration used by the route speed profile (provisional).
@export var maneuver_window_factor := 2.0 # A turn's maneuvering distance is at most this × planning radius (provisional).
@export var navigation_path := NodePath("../../../StaticNavigation")

var status := RouteStatus.NONE
var route := PackedVector2Array() # Planned route; the last point is the resolved destination.
var requested := Vector2.ZERO # The point the player clicked.
var segment := 0 # Current route segment: route[segment] -> route[segment + 1].
var aim_point := Vector2.ZERO
var lookahead := 0.0
var remaining := 0.0 # Route length still to fly (ship -> aim -> rest of route).
var progress := 0.0 # Route distance of the ship's progress point.
var aim_progress := 0.0 # Stage 6B.2: route distance the lookahead is measured from (progress without its jumps).
var speed_cap := INF # Route speed cap of the last step (u/s).
# Speed restrictions planned with the route, in route order: x = route distance where
# the maneuvering window starts, y = where it ends, z = speed for that window. The
# last one is the destination (speed 0).
var restrictions := PackedVector3Array()
var plans := 0 # Route calculations made (one per executed command).
var replans := 0 # Re-plans of the current order after a pass (replan(); not counted in plans).
var last_step_usec := 0 # Cost of the last route-following step (diagnostics).
var guided_refusals := 0 # Orders refused during guided movement (Phase 2.5; should stay 0).
# Stage 6B.2: route index of each fly-through point joined into this route (queued
# Waypoints before the last), in order. Empty for an ordinary single-destination order.
var waypoint_marks := PackedInt32Array()

var _pending := false
var _pending_through := PackedVector2Array()
var _turn_next := false # Stage 6B.2: the next planned order may turn its course (see _start()).
var _before_queue := [RouteStatus.NONE, Vector2.ZERO] # [status, requested] before the first queued order.
var _aim_segment := 0
var _aim_fresh := true # Stage 6B.2: the next step starts the aim anchor at the progress.
var _next_restriction := 0
var _length_after := PackedFloat32Array() # Route length from route[i] to the end.

@onready var _locomotion := get_parent().get_node("Locomotion") as ShipLocomotion
@onready var _navigation := get_node(navigation_path) as StaticNavigation
@onready var _avoidance: Node = get_parent().get_node_or_null("Avoidance") # Optional; read only (its last offset).


func _ready() -> void:
	process_physics_priority = -1 # Before Locomotion, which steps at priority 0.
	_navigation.add_radius(planning_radius())


func planning_radius() -> float:
	return ship_radius + clearance_margin


## Player order. Returns whether it was taken: planned now, or queued (not dropped)
## while the navigation map is not ready yet. Without a route it is refused with a
## notice and nothing changes: the current order, if any, goes on as before (a
## queued order that finds no route restores the state from before it was queued).
## Stage 6B.2: `through` (queued Waypoints after `point`) joins further legs, each
## planned from the end of the one before, while they have a route; `point` and every
## joined point but the last are flown through as route corners (waypoint_marks), and
## the last joined point is the destination. Only the first leg decides acceptance.
func order(point: Vector2, through := PackedVector2Array(), turn_course := false) -> bool:
	_turn_next = turn_course
	if _locomotion.guided:
		# Phase 2.5: the station is moving the ship; commands are held until control
		# ends, so nothing legitimate arrives here. Refused, nothing changes.
		guided_refusals += 1
		notice.emit("Order refused during station control")
		return false
	if not _navigation.is_ready(planning_radius()):
		if not _pending:
			_before_queue = [status, requested]
		requested = point
		_pending = true
		_pending_through = through
		status = RouteStatus.WAITING
		notice.emit("Navigation map not ready - order queued")
		return true
	return _plan(point, through)


## Phase 2.5: drops the route, any queued order and the status when the station
## takes over the ship (handover, controlled exit); nothing else changes.
func clear() -> void:
	status = RouteStatus.NONE
	route = PackedVector2Array()
	_pending = false
	speed_cap = INF
	restrictions.clear()
	waypoint_marks.clear()


## Stage 6B.2: fly-through points of this route not passed yet (the route has advanced
## beyond a point once its segment starts at or after it).
func waypoints_left() -> int:
	var left := 0
	for mark in waypoint_marks:
		left += int(segment < mark)
	return left


func _physics_process(delta: float) -> void:
	if _pending and _navigation.is_ready(planning_radius()):
		_plan(requested, _pending_through)
	if status == RouteStatus.DIRECT and _locomotion.has_destination:
		_update_direct_aim()
		return
	if status != RouteStatus.ROUTE or not _locomotion.has_destination:
		return
	var start_usec := Time.get_ticks_usec()
	var position := _locomotion.planar_position
	_advance(position)
	var from := Geometry2D.get_closest_point_to_segment(position, route[segment], route[segment + 1])
	progress = _length_after[0] - _length_after[segment] + route[segment].distance_to(from)
	lookahead = lookahead_length()
	# Stage 6B.2: the closest point jumps forward when the segment advances (across the
	# corner's bisector, from one leg to the next), which moved the aim abruptly. The
	# aim's anchor follows progress but gains at most AIM_CATCH_UP x speed (+ 1 u/s)
	# per second, so the lookahead slides around the corner instead.
	var gain := (AIM_CATCH_UP * _locomotion.velocity.length() + 1.0) * delta
	aim_progress = progress if _aim_fresh else minf(progress, aim_progress + gain)
	_aim_fresh = false
	aim_point = _find_aim(position, aim_progress)
	remaining = position.distance_to(aim_point) + aim_point.distance_to(route[_aim_segment + 1]) + _length_after[_aim_segment + 1]
	speed_cap = _route_speed_cap()
	_locomotion.steer(aim_point, remaining, speed_cap)
	last_step_usec = Time.get_ticks_usec() - start_usec


## Lookahead length for the current speed: max(ship radius, stopping distance).
func lookahead_length() -> float:
	var speed := _locomotion.velocity.length()
	return maxf(ship_radius, speed * speed / (2.0 * ShipLocomotion.BRAKE_MARGIN * _locomotion.reverse_accel))


## Clearance a straight steering line keeps: the ship radius plus the reserved share of the margin.
func line_clearance() -> float:
	return ship_radius + lookahead_reserve * clearance_margin


# Direct move (Stage 4, for avoidance only): the aim point at the lookahead length
# along the single leg. Locomotion still flies the plain move; nothing is steered.
func _update_direct_aim() -> void:
	var position := _locomotion.planar_position
	var from := Geometry2D.get_closest_point_to_segment(position, route[0], route[1])
	lookahead = lookahead_length()
	var left := from.distance_to(route[1])
	aim_point = route[1] if left <= lookahead else from + (route[1] - from) / left * lookahead


## Ship footprint (bounding circle) clearance from the nearest obstacle surface.
func footprint_clearance() -> float:
	return _navigation.surface_distance(_locomotion.planar_position) - ship_radius


## Ship footprint (bounding circle) clearance from the nearest sector edge.
func edge_clearance() -> float:
	var position := _locomotion.planar_position
	return _navigation.map_half_size - ship_radius - maxf(absf(position.x), absf(position.y))


func distance_off_route() -> float:
	if status != RouteStatus.ROUTE:
		return 0.0
	var position := _locomotion.planar_position
	return Geometry2D.get_closest_point_to_segment(position, route[segment], route[segment + 1]).distance_to(position)


# Plans the order; the route and status change only once a route exists.
func _plan(point: Vector2, through := PackedVector2Array()) -> bool:
	var queued := _pending
	_pending = false
	plans += 1
	var position := _locomotion.planar_position
	var planned := _navigation.plan(planning_radius(), position, point)
	if planned.size() < 2:
		if queued:
			status = _before_queue[0]
			requested = _before_queue[1]
		_turn_next = false
		notice.emit("No route found")
		return false
	requested = point
	var marks := PackedInt32Array()
	_start(_chain(planned, through, marks), position, marks)
	return true


# Stage 6B.2: appends a leg to each point of `through` in turn, planned from the end of
# the route so far, until one has no route; every point joined before another becomes
# a fly-through mark (its route index).
func _chain(planned: PackedVector2Array, through: PackedVector2Array, marks: PackedInt32Array) -> PackedVector2Array:
	for point in through:
		var end := planned[planned.size() - 1]
		var leg := _navigation.plan(planning_radius(), end, point)
		if leg.size() < 2:
			break
		marks.append(planned.size() - 1)
		if leg[leg.size() - 1].distance_to(end) > START_TOLERANCE:
			planned.append_array(leg.slice(1))
	return planned


## Group MOVE collision fix step 2: the current order planned again from the ship's
## actual position to the same resolved destination (called by Avoidance when a pass
## ends with the ship far off its path). Not a new order: `requested` and `plans` are
## unchanged (ShipBehavior reads a new plan as a player Move), no notice; without a
## route, or while guided or queued, the current order goes on. Counted in `replans`.
func replan() -> bool:
	if _locomotion.guided or _pending or not _locomotion.has_destination or route.size() < 2 \
			or not (status == RouteStatus.ROUTE or status == RouteStatus.DIRECT):
		return false
	var position := _locomotion.planar_position
	# Stage 6B.2: fly-through points not passed yet stay on the re-planned route.
	var targets := PackedVector2Array()
	for mark in waypoint_marks:
		if segment < mark:
			targets.append(route[mark])
	targets.append(route[route.size() - 1])
	var planned := _navigation.plan(planning_radius(), position, targets[0])
	if planned.size() < 2:
		return false
	var marks := PackedInt32Array()
	planned = _chain(planned, targets.slice(1), marks)
	if marks.size() < targets.size() - 1:
		return false # A fly-through leg lost its route: the current order goes on.
	replans += 1
	_turn_next = false # A re-plan never turns its course.
	_start(planned, position, marks)
	return true


# Takes a planned route from `position`: route state, speed profile, status and the
# Locomotion move.
func _start(planned: PackedVector2Array, position: Vector2, marks := PackedInt32Array()) -> void:
	route = planned
	waypoint_marks = marks
	segment = 0
	_aim_segment = 0
	_aim_fresh = true
	_next_restriction = 0
	speed_cap = INF
	_length_after.resize(route.size())
	_length_after[route.size() - 1] = 0.0
	for i in range(route.size() - 2, -1, -1):
		_length_after[i] = _length_after[i + 1] + route[i].distance_to(route[i + 1])
	_plan_speeds()
	# A single straight leg from the ship is a direct Stage 2 move (no steering).
	var direct := route.size() == 2 and route[0].distance_to(position) <= START_TOLERANCE
	status = RouteStatus.DIRECT if direct else RouteStatus.ROUTE
	# Stage 6B.2: a ship under way on a player Move turns onto a corner-free route only
	# with room for the turn (_course_room()); every other order is redirected at once.
	var turn := _turn_next and route.size() == 2 and _course_room()
	_turn_next = false
	_locomotion.move_to(route[route.size() - 1], direct, turn)


# Route speed profile, once per order. Each corner is flown as an arc spread over a
# maneuvering distance d = min(incoming leg, outgoing leg, window factor × planning
# radius), i.e. a turn radius r = d / angle. Its speed is limited by lateral
# acceleration (v ≤ √(lateral accel · r)) and by turn rate (v ≤ max turn rate · r);
# the lower one applies over the window around the corner. The destination has
# speed 0. Corners the ship can take at full speed are not stored.
func _plan_speeds() -> void:
	restrictions.clear()
	var total := _length_after[0]
	var max_rate := deg_to_rad(_locomotion.max_turn_rate_deg)
	for i in range(1, route.size() - 1):
		var into := route[i] - route[i - 1]
		var out := route[i + 1] - route[i]
		var angle := absf(into.angle_to(out))
		if angle <= ShipLocomotion.EPSILON:
			continue
		var window := minf(minf(into.length(), out.length()), maneuver_window_factor * planning_radius())
		var radius := window / angle
		var turn_speed := minf(sqrt(_locomotion.lateral_accel * radius), max_rate * radius)
		if turn_speed >= _locomotion.max_speed:
			continue
		var at := total - _length_after[i]
		restrictions.append(Vector3(at - window * 0.5, at + window * 0.5, turn_speed))
	restrictions.append(Vector3(total, total, 0.0))


# Bounded speed profile: v_allowed = √(v_turn² + 2 · a_brake · distance to the turn's
# window), a_brake = turn_brake_share × reverse acceleration; held at v_turn inside the
# window. Only restrictions the ship could still need to brake for are read.
# The destination (the last restriction) is at least the ship's straight distance
# away while that line is clear: progress is measured on the route, so a ship pushed
# off it near its end (by avoidance) can have reached the end in progress without
# having arrived, and must not be capped to 0 short of its destination.
func _route_speed_cap() -> float:
	while _next_restriction < restrictions.size() - 1 and restrictions[_next_restriction].y < progress:
		_next_restriction += 1
	var brake := turn_brake_share * _locomotion.reverse_accel
	var cap := INF
	for k in range(_next_restriction, restrictions.size()):
		var restriction := restrictions[k]
		var ahead := maxf(0.0, restriction.x - progress)
		if k == restrictions.size() - 1:
			ahead = _destination_distance(ahead)
		var reach := 2.0 * brake * ahead
		cap = minf(cap, sqrt(restriction.z * restriction.z + reach))
		if reach >= _locomotion.max_speed * _locomotion.max_speed:
			break # Later restrictions are farther away and cannot bind.
	return cap


# Distance to brake for at the destination: the route distance left, or, when longer,
# the ship's straight distance to where it is steered at the destination (the
# destination shifted by avoidance's current offset, so a ship held beside an
# occupied destination settles there instead of overshooting it), provided its line
# to the destination keeps the steering clearance from obstacles.
func _destination_distance(along_route: float) -> float:
	var position := _locomotion.planar_position
	var destination := route[route.size() - 1]
	var shift: Vector2 = _avoidance.offset if _avoidance != null else Vector2.ZERO
	var straight := position.distance_to(destination + shift)
	if straight <= along_route or not _navigation.segment_clear(position, destination, line_clearance()):
		return along_route
	return straight


# Moves to the next segment only once the ship has crossed the boundary between the
# current segment and the next: the line through their shared corner along the
# corner's bisector. Segments further ahead are never considered, one step at a time.
func _advance(position: Vector2) -> void:
	while segment < route.size() - 2:
		var corner := route[segment + 1]
		var into := (corner - route[segment]).normalized()
		var out := (route[segment + 2] - corner).normalized()
		var normal := into + out
		if normal.length() < 0.000001:
			normal = into
		if (position - corner).dot(normal) < 0.0:
			return
		segment += 1


# Farthest route point within the lookahead whose straight line from the ship keeps
# line_clearance() from obstacles. Walks forward from the route distance `start` (the
# aim anchor) and stops at the first blocked point.
func _find_aim(position: Vector2, start: float) -> Vector2:
	var total := _length_after[0]
	var i := segment
	while i > 0 and total - _length_after[i] > start:
		i -= 1
	var from := route[i].move_toward(route[i + 1], start - (total - _length_after[i]))
	var budget := lookahead
	while true:
		var corner := route[i + 1]
		var length := from.distance_to(corner)
		var end := corner if length <= budget else from.lerp(corner, budget / length)
		if not _navigation.segment_clear(position, end, line_clearance()):
			_aim_segment = i
			return _farthest_clear(position, from, end)
		if length >= budget or i + 1 >= route.size() - 1:
			_aim_segment = i
			return end
		budget -= length
		from = corner
		i += 1
	return from # Not reached.


# Bisection between a point taken as reachable (from) and a blocked point (to).
func _farthest_clear(position: Vector2, from: Vector2, to: Vector2) -> Vector2:
	var low := 0.0
	var high := 1.0
	for step in SEARCH_STEPS:
		var middle := (low + high) * 0.5
		if _navigation.segment_clear(position, from.lerp(to, middle), line_clearance()):
			low = middle
		else:
			high = middle
	return from.lerp(to, low)


# Stage 6B.2: room for a course turn: the footprint's clearance from obstacles and from
# the sector edge at least three times the ship's stopping distance (its lookahead; the
# turn's outward excursion stays under it), the route ahead at least twice it.
func _course_room() -> bool:
	var lookahead := lookahead_length()
	return minf(footprint_clearance(), edge_clearance()) >= 3.0 * lookahead and _length_after[0] >= 2.0 * lookahead
