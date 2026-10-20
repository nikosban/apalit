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


## A ship left the scene (combat: a destroyed hulk removed): its encounter, committed side
## and contact records here go. Nothing else changes.
func forget(other: Node3D) -> void:
	encounters.erase(other)
	_history.erase(other)
	_touching.erase(other)


func reset() -> void:
	encounters.clear()
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
	# The prediction starts at the route position, so on a direct move it ends where the
	# leg does: the leg left from there, not the straight distance from a ship a pass has
	# displaced (that ran past the destination into ships parked beyond it).
	var horizon_length := remaining if routed else from.distance_to(b)
	var own := {"from": from, "dir": dir, "side_axis": side_axis, "velocity": dir * preferred,
		"end": horizon_length / preferred if preferred > EPSILON else 0.0, "preferred": preferred,
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
	var stationary := []
	for ship: Node in encounters:
		var encounter: Dictionary = encounters[ship]
		if not encounter.give_way:
			continue
		var prediction: Dictionary = predictions[ship]
		if _released(encounter, ship, own, predictions):
			speed_cap = minf(speed_cap, _pass_cap(prediction, own, ship))
			continue
		if encounter.response == Response.YIELD and not passing and not _has_pass():
			_choose(encounter, ship, own, predictions) # Slowing gives more time: passing may become feasible.
			if encounter.response == Response.PASS:
				response_changes += 1
		if encounter.response == Response.PASS and not passing:
			passing = true
			primary = encounter
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

	if passing:
		state = State.PASSING
	elif speed_cap < INF:
		state = State.WAITING if _is_waiting(_locomotion) else State.YIELDING
	if passing:
		var shifted := _follower.aim_point + offset
		target = shifted
		if not routed:
			offset = shifted - _locomotion.destination # Direct move: Locomotion steers to the destination.


# Early release (cause B): a pass committed around a stationary ship is suspended (no
# shift, only the stationary pass cap) once the ship may turn back to where it is
# steered without the shift (the destination on a direct move, else the aim point):
# _release_clear(), and the turn fits within that distance at the current speed,
# v² · angle / (PLANNING_SHARE · lateral acceleration). While suspended only
# _release_clear() is rechecked; if it fails the pass resumes on its committed side.
# The encounter itself ends as before.
func _released(encounter: Dictionary, ship: Node, own: Dictionary, predictions: Dictionary) -> bool:
	encounter.released = false # Cause C baseline: early release disabled.
	return false
	if encounter.response != Response.PASS or not is_stationary(ship.get_node("Locomotion") as ShipLocomotion):
		encounter.released = false
		return false
	var goal := _unshifted_goal()
	var turn_fits := true
	if not encounter.released:
		var to_goal: Vector2 = goal - own.position
		var speed := _locomotion.velocity.length()
		if speed > EPSILON:
			turn_fits = speed * speed * absf(_locomotion.velocity.angle_to(to_goal)) / (PLANNING_SHARE * _locomotion.lateral_accel) <= to_goal.length()
	encounter.released = turn_fits and _release_clear(ship, goal, own, predictions)
	return encounter.released


# The ship is past the stationary ship (along its route) and so is the goal; the
# straight line to the goal keeps the route's obstacle clearance and every ship in
# range's separation (footprints + margin); no moving ship is in an encounter.
func _release_clear(ship: Node, goal: Vector2, own: Dictionary, predictions: Dictionary) -> bool:
	var center := (ship.get_node("Locomotion") as ShipLocomotion).planar_position
	var dir: Vector2 = own.dir
	if (own.position - center).dot(dir) <= 0.0 or (goal - center).dot(dir) < 0.0:
		return false
	if not _navigation.segment_clear(own.position, goal, _follower.line_clearance()):
		return false
	for other: Node in predictions:
		var check: Dictionary = predictions[other]
		if not check.in_range:
			continue
		var locomotion := other.get_node("Locomotion") as ShipLocomotion
		if other != ship and encounters.has(other) and not is_stationary(locomotion):
			return false
		var at := locomotion.planar_position
		var position: Vector2 = own.position
		if Geometry2D.get_closest_point_to_segment(at, position, goal).distance_to(at) < check.separation:
			return false
	return true


# Where Locomotion steers the ship without an avoidance shift.
func _unshifted_goal() -> Vector2:
	return _follower.aim_point if _follower.status == RouteFollower.RouteStatus.ROUTE else _locomotion.destination


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
