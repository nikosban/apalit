extends SceneTree
## Combat prototype v0.4 correction: weapon-range-aware automatic target acquisition,
## limited by sensor contact, on E05 (its Sensors). Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/acquisition_test.gd
## Every hostile holds fire; the player ship under test is Aggressive unless stated.

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const TS := CombatShip.TargetState
const EAST := -PI * 0.5
const WEST := PI * 0.5
const PLAYER := 0

var scene: Node3D
var _checks := 0
var _failures := 0
var _bad_shots: Array[String] = []
var _shots := 0


func _initialize() -> void:
	await process_frame
	await _case_reach()
	await _case_contact()
	await _case_escort_reach()
	await _case_persistence()
	await _case_ammunition()
	await _case_manual()
	await _case_stances()
	_free()
	print("Shots audited: %d, outside the weapon's range: %d" % [_shots, _bad_shots.size()])
	for line in _bad_shots.slice(0, 6):
		print("  BAD SHOT " + line)
	_check("every shot within its weapon's authorization range (acquisition never authorizes a shot)", _bad_shots.is_empty() and _shots > 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _free() -> void:
	if scene != null and is_instance_valid(scene):
		root.remove_child(scene)
		scene.free()
	scene = null


## E05 quiet: scripted fleet off, every ship holding fire and parked in a corner, the
## tested ship (`subject`) at (-60, 110) heading east. Every player shot is audited.
func _load(subject: String = "FF01A") -> void:
	_free()
	scene = E05.instantiate()
	scene.scenario_index = 0
	root.add_child(scene)
	scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
	scene.enemy_controller._steps.clear()
	scene.enemy_controller._patrols.clear()
	for ship: Node in scene.get_node("Ships").get_children():
		CombatShip.of(ship).stance = CombatShip.Stance.HOLD_FIRE
	await physics_frame
	while not scene.enemy_controller.started:
		await physics_frame
	var corners := {"FF01A": Vector2(-140, -140), "FF01B": Vector2(-140, 140), "FF01C": Vector2(-120, 140),
		"HostileFF01B": Vector2(140, -140), "HostileFF01C": Vector2(140, -120), "HostileFF01A": Vector2(140, 140)}
	for name: String in corners:
		_place(name, corners[name], EAST)
	_place(subject, Vector2(-60, 110), EAST)
	for ship: Node3D in scene.get_node("Ships").get_children():
		for w in CombatShip.of(ship).weapons:
			w.shot.connect(func(wp: Node, _id: int, t: Node3D, _o: Transform3D) -> void:
				if CombatShip.of(t) == null:
					return # point defense
				_shots += 1
				var reach: float = wp.config.weapon_range
				var distance: float = wp.muzzle.global_position.distance_to(t.global_position)
				if distance > reach + 0.001:
					_bad_shots.append("%s %s at %s: %.1f u > %.0f u" % [wp.ship.name, wp.config.family, t.name, distance, reach]))


func _place(name: String, point: Vector2, heading: float) -> void:
	var ship: Node3D = scene.ship(name)
	ship.get_node("Locomotion").place(point, heading)
	ship.get_node("Avoidance").reset()


func _sense() -> void:
	await physics_frame
	scene.sensors.evaluate()
	await physics_frame
	await physics_frame


func _combat(name: String) -> Variant:
	return CombatShip.of(scene.ship(name))


## 1, 10: the FF01A's reach is its longest weapon (the Wayfarer, 90 u); it acquires a
## detected hostile at 85 u at once, and its weapons still fire only within their own ranges.
func _case_reach() -> void:
	print("\n=== A1 weapon-derived reach")
	await _load()
	var d = _combat("FF01A")
	_place("HostileFF01B", Vector2(25, 110), WEST) # 85 u
	await _sense()
	d.stance = CombatShip.Stance.AGGRESSIVE
	await physics_frame
	await physics_frame
	var cannon: Node = scene.ship("FF01A").get_node("Weapons/ForwardBastionHardpoint").weapon()
	_check("reach %.0f u (longest loadout range: Wayfarer 90); a detected hostile at %.0f u is acquired at once" % [d.acquisition_reach(), d.distance_to(scene.ship("HostileFF01B"))],
		is_equal_approx(d.acquisition_reach(), 90.0) and d.target == scene.ship("HostileFF01B"))
	for i in 180:
		await physics_frame
	_check("acquired at 85 u, the cannon (75 u) still refuses: '%s', no cannon shot" % cannon.reason, cannon.reason.begins_with("Out of range") and cannon.shots == 0)


## 2, 3: no acquisition without faction contact (beyond sensor range, or behind an asteroid).
func _case_contact() -> void:
	print("\n=== A2 sensor contact limits acquisition")
	await _load()
	var d = _combat("FF01A")
	# Test condition: sensors shorter than the FF-01's 90 u reach, so a hostile can lie
	# within reach and beyond sensor range.
	var sensor_range: float = scene.sensors.sensor_range
	scene.sensors.sensor_range = 80.0
	_place("HostileFF01B", Vector2(25, 110), WEST) # 85 u: inside the 90 u reach, beyond the 80 u sensors
	await _sense()
	d.stance = CombatShip.Stance.AGGRESSIVE
	for i in 30:
		await physics_frame
	_check("hostile at 85 u (within reach, beyond sensor range): not detected, not acquired", not scene.sensors.detected(PLAYER, scene.ship("HostileFF01B")) and d.target == null)
	scene.sensors.sensor_range = sensor_range
	var big: MeshInstance3D = null
	for each: MeshInstance3D in scene.get_node("Asteroids").get_children():
		if big == null or each.scale.x > big.scale.x:
			big = each
	var c := Vector2(big.global_position.x, big.global_position.z)
	var r := big.scale.x * 0.5
	_place("FF01A", c + Vector2(-(r + 25.0), 0), EAST)
	_place("HostileFF01B", c + Vector2(r + 12.0, 0), WEST)
	await _sense()
	for i in 30:
		await physics_frame
	_check("hostile behind an asteroid at %.0f u: no contact, not acquired" % d.distance_to(scene.ship("HostileFF01B")),
		not scene.sensors.detected(PLAYER, scene.ship("HostileFF01B")) and d.target == null)


## 4, 5: a ship's reach is its own loadout: FF01B with its Wayfarer out of action reaches
## its cannons' 75 u; a target needing turret rotation is acquired at once.
func _case_escort_reach() -> void:
	print("\n=== A3 FF01B reach and turret rotation")
	await _load("FF01B")
	scene.ship("FF01B").get_node("Weapons/WayfarerHardpoint").weapon().enabled = false
	var g = _combat("FF01B")
	_place("HostileFF01B", Vector2(20, 110), WEST) # 80 u
	await _sense()
	g.stance = CombatShip.Stance.AGGRESSIVE
	for i in 30:
		await physics_frame
	var beyond: bool = g.target == null
	# 70 u at a bearing 120° off the bow: the aft cannon (resting astern) has to turn to it.
	_place("HostileFF01B", Vector2(-60, 110) + Vector2(-35.0, -60.62), WEST)
	await _sense()
	var cannon: Node = scene.ship("FF01B").get_node("Weapons/AftBastionHardpoint").weapon()
	await physics_frame
	var acquired: bool = g.target == scene.ship("HostileFF01B")
	var turning: String = cannon.reason
	_check("FF01B reach %.0f u (cannons 75, rockets 60, point defense 25): a hostile at 80 u is not acquired; at 70 u, 120° off the bow, acquired at once while the cannon is still turning ('%s')" % [g.acquisition_reach(), turning],
		is_equal_approx(g.acquisition_reach(), 75.0) and beyond and acquired and (turning.begins_with("Tracking") or turning.begins_with("Aligning")))


## 6: reloads and alignment do not drop or switch the automatic target, even when a nearer
## hostile appears.
func _case_persistence() -> void:
	print("\n=== A4 target persistence through reloads")
	await _load()
	var d = _combat("FF01A")
	var first: Node3D = scene.ship("HostileFF01B")
	_place("HostileFF01B", Vector2(10, 110), WEST) # 70 u
	await _sense()
	d.stance = CombatShip.Stance.AGGRESSIVE
	await physics_frame
	var changes := [0]
	d.target_changed.connect(func() -> void: changes[0] += 1)
	_place("HostileFF01C", Vector2(-15, 95), WEST) # nearer, appears later
	for i in 60 * 6:
		if i % 12 == 0:
			scene.sensors.evaluate()
		await physics_frame
	var reloads := 0
	for w in d.weapons:
		if w.cooldown_left > 0.0 or w.shots > 0:
			reloads += 1
	_check("6 s of fire and reloads with a nearer hostile appearing: the first target is kept (%d target changes, %d weapons fired)" % [changes[0], reloads],
		d.target == first and changes[0] == 0 and reloads > 0)


## 7: weapons without ammunition do not extend the reach.
func _case_ammunition() -> void:
	print("\n=== A5 empty weapons do not extend the reach")
	await _load()
	var d = _combat("FF01A")
	var missiles: Node = scene.ship("FF01A").get_node("Weapons/WayfarerHardpoint").weapon()
	missiles.ammo = 3 # less than a 4-missile salvo
	_place("HostileFF01B", Vector2(25, 110), WEST) # 85 u
	await _sense()
	d.stance = CombatShip.Stance.AGGRESSIVE
	for i in 30:
		await physics_frame
	_check("3 missiles (no salvo possible): reach %.0f u (cannon), a hostile at 85 u is not acquired" % d.acquisition_reach(),
		is_equal_approx(d.acquisition_reach(), 75.0) and d.target == null)


## 8: a manual target is never replaced, even beyond reach with another hostile close by.
func _case_manual() -> void:
	print("\n=== A6 manual target stays authoritative")
	await _load()
	var d = _combat("FF01A")
	var far: Node3D = scene.ship("HostileFF01A")
	_place("HostileFF01A", Vector2(55, 110), WEST) # 115 u: beyond the reach
	_place("FF01B", Vector2(30, 120), EAST) # spots it for the faction
	_place("HostileFF01B", Vector2(-20, 110), WEST) # 40 u, in reach of every weapon but point defense
	await _sense()
	d.stance = CombatShip.Stance.AGGRESSIVE
	scene.orders.assign_target([scene.ship("FF01A")], far)
	var shots_at_other := [0]
	for w in d.weapons:
		w.shot.connect(func(_wp: Node, _id: int, t: Node3D, _o: Transform3D) -> void:
			if t == scene.ship("HostileFF01B"):
				shots_at_other[0] += 1)
	var locomotion: Node = scene.ship("FF01A").get_node("Locomotion")
	for i in 60 * 4:
		await physics_frame
	_check("manual target at 115 u (beyond reach) with a hostile at 40 u: target kept, %d shots at the nearer ship, no move order" % shots_at_other[0],
		d.target == far and d.manual_target == far and shots_at_other[0] == 0 and not locomotion.has_destination)


## 9: Defensive and Hold Fire do not acquire a merely detected hostile.
func _case_stances() -> void:
	print("\n=== A7 Defensive and Hold Fire unchanged")
	await _load()
	var d = _combat("FF01A")
	_place("HostileFF01B", Vector2(-10, 110), WEST) # 50 u
	await _sense()
	d.stance = CombatShip.Stance.DEFENSIVE
	for i in 60:
		await physics_frame
	var defensive: bool = d.target == null
	d.add_threat(scene.ship("HostileFF01B"))
	await physics_frame
	var threat_taken: bool = d.target == scene.ship("HostileFF01B")
	d.set_stance(CombatShip.Stance.HOLD_FIRE)
	await physics_frame
	_check("Defensive: a detected hostile at 50 u is not acquired until it is a confirmed threat, then it is; Hold Fire: no target",
		defensive and threat_taken and d.target == null)
