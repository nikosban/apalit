extends Node
## Stage 2 locomotion: bounded kinematics on the X/Z plane for its parent Node3D.
## Holds the ship's only movement state; the parent's transform is output only,
## written in _apply_motion().
##
## Phase 2.5 guided mode (station-controlled docking; not used by the game yet):
## guide() flies a fixed list of legs from rest, each a turn in place to a heading or
## a straight move to a point (forward or in reverse, heading held), within the given
## speed, acceleration, turn rate and turn acceleration capped by this ship's own.
## While guided the ship has no destination (so its RouteFollower does not steer and
## its avoidance stays neutral), steer() and avoid() input is ignored, move_to() is
## refused and counted, and the target heading follows the actual heading so nothing
## turns the ship when guidance ends. Every step still goes through _apply_motion()
## (collision; committed motion for Fuel); without propulsion the ship holds still.
##
## UX round (P3): face() asks a ship at rest without a destination to turn in place
## to a heading, with the ordinary step's bounded turn rate, turn acceleration and
## taper (no translation); refused while guided or with a destination; any new
## move_to(), guide() or place() replaces it with its own target heading.

enum HeadingMode { NONE, FACE, HOLD }

const BRAKE_MARGIN := 0.9 # Share of the estimated braking used for stopping speeds (estimate, not a guarantee).
const ARRIVE_DISTANCE := 0.05 # u
const ARRIVE_SPEED := 0.05 # u/s
const EPSILON := 0.000001
const BRAKE_SHARE_STEPS := 12 # Bisection steps for the cross-approach share left after braking.
const TURN_TAPER := 0.5 # Heading time constant = this × max turn rate / turn acceleration (provisional).
const STOP_SHARE := 0.8 # Guided mode: share of the deceleration limit its stopping profile plans with.
const COURSE_MIN_SPEED := 0.5 # u/s; Stage 6B.2: slower ships take a new course directly (turn in place).
const COURSE_DONE := 0.017 # rad (~1 degree); Stage 6B.2: the course turn ends this close to the steering direction.
const COURSE_LEAD := 60.0 # degrees; Stage 6B.2: how far a turning course may lead the actual travel.

@export var max_speed := 10.0 # u/s, forward
@export var max_reverse_speed := 4.0 # u/s
@export var max_lateral_speed := 3.0 # u/s
@export var forward_accel := 6.0 # u/s²
@export var reverse_accel := 3.0 # u/s²
@export var lateral_accel := 2.5 # u/s²
@export var max_turn_rate_deg := 120.0 # °/s
@export var turn_accel_deg := 240.0 # °/s²
@export var collision_path := NodePath("../../../PlanarCollision") # Stage 6 PlanarCollision (optional).

# Authoritative movement state. Vector2 = (X, Z). heading: Godot yaw in radians
# (0 = bow to -Z, positive = nose left); angular_velocity in rad/s, same sign.
var planar_position := Vector2.ZERO
var velocity := Vector2.ZERO
var heading := 0.0
var angular_velocity := 0.0

var destination := Vector2.ZERO
var has_destination := false
var arrived := false
var heading_mode := HeadingMode.NONE # FACE for normal moves, HOLD for short corrections; set per command.
var desired_velocity := Vector2.ZERO # Last step's desired velocity (debug display).
var speed_limit := 0.0 # Debug: last step's desired speed before the directional limits.
var speed_limit_reason := &"" # Debug: the constraint that set it (max, stop, turn, arrive, combat, route, avoid).

# Optional one-step input from Behavior. Ordinary movement remains unchanged without
# a fresh request; move_to/guide/place revoke a pending request before it can execute.
var combat_control := false # Debug: combat input applied in the last ordinary step.
var combat_heading := 0.0
var combat_speed_cap := INF
var _combat_requested := false
var _combat_previous := false
var _combat_point := Vector2.INF # Stage 6B.2: one-step direct-leg steering point (INF: none).
var _course := Vector2.ZERO # Stage 6B.2: travel direction being turned onto a new command's course (ZERO: none).
var _course_rate := 0.0 # rad/s, Vector2 rotation sign.

var _target_heading := 0.0
var _heading_frozen := false # FACE: stop re-aiming once braking has begun.
var _steering := false # Route input (steer()) active for the current command.
var _steer_point := Vector2.ZERO
var _steer_remaining := 0.0
var _steer_speed_cap := INF
var _last_target_heading := 0.0
var _target_fresh := true # The target heading was just set by a command (no rate yet).
var _avoid_offset := Vector2.ZERO # Avoidance input (Stage 4): shift of the steering point.
var _avoid_speed_cap := INF
var avoidance_cap := INF # Avoidance speed cap applied in the last step (read by other ships' avoidance).
var propulsion := true # Phase 2 Stage 4: false (out of fuel, set by Fuel) = immobilized; orders kept.

# Guided mode (Phase 2.5).
var guided := false
var guided_leg := -1 # Index of the current leg.
var guided_order_errors := 0 # move_to() calls refused during guidance (should never happen).
var _legs: Array = [] # {turn: heading} or {move: point, reverse: bool}
var _guided_speed := 0.0 # Along the current move leg (>= 0).
var _guide_speed := 0.0 # u/s
var _guide_accel := 0.0 # u/s²
var _guide_turn_rate := 0.0 # rad/s
var _guide_turn_accel := 0.0 # rad/s²

# Collision enforcement (Stage 6), last step and since place() (debug and tests).
var proposed_motion := Vector2.ZERO # Displacement the step asked for.
var committed_motion := Vector2.ZERO # Displacement committed after collision.
var contacts: Array = [] # Contacts constraining the last step: {blocker, normal, point, gap, swept}.
var collision_count := 0 # Contacts begun (with a blocker not in contact the step before).
var blocked_time := 0.0 # s with the step's displacement constrained.
var contact_limit_count := 0 # Steps whose motion ran out of contact resolutions.
var collision_usec := 0 # Cost of the last step's collision query.
var _touching := {} # blocker -> true (contacts of the step before)

@onready var _ship: Node3D = get_parent()
@onready var _collision := get_node_or_null(collision_path) # Optional: absent, nothing is enforced.


func _ready() -> void:
	planar_position = Vector2(_ship.global_position.x, _ship.global_position.z)
	heading = _ship.global_rotation.y
	_target_heading = heading


func _physics_process(delta: float) -> void:
	_step(delta)


## New destination, accepted immediately; velocity and angular velocity carry over.
## allow_hold = false: never treat the move as a short correction (route orders).
## turn_course (Stage 6B.2): a ship under way turns its travel onto the new course
## (_turn_course()) instead of being redirected at once; given by RouteFollower only.
func move_to(point: Vector2, allow_hold := true, turn_course := false) -> void:
	if guided:
		guided_order_errors += 1
		push_error("%s: move_to() ignored during guided movement" % _ship.name)
		return
	_combat_requested = false
	combat_control = false
	combat_speed_cap = INF
	destination = point
	has_destination = true
	arrived = false
	_heading_frozen = false
	_steering = false
	var offset := point - planar_position
	if offset.length() > EPSILON and not (allow_hold and _is_short_correction(offset)):
		heading_mode = HeadingMode.FACE
		# Stage 6B.2: a ship under way turns its travel onto the new course (see _turn_course());
		# its heading request stays continuous, so the turn-rate history is kept too.
		# It starts from the last requested travel; a course turn already under way continues.
		if turn_course and velocity.length() > COURSE_MIN_SPEED and propulsion:
			if _course == Vector2.ZERO:
				_course = desired_velocity.normalized() if desired_velocity.length() > EPSILON else velocity.normalized()
				_course_rate = -angular_velocity # Vector2 rotation sign (yaw + = nose left).
			return
		_course = Vector2.ZERO
		_target_fresh = true
		_target_heading = _bearing_heading(offset)
	else:
		_course = Vector2.ZERO
		_target_fresh = true
		heading_mode = HeadingMode.HOLD
		_target_heading = heading


## Idle facing request (UX round, mining): without a destination and not guided,
## the ship turns in place toward `new_heading` through the ordinary step's rotation.
## Returns false (nothing changed) while guided or with a destination.
func face(new_heading: float) -> bool:
	if guided or has_destination:
		return false
	_target_heading = wrapf(new_heading, -PI, PI)
	_last_target_heading = _target_heading
	_target_fresh = true
	_heading_frozen = false
	return true


## A fresh autonomous-combat input, before this tick's ordinary step. Never changes
## velocity, route, acceleration or turn limits. Refreshing a route preserves combat
## heading-rate history when Behavior renews this input in the same tick.
## Stage 6B.2: steer_point (optional, this step only) replaces the steering point (the
## destination, or the route's aim point) for this step; braking still uses the
## destination or route distance, and route and avoidance speed caps still apply. The
## caller gives it only for a leg without route corners whose line from the ship is clear.
func combat_motion(new_heading: float, speed_cap: float, steer_point := Vector2.INF) -> bool:
	if guided or not has_destination:
		return false
	combat_heading = wrapf(new_heading, -PI, PI)
	combat_speed_cap = maxf(0.0, speed_cap)
	_combat_point = steer_point
	_combat_requested = true
	return true


func release_combat_motion() -> void:
	var was_combat := combat_control or _combat_requested
	_combat_requested = false
	_combat_previous = false
	combat_control = false
	combat_speed_cap = INF
	if was_combat and not has_destination:
		_hold_heading()


## Cancel only an owned destination; ordinary bounded acceleration brakes the ship.
## The caller clears its RouteFollower first. Collision still constrains every step.
func cancel_move() -> void:
	has_destination = false
	_course = Vector2.ZERO
	arrived = false
	_steering = false
	_avoid_offset = Vector2.ZERO
	_avoid_speed_cap = INF
	release_combat_motion()
	_hold_heading()


## Route input for the current command (Stage 3): steer toward aim_point while
## braking for remaining_distance (route length to the destination), at most at
## speed_cap (the route speed profile). Set every physics tick before _step();
## cleared by move_to(). Arrival is unchanged.
func steer(aim_point: Vector2, remaining_distance: float, speed_cap := INF) -> void:
	_steering = true
	_steer_point = aim_point
	_steer_remaining = remaining_distance
	_steer_speed_cap = speed_cap


## Avoidance input (Stage 4), set every physics tick before _step() by ShipAvoidance:
## the steering point (aim point, or the destination on a direct move) is shifted by
## offset and the desired speed is limited to speed_cap. The braking distance and
## arrival still use the unshifted point. Neutral: (Vector2.ZERO, INF).
func avoid(offset: Vector2, speed_cap := INF) -> void:
	_avoid_offset = offset
	_avoid_speed_cap = speed_cap


## Debug and test placement only (scenario setup): puts the ship at rest at a point
## and heading, with no destination. Not used by movement.
func place(point: Vector2, new_heading: float) -> void:
	release_combat_motion()
	guided = false
	guided_leg = -1
	_legs = []
	_guided_speed = 0.0
	has_destination = false
	_course = Vector2.ZERO
	arrived = false
	heading_mode = HeadingMode.NONE
	_steering = false
	_heading_frozen = false
	_target_heading = new_heading
	_avoid_offset = Vector2.ZERO
	_avoid_speed_cap = INF
	avoidance_cap = INF
	planar_position = point
	heading = new_heading
	collision_count = 0
	blocked_time = 0.0
	contact_limit_count = 0
	_touching.clear()
	_apply_motion(Vector2.ZERO, 0.0, 0.0)


## Guided mode: flies `legs` from rest ({turn: heading} or {move: point, reverse:
## bool}) within the given limits, each capped by this ship's own; any destination
## and steering or avoidance input are dropped.
func guide(legs: Array, speed: float, accel: float, turn_rate_deg: float, turn_accel_deg_limit: float) -> void:
	release_combat_motion()
	has_destination = false
	_course = Vector2.ZERO
	arrived = false
	heading_mode = HeadingMode.NONE
	_steering = false
	_avoid_offset = Vector2.ZERO
	_avoid_speed_cap = INF
	_legs = legs
	_guide_speed = speed
	_guide_accel = accel
	_guide_turn_rate = deg_to_rad(minf(turn_rate_deg, max_turn_rate_deg))
	_guide_turn_accel = deg_to_rad(minf(turn_accel_deg_limit, turn_accel_deg))
	_guided_speed = 0.0
	guided_leg = 0
	guided = not legs.is_empty()
	_hold_heading()


## The ship's position, then the end points of the guided move legs still to fly.
func remaining_points() -> PackedVector2Array:
	var points := PackedVector2Array([planar_position])
	if guided:
		for i in range(guided_leg, _legs.size()):
			if _legs[i].has("move"):
				points.append(_legs[i].move)
	return points


func distance_to_destination() -> float:
	return destination.distance_to(planar_position)


## Velocity in the ship frame: x = forward, y = right.
func local_velocity() -> Vector2:
	return _to_local(velocity)


func get_status() -> String:
	if has_destination:
		return "MOVING"
	return "ARRIVED" if arrived else "IDLE"


func _step(delta: float) -> void:
	if guided:
		release_combat_motion()
		_guided_step(delta)
		return
	combat_control = _combat_requested and has_destination
	_combat_requested = false
	desired_velocity = Vector2.ZERO
	speed_limit = 0.0
	speed_limit_reason = &""
	# Without propulsion the ship's available speed is reported as 0 (waiting, i.e.
	# stationary to the other ships' avoidance).
	avoidance_cap = _avoid_speed_cap if propulsion else 0.0
	var base := _steer_point if _steering else destination
	if combat_control and _combat_point.is_finite():
		base = _combat_point
	if has_destination:
		var offset := base + _avoid_offset - planar_position
		var distance := offset.length()
		if distance > EPSILON:
			var steering := offset / distance
			var direction := _turn_course(steering, delta)
			var remaining := _steer_remaining if _steering else (base - planar_position).length()
			var stop_speed := sqrt(2.0 * BRAKE_MARGIN * _braking_accel(direction) * remaining)
			speed_limit_reason = &"max"
			var speed := _limit(max_speed, stop_speed, &"stop")
			speed = _limit(speed, _turn_speed(steering, distance), &"turn")
			speed = _limit(speed, distance / delta, &"arrive")
			if combat_control:
				speed = _limit(speed, combat_speed_cap, &"combat")
			if _steering:
				speed = _limit(speed, _steer_speed_cap, &"route")
			speed = _limit(speed, _avoid_speed_cap, &"avoid")
			speed_limit = speed
			var intended := direction * speed
			if heading_mode == HeadingMode.FACE and not _heading_frozen:
				if stop_speed <= velocity.length():
					_heading_frozen = true
				else:
					# Aim between actual and intended travel: the bow leads the velocity
					# through a redirect instead of outrunning it; aligned, this is the bearing.
					var aim := velocity + intended
					_target_heading = _bearing_heading(aim if aim.length() > EPSILON else offset)
			# Directional speed limits (forward / reverse / lateral) apply to the desired
			# velocity only; any actual velocity beyond them is removed by the acceleration below.
			desired_velocity = _from_local(_limit_speed(_to_local(intended)))
	if combat_control:
		_target_heading = combat_heading
		if _combat_previous:
			_target_fresh = false
	_combat_previous = combat_control

	# Translation: bounded acceleration toward the desired velocity, limited in the ship frame.
	var wanted := (desired_velocity - velocity) / delta
	var accel := _limit_accel(_to_local(wanted))
	# Braking priority: while the ship must slow along its approach (toward the
	# steering point or destination), that braking is limited into the ellipse first
	# and the cross-approach correction gets the remaining capacity.
	var approach := Vector2.ZERO
	if has_destination:
		approach = _course if _course != Vector2.ZERO else (base + _avoid_offset - planar_position).normalized()
	var along := wanted.dot(approach)
	if along < 0.0:
		var brake := _limit_accel(_to_local(approach * along))
		var cross := _to_local(wanted - approach * along)
		var share := 1.0
		if _ellipse_size(brake + cross) > 1.0:
			var low := 0.0
			var high := 1.0
			for i in BRAKE_SHARE_STEPS:
				var middle := (low + high) * 0.5
				if _ellipse_size(brake + cross * middle) <= 1.0:
					low = middle
				else:
					high = middle
			share = low
		accel = brake + cross * share
	var new_velocity := velocity + (_forward() * accel.x + _right() * accel.y) * delta

	# Without propulsion (Phase 2 Stage 4, out of fuel) the ship holds still: no drift
	# and no velocity kept for later; the order is kept.
	if not propulsion:
		new_velocity = Vector2.ZERO

	# Numerical settling exception to bounded acceleration: inside the arrival
	# threshold the remaining velocity (< ARRIVE_SPEED) is set to zero.
	if has_destination and distance_to_destination() < ARRIVE_DISTANCE and new_velocity.length() < ARRIVE_SPEED:
		new_velocity = Vector2.ZERO
		has_destination = false
		arrived = true
		_course = Vector2.ZERO

	# Rotation: bounded angular acceleration toward the target heading.
	var error := wrapf(_target_heading - heading, -PI, PI)
	var max_rate := deg_to_rad(max_turn_rate_deg)
	var turn_accel := deg_to_rad(turn_accel_deg)
	# Small errors close proportionally (rate = error / time constant) instead of at
	# the fastest possible rate, so small course changes are gentle and settle without
	# overshoot; larger errors keep the maximum rate and the deceleration profile.
	# The target heading's own rate of change is followed directly (not on the first
	# step of a command, where the target jumps), so a moving target is not lagged.
	var target_rate := 0.0
	if not _target_fresh:
		target_rate = wrapf(_target_heading - _last_target_heading, -PI, PI) / delta
	_target_fresh = false
	_last_target_heading = _target_heading
	var time_constant := maxf(TURN_TAPER * max_rate / turn_accel, delta)
	var correction := signf(error) * minf(sqrt(2.0 * BRAKE_MARGIN * turn_accel * absf(error)), absf(error) / time_constant)
	var desired_rate := clampf(target_rate + correction, -max_rate, max_rate)
	var new_angular_velocity := angular_velocity + clampf(desired_rate - angular_velocity, -turn_accel * delta, turn_accel * delta)
	if not propulsion:
		new_angular_velocity = 0.0 # Heading held, no turn rate kept.

	_apply_motion(new_velocity, new_angular_velocity, delta)


# The only place calculated movement is applied to the state and the ship.
# Collision (Stage 6): PlanarCollision limits the displacement and removes the
# velocity components into its contacts before they are committed here; with no
# contact both pass unchanged. Rotation is never constrained (circular footprints).
func _apply_motion(new_velocity: Vector2, new_angular_velocity: float, delta: float) -> void:
	var motion := new_velocity * delta
	proposed_motion = motion
	contacts = []
	if _collision != null and delta > 0.0:
		var start_usec := Time.get_ticks_usec()
		var resolved: Dictionary = _collision.resolve(_ship, planar_position, motion, new_velocity)
		collision_usec = Time.get_ticks_usec() - start_usec
		motion = resolved.motion
		new_velocity = resolved.velocity
		contacts = resolved.contacts
		_count_contacts(resolved, delta)
	committed_motion = motion
	velocity = new_velocity
	angular_velocity = new_angular_velocity
	planar_position += motion
	heading = wrapf(heading + angular_velocity * delta, -PI, PI)
	_ship.global_position = Vector3(planar_position.x, _ship.global_position.y, planar_position.y)
	_ship.global_rotation = Vector3(0.0, heading, 0.0)


# One guided step: the current leg's speed (or turn rate) moves toward the stopping
# profile within the acceleration limits; a leg ends once arrived and at rest.
func _guided_step(delta: float) -> void:
	avoidance_cap = INF if propulsion else 0.0
	var leg: Dictionary = _legs[guided_leg]
	var new_velocity := Vector2.ZERO
	var new_rate := 0.0
	if leg.has("turn"):
		var error := wrapf(leg.turn - heading, -PI, PI)
		var want := signf(error) * minf(minf(_guide_turn_rate, _stop_speed(_guide_turn_accel, absf(error), delta)), absf(error) / delta)
		new_rate = angular_velocity + clampf(want - angular_velocity, -_guide_turn_accel * delta, _guide_turn_accel * delta)
	else:
		var reverse: bool = leg.reverse
		var top := minf(_guide_speed, max_reverse_speed if reverse else max_speed)
		var accel := minf(_guide_accel, reverse_accel if reverse else forward_accel)
		var brake := minf(_guide_accel, forward_accel if reverse else reverse_accel)
		var offset: Vector2 = leg.move - planar_position
		var distance := offset.length()
		var want := minf(top, _stop_speed(brake, distance, delta))
		_guided_speed = clampf(want, _guided_speed - brake * delta, _guided_speed + accel * delta)
		_guided_speed = minf(_guided_speed, distance / delta)
		if distance > EPSILON:
			new_velocity = offset / distance * _guided_speed
		new_rate = angular_velocity + clampf(-angular_velocity, -_guide_turn_accel * delta, _guide_turn_accel * delta)
	if not propulsion:
		new_velocity = Vector2.ZERO
		new_rate = 0.0
	desired_velocity = new_velocity
	_apply_motion(new_velocity, new_rate, delta)
	_hold_heading()
	var done := false
	if leg.has("turn"):
		done = absf(wrapf(leg.turn - heading, -PI, PI)) < 0.0001 and absf(angular_velocity) < 0.000001
	else:
		_guided_speed = minf(_guided_speed, velocity.length()) # A contact or no propulsion removed part of it.
		done = planar_position.distance_to(leg.move) < 0.001 and _guided_speed < 0.000001
	if done:
		velocity = Vector2.ZERO
		angular_velocity = 0.0
		_guided_speed = 0.0
		guided_leg += 1
		if guided_leg >= _legs.size():
			guided = false
			guided_leg = -1
			_legs = []


# The ordinary step keeps turning toward its own target heading; during guidance and
# at hand-back that target is the actual heading, so the ship does not swing back to
# the bearing of its last ordinary order when guidance ends.
func _hold_heading() -> void:
	_target_heading = heading
	_last_target_heading = heading
	_target_fresh = true
	_heading_frozen = false


# Speed from which slowing by STOP_SHARE × decel every tick covers exactly `distance`
# (n ticks at n, n - 1, ... 1 steps of the per-tick change, the last one landing).
static func _stop_speed(decel: float, distance: float, delta: float) -> float:
	var step := STOP_SHARE * decel * delta
	return step * (sqrt(2.0 * distance / (step * delta) + 0.25) - 0.5)


func _count_contacts(resolved: Dictionary, delta: float) -> void:
	var touching := {}
	for contact: Dictionary in resolved.contacts:
		touching[contact.blocker] = true
		if not _touching.has(contact.blocker):
			collision_count += 1
	_touching = touching
	if resolved.motion != proposed_motion:
		blocked_time += delta
	if resolved.exhausted:
		contact_limit_count += 1


# Deceleration available against the current velocity (or, at rest, against the
# approach direction) with the current heading. An estimate: the heading may change.
func _braking_accel(direction: Vector2) -> float:
	var brake_direction := -velocity.normalized() if velocity.length() > EPSILON else -direction
	return _accel_limit(_to_local(brake_direction))


# Largest acceleration along a unit direction in the ship frame (limit ellipse).
func _accel_limit(local_direction: Vector2) -> float:
	var axis_limit := forward_accel if local_direction.x >= 0.0 else reverse_accel
	return 1.0 / sqrt(pow(local_direction.x / axis_limit, 2) + pow(local_direction.y / lateral_accel, 2))


# Size of a ship-frame acceleration relative to the limit ellipse (1 = on the limit).
func _ellipse_size(local_accel: Vector2) -> float:
	var axis_limit := forward_accel if local_accel.x >= 0.0 else reverse_accel
	return sqrt(pow(local_accel.x / axis_limit, 2) + pow(local_accel.y / lateral_accel, 2))


# Scales a ship-frame acceleration into the limit ellipse, keeping its direction.
func _limit_accel(local_accel: Vector2) -> Vector2:
	var axis_limit := forward_accel if local_accel.x >= 0.0 else reverse_accel
	var size := sqrt(pow(local_accel.x / axis_limit, 2) + pow(local_accel.y / lateral_accel, 2))
	return local_accel / size if size > 1.0 else local_accel


# Short correction (HOLD): a move too short to reach the ship's speed limit in that
# direction (current heading) before it would have to brake again.
func _is_short_correction(offset: Vector2) -> bool:
	var local := _to_local(offset.normalized())
	var cruise := _limit_speed(local * max_speed).length()
	var ramp_distance := cruise * cruise * 0.5 * (1.0 / _accel_limit(local) + 1.0 / _accel_limit(-local))
	return offset.length() <= ramp_distance


# Speed that lets the actual velocity turn onto the destination direction within the
# remaining distance: at speed s, turning the velocity by angle a with acceleration
# A covers about s² · a / A, so s ≤ √(A · distance / a). No limit when aligned or at rest.
func _turn_speed(direction: Vector2, distance: float) -> float:
	var speed := velocity.length()
	if speed <= EPSILON:
		return INF
	var travel := velocity / speed
	var angle := absf(travel.angle_to(direction))
	if angle <= EPSILON:
		return INF
	var push := (direction - travel).normalized()
	return sqrt(BRAKE_MARGIN * _accel_limit(_to_local(push)) * distance / angle)


# Stage 6B.2: after a new command reaches a ship under way, its travel direction turns
# from where it was onto the new steering direction with the hull's own turn rate and
# turn acceleration (starting from the turn rate it had), instead of being redirected
# at once; translation and the FACE heading request then follow one continuous course
# and a reversal becomes a turn. Avoidance input, combat input, lost propulsion or a
# slow ship end it at once (the plain steering direction applies, as before).
func _turn_course(direction: Vector2, delta: float) -> Vector2:
	if _course == Vector2.ZERO:
		return direction
	if combat_control or _avoid_offset != Vector2.ZERO or _avoid_speed_cap < INF or not propulsion \
			or velocity.length() < COURSE_MIN_SPEED * 0.5:
		_course = Vector2.ZERO
		return direction
	var max_rate := deg_to_rad(max_turn_rate_deg)
	var turn_accel := deg_to_rad(turn_accel_deg)
	var error := _course.angle_to(direction)
	if absf(absf(error) - PI) < 0.001 and _course_rate != 0.0:
		error = absf(error) * signf(_course_rate) # Straight behind: keep turning the way it turns.
	if absf(error) < COURSE_DONE and absf(_course_rate) < turn_accel * delta * 2.0:
		_course = Vector2.ZERO
		return direction
	var wanted := signf(error) * minf(max_rate, sqrt(2.0 * BRAKE_MARGIN * turn_accel * absf(error)))
	_course_rate = move_toward(_course_rate, wanted, turn_accel * delta)
	var step := _course_rate * delta
	if signf(step) == signf(error) and absf(step) > absf(error):
		step = error
	var turned := _course.rotated(step)
	# The course leads the actual travel by at most COURSE_LEAD: the bow (aimed between
	# them) leads by about half, so forward thrust carries the turn rather than the hull
	# swinging round ahead of a ship still sliding on its old line. Held there, the course
	# turns as fast as the travel does (its rate follows, so it cannot wind up).
	var travel := velocity.normalized()
	var lead := travel.angle_to(turned)
	if absf(lead) > deg_to_rad(COURSE_LEAD):
		turned = travel.rotated(signf(lead) * deg_to_rad(COURSE_LEAD))
		_course_rate = _course.angle_to(turned) / delta
	_course = turned
	return _course


# The lower of a speed and a limit; a binding limit is recorded as the step's reason (debug).
func _limit(speed: float, limit: float, reason: StringName) -> float:
	if limit < speed:
		speed_limit_reason = reason
		return limit
	return speed


# Scales a ship-frame velocity into the speed-limit ellipse (forward / reverse / lateral).
func _limit_speed(local_velocity: Vector2) -> Vector2:
	var axis_limit := max_speed if local_velocity.x >= 0.0 else max_reverse_speed
	var size := sqrt(pow(local_velocity.x / axis_limit, 2) + pow(local_velocity.y / max_lateral_speed, 2))
	return local_velocity / size if size > 1.0 else local_velocity


## Heading whose bow points along `offset` (the ship's heading convention).
func bearing_heading(offset: Vector2) -> float:
	return _bearing_heading(offset)


func _bearing_heading(offset: Vector2) -> float:
	return atan2(-offset.x, -offset.y)


func _forward() -> Vector2:
	return Vector2(-sin(heading), -cos(heading))


func _right() -> Vector2:
	return Vector2(cos(heading), -sin(heading))


func _to_local(vector: Vector2) -> Vector2:
	return Vector2(vector.dot(_forward()), vector.dot(_right()))


func _from_local(local: Vector2) -> Vector2:
	return _forward() * local.x + _right() * local.y
