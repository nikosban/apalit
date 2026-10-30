extends SceneTree
## Combat prototype v0.4 (A3): weapon information checks on E05. Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/weapon_info_test.gd
##   W1  Weapon.assess() (read-only eligibility) against the firing authorization the same
##       tick, over the passive E05 battle.
##   W2  Eligibility reasons per family: in range, out of range, outside the arc or cone,
##       asteroid obstruction, no ammunition, reloading, no sensor contact; the HUD readout.
##   W3  Envelope display: only on request (Alt, target selection), every weapon for one
##       ship, one outline per ship for several; Alt held does not change movement orders or
##       target selection clicks.

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const CombatHud := preload("res://game/ui/combat_hud.gd")
const TS := CombatShip.TargetState
const EAST := -PI * 0.5
const WEST := PI * 0.5

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _case_agreement()
	await _case_reasons()
	await _case_display()
	_free()
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


func _load(quiet: bool) -> Node3D:
	_free()
	scene = E05.instantiate()
	scene.scenario_index = 0
	var sensors := scene.get_node("Sensors") # A3 / A4 checks without the fog of war (fog_test covers it)
	scene.remove_child(sensors)
	sensors.free()
	root.add_child(scene)
	if quiet:
		scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
		scene.enemy_controller._steps.clear()
		scene.enemy_controller._patrols.clear()
		for ship: Node in scene.get_node("Ships").get_children():
			CombatShip.of(ship).stance = CombatShip.Stance.HOLD_FIRE
	await physics_frame
	while not scene.enemy_controller.started:
		await physics_frame
	return scene


func _place(ship_name: String, point: Vector2, heading: float) -> void:
	var ship: Node3D = scene.ship(ship_name)
	ship.get_node("Locomotion").place(point, heading)
	ship.get_node("Avoidance").reset()


func _weapon(ship_name: String, family: String) -> Node:
	for weapon in CombatShip.of(scene.ship(ship_name)).weapons:
		if String(weapon.config.family) == family:
			return weapon
	return null


## W1: every tick of the passive battle, for every weapon engaging its ship's offensive
## target without firing that tick, assess() gives the same state and reason as the firing
## authorization just ran, in the firing order (ticks that fired, whose cooldown has just
## restarted, and point defense ticks, whose target is ordnance, are excluded).
func _case_agreement() -> void:
	print("\n=== W1 assess() against the firing authorization")
	await _load(false)
	var compared := 0
	var mismatches: Array[String] = []
	var battle := scene.get_node("FleetBattle")
	for i in 60 * 120:
		await physics_frame
		for ship: Node3D in scene.get_node("Ships").get_children():
			var combat = CombatShip.of(ship)
			if combat == null or not combat.alive or combat.target == null or not is_instance_valid(combat.target):
				continue
			for weapon in combat.weapons:
				if weapon.reason == "Firing" or weapon.get("mode") == "defense":
					continue
				var result: Dictionary = weapon.assess(combat.target, true)
				compared += 1
				if result.state != weapon.state or (result.reason != weapon.reason and not (result.reason == "Ready" and weapon.reason == "Firing")):
					mismatches.append("%.2f %s %s: assess %s '%s' / authorization %s '%s'" % [CombatShip.now(), ship.name, weapon.name,
						CombatShip.STATE_NAMES[result.state], result.reason, CombatShip.STATE_NAMES[weapon.state], weapon.reason])
		if battle.finished:
			break
	for line in mismatches.slice(0, 10):
		print("  MISMATCH " + line)
	_check("assess() matches the firing authorization in %d weapon-ticks (%d mismatches)" % [compared, mismatches.size()], compared > 1000 and mismatches.is_empty())


## W2: the reasons the target-selection readout gives, per family, are the authorization's.
func _case_reasons() -> void:
	print("\n=== W2 eligibility reasons per family")
	await _load(true)
	var asteroid: MeshInstance3D = null
	var origin := Vector2(-60, 60)
	for each: MeshInstance3D in scene.get_node("Asteroids").get_children():
		if each.scale.x >= 6.0 and each.scale.x <= 14.0 and (asteroid == null or Vector2(each.global_position.x, each.global_position.z).distance_to(origin) < Vector2(asteroid.global_position.x, asteroid.global_position.z).distance_to(origin)):
			asteroid = each
	var center := Vector2(asteroid.global_position.x, asteroid.global_position.z)
	var radius := asteroid.scale.x * 0.5
	# Clear water first: FF01A heading east, the target 50 u ahead.
	var open := Vector2(-20, 110)
	for name in ["FF01B", "FF01C", "HostileFF01C", "HostileFF01A"]:
		_place(name, Vector2(-140 + 10 * ["FF01B", "FF01C", "HostileFF01C", "HostileFF01A"].find(name), -140), EAST)
	_place("FF01A", open, EAST)
	_place("HostileFF01B", open + Vector2(50, 0), WEST)
	var ff01a = CombatShip.of(scene.ship("FF01A"))
	ff01a.stance = CombatShip.Stance.AGGRESSIVE
	var target: Node3D = scene.ship("HostileFF01B")
	await physics_frame
	var cannon := _weapon("FF01A", "cannon")
	var gatling := _weapon("FF01A", "gatling")
	var rocket := _weapon("FF01A", "rocket")
	var missile := _weapon("FF01A", "missile")
	var r := {}
	for w in [cannon, gatling, rocket, missile]:
		r[w.config.family] = w.assess(target)
	print("  ahead 50 u: " + str(r))
	_check("50 u ahead: cannon, point defense (75 u), rockets and missiles can engage",
		r[&"cannon"].capable and r[&"gatling"].capable and r[&"rocket"].capable and r[&"missile"].capable)
	_place("HostileFF01B", open + Vector2(85, 0), WEST) # beyond the cannon's and the PDC's 75 u
	await physics_frame
	var beyond := {"cannon": cannon.assess(target), "gatling": gatling.assess(target), "missile": missile.assess(target)}
	print("  ahead 85 u: " + str(beyond))
	_check("85 u ahead: cannon and point defense out of range (75 u), missiles (90 u) still capable",
		not beyond.cannon.capable and beyond.cannon.reason.begins_with("Out of range") and not beyond.gatling.capable
		and beyond.gatling.reason.begins_with("Out of range") and beyond.missile.capable)
	_place("HostileFF01B", open + Vector2(-30, 0), WEST) # astern
	await physics_frame
	var astern := {"cannon": cannon.assess(target), "rocket": rocket.assess(target), "missile": missile.assess(target)}
	print("  astern 30 u: " + str(astern))
	_check("dead astern 30 u: the forward cannon is outside its traverse (blind arc), missiles still capable",
		astern.cannon.state == TS.OUTSIDE_ARC and astern.missile.capable)
	# Behind the asteroid: FF01A west of it facing east, target east of it.
	_place("FF01A", center + Vector2(-(radius + 16.0), 0), EAST)
	_place("HostileFF01B", center + Vector2(radius + 12.0, 0), WEST)
	await physics_frame
	var hidden := {"cannon": cannon.assess(target), "rocket": rocket.assess(target), "missile": missile.assess(target)}
	print("  behind asteroid r %.1f: %s" % [radius, str(hidden)])
	_check("an asteroid between: the cannon obstructed (asteroid), missiles still capable (they avoid obstacles)",
		hidden.cannon.state == TS.OBSCURED and hidden.missile.capable)
	_place("FF01A", open, EAST)
	_place("HostileFF01B", open + Vector2(50, 0), WEST)
	await physics_frame
	cannon.ammo = 0
	missile.cancel_salvo("test set-up") # E05's salvo launchers may be mid-salvo from the last tick
	rocket.cancel_salvo()
	missile.cooldown_left = 1.5
	var empty: Dictionary = cannon.assess(target)
	var reloading: Dictionary = missile.assess(target)
	_check("no ammunition: '%s'; reloading: '%s' (capable, waiting)" % [empty.reason, reloading.reason],
		not empty.capable and empty.reason == "Out of ammunition" and reloading.capable and reloading.reason.begins_with("Reloading"))
	scene.contacts.set_contact(0, target, false)
	var lost: Dictionary = rocket.assess(target)
	_check("no sensor contact: '%s', not capable" % lost.reason, not lost.capable and lost.state == TS.CONTACT_LOST)
	scene.contacts.set_contact(0, target, true)
	# The same target assigned for real: one tick of the authorization gives the same reasons.
	var before := {}
	for w in [cannon, gatling, rocket, missile]:
		before[w] = w.assess(target, true)
	missile.cooldown_left = 1.5 + 1.0 / 60.0 # stays reloading after the tick
	rocket.cooldown_left = 3.0
	before[missile] = missile.assess(target, true)
	before[rocket] = rocket.assess(target, true)
	scene.orders.assign_target([scene.ship("FF01A")], target)
	await physics_frame
	var same := true
	for w in [cannon, gatling, rocket, missile]:
		var expect: Dictionary = before[w]
		var reason: String = w.reason
		if expect.reason.begins_with("Reloading") and reason.begins_with("Reloading"):
			continue
		# Out of range reports the live muzzle distance and Tracking the live angle off the
		# solution; both move with a turning turret.
		for live: String in ["Out of range", "Tracking ("]:
			if expect.state == w.state and expect.reason.begins_with(live) and reason.begins_with(live):
				reason = expect.reason
		if expect.state != w.state or (expect.reason != reason and not (expect.reason == "Ready" and reason == "Firing")):
			same = false
			print("  differs: %s assess '%s' / authorization '%s'" % [w.name, expect.reason, reason])
	_check("assigned for real, the next tick's authorization gives the reasons the readout showed", same)
	var text := CombatHud.inspect_text([scene.ship("FF01A")], target)
	print(text.indent("  "))
	var lines_ok := true
	for w in CombatShip.of(scene.ship("FF01A")).weapons:
		var now: Dictionary = w.assess(target)
		lines_ok = lines_ok and text.contains("%s %s: %s" % ["+" if now.capable else "-", w.config.display_name, now.reason])
	_check("the HUD readout lists the distance and every weapon with its assess() reason",
		text.contains("FF-01") and text.contains("50.0 u") and text.contains("- NC-90 Bastion: Out of ammunition") and text.contains("+ PDC-20 Kestrel: ") and lines_ok)


## W3: envelopes only on request; Alt does not change orders or target-selection clicks.
func _case_display() -> void:
	print("\n=== W3 envelope display and the Alt modifier")
	await _load(true)
	var envelopes: Node = scene.envelopes
	var ff01a: Node3D = scene.ship("FF01A")
	var ff01b: Node3D = scene.ship("FF01B")
	var rig: Node3D = scene.get_node("CameraRig")
	rig.global_position = Vector3(ff01a.global_position.x + 10, 0, ff01a.global_position.z)
	rig.rotation = Vector3.ZERO
	await process_frame
	scene.selection().set_selection([ff01a])
	await process_frame
	var idle_drawn: int = envelopes.drawn_weapons
	_press_alt(true)
	await process_frame
	await process_frame
	var single: int = envelopes.drawn_weapons
	var weapons: int = CombatShip.of(ff01a).weapons.size()
	# Alt held: a right-click on the ground still moves the ship.
	var camera := scene.get_viewport().get_camera_3d()
	var goal := Vector3(ff01a.global_position.x + 12, 0, ff01a.global_position.z + 6)
	_mouse(camera.unproject_position(goal), MOUSE_BUTTON_RIGHT, true)
	await process_frame
	var moved: bool = ff01a.get_node("Locomotion").has_destination
	scene.selection().set_selection([ff01a, ff01b])
	await process_frame
	var outlines: Array = envelopes.visible_ships
	var outline_weapons: int = envelopes.drawn_weapons
	_press_alt(false)
	await process_frame
	var released: int = envelopes.visible_ships.size()
	_check("selected, no Alt: no envelope (%d drawn); Alt held: all %d weapons of the one ship (%d)" % [idle_drawn, weapons, single], idle_drawn == 0 and single == weapons)
	_check("Alt held: a right-click on the ground still gives the MOVE", moved)
	_check("two ships selected with Alt: one outline each, no per-weapon envelopes (%d ships, %d weapons); released: none" % [outlines.size(), outline_weapons],
		outlines.size() == 2 and outline_weapons == 0 and released == 0)
	# Target selection shows the envelopes without Alt, and an Alt-click assigns as usual.
	scene.selection().set_selection([ff01a])
	var hostile: Node3D = scene.ship("HostileFF01B")
	_place("HostileFF01B", Vector2(ff01a.global_position.x + 40, ff01a.global_position.z), WEST)
	await physics_frame
	await process_frame
	scene.begin_target_selection()
	await process_frame
	var during: int = envelopes.drawn_weapons
	_press_alt(true)
	_mouse(camera.unproject_position(hostile.global_position), MOUSE_BUTTON_LEFT, true)
	await process_frame
	_press_alt(false)
	_check("target selection shows the envelopes without Alt (%d); an Alt-click on the hostile assigns it and closes selection" % during,
		during == weapons and CombatShip.of(ff01a).manual_target == hostile and not scene.target_selection)


func _press_alt(down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_ALT
	event.physical_keycode = KEY_ALT
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _mouse(position: Vector2, button: MouseButton, alt: bool) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = position
		event.global_position = position
		event.alt_pressed = alt
		root.push_input(event, true)
