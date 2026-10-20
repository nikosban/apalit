extends Node3D
## Combat (migrated from the prototype): shared weapon execution (base of FixedWeapon, Turret, Cannon, Gatling
## and Launcher). The node is the mount (its transform is the configurable mounting
## transform, authored in the ship scene; on a hardpoint it sits at the hardpoint's
## origin and the hardpoint supplies the physical limits); the subclass generates the
## geometry and a `muzzle` marker.
##
## step() (called by the ship's Combat each tick): timers, a minimal lead solution
## (straight-line intercept at projectile speed, scaled by the lead quality beyond the
## effective range), articulation (turrets), then the firing authorization in this order;
## the first failing check is the reason it does not fire:
##   1 owner alive and operational, 2 ammunition left, 3 target valid and hostile,
##   4 target observable, 5 stance authorizes it, 6 within the maximum range (target and
##   aim point), 7 within the weapon's mechanical coverage, 8 aligned within tolerance,
##   9 magazine not reloading, 10 cooldown (reload between shots) elapsed, 11 firing
##   solution valid (intercept within the projectile's lifetime and travel), 12 firing
##   path clear (no asteroid, own hull, friendly hull or hulk in the way).
## A shot leaves the muzzle along the muzzle's forward axis (the barrel), so visual
## direction and projectile direction are the same; it uses one round of the stock and
## registers the attack (threats).
##
## Ammunition (v0.3): `ammo` is the stock outside the magazine (the whole stock for
## weapons without one), `magazine` the rounds ready to fire. An empty magazine starts a
## reload at once; a partly used one is refilled once the weapon has had no actionable
## shot for `idle_reload_delay` (actionable: a valid, authorized target in range and
## coverage, only waiting for alignment, the reload or the cooldown). A started reload
## always runs to the end, moves min(missing, stock) rounds (never creates any) and is
## never restarted while it runs. Switching targets never empties the magazine.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const TS := CombatShip.TargetState
const CombatObstacles := preload("res://game/combat/combat_obstacles.gd")

signal shot(weapon: Node, projectile_id: int, target: Node3D, origin: Transform3D)
signal reload_started(weapon: Node, cause: String)
signal reload_finished(weapon: Node, moved: int)

@export var config: Resource
## v0.4: starting stock for this mount when ≥ 0 (a scenario's tuning value, e.g. E05's 12
## missiles), else the configuration's `ammunition`.
@export var ammunition_override := -1

var fixed := false
var muzzle: Node3D
var enabled := true
var cooldown_left := 0.0
var state: int = TS.NONE
var reason := "No target"
var aim_point := Vector3.ZERO
var has_solution := false
var flight_time := 0.0
var lead_factor := 1.0
var shots := 0
var tracking := "Neutral" # Turrets: articulation state (debug).
var hardpoint: Node3D = null
var ammo := 0 # Stock outside the magazine.
var magazine := 0
var reload_left := 0.0
var reloads := 0
var idle_reloads := 0
var idle_time := 0.0
var actionable := false

@onready var ship := _owner_ship()
@onready var combat = ship.get_node("Combat")


func _ready() -> void:
	if get_parent() != null and get_parent().has_method("accepts"):
		hardpoint = get_parent()
	if config != null:
		if config.magazine_size > 0:
			magazine = mini(config.magazine_size, capacity())
			ammo = capacity() - magazine
		else:
			ammo = capacity()
	_build()


## Starting stock (magazine included): the override, else the configuration's.
func capacity() -> int:
	return ammunition_override if ammunition_override >= 0 else config.ammunition


func _owner_ship() -> Node3D:
	var mounts := get_parent()
	if mounts != null and mounts.has_method("accepts"):
		mounts = mounts.get_parent()
	return mounts.get_parent() as Node3D


## Builds the geometry and sets `muzzle` (subclasses).
func _build() -> void:
	pass


func disable() -> void:
	enabled = false
	state = TS.NONE
	reason = "Destroyed"


## v0.4: how far this weapon extends its ship's automatic acquisition: its authorization
## range while it can still fire (enabled, rounds left), else 0. Timers do not shorten it.
func offensive_reach() -> float:
	return config.weapon_range if enabled and rounds_left() > 0 else 0.0


## Rounds left in total (magazine and stock).
func rounds_left() -> int:
	return ammo + magazine


func reloading() -> bool:
	return reload_left > 0.0


## Physical limits: the hardpoint's when installed on one, else the configuration's.
func yaw_limit_deg() -> float:
	return hardpoint.yaw_limit_deg if hardpoint != null else config.yaw_limit_deg


func pitch_min_deg() -> float:
	return hardpoint.pitch_min_deg if hardpoint != null else config.pitch_min_deg


func pitch_max_deg() -> float:
	return hardpoint.pitch_max_deg if hardpoint != null else config.pitch_max_deg


func cone_deg() -> float:
	return hardpoint.cone_deg if hardpoint != null else config.firing_cone_deg


func step(delta: float) -> void:
	_tick(delta)
	var target: Node3D = combat.target
	var status: int = combat.target_status(target)
	has_solution = false
	if status == TS.VALID:
		has_solution = _solve(target)
	_track(delta, target if status == TS.VALID else null)
	if _authorize(target, status):
		_fire(target)
	_idle_reload(delta)


func _tick(delta: float) -> void:
	cooldown_left = maxf(0.0, cooldown_left - delta)
	if reload_left > 0.0:
		reload_left -= delta
		if reload_left <= 0.000001:
			_finish_reload()


func _finish_reload() -> void:
	reload_left = 0.0
	var moved := mini(config.magazine_size - magazine, ammo)
	magazine += moved
	ammo -= moved
	reload_finished.emit(self, moved)


# Refill the magazine when it is empty, or after `idle_reload_delay` without an
# actionable shot while partly used (never restarted while one runs).
func _idle_reload(delta: float) -> void:
	actionable = state == TS.VALID
	idle_time = 0.0 if actionable else idle_time + delta
	if config.magazine_size <= 0 or reload_left > 0.0 or ammo <= 0 or magazine >= config.magazine_size:
		return
	if magazine == 0:
		_start_reload("empty")
	elif idle_time >= config.idle_reload_delay - 0.000001:
		idle_reloads += 1
		_start_reload("idle")


func _start_reload(cause: String) -> void:
	reload_left = config.reload_time
	reloads += 1
	reload_started.emit(self, cause)
	if reload_left <= 0.0:
		_finish_reload()


# Steps 1–12. Sets state / reason; true = fire now.
func _authorize(target: Node3D, status: int) -> bool:
	var gate := _gate_check(target, status)
	if not gate.is_empty():
		return _deny(gate[0], gate[1])
	return _authorize_shot(target)


# Steps 1–5 (owner, ammunition, target, contact, stance): [state, reason] of the first
# failing step, or [] when all pass. Read-only (v0.4: shared with assess()).
func _gate_check(target: Node3D, status: int) -> Array:
	if not enabled or not combat.alive:
		return [TS.NONE, "Owner not operational" if enabled else reason]
	if rounds_left() <= 0:
		return [TS.NONE, "Out of ammunition"]
	if status != TS.VALID and status != TS.CONTACT_LOST:
		return [status, CombatShip.STATE_NAMES[status]]
	if status == TS.CONTACT_LOST:
		return [status, "Sensor contact lost"]
	var allowed: int = combat.stance_allows(target)
	if allowed != TS.VALID:
		return [allowed, CombatShip.STATE_NAMES[allowed]]
	return []


# Steps 6–12 against a target already known to be valid and authorized.
func _authorize_shot(target: Node3D) -> bool:
	var aim := aim_point if has_solution else target.global_position
	var result := _shot_check(target, has_solution, aim_point, _in_coverage(aim))
	state = result[0]
	reason = result[1]
	return result[2]


# Steps 6–12 for a solution (`solved`, `solution_aim`) and its coverage result:
# [state, reason, fire]. Read-only (v0.4: shared by the firing path and assess()).
## `waits` false skips the waiting steps (alignment, magazine reload, cooldown) so that a
## structural reason behind them (no solution, obstruction) shows.
func _shot_check(target: Node3D, solved: bool, solution_aim: Vector3, covered: bool, waits: bool = true) -> Array:
	var origin := muzzle.global_position
	var distance := origin.distance_to(target.global_position)
	if distance > config.weapon_range or (solved and origin.distance_to(solution_aim) > config.weapon_range):
		return [TS.OUT_OF_RANGE, "Out of range (%.1f / %.0f u)" % [distance, config.weapon_range], false]
	var aim := solution_aim if solved else target.global_position
	if not covered:
		return [TS.OUTSIDE_ARC, _coverage_reason(), false]
	if waits:
		var error := _alignment_error(origin, aim)
		if error > config.alignment_tolerance_deg:
			return [TS.VALID, _alignment_reason(error), false]
		if reload_left > 0.0:
			return [TS.VALID, "Reloading magazine (%.1f s)" % reload_left, false]
		if cooldown_left > 0.0:
			return [TS.VALID, "Reloading (%.1f s)" % cooldown_left, false]
	if not solved:
		return [TS.OUT_OF_RANGE, "No firing solution", false]
	var blocker := _path_blocker(origin, aim, target)
	if blocker != "":
		return [TS.OBSCURED, blocker, false]
	return [TS.VALID, "Firing", true]


## v0.4: read-only eligibility of `target` for this weapon now, through the same steps
## 1–12 as firing (nothing is written: no state, aim, articulation or timers): {state,
## reason, capable}. `capable` = the weapon could engage it (state Valid: only alignment,
## a reload or the cooldown may remain), as Combat's summary counts it. By default the
## structural steps are judged first, so a reload never hides an obstruction or a missing
## solution (the player readout); `pipeline_order` gives exactly the firing order's first
## failing step instead.
func assess(target: Node3D, pipeline_order: bool = false) -> Dictionary:
	var status: int = combat.target_status(target)
	var gate := _gate_check(target, status)
	var result: Array
	if not gate.is_empty():
		result = [gate[0], gate[1], false]
	else:
		var solution := _solution(target)
		var aim: Vector3 = solution[1] if solution[0] else target.global_position
		result = _shot_check(target, solution[0], solution[1], _covers(aim), pipeline_order)
		if not pipeline_order and result[0] == TS.VALID:
			result = _shot_check(target, solution[0], solution[1], _covers(aim), true)
	return {"state": result[0], "reason": "Ready" if result[2] else result[1], "capable": result[0] == TS.VALID}


## v0.4: the firing solution for `target` without storing it: [solved, aim point].
func _solution(target: Node3D) -> Array:
	var origin := muzzle.global_position
	var velocity := velocity_of(target)
	var speed: float = config.projectile_speed
	var time := intercept_time(origin, target.global_position, velocity, speed)
	if time <= 0.0:
		return [false, Vector3.ZERO]
	var aim: Vector3 = target.global_position + velocity * time * config.lead_quality(origin.distance_to(target.global_position))
	return [time <= config.projectile_lifetime and speed * time <= config.max_travel(), aim]


## v0.4: whether `aim` lies in the weapon's mechanical coverage (read-only; turrets
## compute it from their limits instead of the tracked state).
func _covers(aim: Vector3) -> bool:
	return _in_coverage(aim)


func _deny(new_state: int, text: String) -> bool:
	state = new_state
	reason = text
	return false


## Muzzle forward (the barrel axis; projectiles travel along it).
func forward() -> Vector3:
	return -muzzle.global_basis.z.normalized()


func _alignment_error(origin: Vector3, aim: Vector3) -> float:
	return rad_to_deg(forward().angle_to(aim - origin))


## Velocity of a ship (its Combat's) or of guided ordnance (its `velocity`).
static func velocity_of(node: Node3D) -> Vector3:
	var combat = CombatShip.of(node)
	if combat != null:
		return combat.velocity()
	var value: Variant = node.get("velocity")
	return value if value is Vector3 else Vector3.ZERO


func _solve(target: Node3D) -> bool:
	return _solve_for(target.global_position, velocity_of(target))


func _solve_for(position: Vector3, velocity: Vector3) -> bool:
	var origin := muzzle.global_position
	var speed: float = config.projectile_speed
	var time := intercept_time(origin, position, velocity, speed)
	if time <= 0.0:
		return false
	flight_time = time
	lead_factor = config.lead_quality(origin.distance_to(position))
	aim_point = position + velocity * time * lead_factor
	return time <= config.projectile_lifetime and speed * time <= config.max_travel()


## First (smallest positive) time at which a straight shot at `speed` from `origin`
## meets a point moving from `position` at constant `velocity`; -1 when none.
static func intercept_time(origin: Vector3, position: Vector3, velocity: Vector3, speed: float) -> float:
	var offset := position - origin
	var a := velocity.dot(velocity) - speed * speed
	var b := 2.0 * offset.dot(velocity)
	var c := offset.dot(offset)
	if absf(a) < 0.000001:
		return -c / b if absf(b) > 0.000001 else -1.0
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return -1.0
	var root := sqrt(discriminant)
	var best := -1.0
	for t in [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]:
		if t > 0.0 and (best < 0.0 or t < best):
			best = t
	return best


## Turret articulation (subclass); `target` is null when there is nothing to track.
func _track(_delta: float, _target: Node3D) -> void:
	pass


func _in_coverage(_aim: Vector3) -> bool:
	return true


func _coverage_reason() -> String:
	return "Outside firing arc"


func _alignment_reason(error: float) -> String:
	return "Aligning (%.1f°)" % error


# First obstruction between the muzzle and the aim point, or "" when clear: asteroids,
# stations, the own hull, and any hull other than the target that a projectile would hit without
# damaging it (friendly ships, hulks).
func _path_blocker(from: Vector3, to: Vector3, target: Node3D) -> String:
	var asteroids: Node = combat.asteroids
	if asteroids != null and asteroids.has_method("ids"):
		for id: int in asteroids.ids():
			if _segment_sphere(from, to, asteroids.center(id), asteroids.radius(id)):
				return "Temporarily obscured (asteroid)"
	if CombatObstacles.blocked(get_tree(), from, to):
		return "Temporarily obscured (station)" # Stations stop direct fire (combat_obstacles.gd).
	if combat.segment_fraction(from, to) >= 0.0:
		return "Own hull in line of fire"
	for other: Node in combat.ships_node.get_children():
		if other == ship or other == target:
			continue
		var other_combat = CombatShip.of(other)
		if other_combat == null or other_combat.removed_from_play:
			continue
		if (other_combat.faction == combat.faction or not other_combat.alive) and other_combat.segment_fraction(from, to) >= 0.0:
			return "Friendly hull in line of fire" if other_combat.alive else "Wreck in line of fire"
	return ""


static func _segment_sphere(a: Vector3, b: Vector3, center: Vector3, radius: float) -> bool:
	var closest := Geometry3D.get_closest_point_to_segment(center, a, b)
	return closest.distance_to(center) <= radius


# Uses one round: from the magazine (an empty magazine starts its reload at once) or,
# without a magazine, from the stock.
func _use_round() -> void:
	if config.magazine_size > 0:
		magazine -= 1
		if magazine == 0 and ammo > 0:
			_start_reload("empty")
	else:
		ammo -= 1


func _fire(target: Node3D) -> void:
	var origin := muzzle.global_transform
	var direction := -origin.basis.z.normalized()
	var id := -1
	if combat.projectiles != null:
		id = combat.projectiles.spawn(ship, combat.faction, origin.origin, direction * config.projectile_speed,
			config.damage, config.max_travel(), config.projectile_lifetime, target, config.projectile_style)
	_use_round()
	cooldown_left = config.cooldown
	shots += 1
	if combat.effects != null:
		combat.effects.muzzle_flash(origin.origin, direction, CombatShip.FACTION_COLORS[combat.faction], _flash_scale())
	shot.emit(self, id, target, origin)
	combat.on_fired(self, target)


func _flash_scale() -> float:
	return 1.0
