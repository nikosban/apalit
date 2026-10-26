extends "res://game/weapons/weapon.gd"
## Combat: Rocket family (RL-8 Barrage and future variants; weapon values in the variant's
## WeaponConfig, flight values in its `ordnance` OrdnanceConfig of kind rocket, salvo and
## tube layout on the variant scene). A fixed forward launcher: tubes laid out across the
## mount, every tube along the mount's −Z. It uses the shared firing authorization against
## the rocket's flight (straight-line intercept at the rocket's speed, within its lifetime
## and travel): the intercept point must be within `alignment_tolerance_deg` of the
## launcher's forward axis, inside `weapon_range`, with a clear line. The hull is never
## turned toward the target (not a `fixed` weapon for Combat's facing request).
##
## Salvo: one authorized firing action commits `salvo_size` rockets (authorized only with at
## least that many left; no partial salvos). At that moment the launcher's forward axis in
## world space is locked as the salvo's intended direction; rocket 1 leaves at once and
## rocket k at (k − 1) × `salvo_interval` s of accumulated simulation time, each in the
## first tick on or after its time. Every rocket leaves its own tube (tube k mod tubes) along
## the locked direction deviated within the configuration's `dispersion_max_deg` (Weapon
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
	var solution := _solution(target)
	aim_point = solution[1] if solution[0] else target.global_position
	flight_time = solution[2]
	lead_factor = 1.0
	return solution[0]


## [solved, aim point, flight time] (read-only).
func _solution(target: Node3D) -> Array:
	var rocket: Resource = config.ordnance
	var velocity := velocity_of(target)
	var time := intercept_time(muzzle.global_position, target.global_position, velocity, rocket.speed)
	if time <= 0.0:
		return [false, Vector3.ZERO, 0.0]
	return [time <= rocket.lifetime and rocket.speed * time <= rocket.max_travel, target.global_position + velocity * time, time]


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
	salvo_direction = forward()
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
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	var origin := Transform3D(Basis.looking_at(direction, up), tube.global_position)
	var target := salvo_target if is_instance_valid(salvo_target) else null
	var id := -1
	if combat.projectiles != null:
		id = combat.projectiles.launch(ship, combat.faction, origin, config, target)
	_use_round()
	shots += 1
	salvo_launched += 1
	salvo_left -= 1
	launch_times.append(salvo_time)
	if salvo_left == 0:
		cooldown_left = config.cooldown
		salvo_target = null
	if combat.effects != null:
		combat.effects.muzzle_flash(origin.origin, direction, CombatShip.FACTION_COLORS[combat.faction], 0.6)
	shot.emit(self, id, target, origin)
	if target != null:
		combat.on_fired(self, target)
