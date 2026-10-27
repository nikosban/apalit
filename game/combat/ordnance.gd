extends Node3D
## Combat (migrated from the prototype v0.3): one guided torpedo or missile (created and stepped by the
## projectile system, which also resolves its collisions). Its node transform is the
## simulation state: position, and the basis whose −Z is the nose. The model, plume,
## attitude thrusters and trail are drawn from that state; nothing visual feeds back.
##
## Guidance point: while its assigned target is a live hostile in contact, the target's
## first-order intercept point (target velocity, own speed); without contact, or once
## the target is destroyed, its last known position (no lead); once that is reached
## without contact, none (it flies on). Contact returning restores target guidance. It
## never takes another target and reveals nothing about hidden ships.
##
## Torpedo: constant speed along the nose (velocity = nose × speed); straight for the
## arming distance, then the nose turns toward the guidance point at most turn_rate ×
## dt per tick (in 3D; with ships on one plane it stays level). No obstacle avoidance.
## A target that manoeuvres early enough makes it miss; after a miss it keeps steering
## but its turning circle is far larger than the engagement, so it runs on until its
## technical limit (lifetime / travel) without looping back (measured; no terminal rule).
##
## Missile: (1) ejection along the launch axis at eject_speed, no turning, no thrust,
## until `clearance` from the launch point and clear of its own hull boxes by
## hull_margin; (2) orientation: it keeps drifting with the ejection velocity while the
## nose turns toward the wanted direction at orient_rate (attitude thrusters, no main
## thrust) until within powered_within_deg; (3) powered pursuit: main thrust accelerates
## it along the nose (velocity integrated, capped at max_speed: momentum is kept, so
## velocity lags the nose in a turn and it can overshoot) while the nose turns at
## turn_rate toward the steering command: the velocity change needed to fly the wanted
## direction at max_speed, or, once the velocity is within steering_deadband_deg of the
## wanted direction, that direction itself (guidance stability: without it the nose
## swings across a small error at the speed cap, reversing every tick). Local avoidance bends the wanted direction toward the clear
## edge of the nearest obstacle sphere ahead (asteroids, ships other than its target and
## its own ship): over, under or around as the geometry gives. At flight_time it
## self-destructs.
##
## FF-01 profiles (positive transition_timeout): world-height clearance, inherited release
## velocity, bounded post-clearance transition. Wayfarer retains its drifting orientation
## and powered guidance. Barrage turns at ejection speed toward its immutable dispersed
## salvo point, steering both the nose and world velocity finitely. It commits the
## achieved velocity ray, then accelerates along that fixed ray to cruise speed; it
## never reads contacts or target motion. Launch travel counts toward the same limits.
## Legacy ordnance with zero timeout retains its previous launch behavior.

const WeaponGeometry := preload("res://game/weapons/weapon_geometry.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const CombatObstacles := preload("res://game/combat/combat_obstacles.gd")
const GuidedMissileConfig := preload("res://game/weapons/guided_missile_config.gd")
const RCS_HOLD := 0.1 # s a thruster stays lit after a turn above the threshold
const RCS_THRESHOLD_DEG := 15.0 # °/s of measured turn about an axis lights its thruster

var id := 0
var kind := &"torpedo"
var config: Resource # OrdnanceConfig
var damage := 0.0
var penetration: Variant = null # null = unconfigured (bypasses armor)
var armor_damage := 0.0
var owner_ship: Node3D
var owner_id := 0
var owner_name := ""
var owner_combat = null
var faction := 0
var target: Node3D
var target_name := ""
var target_id := 0 # Assigned identity remains meaningful after the target node is freed.
var strict_flight_expiration := false # New guided-missile family only; legacy semantics unchanged.
var contacts = null
var live := true
var finished := "" # Set when it ends by itself (expired, self_destruct).

var velocity := Vector3.ZERO
var phase := "" # torpedo: arming, guided; missile: eject, orient, powered; rocket: eject, orient, flight
var age := 0.0
var traveled := 0.0
var launch_point := Vector3.ZERO
var launch_axis := Vector3.FORWARD
var profiled_launch := false
var inherited_velocity := Vector3.ZERO # Captured once at release, never follows its owner.
var transition_elapsed := 0.0 # Starts after clearance; does not include ejection.
var locked_point := Vector3.ZERO # Rockets only: immutable salvo solution, no tracking.
var dispersion := Basis.IDENTITY # Rockets only: per-release fixed dispersion rotation.
var rocket_cruise_direction := Vector3.ZERO # Actual world velocity direction frozen at commitment.
var prev_position := Vector3.ZERO
var last_known := Vector3.ZERO
var has_contact := false
var has_goal := false
var goal := Vector3.ZERO
var avoiding := false
var wanted_direction := Vector3.ZERO # Missile: the last wanted direction (guidance + avoidance).
var avoided: Array[String] = [] # Obstacles it steered around (tests, debug).
var turn_last := 0.0 # rad, nose turn in the last tick
var turn_local := Vector2.ZERO # rad, last tick's nose turn about the local Y (x) and X (y) axes
var rcs_left: Array[float] = [0.0, 0.0, 0.0, 0.0] # +X, −X, +Y, −Y thrusters
var thrusting := false
var trail: Array[Vector3] = [] # Nozzle positions of the recent ticks with the engine lit, newest last.
var trail_ages: Array[float] = []

var _plume: Node3D
var _rcs: Array = []
var _target_combat = null


func setup(new_id: int, owner_node: Node3D, new_faction: int, weapon_config: Resource, new_target: Node3D, contact_board: Variant, remembered_target: Dictionary = {}) -> void:
	id = new_id
	config = weapon_config.ordnance
	kind = config.kind
	damage = weapon_config.damage
	penetration = weapon_config.resolved_penetration()
	armor_damage = weapon_config.armor_damage
	owner_ship = owner_node
	owner_id = owner_node.get_instance_id()
	owner_name = String(owner_node.name)
	owner_combat = CombatShip.of(owner_node)
	faction = new_faction
	target = new_target
	target_name = String(new_target.name) if new_target != null else ""
	target_id = new_target.get_instance_id() if new_target != null else 0
	strict_flight_expiration = weapon_config is GuidedMissileConfig
	profiled_launch = config.transition_timeout > 0.0 and (kind == &"rocket" or strict_flight_expiration)
	if kind == &"rocket":
		locked_point = remembered_target.get("locked_point", Vector3.ZERO)
		dispersion = remembered_target.get("dispersion", Basis.IDENTITY)
	if strict_flight_expiration and not remembered_target.is_empty():
		target_id = remembered_target.target_id
		target_name = remembered_target.target_name
		last_known = remembered_target.position
		goal = last_known
		has_goal = true
	_target_combat = CombatShip.of(new_target)
	contacts = contact_board
	name = "%s%d" % [{&"torpedo": "Torpedo", &"rocket": "Rocket"}.get(kind, "Missile"), id]


func begin(origin: Transform3D) -> void:
	global_transform = origin
	launch_point = origin.origin
	prev_position = origin.origin
	launch_axis = -origin.basis.z.normalized()
	if profiled_launch:
		inherited_velocity = owner_combat.velocity() if owner_combat != null else Vector3.ZERO
	var parts := WeaponGeometry.build_ordnance(self, kind, config.length, config.body_radius, faction)
	_plume = parts.plume
	_rcs = parts.rcs
	_plume.nozzle_scale = config.thruster_scale
	_plume.length_multiplier = config.thruster_length
	for jet: Node3D in _rcs:
		jet.nozzle_scale = config.rcs_scale
	if kind == &"torpedo":
		phase = "arming"
		velocity = launch_axis * config.speed
	elif kind == &"rocket" and not profiled_launch:
		phase = "flight"
		velocity = launch_axis * config.speed
	else:
		phase = "eject"
		velocity = launch_axis * config.eject_speed + inherited_velocity
	if kind != &"rocket":
		_update_contact()
	_record_trail(0.0)
	_update_visuals(0.0)


func forward() -> Vector3:
	return -global_basis.z.normalized()


## The nozzle exit (rear end of the model, on its axis).
func nozzle_position() -> Vector3:
	return global_transform * Vector3(0.0, 0.0, config.length * 0.5)


func speed() -> float:
	return velocity.length()


## Seconds of flight left (missile flight time or the technical lifetime).
func remaining_time() -> float:
	var limit: float = config.flight_time if kind == &"missile" and config.flight_time > 0.0 else config.lifetime
	return maxf(0.0, limit - age)


## Still steering at a guidance point (its target or the target's last known position).
func homing() -> bool:
	return has_goal


## Still in a launch stage (missile ejection / orientation, torpedo arming).
func launching() -> bool:
	return phase in ["eject", "orient", "arming"]


func step(delta: float, _system: Node) -> void:
	if strict_flight_expiration:
		delta = minf(delta, maxf(0.0, config.flight_time - age))
	elif profiled_launch:
		delta = minf(delta, maxf(0.0, config.lifetime - age))
	prev_position = global_position
	if kind != &"rocket":
		_update_contact()
	var before := forward()
	if kind == &"torpedo":
		_step_torpedo(delta)
	elif kind == &"missile":
		_step_missile(delta)
	elif kind == &"rocket" and profiled_launch:
		_step_rocket(delta)
	if profiled_launch and kind == &"rocket":
		delta = minf(delta, maxf(0.0, config.max_travel - traveled) / maxf(velocity.length(), 0.000001))
	age += delta
	global_position += velocity * delta
	traveled += velocity.length() * delta
	global_basis = global_basis.orthonormalized()
	_measure_turn(before, delta)
	_record_trail(delta)
	_update_visuals(delta)
	if strict_flight_expiration and age >= config.flight_time - 0.000000000001:
		age = config.flight_time
		finished = "self_destruct"
	elif not strict_flight_expiration and kind == &"missile" and config.flight_time > 0.0 and age >= config.flight_time - 0.000001:
		finished = "self_destruct"
	elif age >= config.lifetime - 0.000001 or traveled >= config.max_travel - 0.000001:
		finished = "expired"


# --- Guidance -------------------------------------------------------------------------

func _update_contact() -> void:
	var valid: bool = _target_combat != null and is_instance_valid(target) and target.is_inside_tree() \
		and _target_combat.alive and not _target_combat.removed_from_play and _target_combat.faction != faction
	has_contact = valid and (contacts == null or contacts.observable(faction, target))
	if has_contact:
		last_known = target.global_position
		has_goal = true
		goal = _intercept(target.global_position, _target_combat.velocity(), _guidance_speed())
	elif has_goal:
		goal = last_known
		if global_position.distance_to(last_known) <= config.arrival_distance:
			has_goal = false # Reached the last known position: flies on until contact returns.


func _guidance_speed() -> float:
	return config.speed if kind == &"torpedo" else config.max_speed


func _intercept(position: Vector3, target_velocity: Vector3, own_speed: float) -> Vector3:
	var offset := position - global_position
	var a := target_velocity.dot(target_velocity) - own_speed * own_speed
	var b := 2.0 * offset.dot(target_velocity)
	var c := offset.dot(offset)
	var time := -1.0
	if absf(a) < 0.000001:
		time = -c / b if absf(b) > 0.000001 else -1.0
	else:
		var discriminant := b * b - 4.0 * a * c
		if discriminant >= 0.0:
			var root := sqrt(discriminant)
			for t in [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]:
				if t > 0.0 and (time < 0.0 or t < time):
					time = t
	return position + target_velocity * time if time > 0.0 else position


func _step_torpedo(delta: float) -> void:
	if phase == "arming" and traveled >= config.arming_distance - 0.000001:
		phase = "guided"
	if phase == "guided" and has_goal:
		_turn_toward(goal - global_position, deg_to_rad(config.turn_rate_deg) * delta)
	velocity = forward() * config.speed


func _step_missile(delta: float) -> void:
	thrusting = false
	match phase:
		"eject":
			if _reached_clearance() and _clear_of_owner():
				phase = "orient"
		"orient":
			var wanted := _wanted_direction()
			var turn_delta := _transition_step(delta)
			_turn_toward(wanted, deg_to_rad(config.orient_rate_deg) * turn_delta)
			if rad_to_deg(forward().angle_to(wanted)) <= config.powered_within_deg or _transition_expired():
				phase = "powered"
		"powered":
			var wanted := _wanted_direction()
			var top: float = config.max_speed
			var command := wanted * top - velocity
			# Dead band (guidance stability): flying within it of the wanted direction, the
			# nose points along the wanted direction instead of across the small error.
			var band: float = config.steering_deadband_deg
			if command.length() < 0.5 or (velocity.length() > 0.5 and rad_to_deg(velocity.angle_to(wanted)) <= band):
				command = wanted
			_turn_toward(command, deg_to_rad(config.turn_rate_deg) * delta)
			velocity += forward() * config.acceleration * delta
			if velocity.length() > config.max_speed:
				velocity = velocity.normalized() * config.max_speed
			thrusting = true


func _reached_clearance() -> bool:
	var clearance: float = global_position.y - launch_point.y if profiled_launch else launch_point.distance_to(global_position)
	return clearance >= config.clearance - 0.000001


func _transition_step(delta: float) -> float:
	if not profiled_launch:
		return delta
	var step := minf(delta, maxf(0.0, config.transition_timeout - transition_elapsed))
	transition_elapsed += step
	return step


func _transition_expired() -> bool:
	return profiled_launch and transition_elapsed >= config.transition_timeout - 0.000000000001


func _step_rocket(delta: float) -> void:
	match phase:
		"eject":
			if _reached_clearance() and _clear_of_owner():
				phase = "orient"
		"orient":
			# No target node/contact reads: only the immutable, dispersed salvo solution.
			var wanted := dispersion * (locked_point - global_position).normalized()
			var turn_limit := deg_to_rad(config.orient_rate_deg) * _transition_step(delta)
			_turn_toward(wanted, turn_limit)
			# Ejection includes ship motion: the nose and actual velocity need not agree.
			# Apply a bounded turn to that existing velocity, preserving its magnitude and
			# momentum continuously instead of rebuilding it from nose * speed.
			var direction := velocity.normalized()
			var angle := direction.angle_to(wanted)
			if angle > 0.0000001:
				var axis := direction.cross(wanted)
				if axis.length() < 0.000001:
					axis = global_basis.y if absf(global_basis.y.dot(direction)) < 0.99 else global_basis.x
				velocity = Basis(axis.normalized(), minf(angle, turn_limit)) * velocity
			var aligned := forward().angle_to(wanted) < 0.0001 and velocity.angle_to(wanted) < 0.0001
			if aligned or _transition_expired():
				phase = "flight"
				rocket_cruise_direction = velocity.normalized()
				# No change to position, heading or velocity at the phase boundary.
				return
		"flight":
			if rocket_cruise_direction == Vector3.ZERO:
				rocket_cruise_direction = velocity.normalized()
			velocity = velocity.move_toward(rocket_cruise_direction * config.speed, config.acceleration * delta)
			return # Engine changes speed only: never steer the committed ray again.


# The direction it wants to fly: toward the guidance point (else straight on), bent by
# local avoidance.
func _wanted_direction() -> Vector3:
	var wanted := forward()
	if has_goal and global_position.distance_to(goal) > 0.01:
		wanted = (goal - global_position).normalized()
	elif velocity.length() > 0.5 and phase == "powered":
		wanted = velocity.normalized()
	avoiding = false
	if config.avoidance:
		wanted = _avoid(wanted)
	wanted_direction = wanted
	return wanted


func _avoid(wanted: Vector3) -> Vector3:
	var top: float = config.max_speed
	var lookahead: float = config.avoid_lookahead
	var model_length: float = config.length
	var look := maxf(velocity.length(), top * 0.5) * lookahead + model_length
	var from := global_position
	var to := from + wanted * look
	var best_distance := INF
	var best_aim := Vector3.ZERO
	var best_name := ""
	for obstacle in _obstacles():
		var center: Vector3 = obstacle[0]
		var reach: float = obstacle[1]
		var closest := Geometry3D.get_closest_point_to_segment(center, from, to)
		if closest.distance_to(center) > reach or center.distance_to(from) <= reach * 0.5:
			continue
		var along := from.distance_to(closest)
		if along < best_distance:
			best_distance = along
			var away := closest - center
			if away.length() < 0.001:
				away = wanted.cross(Vector3.UP)
				if away.length() < 0.001:
					away = Vector3.RIGHT
			best_aim = center + away.normalized() * (reach + 0.5)
			best_name = obstacle[2]
	# Its own hull (it may still be above it): climb rather than cut through it.
	if owner_combat != null and is_instance_valid(owner_ship) and owner_combat.segment_fraction(from, to) >= 0.0:
		avoiding = true
		if not avoided.has("own hull"):
			avoided.append("own hull")
		return Vector3(wanted.x, maxf(wanted.y, 0.5), wanted.z).normalized()
	if best_distance == INF:
		return wanted
	avoiding = true
	if not avoided.has(best_name):
		avoided.append(best_name)
	return (best_aim - from).normalized()


# Obstacle spheres for avoidance: [center, radius + margin, name].
func _obstacles() -> Array:
	var found := []
	var asteroids = owner_combat.asteroids if owner_combat != null and is_instance_valid(owner_ship) else null
	if asteroids == null:
		var arena := get_parent().get_parent() if get_parent() != null else null
		asteroids = arena.get_node_or_null("Asteroids") if arena != null else null
	if asteroids != null and asteroids.has_method("ids"):
		for asteroid_id: int in asteroids.ids():
			found.append([asteroids.center(asteroid_id), asteroids.radius(asteroid_id) + config.avoid_margin, "asteroid %d" % asteroid_id])
	# Production world: station parts, as their bounding spheres (combat_obstacles.gd).
	if is_inside_tree():
		for node in get_tree().get_nodes_in_group(CombatObstacles.GROUP):
			var part := node as MeshInstance3D
			if part != null and part.mesh != null:
				var box := part.global_transform * part.get_aabb()
				found.append([box.get_center(), box.size.length() * 0.5 + config.avoid_margin, String(part.name)])
	var ships := get_parent().get_parent().get_node_or_null("Ships") if get_parent() != null else null
	if ships != null:
		for ship: Node in ships.get_children():
			if ship == target or ship == owner_ship:
				continue
			var combat = CombatShip.of(ship)
			if combat == null or combat.removed_from_play:
				continue
			found.append([(ship as Node3D).global_position, combat.bounds_radius + config.avoid_margin, String(ship.name)])
	return found


func _clear_of_owner() -> bool:
	if owner_combat == null or not is_instance_valid(owner_ship):
		return true
	var local := owner_ship.global_transform.affine_inverse() * global_position
	for box: AABB in owner_combat.hitboxes:
		if box.grow(config.hull_margin).has_point(local):
			return false
	return true


# Turns the nose (the whole basis, so roll stays continuous) toward `direction` by at
# most `max_angle` radians.
func _turn_toward(direction: Vector3, max_angle: float) -> void:
	if direction.length() < 0.000001:
		return
	var nose := forward()
	var angle := nose.angle_to(direction)
	if angle < 0.0000001:
		return
	var axis := nose.cross(direction)
	if axis.length() < 0.000001:
		axis = global_basis.y if absf(global_basis.y.dot(nose)) < 0.99 else global_basis.x
	global_basis = Basis(axis.normalized(), minf(angle, max_angle)) * global_basis


# --- Presentation (driven by the state, never driving it) ----------------------------------

func _measure_turn(before: Vector3, delta: float) -> void:
	var after := forward()
	turn_last = before.angle_to(after)
	# Nose movement seen in the new body frame: x toward +X (yaw), y toward +Y (pitch).
	var local := global_basis.inverse() * before
	turn_local = Vector2(-local.x, -local.y) # before lies opposite to the turn
	for i in 4:
		rcs_left[i] = maxf(0.0, rcs_left[i] - delta)
	if kind != &"missile" or delta <= 0.0:
		return
	var threshold := deg_to_rad(RCS_THRESHOLD_DEG) * delta
	# Turning the nose toward +X needs thrust toward +X at the nose: the −X thruster vents.
	if turn_local.x > threshold:
		rcs_left[1] = RCS_HOLD
	elif turn_local.x < -threshold:
		rcs_left[0] = RCS_HOLD
	if turn_local.y > threshold:
		rcs_left[3] = RCS_HOLD
	elif turn_local.y < -threshold:
		rcs_left[2] = RCS_HOLD


# The trail is exhaust: a point at the nozzle exit each tick the main engine is lit
# (torpedoes always, missiles in powered flight); older points age out either way.
func _record_trail(delta: float) -> void:
	for i in trail_ages.size():
		trail_ages[i] += delta
	if kind != &"missile" or thrusting:
		trail.append(nozzle_position())
		trail_ages.append(0.0)
	while not trail_ages.is_empty() and trail_ages[0] > config.trail_time:
		trail.remove_at(0)
		trail_ages.remove_at(0)


func _update_visuals(_delta: float) -> void:
	# The shared thruster effects: full thrust while lit (the nozzle glow only then: an
	# unlit engine shows nothing), off otherwise.
	var lit := kind != &"missile" or thrusting
	_plume.thrust = 1.0 if lit else 0.0
	_plume.powered = lit
	for i in _rcs.size():
		_rcs[i].thrust = 1.0 if rcs_left[i] > 0.0 else 0.0
