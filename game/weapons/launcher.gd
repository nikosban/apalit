extends "res://game/weapons/weapon.gd"
## Combat (migrated from the prototype v0.3): guided-ordnance launcher (torpedo tube or missile deck cells;
## the kind comes from the configuration's ordnance). It uses the shared firing
## authorization and ammunition (one ordnance per launch, `cooldown` = reload between
## launches) and hands the launch to the projectile system with the muzzle transform.
##   Torpedo tube: fixed to the hull along the mount's −Z; it launches only when the
##     intercept point (first-order lead at torpedo speed) lies within the hardpoint's
##     planar launch cone (the idle, unlocked hull may turn toward it like a fixed
##     weapon); the line of fire must be clear (asteroids, own and friendly hulls), since
##     torpedoes do not avoid obstacles. Guidance does the rest, so no tighter alignment
##     is required.
##   Missile cells: missiles leave vertically from alternating cells and steer to any
##     bearing (no launch cone, no line-of-sight requirement: they avoid obstacles).
## Flight limits and steering are the ordnance's (ordnance.gd).
##
## v0.4 salvos (missile cells; configuration data on the launcher): `cells` is 2, 4, 6 or
## 8 cells laid out in `cell_columns` columns; `salvo_size` > 1 makes one authorized firing
## action a salvo: cell 1 launches at once, then the next cells in order every
## `salvo_interval` s of simulation time (physics delta: a pause freezes the sequence, time
## speed scales it). A salvo needs `salvo_size` rounds to be authorized (no partial salvos);
## each missile uses one round when it actually leaves. The salvo is one firing cycle: the
## cooldown starts with its first launch and no new salvo is authorized until it has ended
## and the cooldown has run out. Before each later launch the salvo's target must still be
## the ship's target, a valid hostile in contact, with the stance allowing fire; otherwise
## the remaining launches are cancelled (never redirected) and their rounds kept. Missiles
## already in flight continue under their own guidance. `salvo_size` 1 is the v0.3
## behaviour (one missile per firing action, alternating cells).

const WeaponGeometry := preload("res://game/weapons/weapon_geometry.gd")
const VALID_CELLS := [2, 4, 6, 8]

@export var tube_length := 1.0 # u (torpedo)
@export var tube_radius := 0.2 # u (torpedo)
@export var cell_size := Vector3(0.8, 0.2, 1.2) # u, deck box (missile)
@export var cells := 2
@export var cell_columns := 1 # v0.4: cells across the mount (1 = one row along Z, v0.3)
@export var salvo_size := 1 # v0.4: missiles per firing action (1 = single launches, v0.3)
@export var salvo_interval := 0.2 # v0.4: s of simulation time between salvo launches (provisional)

var kind := &"torpedo"
var muzzles: Array[Node3D] = []
var next_cell := 0
var salvo_target: Node3D = null # The authorized target of the salvo under way.
var salvo_left := 0 # Launches still scheduled in the salvo under way.
var salvo_next := 0.0 # s of simulation time until the next scheduled launch.
var salvo_launched := 0 # Missiles of the salvo under way already launched.
var salvos := 0 # Salvos begun.
var salvos_cancelled := 0
var salvo_cancel_reason := ""


func _build() -> void:
	kind = config.ordnance.kind
	if kind == &"torpedo":
		fixed = true
		muzzle = WeaponGeometry.build_tube(self, tube_length, tube_radius)
		muzzles = [muzzle]
	else:
		if not VALID_CELLS.has(cells):
			push_error("%s: %d missile cells is not a supported launcher (2, 4, 6 or 8)" % [name, cells])
		salvo_size = clampi(salvo_size, 1, cells)
		muzzles = WeaponGeometry.build_cells(self, cell_size.x, cell_size.y, cell_size.z, cells, cell_columns)
		muzzle = muzzles[0]


func step(delta: float) -> void:
	if salvo_left > 0:
		_salvo_tick(delta)
	super.step(delta)


func _authorize(target: Node3D, status: int) -> bool:
	if salvo_left > 0:
		return _deny(TS.VALID, "Salvo under way (%d of %d launched)" % [salvo_launched, salvo_size])
	return super._authorize(target, status)


## A salvo launcher reaches only while it can still fire a whole salvo (or one is under way).
func offensive_reach() -> float:
	if salvo_left > 0:
		return config.weapon_range
	if salvo_size > 1 and rounds_left() < salvo_size:
		return 0.0
	return super.offensive_reach()


## The readout mirrors the authorization: a salvo under way comes first.
func assess(target: Node3D, pipeline_order: bool = false) -> Dictionary:
	if salvo_left > 0:
		return {"state": TS.VALID, "reason": "Salvo under way (%d of %d launched)" % [salvo_launched, salvo_size], "capable": true}
	return super.assess(target, pipeline_order)


## A salvo launcher needs a whole salvo of rounds (step 2 of the authorization).
func _gate_check(target: Node3D, status: int) -> Array:
	var gate := super._gate_check(target, status)
	if gate.is_empty() and salvo_size > 1 and rounds_left() < salvo_size:
		return [TS.NONE, "Salvo needs %d missiles (%d left)" % [salvo_size, rounds_left()]]
	return gate


## The salvo under way: whether its target still allows the next launch ("" = yes).
func _salvo_block() -> String:
	if not enabled or not combat.alive:
		return "launcher not operational"
	if rounds_left() <= 0:
		return "out of missiles"
	if salvo_target == null or not is_instance_valid(salvo_target):
		return "target gone"
	var status: int = combat.target_status(salvo_target)
	if status != TS.VALID:
		return CombatShip.STATE_NAMES[status].to_lower()
	if combat.target != salvo_target:
		return "target changed"
	if combat.stance_allows(salvo_target) != TS.VALID:
		return CombatShip.STATE_NAMES[combat.stance_allows(salvo_target)].to_lower()
	return ""


func _salvo_tick(delta: float) -> void:
	salvo_next -= delta
	while salvo_left > 0 and salvo_next <= 0.000001:
		var block := _salvo_block()
		if block != "":
			cancel_salvo(block)
			return
		_launch(salvo_launched, salvo_target)
		salvo_left -= 1
		salvo_next += salvo_interval
	if salvo_left == 0:
		salvo_target = null


## The ship is destroyed: no scheduled launch survives it.
func disable() -> void:
	cancel_salvo("launcher destroyed")
	super.disable()


## Cancels the launches still scheduled (their rounds are kept); missiles in flight go on.
func cancel_salvo(why: String) -> void:
	if salvo_left <= 0:
		return
	salvos_cancelled += 1
	salvo_cancel_reason = why
	salvo_left = 0
	salvo_target = null


# Torpedo fire control: the first-order intercept point at the torpedo's speed (the hull
# turns toward it and the launch cone is judged against it); missiles: the target.
func _solve(target: Node3D) -> bool:
	aim_point = target.global_position
	flight_time = 0.0
	lead_factor = 1.0
	if kind == &"torpedo":
		var velocity := velocity_of(target)
		var time := intercept_time(muzzle.global_position, target.global_position, velocity, config.ordnance.speed)
		if time > 0.0:
			flight_time = time
			aim_point = target.global_position + velocity * time
	return true


## v0.4 (read-only): the same fire control as _solve() without storing it.
func _solution(target: Node3D) -> Array:
	if kind == &"torpedo":
		var velocity := velocity_of(target)
		var time := intercept_time(muzzle.global_position, target.global_position, velocity, config.ordnance.speed)
		if time > 0.0:
			return [true, target.global_position + velocity * time]
	return [true, target.global_position]


func _in_coverage(aim: Vector3) -> bool:
	if kind != &"torpedo":
		return true
	var bow := forward()
	var to_aim := aim - muzzle.global_position
	var bow_planar := Vector2(bow.x, bow.z)
	var aim_planar := Vector2(to_aim.x, to_aim.z)
	if bow_planar.length() < 0.000001 or aim_planar.length() < 0.000001:
		return false
	return absf(rad_to_deg(bow_planar.angle_to(aim_planar))) <= cone_deg()


func _coverage_reason() -> String:
	return "Outside launch cone (±%.0f°)" % cone_deg()


func _alignment_error(_origin: Vector3, _aim: Vector3) -> float:
	return 0.0 # Coverage (torpedo cone) is the alignment; missiles turn after launch.


func _path_blocker(from: Vector3, to: Vector3, target: Node3D) -> String:
	if kind != &"torpedo":
		return ""
	return super._path_blocker(from, to, target)


func _fire(target: Node3D) -> void:
	if salvo_size > 1:
		# One firing action = one salvo: cell 1 now, the rest scheduled (_salvo_tick).
		salvos += 1
		salvo_target = target
		salvo_launched = 0
		salvo_left = salvo_size - 1
		salvo_next = salvo_interval
		cooldown_left = config.cooldown
		_launch(0, target)
		return
	cooldown_left = config.cooldown
	_launch(next_cell, target)
	if muzzles.size() > 1:
		next_cell = (next_cell + 1) % muzzles.size()
		muzzle = muzzles[next_cell]


# One ordnance from cell `cell` (its own muzzle transform), one round used.
func _launch(cell: int, target: Node3D) -> void:
	var origin := muzzles[cell].global_transform
	var id := -1
	if combat.projectiles != null:
		id = combat.projectiles.launch(ship, combat.faction, origin, config, target)
	_use_round()
	shots += 1
	salvo_launched += 1
	if combat.effects != null:
		combat.effects.muzzle_flash(origin.origin, -origin.basis.z.normalized(), CombatShip.FACTION_COLORS[combat.faction], 1.4)
	shot.emit(self, id, target, origin)
	combat.on_fired(self, target)
