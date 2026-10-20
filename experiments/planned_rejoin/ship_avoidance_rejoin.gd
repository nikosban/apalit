extends Node
## Stage 4 local avoidance prototype for its ship. Every physics tick, after the
## RouteFollower and before Locomotion, it predicts nearby ships with bounded,
## closed-form straight-line prediction and, when this ship gives way, asks
## Locomotion for a temporary steering offset (passing) or speed cap (yielding)
## through avoid(). Never moves the ship, never changes the route, no recovery.
## With no conflict the request is neutral and Stage 3 movement is unchanged.
##
## Encounter = a predicted conflict with one other ship: closest approach of the
## footprints (bounding circles + margin) inside the horizon. Prediction: this ship
## at its preferred speed along its current route segment from its route position
## (stopping at the end of its remaining route), the other ship at its current
## velocity. Roles, side and response are committed per encounter.

enum State { NORMAL, PASSING, YIELDING, WAITING }
enum Response { NONE, PASS, YIELD }

const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const PLANNING_SHARE := 0.65 # Share of the acceleration limits planned with (as the route speed profile; provisional).
const WAIT_SPEED := 0.1 # u/s; held by avoidance and slower than this = waiting, stationary to others (provisional).
const HEAD_ON_ANGLE := 20.0 # deg; travel directions within this of reciprocal are head-on (provisional).
const CROSSING_ANGLE := 45.0 # deg; a moving ship whose travel differs more than this (not head-on) is crossing (provisional).
const MIN_LEVERAGE := 0.2 # A sideways shift must move the relative track by at least this share of itself.
const CLEAR_STEPS := 6 # Bisection steps when obstacles cut a committed passing shift short.
const PASS_RESERVE := 0.5 # Share of the margin a pass in progress must keep from its actual position (as the route lookahead reserve; provisional).
const REJOIN_SHIFT_TOLERANCE := 0.25 # u; change of the applied passing shift that re-places a committed rejoin point (prototype).
const REJOIN_STEPS := 12 # Bisection steps for the rejoin point and the clear part of its turn.
const EPSILON := 0.000001

@export var size_class := 1 # Give-way rule: the smaller class gives way; equal: the later ship in the scene.
@export var separation_margin := 1.0 # Gap kept between footprints (u, provisional).
@export var ships_path := NodePath("../..")
@export var navigation_path := NodePath("../../../StaticNavigation")

var state := State.NORMAL
var encounters := {} # other ship -> {give_way, response, side, need, shift, limited, head_on, astern, converging}
var offset := Vector2.ZERO # Steering offset requested this tick.
var speed_cap := INF # Speed cap requested this tick.
var target := Vector2.ZERO # Steering point this ship is sent to (aim point + passing shift).
# Predicted closest approach to the nearest-threatening ship in range (debug).
var closest_name := ""
var closest_gap := INF # footprint gap (u) at the predicted closest approach
var closest_time := 0.0
var closest_points := PackedVector2Array() # own and other predicted positions at that time
# Counters since the last reset() (debug and tests).
var min_separation := INF # Smallest actual footprint gap to any ship.
var contacts := 0 # Starts of footprint overlap with another ship.
var role_changes := 0 # Encounters where this ship took over giving way (stand-on -> give way).
var response_changes := 0 # Yielding encounters upgraded to passing.
var restarts := 0 # Encounters started again with a ship after an earlier one ended.
var side_flips := 0 # Restarts that passed on the other side than before.
var last_step_usec := 0
# Planned rejoin (cause B prototype, direct moves): the committed end of a pass around
# stationary ships. {goal, side, shift, ships, point, along, start, out_dir, window, speed, turned}
var rejoin := {}

var _history := {} # other ship -> last committed side (0 = yielded)
var _touching := {} # other ship -> true while the footprints overlap

@onready var _ship := get_parent() as Node3D
@onready var _locomotion := _ship.get_node("Locomotion") as ShipLocomotion
@onready var _follower := _ship.get_node("RouteFollower") as RouteFollower
@onready var _ships := get_node(ships_path)
@onready var _navigation := get_node(navigation_path) as StaticNavigation


func _ready() -> void:
	process_physics_priority = -1 # After the RouteFollower (earlier sibling), before Locomotion (0).


func _physics_process(_delta: float) -> void:
	var start_usec := Time.get_ticks_usec()
	_update()
	_locomotion.avoid(offset, speed_cap)
	last_step_usec = Time.get_ticks_usec() - start_usec


func reset() -> void:
	encounters.clear()
	rejoin = {}
	_history.clear()
	_touching.clear()
	min_separation = INF
	contacts = 0
	role_changes = 0
	response_changes = 0
	restarts = 0
	side_flips = 0


func _update() -> void:
	offset = Vector2.ZERO
	speed_cap = INF
	state = State.NORMAL
	closest_name = ""
	closest_gap = INF
	closest_points = PackedVector2Array()
	var position := _locomotion.planar_position
	_measure_separation(position)
	var routed := _follower.status == RouteFollower.RouteStatus.ROUTE
	target = _follower.aim_point if _locomotion.has_destination else position
	if not _locomotion.has_destination or not (routed or _follower.status == RouteFollower.RouteStatus.DIRECT):
		encounters.clear()
		rejoin = {}
		return

	# Own prediction basis: route position, segment direction, preferred speed.
	var segment := _follower.segment if routed else 0
	var a := _follower.route[segment]
	var b := _follower.route[segment + 1]
	var dir := (b - a).normalized()
	var side_axis := Vector2(-dir.y, dir.x) # Starboard (right of travel).
	var from := Geometry2D.get_closest_point_to_segment(position, a, b)
	var remaining := _follower.remaining if routed else position.distance_to(_locomotion.destination)
	var preferred := minf(_locomotion.max_speed, sqrt(2.0 * PLANNING_SHARE * _locomotion.reverse_accel * remaining))
	if routed:
		preferred = minf(preferred, _follower.speed_cap)
	var own := {"from": from, "dir": dir, "side_axis": side_axis, "velocity": dir * preferred,
		"end": remaining / preferred if preferred > EPSILON else 0.0, "preferred": preferred,
		"remaining": remaining, "position": position}

	var predictions := {}
	for ship: Node in _ships.get_children():
		if ship == _ship or ship.get_node_or_null("Locomotion") == null:
			continue
		var prediction := _predict(own, ship, from)
		predictions[ship] = prediction
		if prediction.in_range:
			_show_closest(ship, prediction)

	# Start, keep or end encounters.
	for ship: Node in predictions:
		var prediction: Dictionary = predictions[ship]
		var other_position := (ship.get_node("Locomotion") as ShipLocomotion).planar_position
		if encounters.has(ship):
			var encounter: Dictionary = encounters[ship]
			# A committed pass ends only when the ships are not still closing beyond the
			# prediction window (overtaking), the route is clear again, and the ship's actual
			# position is not in conflict either.
			var holding: bool = encounter.response == Response.PASS and (prediction.closing or prediction.actual_conflict
				or from.distance_to(other_position) < prediction.separation)
			if not (prediction.conflict or holding):
				_history[ship] = encounter.side
				encounters.erase(ship)
				continue
			if not encounter.give_way and _gives_way(ship, own):
				encounter.give_way = true
				role_changes += 1
				_choose(encounter, ship, own, predictions)
		elif prediction.conflict:
			# Classified by the other ship's travel: its velocity, or for a ship starting
			# from rest toward its destination its intended direction (not parked).
			var other_velocity := _travel(ship)
			var moving := other_velocity.length() > WAIT_SPEED
			var head_on := moving and dir.dot(other_velocity.normalized()) < -cos(deg_to_rad(HEAD_ON_ANGLE))
			# Crossing: the other ship moves across this ship's track. Its astern side
			# (where it has been) is the side of this track its velocity comes from.
			var crossing := moving and not head_on and dir.dot(other_velocity.normalized()) < cos(deg_to_rad(CROSSING_ANGLE))
			# Converging: both moving the same general way, the ships closing mostly across
			# this ship's track (relative velocity), not along it as when overtaking. A pass
			# may only go away from the other ship (never across its track).
			var relative_velocity: Vector2 = other_velocity - own.velocity
			var converging := moving and not head_on and not crossing \
				and absf(relative_velocity.dot(side_axis)) > absf(relative_velocity.dot(dir))
			var away := -1 if (prediction.relative as Vector2).dot(side_axis) > 0.0 else 1
			var encounter := {"give_way": _gives_way(ship, own), "response": Response.NONE, "side": 0, "need": 0.0,
				"shift": 0.0, "limited": false, "released": false, "head_on": head_on,
				"astern": int(signf(side_axis.dot(-other_velocity))) if crossing else 0,
				"converging": away if converging else 0}
			encounters[ship] = encounter
			if encounter.give_way:
				_choose(encounter, ship, own, predictions)
			if _history.has(ship):
				restarts += 1
				if _history[ship] != 0 and encounter.side != 0 and _history[ship] != encounter.side:
					side_flips += 1

	# Responses: at most one passing shift; every yield adds a speed cap. A stationary
	# ship's yield is decided once the pass (if any) is applied: if the applied shift
	# already clears it (the feasibility test), it takes the pass's side and only the
	# stationary pass cap; otherwise it yields as any other.
	var passing := false
	var primary := {}
	var primary_ship: Node = null
	var stationary := []
	for ship: Node in encounters:
		var encounter: Dictionary = encounters[ship]
		if not encounter.give_way:
			continue
		var prediction: Dictionary = predictions[ship]
		if encounter.response == Response.YIELD and not passing and not _has_pass():
			_choose(encounter, ship, own, predictions) # Slowing gives more time: passing may become feasible.
			if encounter.response == Response.PASS:
				response_changes += 1
		if encounter.response == Response.PASS and not passing:
			passing = true
			primary = encounter
			primary_ship = ship
			_apply_pass(encounter, ship, own, predictions)
			speed_cap = minf(speed_cap, _pass_cap(prediction, own, ship))
		elif is_stationary(ship.get_node("Locomotion") as ShipLocomotion):
			stationary.append(ship)
		else:
			speed_cap = minf(speed_cap, _yield_cap(encounter, ship, prediction, own))
	for ship: Node in stationary:
		var encounter: Dictionary = encounters[ship]
		var prediction: Dictionary = predictions[ship]
		if passing and _shift_clears(prediction, own.side_axis * primary.side * primary.shift, own):
			_follow_pass(encounter, primary.side, prediction, own)
			speed_cap = minf(speed_cap, _pass_cap(prediction, own, ship))
		else:
			speed_cap = minf(speed_cap, _yield_cap(encounter, ship, prediction, own))
	# Direct moves: a pass around stationary ships ends with its planned rejoin.
	var rejoining := not routed and _rejoin_step(passing, primary_ship, primary, own, predictions)

	if passing or rejoining:
		state = State.PASSING
	elif speed_cap < INF:
		state = State.WAITING if _is_waiting(_locomotion) else State.YIELDING
	if passing or rejoining:
		var shifted := _follower.aim_point + offset
		target = shifted
		if not routed:
			offset = shifted - _locomotion.destination # Direct move: Locomotion steers to the destination.


# Planned rejoin (cause B prototype, direct moves only): the end of a pass around
# stationary ships, planned once as one path (_place_rejoin): the shifted track up to T1,
# a circular turn T1 -> T2 (RouteFollower's corner geometry around the rejoin corner R),
# and the straight leg T2 -> destination. Steering and speed use that same path:
# - steering: before T1 the pass's own steering (unchanged); from T1 the path's direction
#   at the ship's own place on it, one committed lookahead long (no corner cutting, so the
#   turn starts at T1 and any lag stays outside the arc); on the straight leg the point
#   one lookahead ahead, up to the destination;
# - speed: down to the turn speed by T1, held through the turn, then the arrival profile
#   along the straight leg. The turn speed is RouteFollower's corner speed, lowered so the
#   ship can stop on the leg after T2: the velocity is aligned before arrival braking
#   starts, so braking never takes the acceleration the turn needs;
# - the arrival profile along the remaining path throughout.
# Planned only once the ship flies the shifted track (within REJOIN_SHIFT_TOLERANCE);
# re-planned only before T1, when the applied shift changes by more than
# REJOIN_SHIFT_TOLERANCE, the passed stationary ships change, or the path stops being
# clear; the side never changes. A moving ship this ship gives way to suspends it (the
# existing responses apply). False: no rejoin applies.
func _rejoin_step(passing: bool, primary_ship: Node, primary: Dictionary, own: Dictionary, predictions: Dictionary) -> bool:
	var goal := _locomotion.destination
	if not rejoin.is_empty() and rejoin.goal != goal:
		rejoin = {}
	for ship: Node in encounters:
		if encounters[ship].give_way and not is_stationary(ship.get_node("Locomotion") as ShipLocomotion):
			return false
	var position: Vector2 = own.position
	var turning := not rejoin.is_empty() and _path_progress(position) >= -float(rejoin.lookahead)
	if passing and is_stationary(primary_ship.get_node("Locomotion") as ShipLocomotion):
		var ships := [primary_ship]
		for ship: Node in encounters:
			var encounter: Dictionary = encounters[ship]
			if ship != primary_ship and encounter.give_way and encounter.response == Response.PASS and encounter.side == primary.side \
					and is_stationary(ship.get_node("Locomotion") as ShipLocomotion):
				ships.append(ship)
		# Planned (and re-planned) only once the ship flies the shifted track: the turn starts from it.
		var established := absf((position - _follower.route[0]).dot(own.side_axis) - primary.side * primary.shift) <= REJOIN_SHIFT_TOLERANCE
		if not rejoin.is_empty() and rejoin.side != primary.side:
			rejoin = {}
		if rejoin.is_empty():
			if established:
				_place_rejoin(primary.side, primary.shift, ships, goal, own, predictions, (position - _follower.route[0]).dot(own.dir))
		elif not turning and established and (absf(primary.shift - rejoin.shift) > REJOIN_SHIFT_TOLERANCE or not _same_ships(ships, rejoin.ships)
				or not _path_clear(rejoin, goal, rejoin.ships, predictions)):
			_place_rejoin(primary.side, primary.shift, ships, goal, own, predictions, rejoin.start)
	elif not rejoin.is_empty() and not _path_clear(rejoin, goal, rejoin.ships, predictions):
		if turning:
			rejoin = {} # Committed turn no longer clear: back to the plain pass (collision stays the safety net).
		else:
			_place_rejoin(rejoin.side, rejoin.shift, rejoin.ships, goal, own, predictions, rejoin.start)
	if rejoin.is_empty():
		return false

	var lookahead: float = rejoin.lookahead
	var turn_speed: float = rejoin.speed
	var total: float = rejoin.arc + rejoin.leg
	var progress := _path_progress(position)
	var brake := _follower.turn_brake_share * _locomotion.reverse_accel
	var remaining := position.distance_to(goal) if rejoin.phase == 2 else total - progress
	var cap := sqrt(2.0 * brake * remaining)
	if progress < 0.0:
		cap = minf(cap, sqrt(turn_speed * turn_speed + 2.0 * brake * -progress))
	elif rejoin.phase < 2:
		cap = minf(cap, turn_speed)
	speed_cap = minf(speed_cap, cap)
	rejoin.progress = progress
	var steer: Vector2
	if rejoin.phase == 2:
		steer = _path_point(minf(progress + lookahead, total))
	elif progress >= 0.0:
		# Along the path's direction at the ship's own place on it (no corner cutting): the
		# turn starts at T1, and lagging behind it keeps the ship outside the planned arc.
		steer = _path_point(progress) + _path_tangent(progress) * minf(lookahead, total - progress)
	elif passing:
		steer = _follower.aim_point + offset # Before T1: the pass's own steering.
	else:
		steer = _path_point(progress + _follower.lookahead) # The shifted track before T1.
	offset = steer - _follower.aim_point
	return true


# The ship's place on the planned path (0 at T1; negative before it), and its phase
# (0 before T1, 1 in the turn, 2 on the straight leg), which only advances.
func _path_progress(position: Vector2) -> float:
	var t1: Vector2 = rejoin.t1
	var t2: Vector2 = rejoin.t2
	var dir: Vector2 = rejoin.dir
	var out_dir: Vector2 = rejoin.out_dir
	if rejoin.phase == 0 and (position - t1).dot(dir) >= 0.0:
		rejoin.phase = 1
	if rejoin.phase == 1 and (position - t2).dot(out_dir) >= 0.0:
		rejoin.phase = 2
	match rejoin.phase:
		0:
			return (position - t1).dot(dir)
		1:
			var center: Vector2 = rejoin.center
			var turned := absf((t1 - center).angle_to(position - center))
			return clampf(turned * float(rejoin.radius), 0.0, rejoin.arc)
	return float(rejoin.arc) + (position - t2).dot(out_dir)


# Point of the planned path at a path distance from T1.
func _path_point(distance: float) -> Vector2:
	var t1: Vector2 = rejoin.t1
	if distance <= 0.0:
		return t1 + (rejoin.dir as Vector2) * distance
	var arc: float = rejoin.arc
	if distance <= arc:
		var center: Vector2 = rejoin.center
		return center + (t1 - center).rotated(float(rejoin.sign) * distance / float(rejoin.radius))
	return (rejoin.t2 as Vector2) + (rejoin.out_dir as Vector2) * (distance - arc)


# Direction of the planned path at a path distance from T1.
func _path_tangent(distance: float) -> Vector2:
	if distance <= 0.0:
		return rejoin.dir
	if distance >= float(rejoin.arc):
		return rejoin.out_dir
	return (rejoin.dir as Vector2).rotated(float(rejoin.sign) * distance / float(rejoin.radius))


# Rejoin plan: the first rejoin corner R on the shifted track (route line + side · shift),
# at or past every passed stationary ship, whose path (turn and straight leg) is clear
# (_path_clear; bisection, assuming it stays clear further on). The turn is
# RouteFollower._plan_speeds()'s corner: an arc of radius window / angle, window =
# min(track before R since the pass began, R -> destination, window factor × planning
# radius), tangent to the track at T1 and to R -> destination at T2. Its speed is the
# corner speed (lateral acceleration and turn rate) and at most the speed the ship can
# stop from over T2 -> destination (planning share, as the arrival profile). The steering
# lookahead is RouteFollower.lookahead_length() at that speed, fixed for the maneuver.
# None (rejoin cleared) if no such corner lies before the destination.
func _place_rejoin(side: int, shift: float, ships: Array, goal: Vector2, own: Dictionary, predictions: Dictionary, start: float) -> void:
	var a: Vector2 = _follower.route[0]
	var dir: Vector2 = own.dir
	var lateral: Vector2 = (own.side_axis as Vector2) * side * shift
	var low := -INF
	for ship: Node in ships:
		low = maxf(low, ((ship.get_node("Locomotion") as ShipLocomotion).planar_position - a).dot(dir))
	var high := (goal - a).dot(dir)
	var plan := {}
	if high > low:
		plan = _turn_plan(a, dir, lateral, high, start, goal)
	if plan.is_empty() or not _path_clear(plan, goal, ships, predictions):
		rejoin = {}
		return
	var first := _turn_plan(a, dir, lateral, low, start, goal)
	if not first.is_empty() and _path_clear(first, goal, ships, predictions):
		plan = first
	else:
		for i in REJOIN_STEPS:
			var middle := (low + high) * 0.5
			var candidate := _turn_plan(a, dir, lateral, middle, start, goal)
			if not candidate.is_empty() and _path_clear(candidate, goal, ships, predictions):
				high = middle
				plan = candidate
			else:
				low = middle
	var brake := _follower.turn_brake_share * _locomotion.reverse_accel
	var speed := sqrt(2.0 * brake * float(plan.leg))
	var radius: float = plan.radius
	if radius < INF:
		speed = minf(speed, minf(sqrt(_locomotion.lateral_accel * radius), deg_to_rad(_locomotion.max_turn_rate_deg) * radius))
	plan.speed = speed
	plan.lookahead = maxf(_follower.ship_radius, speed * speed / (2.0 * ShipLocomotion.BRAKE_MARGIN * _locomotion.reverse_accel))
	plan.goal = goal
	plan.side = side
	plan.shift = shift
	plan.ships = ships
	plan.start = start
	plan.phase = 0
	plan.progress = -INF
	rejoin = plan


# Turn geometry for the rejoin corner at `along` on the shifted track; empty if the turn
# does not fit between the start of the pass and the destination.
func _turn_plan(a: Vector2, dir: Vector2, lateral: Vector2, along: float, start: float, goal: Vector2) -> Dictionary:
	var point := a + dir * along + lateral
	var out := goal - point
	var out_length := out.length()
	if out_length <= EPSILON:
		return {}
	var out_dir := out / out_length
	var angle := dir.angle_to(out_dir)
	var window := minf(minf(maxf(along - start, 0.0), out_length), _follower.maneuver_window_factor * _follower.planning_radius())
	var plan := {"point": point, "along": along, "dir": dir, "out_dir": out_dir, "window": window, "angle": absf(angle),
		"radius": INF, "sign": 0.0, "center": point, "t1": point, "t2": point, "arc": 0.0}
	if absf(angle) > EPSILON and window > EPSILON:
		var radius := window / absf(angle)
		var tangent := radius * tan(absf(angle) * 0.5)
		if tangent > out_length or tangent > along - start:
			return {}
		plan.radius = radius
		plan.sign = signf(angle)
		plan.t1 = point - dir * tangent
		plan.t2 = point + out_dir * tangent
		plan.center = (plan.t1 as Vector2) + dir.rotated(signf(angle) * PI * 0.5) * radius
		plan.arc = radius * absf(angle)
	plan.leg = (plan.t2 as Vector2).distance_to(goal)
	return plan


# The planned turn and straight leg keep the route's obstacle clearance and the
# separation (footprints + margin) of every passed ship and every stationary ship in range.
func _path_clear(plan: Dictionary, goal: Vector2, ships: Array, predictions: Dictionary) -> bool:
	var t1: Vector2 = plan.t1
	var t2: Vector2 = plan.t2
	var center: Vector2 = plan.center
	var radius: float = plan.radius
	var arc: float = plan.arc
	var clearance := _follower.line_clearance()
	if not _navigation.segment_clear(t2, goal, clearance):
		return false
	if arc > 0.0:
		var previous := t1
		for i in range(1, REJOIN_STEPS + 1):
			var next := center + (t1 - center).rotated(float(plan.sign) * arc / radius * i / REJOIN_STEPS)
			if not _navigation.segment_clear(previous, next, clearance):
				return false
			previous = next
	for other: Node in predictions:
		var check: Dictionary = predictions[other]
		var locomotion := other.get_node("Locomotion") as ShipLocomotion
		if not (ships.has(other) or (check.in_range and is_stationary(locomotion))):
			continue
		var at := locomotion.planar_position
		if Geometry2D.get_closest_point_to_segment(at, t2, goal).distance_to(at) < check.separation:
			return false
		if arc > 0.0 and _arc_distance(at, plan) < check.separation:
			return false
	return true


# Distance from a point to the planned turn's arc.
static func _arc_distance(point: Vector2, plan: Dictionary) -> float:
	var center: Vector2 = plan.center
	var t1: Vector2 = plan.t1
	var swept := (t1 - center).angle_to(point - center) * float(plan.sign)
	if swept >= 0.0 and swept <= float(plan.angle):
		return absf(point.distance_to(center) - float(plan.radius))
	return minf(point.distance_to(t1), point.distance_to(plan.t2))


static func _same_ships(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for ship: Node in first:
		if not second.has(ship):
			return false
	return true


func _has_pass() -> bool:
	for ship: Node in encounters:
		if encounters[ship].give_way and encounters[ship].response == Response.PASS:
			return true
	return false


# Closed-form prediction against one ship. Relative position of the other ship to
# this ship's route position over [0, horizon]: this ship moves at its preferred
# velocity until its remaining route is used up, then stays; the other keeps its
# current velocity. Horizon = both ships' stopping times from their top speeds.
func _predict(own: Dictionary, ship: Node, from: Vector2) -> Dictionary:
	var other := ship.get_node("Locomotion") as ShipLocomotion
	var other_radius: float = (ship.get_node("RouteFollower") as RouteFollower).ship_radius
	var separation := _follower.ship_radius + other_radius + separation_margin
	var horizon := _stop_time(_locomotion) + _stop_time(other)
	var p := other.planar_position - from
	var w := other.velocity
	var result := {"in_range": false, "conflict": false, "closing": false, "separation": separation, "time": 0.0,
		"actual": Vector3(INF, 0.0, INF), "actual_conflict": false,
		"entry": INF, "entry_stopped": INF, "relative": p, "other_velocity": w, "horizon": horizon,
		"other_end": _end_time(ship)}
	if p.length() > (own.preferred + w.length()) * horizon + separation:
		return result
	result.in_range = true
	var closest := _closest(p, w, own.velocity, own.end, horizon, separation, result.other_end)
	result.entry = closest.z
	result.time = closest.y
	# Still closing at the end of the window: the closest approach lies beyond it.
	result.closing = closest.y >= horizon - 0.001
	result.conflict = closest.x < separation and closest.y > EPSILON
	# The same from the ship's actual position (moving parallel to its route), keeping
	# the footprints plus half the margin (the pass itself aims for the whole margin):
	# while passing, it limits closing in (_pass_cap) and keeps the pass from ending early.
	var reserve := _reserve(separation)
	result.actual =_closest(other.planar_position - own.position, w, own.velocity, own.end, horizon, reserve, result.other_end)
	result.actual_conflict = result.actual.x < reserve and result.actual.y > EPSILON
	# If this ship stopped at its route position now: when the other ship would reach it.
	result.entry_stopped = _closest(p, w, Vector2.ZERO, 0.0, horizon, separation, result.other_end).z
	return result


# Debug: predicted closest approach from the actual positions and velocities, kept
# for the ship with the smallest predicted footprint gap.
func _show_closest(ship: Node, prediction: Dictionary) -> void:
	var other := ship.get_node("Locomotion") as ShipLocomotion
	var position := _locomotion.planar_position
	var closest := _closest(other.planar_position - position, other.velocity, _locomotion.velocity, INF, prediction.horizon, prediction.separation, prediction.other_end)
	var gap: float = closest.x - (prediction.separation - separation_margin)
	if gap < closest_gap:
		closest_gap = gap
		closest_time = closest.y
		closest_name = ship.name
		closest_points = PackedVector2Array([position + _locomotion.velocity * closest.y, other.planar_position + other.velocity * closest.y])


# (closest distance, its time, first time within separation or INF) over [0, horizon]:
# both ships move until the first one reaches its end (this ship: its remaining route;
# the other: its destination), then the other one alone, then both stand.
static func _closest(p: Vector2, w: Vector2, own_velocity: Vector2, own_end: float, horizon: float, separation: float, other_end := INF) -> Vector3:
	var first_stop := minf(minf(own_end, other_end), horizon)
	var second_stop := minf(maxf(own_end, other_end), horizon)
	var pieces := [[first_stop, w - own_velocity]]
	if second_stop > first_stop:
		pieces.append([second_stop, w if other_end > own_end else -own_velocity])
	if horizon > second_stop:
		pieces.append([horizon, Vector2.ZERO])
	var r := p
	var start := 0.0
	var best := Vector2(INF, 0.0)
	var entry := INF
	for piece: Array in pieces:
		var length: float = piece[0] - start
		var u: Vector2 = piece[1]
		var closest := _piece_closest(r, u, length)
		if closest.x < best.x:
			best = Vector2(closest.x, start + closest.y)
		if entry == INF:
			var inside := _piece_entry(r, u, length, separation)
			if inside != INF:
				entry = start + inside
		r += u * length
		start = piece[0]
	return Vector3(best.x, best.y, entry)


# Time until the other ship reaches its destination at its current speed (INF if it
# has none or stands): its predicted path stops there.
func _end_time(ship: Node) -> float:
	var other := ship.get_node("Locomotion") as ShipLocomotion
	var speed := other.velocity.length()
	if not other.has_destination or speed <= EPSILON:
		return INF
	var follower := ship.get_node("RouteFollower") as RouteFollower
	var remaining := follower.remaining if follower.status == RouteFollower.RouteStatus.ROUTE else other.distance_to_destination()
	return remaining / speed


# Closest distance of r0 + u·t over t in [0, length]: (distance, t).
static func _piece_closest(r0: Vector2, u: Vector2, length: float) -> Vector2:
	var t := 0.0
	var uu := u.length_squared()
	if uu > EPSILON:
		t = clampf(-r0.dot(u) / uu, 0.0, length)
	return Vector2((r0 + u * t).length(), t)


# First t in [0, length] with |r0 + u·t| < separation (0 if already inside), else INF.
static func _piece_entry(r0: Vector2, u: Vector2, length: float, separation: float) -> float:
	var c := r0.length_squared() - separation * separation
	if c < 0.0:
		return 0.0
	var a := u.length_squared()
	var b := r0.dot(u)
	if a < EPSILON or b >= 0.0:
		return INF
	var disc := b * b - a * c
	if disc < 0.0:
		return INF
	var t := (-b - sqrt(disc)) / a
	return t if t <= length else INF


# Give-way rule: idle ships hold position, so a moving ship always gives way to them;
# a ship waiting for avoidance counts as stationary; a ship overtaking another
# (coming up from behind on the same general course) gives way to it and the
# overtaken ship stands on, whatever their sizes; otherwise the smaller size class
# gives way, and for equal classes the ship later in the scene.
func _gives_way(ship: Node, own: Dictionary) -> bool:
	var other := ship.get_node("Locomotion") as ShipLocomotion
	if not other.has_destination:
		return true
	if _is_waiting(other) and not _is_waiting(_locomotion):
		return true
	var overtaking := _overtaking(ship, own)
	if overtaking != 0:
		return overtaking > 0
	var other_avoidance := ship.get_node_or_null("Avoidance")
	var other_class: int = other_avoidance.size_class if other_avoidance != null else size_class
	if size_class != other_class:
		return size_class < other_class
	return _ship.get_index() > ship.get_index()


# +1: this ship is overtaking the other (the other is ahead, more ahead than abeam,
# on the same general course, and this ship closes on it along its travel);
# -1: the other is overtaking this ship (behind, more behind than abeam, same
# general course, actually faster along this ship's travel); 0: neither.
func _overtaking(ship: Node, own: Dictionary) -> int:
	var other := ship.get_node("Locomotion") as ShipLocomotion
	var travel := _travel(ship)
	var dir: Vector2 = own.dir
	if travel.length() <= WAIT_SPEED or dir.dot(travel.normalized()) < cos(deg_to_rad(CROSSING_ANGLE)):
		return 0
	var p: Vector2 = other.planar_position - own.position
	var along := p.dot(dir)
	var abeam := absf(p.dot(own.side_axis))
	if along > abeam and own.preferred > other.velocity.dot(dir) + EPSILON:
		return 1
	if -along > abeam and other.velocity.dot(dir) > _locomotion.velocity.dot(dir) + EPSILON:
		return -1
	return 0


# The other ship's travel: its velocity; for a ship with an order still starting from
# rest (and not held by avoidance), the direction of its route at its top speed.
func _travel(ship: Node) -> Vector2:
	var other := ship.get_node("Locomotion") as ShipLocomotion
	if other.velocity.length() > WAIT_SPEED or not other.has_destination or _is_waiting(other):
		return other.velocity
	var follower := ship.get_node("RouteFollower") as RouteFollower
	var next := other.destination
	if follower.route.size() >= 2:
		next = follower.route[mini(follower.segment + 1, follower.route.size() - 1)]
	var offset := next - other.planar_position
	return offset.normalized() * other.max_speed if offset.length() > EPSILON else Vector2.ZERO


static func _is_waiting(locomotion: ShipLocomotion) -> bool:
	return locomotion.has_destination and locomotion.velocity.length() < WAIT_SPEED and locomotion.avoidance_cap < WAIT_SPEED


## Genuinely stationary: standing with no order (idle, arrived, mining, docked) or
## without propulsion (out of fuel). A ship with an order held back by avoidance, or
## braking, is not (it is about to move on).
static func is_stationary(locomotion: ShipLocomotion) -> bool:
	return (not locomotion.has_destination or not locomotion.propulsion) and locomotion.velocity.length() < WAIT_SPEED


# Gap a pass in progress keeps from its actual position: the footprints plus PASS_RESERVE of the margin.
func _reserve(separation: float) -> float:
	return separation - (1.0 - PASS_RESERVE) * separation_margin


# Pass on a feasible side (head-on: starboard first; crossing: only astern of the
# other ship; converging: only away from it, at most one separation; otherwise the
# smaller shift first, starboard on a tie), else yield.
# The side is then kept for the encounter.
func _choose(encounter: Dictionary, ship: Node, own: Dictionary, predictions: Dictionary) -> void:
	var prediction: Dictionary = predictions[ship]
	var u: Vector2 = prediction.other_velocity - own.velocity
	var sides := [1, -1]
	var bound := INF
	if encounter.astern != 0:
		sides = [encounter.astern]
	elif encounter.converging != 0:
		# Converging: only away from the other ship, and only a shift within one
		# separation (the encounter's own scale); otherwise slow down and let it merge.
		sides = [encounter.converging]
		bound = prediction.separation
	elif not encounter.head_on:
		var starboard := _need(prediction.relative, u, own, 1, prediction.separation)
		var port := _need(prediction.relative, u, own, -1, prediction.separation)
		if port < starboard:
			sides = [-1, 1]
	for side: int in sides:
		var need := _need(prediction.relative, u, own, side, prediction.separation)
		# need 0: the straight-line model sees no fix by shifting (e.g. this ship stops first).
		if need > 0.0 and need <= bound and need < INF and _pass_feasible(ship, side, need, prediction, own, predictions):
			encounter.response = Response.PASS
			encounter.side = side
			encounter.need = need
			return
	encounter.response = Response.YIELD
	encounter.side = 0


# Sideways shift of this ship's track (to `side`: +1 starboard, -1 port) that puts
# the relative track `separation` away from this ship, on the far side of the shift.
# The relative track is the line p + u·t (its direction: the relative velocity, or
# this ship's travel when both move alike).
func _need(p: Vector2, u: Vector2, own: Dictionary, side: int, separation: float) -> float:
	var axis: Vector2 = u.normalized() if u.length() > 0.01 else own.dir
	var leverage: float = (own.side_axis as Vector2).cross(axis)
	if absf(leverage) < MIN_LEVERAGE:
		return INF
	var wanted := -side * signf(leverage) * separation
	return maxf(0.0, (p.cross(axis) - wanted) / (side * leverage))


# A pass is feasible if the ship can make the shift before the conflict starts with
# its own turning, forward, lateral and braking limits (_shift_reach), the shifted
# track keeps the route's clearance from obstacles (steering line and the stretch
# through the encounter), and it creates no conflict with another nearby ship.
func _pass_feasible(ship: Node, side: int, need: float, prediction: Dictionary, own: Dictionary, predictions: Dictionary) -> bool:
	# Time to make the shift: until the conflict starts, or longer if this ship can hold
	# back (a stationary ship, or one ahead moving away, then never reaches it), but
	# never beyond the prediction horizon.
	if need > _shift_reach(minf(maxf(prediction.entry, prediction.entry_stopped), prediction.horizon)):
		return false
	var shift: Vector2 = own.side_axis * side * need
	var clearance := _follower.line_clearance()
	if not _navigation.segment_clear(own.position, _follower.aim_point + shift, clearance):
		return false
	var through := minf(own.remaining, own.preferred * prediction.time + prediction.separation)
	if not _navigation.segment_clear(own.from + shift, own.from + own.dir * through + shift, clearance):
		return false
	for other: Node in predictions:
		var check: Dictionary = predictions[other]
		if other == ship or not check.in_range:
			continue
		if not _shift_clears(check, shift, own):
			return false
	return true


# True if this ship's track shifted by `shift` creates no conflict with the ship of
# prediction `check`, and the move across to the shifted track (ship -> shifted
# steering point) does not sweep through its predicted path either.
func _shift_clears(check: Dictionary, shift: Vector2, own: Dictionary) -> bool:
	var moved := _closest(check.relative - shift, check.other_velocity, own.velocity, own.end, check.horizon, check.separation, check.other_end)
	if moved.x < check.separation and moved.y > EPSILON:
		return false
	var leg: Vector2 = _follower.aim_point + shift - own.position
	if own.preferred > EPSILON and leg.length() > EPSILON:
		var leg_time: float = leg.length() / own.preferred
		var swept := _closest(check.relative + own.from - own.position, check.other_velocity, leg / leg_time, leg_time, leg_time, check.separation, check.other_end)
		if swept.x < check.separation and swept.y > EPSILON:
			return false
	return true


# A stationary ship the applied pass already clears: committed to the pass's side
# (with its own shift need on that side), so it continues the pass on the same side
# once the applied one ends instead of switching across.
func _follow_pass(encounter: Dictionary, side: int, prediction: Dictionary, own: Dictionary) -> void:
	if encounter.response == Response.PASS and encounter.side == side:
		return
	var need := _need(prediction.relative, prediction.other_velocity - own.velocity, own, side, prediction.separation)
	encounter.response = Response.PASS
	encounter.side = side
	encounter.need = need if need < INF else 0.0


# Committed pass: the shift is recomputed on the committed side each tick; it may only
# grow while the larger shift still passes the feasibility check (otherwise it stays,
# and the pass cap slows the ship); if the shifted steering line would cross an
# obstacle, the shift is cut to the largest clear one (the encounter is flagged limited).
func _apply_pass(encounter: Dictionary, ship: Node, own: Dictionary, predictions: Dictionary) -> void:
	var prediction: Dictionary = predictions[ship]
	var u: Vector2 = prediction.other_velocity - own.velocity
	var need := _need(prediction.relative, u, own, encounter.side, prediction.separation)
	if need < INF and (need <= encounter.need or _pass_feasible(ship, encounter.side, need, prediction, own, predictions)):
		encounter.need = need
	if encounter.converging != 0:
		encounter.need = minf(encounter.need, prediction.separation) # Bounded; the pass cap slows the rest.
	var axis: Vector2 = own.side_axis * encounter.side
	var clearance := _follower.line_clearance()
	var shift: float = encounter.need
	if not _navigation.segment_clear(own.position, _follower.aim_point + axis * shift, clearance):
		var low := 0.0
		var high := shift
		for i in CLEAR_STEPS:
			var middle := (low + high) * 0.5
			if _navigation.segment_clear(own.position, _follower.aim_point + axis * middle, clearance):
				low = middle
			else:
				high = middle
		shift = low
	encounter.shift = shift
	encounter.limited = shift < encounter.need - 0.01
	offset = axis * shift
	var other := ship.get_node("Locomotion") as ShipLocomotion
	if is_stationary(other):
		offset = _keep_reserve(other.planar_position, _reserve(prediction.separation), own, offset)


# Passing a stationary ship: the steering line (ship -> shifted aim point) must keep the
# reserve from it; otherwise the steering point is pulled back along the route toward
# the ship's route position (bisection; at most a sideways step from there), so the
# ship moves out before it moves on. Unchanged if that line would not keep the route's
# clearance from obstacles. Returns the steering offset from the aim point.
func _keep_reserve(center: Vector2, reserve: float, own: Dictionary, shift: Vector2) -> Vector2:
	var aim := _follower.aim_point
	if _keeps(own.position, aim + shift, center, reserve):
		return shift
	var from: Vector2 = own.from
	var low := 0.0
	var high := 1.0
	for i in CLEAR_STEPS:
		var middle := (low + high) * 0.5
		if _keeps(own.position, from.lerp(aim, middle) + shift, center, reserve):
			low = middle
		else:
			high = middle
	var point := from.lerp(aim, low) + shift
	if not _navigation.segment_clear(own.position, point, _follower.line_clearance()):
		return shift
	return point - aim


static func _keeps(a: Vector2, b: Vector2, center: Vector2, radius: float) -> bool:
	return Geometry2D.get_closest_point_to_segment(center, a, b).distance_to(center) >= radius


# While passing, the ship does not close in faster than its actual sideways position
# allows: the same prediction from its actual position (moving parallel to its route)
# gives the yield cap until the shift is made. Passing a stationary ship, only the
# ship's travel is limited instead (its velocity, or at rest the direction to its
# steering point): along it the ship must be able to stop before entering the reserve,
# √(2 · a_brake · distance); travel leading out of the reserve or missing it is not
# limited, so the move out sideways is never held.
func _pass_cap(prediction: Dictionary, own: Dictionary, ship: Node) -> float:
	var other := ship.get_node("Locomotion") as ShipLocomotion
	if is_stationary(other):
		var travel := _locomotion.velocity
		if travel.length() <= EPSILON:
			travel = _follower.aim_point + offset - own.position # Set by _apply_pass this tick.
			if travel.length() <= EPSILON:
				return INF
		var direction := travel.normalized()
		var p: Vector2 = other.planar_position - own.position
		var reserve := _reserve(prediction.separation)
		if p.length() < reserve:
			return INF if p.dot(direction) <= 0.0 else 0.0
		var entry := _piece_entry(p, -direction, INF, reserve)
		return INF if entry == INF else sqrt(2.0 * PLANNING_SHARE * _locomotion.reverse_accel * entry)
	if prediction.actual_conflict:
		return _cap(prediction.actual.z, prediction.other_velocity, own)
	return INF


# Yield: slow so the ship could stop before the conflict starts (entry: time until
# then at the preferred speed), or follow the other ship at its speed along this
# ship's travel: √(v_follow² + 2 · a_brake · free distance), a_brake =
# PLANNING_SHARE × reverse acceleration (the route speed profile's formula).
func _cap(entry: float, other_velocity: Vector2, own: Dictionary) -> float:
	var follow := maxf(0.0, other_velocity.dot(own.dir))
	var free: float = 0.0 if entry == INF else own.preferred * minf(entry, own.end)
	return sqrt(follow * follow + 2.0 * PLANNING_SHARE * _locomotion.reverse_accel * free)


# Yield speed cap. Crossing: stop before the other ship's corridor, its footprint plus
# this ship's and the margin (separation) swept along its current leg (only its
# footprint while it waits): √(2 · a_brake · distance to the corridor), no following
# floor, 0 inside it; if this ship's track does not reach the corridor, the free
# distance before the predicted conflict instead. Otherwise _cap (following kept).
func _yield_cap(encounter: Dictionary, ship: Node, prediction: Dictionary, own: Dictionary) -> float:
	if encounter.astern == 0:
		return _cap(prediction.entry, prediction.other_velocity, own)
	var other := ship.get_node("Locomotion") as ShipLocomotion
	var follower := ship.get_node("RouteFollower") as RouteFollower
	var a := other.planar_position
	var b := a
	if other.has_destination and not _is_waiting(other):
		b = other.destination
		if follower.status == RouteFollower.RouteStatus.ROUTE:
			b = follower.route[mini(follower.segment + 1, follower.route.size() - 1)]
	var safe := _corridor_distance(own.position, own.dir, own.remaining, a, b, prediction.separation)
	if safe == INF:
		safe = 0.0 if prediction.entry == INF else own.preferred * minf(prediction.entry, own.end)
	return sqrt(2.0 * PLANNING_SHARE * _locomotion.reverse_accel * safe)


# Distance along origin + dir·s (s in [0, length]) to the first point within radius of
# the segment a-b (0 if already within it, INF if never).
static func _corridor_distance(origin: Vector2, dir: Vector2, length: float, a: Vector2, b: Vector2, radius: float) -> float:
	if Geometry2D.get_closest_point_to_segment(origin, a, b).distance_to(origin) <= radius:
		return 0.0
	var to := origin + dir * length
	var nearest := INF
	for center: Vector2 in [a, b]:
		var fraction := Geometry2D.segment_intersects_circle(origin, to, center, radius)
		if fraction >= 0.0:
			nearest = minf(nearest, fraction * length)
	var axis := b - a
	if axis.length() > EPSILON:
		var normal := Vector2(-axis.y, axis.x).normalized() * radius
		for side: Vector2 in [normal, -normal]:
			var hit: Variant = Geometry2D.segment_intersects_segment(origin, to, a + side, b + side)
			if hit != null:
				nearest = minf(nearest, origin.distance_to(hit))
	return nearest


# Sideways distance the ship can cover in time t and end moving parallel again
# (estimate): accelerate sideways for half the time, decelerate for the other half.
# The sideways acceleration grows as the bow turns toward the side (forward thrust
# at the bow angle reachable in a quarter of the time, within turn rate and turn
# acceleration), never below the lateral thrusters; the sideways speed is limited the
# same way by the lateral and forward speed limits.
func _shift_reach(t: float) -> float:
	if t <= 0.0 or t == INF:
		return INF if t == INF else 0.0
	var angle := minf(_turn_angle(0.25 * t), PI * 0.5)
	var accel := PLANNING_SHARE * maxf(_locomotion.lateral_accel, _locomotion.forward_accel * sin(angle))
	var speed := maxf(_locomotion.max_lateral_speed, _locomotion.max_speed * sin(angle))
	if accel * t * 0.5 <= speed:
		return accel * t * t * 0.25
	return speed * (t - speed / accel)


# Heading change reachable from a steady heading in time t (turn acceleration, then turn rate).
func _turn_angle(t: float) -> float:
	var rate := deg_to_rad(_locomotion.max_turn_rate_deg)
	var accel := PLANNING_SHARE * deg_to_rad(_locomotion.turn_accel_deg)
	var ramp := rate / accel
	if t <= ramp:
		return 0.5 * accel * t * t
	return 0.5 * rate * ramp + rate * (t - ramp)


static func _stop_time(locomotion: ShipLocomotion) -> float:
	return locomotion.max_speed / (PLANNING_SHARE * locomotion.reverse_accel)


# Actual footprint gaps to every other ship: minimum since reset() and contact starts.
func _measure_separation(position: Vector2) -> void:
	for ship: Node in _ships.get_children():
		if ship == _ship or ship.get_node_or_null("Locomotion") == null:
			continue
		var other_radius: float = (ship.get_node("RouteFollower") as RouteFollower).ship_radius
		var gap := position.distance_to((ship.get_node("Locomotion") as ShipLocomotion).planar_position) - _follower.ship_radius - other_radius
		min_separation = minf(min_separation, gap)
		if gap < 0.0 and not _touching.has(ship):
			_touching[ship] = true
			contacts += 1
		elif gap >= 0.0:
			_touching.erase(ship)
