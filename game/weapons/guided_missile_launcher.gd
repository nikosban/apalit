extends "res://game/weapons/launcher.gd"
## Guided cruise-missile family. Reuses the legacy launcher's cells, authorization and
## omnidirectional fire control, with committed target identity and cooldown after the
## final launch. The legacy launcher itself is unchanged. All variant values are read
## from GuidedMissileConfig; no shared resource is modified at runtime.

var salvo_time := 0.0
var salvo_target_id := 0
var salvo_target_name := ""
var salvo_last_known := Vector3.ZERO
var launch_times: Array[float] = [] # Latest salvo, elapsed simulation seconds.


func _build() -> void:
	cells = config.cells
	cell_columns = config.cell_columns
	cell_size = config.cell_size
	salvo_size = config.salvo_size
	salvo_interval = config.salvo_interval
	super._build()
	for cell: Node3D in muzzles:
		cell.rotation_degrees = config.launch_rotation_degrees


## Launcher.step accumulates the salvo before Weapon.step advances its timers. Launch
## here only after those timers, so a newly started cooldown loses no time on this tick.
func _salvo_tick(delta: float) -> void:
	salvo_time += delta


func _tick(delta: float) -> void:
	super._tick(delta)
	if cooldown_left < 0.000000000001:
		cooldown_left = 0.0
	if salvo_left <= 0:
		return
	if not enabled or not combat.alive:
		cancel_salvo("launcher destroyed")
		return
	_remember_target()
	while salvo_left > 0 and salvo_time + 0.000000000001 >= salvo_launched * salvo_interval:
		var assigned: Node3D = salvo_target if is_instance_valid(salvo_target) else null
		_launch(salvo_launched % muzzles.size(), assigned)


func _remember_target() -> void:
	# target_status checks contact before any position is read. A changed player target
	# has no effect on this salvo's identity or memory.
	if combat.target_status(salvo_target) == TS.VALID:
		salvo_last_known = salvo_target.global_position


func _fire(target: Node3D) -> void:
	salvos += 1
	salvo_target = target
	salvo_target_id = target.get_instance_id()
	salvo_target_name = String(target.name)
	salvo_last_known = target.global_position # Authorized, detected target at commitment.
	salvo_time = 0.0
	salvo_launched = 0
	salvo_left = salvo_size
	launch_times.clear()
	_launch(0, target)


func _launch(cell: int, target: Node3D) -> void:
	if rounds_left() <= 0:
		cancel_salvo("out of missiles")
		return
	var origin := muzzles[cell].global_transform
	var memory := {"target_id": salvo_target_id, "target_name": salvo_target_name, "position": salvo_last_known}
	var id := -1
	if combat.projectiles != null:
		id = combat.projectiles.launch(ship, combat.faction, origin, config, target, memory)
	_use_round()
	shots += 1
	salvo_launched += 1
	salvo_left -= 1
	launch_times.append(salvo_time)
	if salvo_left == 0:
		cooldown_left = config.cooldown
		salvo_target = null
	if combat.effects != null:
		combat.effects.muzzle_flash(origin.origin, -origin.basis.z.normalized(), CombatShip.FACTION_COLORS[combat.faction], 1.4)
	shot.emit(self, id, target, origin)
	# on_fired reads the target position for nearby allies' threat registration. Never
	# invoke it on a hidden/dead target; the authorized first launch registered the attack.
	if combat.target_status(target) == TS.VALID:
		combat.on_fired(self, target)
	else:
		combat.fired.emit(self, target)
