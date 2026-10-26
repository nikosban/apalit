extends "res://game/weapons/weapon.gd"
## Combat: Rocket family (RL-8 Barrage and future variants; weapon values in the variant's
## WeaponConfig, flight values in its `ordnance` OrdnanceConfig of kind rocket, salvo and
## tube layout on the variant scene). The existing eight cell positions eject world +Y,
## then turn after clearance toward one captured firing solution. Authorization keeps
## the existing speed-based intercept/range check (it is not a full launch-path reach
## prediction), with a clearance/elevated obstruction check and no bow alignment gate.
## The hull is never turned toward the target.
##
## Salvo: one authorized firing action commits `salvo_size` rockets (authorized only with at
## least that many left; no partial salvos). At that moment the target solution in
## world space is locked; rocket 1 leaves at once and
## rocket k at (k − 1) × `salvo_interval` s of accumulated simulation time, each in the
## first tick on or after its time. Every rocket leaves its own tube (tube k mod tubes),
## with a fixed dispersion rotation within `dispersion_max_deg` toward the solution (Weapon
## .disperse, its own draw from `rng`). The salvo never re-aims and is not cancelled by a
## target change or destruction, lost contact, a stance change or the ship's own motion;
## only the owner's destruction cancels the launches left. One round is used per rocket
## actually launched. `cooldown` starts when the last rocket leaves.
## Flight, collision, interception and damage belong to the projectile system (ordnance.gd,
## kind rocket: unguided).

const WeaponGeometry := preload("res://game/weapons/weapon_geometry.gd")

@export var salvo_size := 8 # rockets committed per salvo
@export var salvo_interval := 0.12 # s of simulation time between launches
@export var tube_columns := 4
@export var tube_rows := 2
@export var tube_spacing := 0.3 # u between tube centres
@export var tube_length := 0.4 # u, from the mount origin forward
@export var tube_radius := 0.1 # u

var muzzles: Array[Node3D] = []
var salvo_left := 0 # Rockets of the salvo under way not yet launched.
var salvo_launched := 0 # Rockets of the salvo under way already launched.
var salvo_time := 0.0 # s of simulation time since the salvo began.
var salvo_direction := Vector3.ZERO # Locked world-space intended direction.
var salvo_point := Vector3.ZERO # Single world-space firing solution captured at commitment.
var salvo_target: Node3D = null # The target the salvo was authorized against (attack registration only).
var salvos := 0 # Salvos begun.
var salvos_cancelled := 0
var launch_times: Array[float] = [] # s since the salvo began, per launch of the latest salvo (tests).


func _build() -> void:
	var parts := WeaponGeometry.build_rocket_tubes(self, tube_columns, tube_rows, tube_spacing, tube_length, tube_radius)
	muzzles = parts.muzzles
	muzzle = parts.aim


## Salvo progress runs with the timers, so the cooldown set by the last launch counts down
## from the next tick like any other weapon's.
func _tick(delta: float) -> void:
	super._tick(delta)
	if salvo_left > 0:
		_salvo_tick(delta)


func _authorize(target: Node3D, status: int) -> bool:
	if salvo_left > 0:
		return _deny(TS.VALID, "Salvo under way (%d of %d launched)" % [salvo_launched, salvo_size])
	return super._authorize(target, status)


## A whole salvo of rockets is needed (step 2 of the authorization).
func _gate_check(target: Node3D, status: int) -> Array:
	var gate := super._gate_check(target, status)
	if gate.is_empty() and rounds_left() < salvo_size:
		return [TS.NONE, "Salvo needs %d rockets (%d left)" % [salvo_size, rounds_left()]]
	return gate


func offensive_reach() -> float:
	if salvo_left > 0:
		return config.weapon_range
	if rounds_left() < salvo_size:
		return 0.0
	return super.offensive_reach()


func assess(target: Node3D, pipeline_order: bool = false) -> Dictionary:
	if salvo_left > 0:
		return {"state": TS.VALID, "reason": "Salvo under way (%d of %d launched)" % [salvo_launched, salvo_size], "capable": true}
	return super.assess(target, pipeline_order)


# Fire control at the rocket's speed and flight limits (full lead).
func _solve(target: Node3D) -> bool:
	if salvo_left > 0:
		aim_point = salvo_point
		return true # Pending rockets do not recalculate the committed target solution.
	var solution := _solution(target)
	aim_point = solution[1] if solution[0] else target.global_position
	flight_time = solution[2]
	lead_factor = 1.0
	return solution[0]


## [solved, aim point, flight time] (read-only).
func _solution(target: Node3D) -> Array:
	var rocket: Resource = config.ordnance
	var origin := muzzle.global_position
	var position := target.global_position
	var velocity := velocity_of(target)
	var nominal_time := intercept_time(origin, position, velocity, rocket.speed)
	if nominal_time <= 0.0:
		return [false, Vector3.ZERO, 0.0]
	var time := nominal_time
	# First-order lead includes launch delay. Approximate the turn as an 8 u/s arc:
	# its forward progress replaces part of straight cruise, while its extra height
	# changes the angle needed. Iterate only before commitment, using this one observed
	# position/velocity snapshot. Collision and actual travel remain authoritative.
	var rate := deg_to_rad(maxf(rocket.orient_rate_deg, 0.001))
	var radius: float = rocket.eject_speed / rate
	var elevated: Vector3 = origin + Vector3.UP * (rocket.clearance + radius)
	var ramp_delay: float = pow(maxf(0.0, rocket.speed - rocket.eject_speed), 2.0) / (2.0 * maxf(rocket.acceleration, 0.001) * rocket.speed)
	for iteration in 3:
		var angle := Vector3.UP.angle_to(position + velocity * time - elevated)
		var turn_time: float = minf(angle / rate, rocket.transition_timeout)
		var progress: float = radius * sin(rate * turn_time)
		var delay: float = rocket.clearance / maxf(rocket.eject_speed, 0.001) + turn_time - progress / rocket.speed + ramp_delay
		var cruise_time := intercept_time(origin, position + velocity * delay, velocity, rocket.speed)
		if cruise_time <= 0.0:
			return [false, Vector3.ZERO, 0.0]
		time = delay + cruise_time
	# Retain the existing admission bounds; this estimate improves lead, not range.
	# The physical travel cap includes launch travel and can still end a shot early.
	return [nominal_time <= rocket.lifetime and rocket.speed * nominal_time <= rocket.max_travel, position + velocity * time, time]


func _alignment_error(_origin: Vector3, _aim: Vector3) -> float:
	return 0.0 # Dorsal launch turns after clearance; no hull-facing requirement.


func _path_blocker(from: Vector3, to: Vector3, target: Node3D) -> String:
	# Authorize the clearance leg and elevated firing line, rather than a bow-level ray
	# through the launching hull. Actual curved flight still uses physical sweeps.
	var elevated: Vector3 = from + Vector3.UP * config.ordnance.clearance
	var blocker := super._path_blocker(from, elevated, target)
	return blocker if blocker != "" else super._path_blocker(elevated, to, target)


## The owner is destroyed: the launches left are cancelled.
func disable() -> void:
	cancel_salvo()
	super.disable()


func cancel_salvo() -> void:
	if salvo_left <= 0:
		return
	salvos_cancelled += 1
	salvo_left = 0
	salvo_target = null


# One firing action = one salvo: direction locked, rocket 1 now, the rest scheduled.
func _fire(target: Node3D) -> void:
	salvos += 1
	salvo_point = aim_point
	salvo_direction = (salvo_point - muzzle.global_position).normalized()
	salvo_target = target
	salvo_launched = 0
	salvo_left = salvo_size
	salvo_time = 0.0
	launch_times.clear()
	_launch()


func _salvo_tick(delta: float) -> void:
	salvo_time += delta
	while salvo_left > 0 and salvo_time >= salvo_launched * salvo_interval - 0.000001:
		_launch()


# The next rocket of the salvo from its tube along the locked direction, dispersed; one
# round used. The last one starts the cooldown.
func _launch() -> void:
	if rounds_left() <= 0:
		cancel_salvo()
		return
	var tube := muzzles[salvo_launched % muzzles.size()]
	var direction := disperse(salvo_direction, config.dispersion_max_deg, rng)
	# Dispersion is a fixed per-rocket rotation of the committed solution, approached
	# with finite steering. Applying it as a heading jump at phase exit would snap.
	var spread := Basis(Quaternion(salvo_direction, direction))
	var origin := Transform3D(Basis.looking_at(Vector3.UP, Vector3.FORWARD), tube.global_position)
	var target := salvo_target if is_instance_valid(salvo_target) else null
	var id := -1
	if combat.projectiles != null:
		id = combat.projectiles.launch(ship, combat.faction, origin, config, target,
			{"locked_point": salvo_point, "dispersion": spread})
	_use_round()
	shots += 1
	salvo_launched += 1
	salvo_left -= 1
	launch_times.append(salvo_time)
	if salvo_left == 0:
		cooldown_left = config.cooldown
		salvo_target = null
	if combat.effects != null:
		combat.effects.muzzle_flash(origin.origin, Vector3.UP, CombatShip.FACTION_COLORS[combat.faction], 0.6)
	shot.emit(self, id, target, origin)
	if target != null:
		combat.on_fired(self, target)
