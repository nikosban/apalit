extends SceneTree
## Combat prototype v0.5: the consolidated hull baseline (150, one value for every prototype
## ship, from combat_rules.tres). Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/hull_test.gd

const LAB := preload("res://game/tests/combat/fixtures/combat_lab.tscn")
const ENCOUNTERS := [
	preload("res://game/tests/combat/fixtures/e01_cannon.tscn"),
	preload("res://game/tests/combat/fixtures/e02_torpedo.tscn"),
	preload("res://game/tests/combat/fixtures/e03_escort.tscn"),
	preload("res://game/tests/combat/fixtures/e04_missile.tscn"),
	preload("res://game/tests/combat/fixtures/e05_fleet.tscn"),
]
const CombatShip := preload("res://game/combat/combat_ship.gd")
const HULL := 150.0
## Weapon values that this baseline must not touch: family -> [damage, cooldown, range, stock].
const WEAPONS := {"cannon": [12.0, 2.5, 75.0, 40], "gatling": [1.0, 0.08, 25.0, 400], "torpedo": [40.0, 6.0, 110.0, 4], "missile": [30.0, 4.0, 90.0, 6]}

var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _case_spawn()
	await _case_damage()
	await _case_reset()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


## Every ship of E01–E05 starts at 150; the weapon values are unchanged. (Production port:
## the v0.2 fixed-weapon arena is not migrated.)
func _case_spawn() -> void:
	print("\n=== H1 spawn hull and weapon values")
	var hulls := {}
	var weapons_ok := true
	var scenes := ENCOUNTERS.duplicate()
	for i in scenes.size():
		var scene: Node3D = scenes[i].instantiate()
		scene.scenario_index = i
		root.add_child(scene)
		await physics_frame
		for ship: Node3D in scene.get_node("Ships").get_children():
			var c = CombatShip.of(ship)
			hulls["%s %s" % [scene.name, ship.name]] = c.health
			for w in c.weapons:
				var want: Array = WEAPONS.get(String(w.config.family), [])
				if not want.is_empty() and [w.config.damage, w.config.cooldown, w.config.weapon_range, w.config.ammunition] != want:
					weapons_ok = false
					print("  weapon differs: %s %s %s" % [ship.name, w.name, str([w.config.damage, w.config.cooldown, w.config.weapon_range, w.config.ammunition])])
		root.remove_child(scene)
		scene.free()
	# Scenario conditions set on purpose (encounters.gd): E03's escorted target is made durable.
	var authored := {"E03Escort HostileGunship": 400.0}
	var wrong := hulls.keys().filter(func(k: String) -> bool: return not is_equal_approx(hulls[k], authored.get(k, HULL)))
	_check("%d ships in E01–E05 start with hull 150 (E03's HostileGunship keeps its scenario hull 400)%s" % [hulls.size(), "" if wrong.is_empty() else " (not: %s)" % ", ".join(wrong)], wrong.is_empty() and hulls.size() >= 20)
	_check("weapon damage, cooldown, range and configured stock unchanged (cannon, Gatling, torpedo, missile)", weapons_ok)


## Damage and destruction thresholds on the 150 hull.
func _case_damage() -> void:
	print("\n=== H2 damage and destruction thresholds")
	var scene: Node3D = ENCOUNTERS[4].instantiate()
	scene.scenario_index = 4
	root.add_child(scene)
	await physics_frame
	var g = CombatShip.of(scene.ship("Gunship"))
	for i in 4:
		g.take_hit(30.0, -1)
	var four_missiles: bool = g.alive and is_equal_approx(g.health, 30.0)
	g.take_hit(30.0, -1)
	var d = CombatShip.of(scene.ship("Destroyer"))
	for i in 12:
		d.take_hit(12.0, -1)
	var twelve_shells: bool = d.alive and is_equal_approx(d.health, 6.0)
	d.take_hit(12.0, -1)
	_check("a full 4-missile salvo (120) leaves 30 of 150, the fifth missile destroys; 12 cannon hits leave 6, the 13th destroys", four_missiles and not g.alive and twelve_shells and not d.alive)
	root.remove_child(scene)
	scene.free()


## E05 through the lab: no profile selection; a reset restores the full hull.
func _case_reset() -> void:
	print("\n=== H3 E05 reset and HUD")
	var lab: Node = LAB.instantiate()
	lab.encounter_index = 4
	root.add_child(lab)
	for i in 5:
		await physics_frame
	var arena: Node = lab.arena
	CombatShip.of(arena.ship("Destroyer")).take_hit(60.0, -1)
	var h_taken: bool = arena._combat_key(KEY_H)
	await process_frame
	var same_arena: bool = lab.arena == arena
	arena._combat_key(KEY_F5)
	await process_frame
	await physics_frame
	var fresh: Node = lab.arena
	var hud_text: String = fresh.get_node("CombatHUD")._speed.text
	_check("H is no longer a command (same battle); F5 restores the Destroyer to 150; no profile property or HUD line ('%s')" % hud_text.replace("\n", " | "),
		not h_taken and same_arena and fresh != arena and is_equal_approx(CombatShip.of(fresh.ship("Destroyer")).health, HULL)
		and fresh.get("balance_profile") == null and not hud_text.contains("profile"))
	root.remove_child(lab)
	lab.free()
