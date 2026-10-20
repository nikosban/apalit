extends SceneTree
## Behavior prototype v0.1: lightweight command-interaction checks (Commands, Tactics,
## Weapon Profiles) on small fixtures built from the P01 scene with its script cleared.
## Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/command_test.gd

const P01 := preload("res://game/tests/combat/fixtures/p01_defensive.tscn")
const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const LAB := preload("res://game/tests/combat/fixtures/combat_lab.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const Profiles := preload("res://game/behavior/weapon_profiles.gd")
const Scenarios := preload("res://game/tests/combat/fixtures/behavior_scenarios.gd")
const Docking := preload("res://game/stations/docking.gd")
const TS := CombatShip.TargetState
const EAST := -PI * 0.5
const WEST := PI * 0.5
const HOLD := 0
const DEFENSIVE := 1
const AGGRESSIVE := 2
const P := Profiles.Profile

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _case_passive_attack()
	await _case_passive_point_defense()
	await _case_defensive_move()
	await _case_attack_move()
	await _case_contact_loss()
	await _case_reacquire()
	await _case_guard_cancellation()
	await _case_guard_destroyed()
	await _case_profiles()
	await _case_profile_does_not_gate_fire()
	await _case_manual_target_pursuit()
	await _case_defensive_priority()
	await _case_ownership()
	await _case_waypoints()
	await _case_paused()
	await _case_dock()
	await _case_without_behavior()
	await _case_reset()
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


## P01 with its script cleared, every ship holding fire in a far corner (the player ships
## keep their Behavior nodes).
func _load() -> void:
	_free()
	scene = P01.instantiate()
	scene.scenario_index = Scenarios.FIRST
	root.add_child(scene)
	scene.enemy_controller._steps.clear()
	scene.enemy_controller._patrols.clear()
	while not scene.enemy_controller.started:
		await physics_frame
	var corners := {"Destroyer": Vector2(-130, -130), "Gunship": Vector2(-130, 130), "Gunship2": Vector2(-110, 130),
		"HostileGunship": Vector2(130, -130), "HostileGunship2": Vector2(130, -110), "HostileDestroyer": Vector2(130, 130)}
	for name: String in corners:
		_put(name, corners[name], EAST)
		scene.orders.set_stance([_ship(name)], HOLD)
	await _sense()


func _ship(name: String) -> Node3D:
	return scene.ship(name)


func _c(name: String) -> Variant:
	return CombatShip.of(_ship(name))


func _b(name: String) -> Variant:
	return Behavior.of(_ship(name))


# Places a ship at rest; a Behavior's defended position and request state start there.
func _put(name: String, point: Vector2, heading: float) -> void:
	var ship := _ship(name)
	ship.get_node("Locomotion").place(point, heading)
	ship.get_node("Avoidance").reset()
	var b = Behavior.of(ship)
	if b != null:
		b._set_anchor()
		b.has_station = false


func _sense() -> void:
	await physics_frame
	scene.sensors.evaluate()
	await physics_frame


func _run(seconds: float, each: Callable = Callable()) -> void:
	var end := CombatShip.now() + seconds
	while CombatShip.now() < end:
		await physics_frame
		if each.is_valid():
			each.call()


func _until(seconds: float, condition: Callable) -> bool:
	var end := CombatShip.now() + seconds
	while CombatShip.now() < end:
		await physics_frame
		if condition.call():
			return true
	return false


# Counts a ship's shots at ships / at ordnance: [ships, ordnance].
func _count_shots(name: String) -> Array:
	var counts := [0, 0]
	for w in _c(name).weapons:
		w.shot.connect(func(_wp: Node, _id: int, t: Node3D, _o: Transform3D) -> void:
			if CombatShip.of(t) != null:
				counts[0] += 1
			else:
				counts[1] += 1)
	return counts


static func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)


func _requests(name: String) -> Array:
	return _b(name).log.filter(func(line: String) -> bool: return line.contains(" request ("))


# --- Passive -----------------------------------------------------------------------------

## Passive + Attack: approach, fire and pursuit are authorized for that target only; the
## stance stays Hold Fire; afterwards ordinary Passive behaviour.
func _case_passive_attack() -> void:
	print("\n=== C1 Passive + Attack")
	await _load()
	_put("Gunship", Vector2(-60, 100), EAST)
	_put("HostileGunship", Vector2(22, 100), WEST) # 82 u: beyond the cannon's 75 u
	await _sense()
	var shots := _count_shots("Gunship")
	var given: int = scene.orders.attack([_ship("Gunship")], _ship("HostileGunship"))
	var stance_kept := [true]
	await _run(20.0, func() -> void: stance_kept[0] = stance_kept[0] and _c("Gunship").stance == HOLD)
	var b = _b("Gunship")
	_check("Attack taken under Hold Fire (%d); it approached (%d requests) and fired (%d shots); stance still Hold Fire" % [given, b.move_requests, shots[0]],
		given == 1 and b.move_requests >= 1 and shots[0] > 0 and stance_kept[0] and b.command == Behavior.Command.ATTACK)
	_c("HostileGunship").destroy()
	var ended: bool = await _until(1.0, func() -> bool: return b.command == Behavior.Command.NONE)
	await _run(1.0) # its stop request settles
	ended = ended and _c("Gunship").attack_target == null and _c("Gunship").manual_target == null
	_put("HostileGunship2", _planar(_ship("Gunship")) + Vector2(40, 0), WEST)
	await _sense()
	var before := [shots[0], b.move_requests]
	await _run(4.0)
	_check("the Attack ended with its target; afterwards a hostile at 40 u draws no fire and no movement (Passive)",
		ended and shots[0] == before[0] and b.move_requests == before[1] and _c("Gunship").target == null and _c("Gunship").stance == HOLD)


## Passive + incoming missiles: point defense intercepts; no offensive fire at the launcher.
func _case_passive_point_defense() -> void:
	print("\n=== C2 Passive + incoming missiles")
	await _load()
	_put("Gunship", Vector2(-60, 100), EAST)
	_put("HostileDestroyer", Vector2(15, 100), WEST) # 75 u: missiles (90 u) reach
	await _sense()
	var shots := _count_shots("Gunship")
	var intercepts := [0]
	scene.projectiles.ordnance_finished.connect(func(record: Dictionary) -> void:
		if record.outcome == "intercepted" and record.intercepted_by == "Gunship":
			intercepts[0] += 1)
	scene.orders.set_stance([_ship("HostileDestroyer")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileDestroyer")], _ship("Gunship"))
	await _run(16.0)
	_check("Hold Fire under missile attack: Gatlings fired at ordnance (%d rounds, %d intercepts); no shot at the launcher, no target, no movement" % [shots[1], intercepts[0]],
		shots[1] > 0 and shots[0] == 0 and _c("Gunship").target == null and _b("Gunship").move_requests == 0)


# --- Defensive + Move ----------------------------------------------------------------------

## Defensive + Move: the attacker is answered on the way; the destination never changes; no
## pursuit or local repositioning until the Move has arrived.
func _case_defensive_move() -> void:
	print("\n=== C3 Defensive + Move")
	await _load()
	_put("Gunship", Vector2(-70, 100), EAST)
	_put("HostileGunship", Vector2(-20, 70), WEST)
	await _sense()
	scene.orders.set_stance([_ship("Gunship")], DEFENSIVE)
	scene.orders.set_stance([_ship("HostileGunship")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileGunship")], _ship("Gunship"))
	var shots := _count_shots("Gunship")
	var point := Vector2(30, 105)
	scene.orders.move([_ship("Gunship")], point)
	var locomotion: Node = _ship("Gunship").get_node("Locomotion")
	var b = _b("Gunship")
	var kept := [true, 0]
	var arrived: bool = await _until(40.0, func() -> bool:
		if locomotion.has_destination:
			kept[0] = kept[0] and locomotion.destination.distance_to(point) <= 0.5 and b.command == Behavior.Command.MOVE
			kept[1] = maxi(kept[1], b.move_requests)
		return not locomotion.has_destination)
	_check("Move under fire: retaliated (%d shots) while the destination stayed (%.0f, %.0f) and the layer requested nothing (%d)" % [shots[0], point.x, point.y, kept[1]],
		arrived and shots[0] > 0 and kept[0] and kept[1] == 0)
	await physics_frame
	_check("after arrival the Move is over and the defended position is where it arrived", b.command == Behavior.Command.NONE and b.anchor.distance_to(point) < 1.0)


# --- Attack-Move -----------------------------------------------------------------------------

## Aggressive + Attack-Move: an enemy met on the way is engaged; the route is not replaced.
func _case_attack_move() -> void:
	print("\n=== C4 Attack-Move")
	await _load()
	_put("Gunship", Vector2(-70, 100), EAST)
	_put("HostileGunship", Vector2(0, 112), WEST) # 12 u off the route, holding fire
	await _sense()
	scene.orders.set_stance([_ship("Gunship")], AGGRESSIVE)
	var shots := _count_shots("Gunship")
	var point := Vector2(60, 100)
	var given: int = scene.orders.attack_move([_ship("Gunship")], point)
	var b = _b("Gunship")
	var offset := [0.0]
	var done: bool = await _until(90.0, func() -> bool:
		if b.command == Behavior.Command.ATTACK_MOVE:
			offset[0] = maxf(offset[0], b._route_offset(b._here()))
		return b.command != Behavior.Command.ATTACK_MOVE)
	var log_text := " | ".join(b.log)
	_check("Aggressive: an enemy close to the route interrupted travel (%d shots, %d requests), within the %.0f u leash (max %.1f u off), then travel resumed to the destination" % [shots[0], b.move_requests, Behavior.ATTACK_MOVE_LEASH, offset[0]],
		given == 1 and done and shots[0] > 0 and log_text.contains("encounter with HostileGunship") and log_text.contains("travel on")
		and b.move_requests >= 2 and offset[0] <= Behavior.ATTACK_MOVE_LEASH + 4.0 and b._here().distance_to(point) <= Behavior.ARRIVAL + 0.5)
	# An enemy beyond reach and beyond the leash: no detour.
	await _load()
	_put("Gunship", Vector2(-70, 100), EAST)
	_put("HostileGunship", Vector2(0, 22), WEST) # 78 u off the route
	await _sense()
	scene.orders.set_stance([_ship("Gunship")], AGGRESSIVE)
	scene.orders.attack_move([_ship("Gunship")], point)
	b = _b("Gunship")
	done = await _until(60.0, func() -> bool: return b.command != Behavior.Command.ATTACK_MOVE)
	_check("Aggressive: an enemy 78 u off the route (positions beyond the leash) causes no detour: one request, arrived (%d)" % b.move_requests,
		done and b.move_requests == 1 and b._here().distance_to(point) <= Behavior.ARRIVAL + 0.5)
	# Passive: travels on, no offensive fire.
	await _load()
	_put("Gunship", Vector2(-70, 100), EAST)
	_put("HostileGunship", Vector2(0, 112), WEST)
	await _sense()
	shots = _count_shots("Gunship")
	scene.orders.attack_move([_ship("Gunship")], point)
	b = _b("Gunship")
	done = await _until(60.0, func() -> bool: return b.command != Behavior.Command.ATTACK_MOVE)
	_check("Passive: Attack-Move travels straight through (%d request), no offensive shot (%d)" % [b.move_requests, shots[0]],
		done and b.move_requests == 1 and shots[0] == 0 and b._here().distance_to(point) <= Behavior.ARRIVAL + 0.5)


# --- Attack and contact loss ---------------------------------------------------------------

## Contact lost: the ship goes to the last position seen in contact (not the live one) and
## cancels the Attack there.
func _case_contact_loss() -> void:
	print("\n=== C5 Attack + contact loss")
	await _load()
	_put("Gunship", Vector2(-70, 100), EAST)
	_put("HostileGunship", Vector2(-10, 100), WEST)
	await _sense()
	scene.orders.set_stance([_ship("Gunship")], DEFENSIVE)
	scene.orders.attack([_ship("Gunship")], _ship("HostileGunship"))
	await _run(1.0)
	var seen := _planar(_ship("HostileGunship"))
	scene.contacts.set_contact(0, _ship("HostileGunship"), false)
	_put("HostileGunship", Vector2(-10, 40), WEST) # its live position, now hidden
	var b = _b("Gunship")
	var ended: bool = await _until(40.0, func() -> bool: return b.command != Behavior.Command.ATTACK)
	var requests := _requests("Gunship")
	var investigate: Array = requests.filter(func(line: String) -> bool: return line.contains("investigate"))
	var near_live: Array = requests.filter(func(line: String) -> bool:
		var r := RegEx.create_from_string("request \\((-?[\\d.]+), (-?[\\d.]+)\\)").search(line)
		return Vector2(float(r.get_string(1)), float(r.get_string(2))).distance_to(Vector2(-10, 40)) < 20.0)
	var point := RegEx.create_from_string("request \\((-?[\\d.]+), (-?[\\d.]+)\\)").search(investigate[0]) if not investigate.is_empty() else null
	var target_point := Vector2(float(point.get_string(1)), float(point.get_string(2))) if point != null else Vector2.INF
	_check("investigated the last known position (%.0f, %.0f) = last seen (%.0f, %.0f), never the live one" % [target_point.x, target_point.y, seen.x, seen.y],
		investigate.size() == 1 and target_point.distance_to(seen) < 1.5 and near_live.is_empty())
	_check("not reacquired there: Attack canceled, its target and authorization cleared (%s)" % b.log[b.log.size() - 2],
		ended and b.command == Behavior.Command.NONE and _c("Gunship").manual_target == null and _c("Gunship").attack_target == null
		and b.log.any(func(line: String) -> bool: return line.contains("not reacquired")))


## Contact returns during the investigation: the Attack continues.
func _case_reacquire() -> void:
	print("\n=== C6 Attack + contact regained")
	await _load()
	_put("Gunship", Vector2(-70, 100), EAST)
	_put("HostileGunship", Vector2(-10, 100), WEST)
	await _sense()
	scene.orders.attack([_ship("Gunship")], _ship("HostileGunship"))
	await _run(1.0)
	scene.contacts.set_contact(0, _ship("HostileGunship"), false)
	var b = _b("Gunship")
	await _until(5.0, func() -> bool: return b.investigating)
	var was_investigating: bool = b.investigating
	scene.contacts.set_contact(0, _ship("HostileGunship"), true)
	await _run(1.5)
	_check("investigating, then contact regained: the Attack goes on (command %s, investigating %s)" % [Behavior.COMMAND_NAMES[b.command], b.investigating],
		was_investigating and b.command == Behavior.Command.ATTACK and not b.investigating and b.log.any(func(line: String) -> bool: return line.contains("contact reacquired")))


# --- Guard ---------------------------------------------------------------------------------

## Every replacing command ends Guard for good; tactic and profile stay.
func _case_guard_cancellation() -> void:
	print("\n=== C7 Guard cancellation")
	await _load()
	_put("Destroyer", Vector2(-60, 100), EAST)
	_put("Gunship", Vector2(-60, 82), EAST)
	_put("HostileGunship", Vector2(30, 100), WEST)
	await _sense()
	scene.orders.set_stance([_ship("Gunship")], AGGRESSIVE)
	var g := [_ship("Gunship")]
	var b = _b("Gunship")
	var o = scene.orders
	var commands := {
		"Move": func() -> void: o.move(g, Vector2(-60, 70)),
		"Attack": func() -> void: o.attack(g, _ship("HostileGunship")),
		"Attack-Move": func() -> void: o.attack_move(g, Vector2(-70, 70)),
		"Waypoint Move": func() -> void: o.request(g, "Waypoint Move"),
		"Dock": func() -> void: o.request(g, "Dock"),
		"Cancel": func() -> void: o.cancel(g),
	}
	var results: Array[String] = []
	var all_ok := true
	for kind: String in commands:
		o.guard(g, _ship("Destroyer"))
		await _run(0.6)
		var guarding: bool = b.command == Behavior.Command.GUARD
		commands[kind].call()
		await physics_frame
		var ended: bool = b.command != Behavior.Command.GUARD and b.guard_target == null
		await _run(1.5)
		var stays: bool = b.command != Behavior.Command.GUARD and b.guard_target == null
		var kept: bool = _c("Gunship").stance == AGGRESSIVE and b.requested_profile == P.MID
		results.append("%s %s" % [kind, "ok" if guarding and ended and stays and kept else "FAILED"])
		all_ok = all_ok and guarding and ended and stays and kept
		o.cancel(g)
		await _run(0.3)
	_check("Guard ended for good by %s; stance and profile kept" % ", ".join(results), all_ok)


## The protected ship's destruction ends Guard in that tick; no automatic new target.
func _case_guard_destroyed() -> void:
	print("\n=== C8 Guard target destroyed")
	await _load()
	_put("Destroyer", Vector2(-60, 100), EAST)
	_put("Gunship", Vector2(-60, 82), EAST)
	_put("Gunship2", Vector2(-60, 118), EAST)
	await _sense()
	scene.orders.set_stance([_ship("Gunship")], AGGRESSIVE)
	scene.orders.guard([_ship("Gunship"), _ship("Gunship2")], _ship("Destroyer"))
	await _run(2.0)
	var guards := [_b("Gunship"), _b("Gunship2")]
	var stances: Array = guards.map(func(g: Node) -> int: return g.combat.stance)
	var profiles: Array = guards.map(func(g: Node) -> int: return g.requested_profile)
	var guarding: bool = guards.all(func(g: Node) -> bool: return g.command == Behavior.Command.GUARD)
	_c("Destroyer").destroy()
	var same_call: bool = guards.all(func(g: Node) -> bool: return g.command == Behavior.Command.NONE and g.guard_target == null)
	await _run(3.0)
	_check("both Guards ended inside the destroy() call; 3 s later still unassigned (Gunship2 not taken as a new target)",
		guarding and same_call and guards.all(func(g: Node) -> bool: return g.command != Behavior.Command.GUARD and g.guard_target == null))
	_check("stances and requested profiles kept", guards.map(func(g: Node) -> int: return g.combat.stance) == stances and guards.map(func(g: Node) -> int: return g.requested_profile) == profiles)


# --- Weapon Profiles -------------------------------------------------------------------------

func _case_profiles() -> void:
	print("\n=== C9 Profile availability and fallback")
	await _load()
	var gunship = _c("Gunship")
	var destroyer = _c("Destroyer")
	var refused: int = scene.orders.set_profile([_ship("Gunship")], P.SIEGE)
	_check("availability from installed weapons: Gunship %s, Destroyer %s; Siege refused for the Gunship (%d taken)" % [str(Profiles.available(gunship)), str(Profiles.available(destroyer)), refused],
		Profiles.available(gunship) == [P.MID, P.CLOSE] and Profiles.available(destroyer) == [P.SIEGE, P.MID, P.CLOSE] and refused == 0 and _b("Gunship").requested_profile == P.MID)
	var b = _b("Destroyer")
	scene.orders.set_profile([_ship("Destroyer")], P.SIEGE)
	for w in destroyer.weapons:
		if Profiles.category(w) == P.SIEGE:
			w.ammo = 0
			w.magazine = 0
	var mid: int = b.effective()
	var mid_reason: String = b.fallback_reason
	for w in destroyer.weapons:
		if Profiles.category(w) == P.MID:
			w.ammo = 0
	var close: int = b.effective()
	_check("Destroyer requested Siege: long-range empty -> %s (%s); cannon empty too -> %s; request still Siege" % [Profiles.NAMES[mid], mid_reason, Profiles.NAMES[close]],
		mid == P.MID and mid_reason == "no ammunition" and close == P.CLOSE and b.requested_profile == P.SIEGE)
	_ship("Gunship2").get_node("Weapons/DorsalHardpoint/Cannon").enabled = false
	_check("a Gatling-only ship (cannon out of action) offers Close Quarters only: %s; fallback order from Mid-range %s" % [str(Profiles.available(_c("Gunship2"))), str(Profiles.fallback_order(P.MID))],
		Profiles.available(_c("Gunship2")) == [P.CLOSE] and Profiles.fallback_order(P.MID) == [P.MID, P.CLOSE, P.SIEGE])


## A profile chooses positions only: under Close Quarters the cannon still fires at 50 u.
func _case_profile_does_not_gate_fire() -> void:
	print("\n=== C10 Profiles do not gate fire")
	await _load()
	_put("Gunship", Vector2(-60, 100), EAST)
	_put("HostileGunship", Vector2(-10, 100), WEST)
	await _sense()
	scene.orders.set_profile([_ship("Gunship")], P.CLOSE)
	scene.orders.set_stance([_ship("Gunship")], AGGRESSIVE)
	var cannon: Node = _ship("Gunship").get_node("Weapons/DorsalHardpoint/Cannon")
	await _run(5.0)
	_check("Close Quarters requested, target at 50 u: the cannon fired anyway (%d shots) while the ship closed in (%d requests)" % [cannon.shots, _b("Gunship").move_requests],
		cannon.shots > 0 and _b("Gunship").move_requests >= 1)


# --- Tactics ---------------------------------------------------------------------------------

## Aggressive pursuit follows the manual target, not a nearer hostile.
func _case_manual_target_pursuit() -> void:
	print("\n=== C11 Aggressive pursuit respects the manual target")
	await _load()
	_put("Gunship", Vector2(-60, 100), EAST)
	_put("HostileGunship", Vector2(-30, 85), WEST) # 34 u, nearer
	_put("HostileGunship2", Vector2(25, 110), WEST) # 86 u, the manual target
	await _sense()
	scene.orders.assign_target([_ship("Gunship")], _ship("HostileGunship2"))
	scene.orders.set_stance([_ship("Gunship")], AGGRESSIVE)
	await _run(3.0)
	var requests := _requests("Gunship")
	_check("pursuit toward the manual target: %s" % (requests[0] if not requests.is_empty() else "no request"),
		not requests.is_empty() and requests.all(func(line: String) -> bool: return line.contains("HostileGunship2")) and _c("Gunship").target == _ship("HostileGunship2"))


## Defensive priority: an attacker of the ship itself before an attacker of an ally.
func _case_defensive_priority() -> void:
	print("\n=== C12 Defensive priority")
	await _load()
	_put("Gunship", Vector2(-60, 100), EAST)
	_put("Destroyer", Vector2(-60, 118), EAST)
	_put("HostileGunship", Vector2(-5, 122), WEST)
	_put("HostileGunship2", Vector2(-10, 82), WEST)
	await _sense()
	scene.orders.set_stance([_ship("Gunship")], DEFENSIVE)
	scene.orders.set_stance([_ship("HostileGunship")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileGunship")], _ship("Destroyer"))
	var g = _c("Gunship")
	var first: bool = await _until(8.0, func() -> bool: return g.target == _ship("HostileGunship"))
	scene.orders.set_stance([_ship("HostileGunship2")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileGunship2")], _ship("Gunship"))
	var switched: bool = await _until(8.0, func() -> bool: return g.target == _ship("HostileGunship2"))
	_check("answers the ally's attacker, then switches to its own attacker once that one fires (direct threat)", first and switched and g.direct_threats.has(_ship("HostileGunship2")))


# --- Ownership, waypoints, pause, dock ---------------------------------------------------------

## A command clears only what it owns: the Attack's own manual target; never an independent one.
func _case_ownership() -> void:
	print("\n=== C15 Command ownership of the manual target")
	await _load()
	_put("Gunship", Vector2(-60, 100), EAST)
	_put("HostileGunship", Vector2(0, 100), WEST)
	_put("HostileGunship2", Vector2(0, 80), WEST)
	await _sense()
	var g := [_ship("Gunship")]
	var c = _c("Gunship")
	var b = _b("Gunship")
	var o = scene.orders
	o.assign_target(g, _ship("HostileGunship")) # independent targeting
	o.move(g, Vector2(-60, 90))
	await _run(0.5)
	var move_keeps: bool = c.manual_target == _ship("HostileGunship")
	o.attack(g, _ship("HostileGunship")) # attack on the already assigned target: not owned
	await _run(0.5)
	o.move(g, Vector2(-60, 110))
	await _run(0.5)
	var attack_end_keeps: bool = c.manual_target == _ship("HostileGunship") and c.attack_target == null and b.command == Behavior.Command.MOVE
	o.clear_target(g)
	o.attack(g, _ship("HostileGunship")) # sets the target itself: owned
	await _run(0.5)
	o.move(g, Vector2(-60, 100))
	await _run(0.5)
	var owned_cleared: bool = c.manual_target == null and c.attack_target == null
	o.attack(g, _ship("HostileGunship"))
	await _run(0.5)
	o.assign_target(g, _ship("HostileGunship2")) # independent re-targeting during the Attack
	await _run(0.5)
	var retarget_kept: bool = b.command != Behavior.Command.ATTACK and c.manual_target == _ship("HostileGunship2") and c.attack_target == null
	_check("Move keeps an independent target; an Attack ending clears only a target it set; re-targeting ends the Attack and stays (%s)" % str([move_keeps, attack_end_keeps, owned_cleared, retarget_kept]),
		move_keeps and attack_end_keeps and owned_cleared and retarget_kept)


## Waypoint Move: legs in order, kept through combat, replaced by Move, cleared by Cancel.
func _case_waypoints() -> void:
	print("\n=== C16 Waypoint Move")
	await _load()
	_put("Gunship", Vector2(-80, 100), EAST)
	_put("HostileGunship", Vector2(-20, 70), WEST)
	await _sense()
	var g := [_ship("Gunship")]
	scene.orders.set_stance(g, AGGRESSIVE)
	scene.orders.set_stance([_ship("HostileGunship")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileGunship")], _ship("Gunship"))
	var points := [Vector2(-40, 110), Vector2(-10, 95), Vector2(20, 115)]
	var taken := 0
	for point: Vector2 in points:
		taken += scene.orders.waypoint(g, point, true)
	var b = _b("Gunship")
	var shots := _count_shots("Gunship")
	var reached: Array[int] = []
	var done: bool = await _until(60.0, func() -> bool:
		for i in points.size():
			if not reached.has(i) and b._here().distance_to(points[i]) <= Behavior.ARRIVAL + 0.5:
				reached.append(i)
		return b.command != Behavior.Command.WAYPOINTS)
	var requests := _requests("Gunship")
	_check("three waypoints flown in order %s under fire (%d shots back), every request a waypoint leg (%d), then the command ends" % [str(reached), shots[0], requests.size()],
		taken == 3 and done and reached == [0, 1, 2] and shots[0] > 0 and requests.size() == 3 and requests.all(func(l: String) -> bool: return l.contains("waypoint")))
	scene.orders.waypoint(g, Vector2(-40, 120), true)
	scene.orders.waypoint(g, Vector2(-70, 120), true)
	await _run(1.0)
	scene.orders.move(g, Vector2(0, 120))
	await _run(0.5)
	var replaced: bool = b.command == Behavior.Command.MOVE and b.waypoints.is_empty()
	scene.orders.waypoint(g, Vector2(-40, 120), true)
	scene.orders.waypoint(g, Vector2(-70, 120), true)
	await _run(0.5)
	scene.orders.cancel(g)
	await _run(0.5)
	_check("a Move replaces the sequence; Cancel clears it (and stops the ship)", replaced and b.command == Behavior.Command.NONE and b.waypoints.is_empty())


## Commands while paused take effect at once; nothing moves until the game resumes.
func _case_paused() -> void:
	print("\n=== C17 Commands while paused")
	await _load()
	_put("Destroyer", Vector2(-60, 100), EAST)
	_put("Gunship", Vector2(-60, 82), EAST)
	_put("Gunship2", Vector2(-80, 100), EAST)
	_put("HostileGunship", Vector2(0, 100), WEST)
	await _sense()
	scene.time_control.set_paused(true)
	await process_frame
	var o = scene.orders
	var before := _planar(_ship("Gunship"))
	o.guard([_ship("Gunship")], _ship("Destroyer"))
	o.attack([_ship("Gunship2")], _ship("HostileGunship"))
	o.waypoint([_ship("Destroyer")], Vector2(-40, 120), true)
	var states := [_b("Gunship").command, _b("Gunship2").command, _b("Destroyer").command]
	o.move([_ship("Gunship")], Vector2(-60, 60)) # as a right-click Move: announced at once (command_given)
	scene.selection().set_selection([_ship("Gunship")])
	var moved_command: int = _b("Gunship").command
	for i in 30:
		await process_frame
	var still: bool = _planar(_ship("Gunship")).distance_to(before) < 0.001
	scene.time_control.set_paused(false)
	await _run(1.0)
	_check("paused: Guard, Attack, Waypoint and then a Move registered at once (%s), nothing moved; resumed, it moves" % str(states.map(func(c: int) -> String: return Behavior.COMMAND_NAMES[c]) + [Behavior.COMMAND_NAMES[moved_command]]),
		states == [Behavior.Command.GUARD, Behavior.Command.ATTACK, Behavior.Command.WAYPOINTS] and moved_command == Behavior.Command.MOVE and still
		and _planar(_ship("Gunship")).distance_to(before) > 0.1)


## Dock: the ship's existing Docking component (from its production archetype) owns the
## movement from its dock request on; Guard ends. No combat scene has a station, so the
## component's state is set directly (its processing paused: no station to fly to).
func _case_dock() -> void:
	print("\n=== C18 Dock hand-over (the ship's Docking component, state set directly)")
	await _load()
	_put("Destroyer", Vector2(-60, 100), EAST)
	_put("Gunship", Vector2(-60, 82), EAST)
	await _sense()
	var docking: Node = _ship("Gunship").get_node("Docking")
	docking.process_mode = Node.PROCESS_MODE_DISABLED
	scene.orders.guard([_ship("Gunship")], _ship("Destroyer"))
	await _run(1.0)
	var b = _b("Gunship")
	var requests: int = b.move_requests
	docking.state = Docking.State.APPROACHING
	await _run(2.0)
	var docking_ok: bool = b.command == Behavior.Command.DOCK and b.guard_target == null and b.move_requests == requests
	docking.state = Docking.State.NONE
	await _run(1.0)
	_check("a dock request (Docking state) became the Dock command: Guard ended for good, no requests while docking; afterwards no command",
		docking_ok and b.command == Behavior.Command.NONE)


# --- Scope and lifecycle -----------------------------------------------------------------------

## Ships without a Behavior node (E05) refuse the new commands; nothing changes.
func _case_without_behavior() -> void:
	print("\n=== C13 Ships without Behavior")
	_free()
	scene = E05.instantiate()
	scene.scenario_index = 4
	root.add_child(scene)
	await physics_frame
	var g := [scene.ship("Gunship")]
	var counts := [scene.orders.attack(g, scene.ship("HostileGunship")), scene.orders.guard(g, scene.ship("Destroyer")), scene.orders.cancel(g),
		scene.orders.attack_move(g, Vector2.ZERO), scene.orders.request(g, "Dock"), scene.orders.set_profile(g, P.MID)]
	_check("E05 ships take none of the behavior commands (%s); no target set, no Behavior view" % str(counts),
		counts.all(func(n: int) -> bool: return n == 0) and CombatShip.of(g[0]).manual_target == null and not scene.has_node("BehaviorView"))


## Reset and scenario changes rebuild everything: no stale references.
func _case_reset() -> void:
	print("\n=== C14 Reset and scenario changes")
	_free()
	var lab: Node = LAB.instantiate()
	lab.encounter_index = 7
	root.add_child(lab)
	await _run(3.0)
	var first: Node = lab.arena
	var old_behavior = Behavior.of(first.ship("Gunship"))
	first._combat_key(KEY_F5)
	await process_frame
	await _run(1.0)
	var fresh: Node = lab.arena
	var guards: Array = ["Gunship", "Gunship2"].map(func(n: String) -> Variant: return Behavior.of(fresh.ship(n)))
	var reset_ok: bool = fresh != first and not is_instance_valid(old_behavior) \
		and guards.all(func(b: Variant) -> bool: return b != null and b.command == Behavior.Command.GUARD and b.guard_target == fresh.ship("Destroyer"))
	var loaded: Array[String] = []
	for key: Key in [KEY_6, KEY_7, KEY_8, KEY_5]:
		lab.arena._combat_key(key)
		await process_frame
		await _run(0.5)
		loaded.append("%s%s" % [lab.arena.name, " +view" if lab.arena.has_node("BehaviorView") else ""])
	_check("F5 on P03 rebuilds it (old Behavior freed, new guards on the new Destroyer); keys 6, 7, 8, 5 load %s" % ", ".join(loaded),
		reset_ok and loaded == ["P01Defensive +view", "P02Siege +view", "P03Guard +view", "E05Fleet +view"])
	root.remove_child(lab)
	lab.free()
