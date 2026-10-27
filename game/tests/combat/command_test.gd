extends SceneTree
## Behavior prototype v0.1: lightweight command-interaction checks (Commands, Tactics,
## Weapon Profiles) on small fixtures built from E05 (three FF-01s per side) with its
## hostile fleet controller off.
## Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/command_test.gd

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const Profiles := preload("res://game/behavior/weapon_profiles.gd")
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


## E05 with its hostile fleet controller off, every ship holding fire in a far corner (the
## player ships get their Behavior nodes).
func _load() -> void:
	_free()
	scene = E05.instantiate()
	scene.behavior_layer = true
	scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(scene)
	scene.enemy_controller._steps.clear()
	scene.enemy_controller._patrols.clear()
	while not scene.enemy_controller.started:
		await physics_frame
	var corners := {"FF01A": Vector2(-130, -130), "FF01B": Vector2(-130, 130), "FF01C": Vector2(-110, 130),
		"HostileFF01B": Vector2(130, -130), "HostileFF01C": Vector2(130, -110), "HostileFF01A": Vector2(110, -130)} # Far from every case
	for name: String in corners:
		_put(name, corners[name], EAST)
		scene.orders.set_stance([_ship(name)], HOLD)
	# Test conditions. FF01B and FF01C stand in for the former escorts: their Wayfarer
	# launcher is out of action, so their longest reach is the cannons' (Mid-range and Close
	# Quarters available, Mid-range requested). The player ships outlast hostile fire: the
	# cases check command handling, not damage.
	for name: String in ["FF01B", "FF01C"]:
		_ship(name).get_node("Weapons/WayfarerHardpoint").weapon().enabled = false
		scene.orders.set_profile([_ship(name)], P.MID)
	for name: String in ["FF01A", "FF01B", "FF01C"]:
		_c(name).health = 100000.0
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
	_put("FF01B", Vector2(-60, 100), EAST)
	_put("HostileFF01B", Vector2(22, 100), WEST) # 82 u: beyond the cannon's 75 u
	await _sense()
	var shots := _count_shots("FF01B")
	var given: int = scene.orders.attack([_ship("FF01B")], _ship("HostileFF01B"))
	var stance_kept := [true]
	await _run(20.0, func() -> void: stance_kept[0] = stance_kept[0] and _c("FF01B").stance == HOLD)
	var b = _b("FF01B")
	_check("Attack taken under Hold Fire (%d); it approached (%d requests) and fired (%d shots); stance still Hold Fire" % [given, b.move_requests, shots[0]],
		given == 1 and b.move_requests >= 1 and shots[0] > 0 and stance_kept[0] and b.command == Behavior.Command.ATTACK)
	_c("HostileFF01B").destroy()
	var ended: bool = await _until(1.0, func() -> bool: return b.command == Behavior.Command.NONE)
	await _run(1.0) # its stop request settles
	ended = ended and _c("FF01B").attack_target == null and _c("FF01B").manual_target == null
	_put("HostileFF01C", _planar(_ship("FF01B")) + Vector2(40, 0), WEST)
	await _sense()
	var before := [shots[0], b.move_requests]
	await _run(4.0)
	_check("the Attack ended with its target; afterwards a hostile at 40 u draws no fire and no movement (Passive)",
		ended and shots[0] == before[0] and b.move_requests == before[1] and _c("FF01B").target == null and _c("FF01B").stance == HOLD)


## Passive + incoming missiles: point defense intercepts; no offensive fire at the launcher.
func _case_passive_point_defense() -> void:
	print("\n=== C2 Passive + incoming missiles")
	await _load()
	_put("FF01B", Vector2(-60, 100), EAST)
	_put("HostileFF01A", Vector2(15, 100), WEST) # 75 u: missiles (90 u) reach
	await _sense()
	var shots := _count_shots("FF01B")
	var intercepts := [0]
	scene.projectiles.ordnance_finished.connect(func(record: Dictionary) -> void:
		if record.outcome == "intercepted" and record.intercepted_by == "FF01B":
			intercepts[0] += 1)
	scene.orders.set_stance([_ship("HostileFF01A")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileFF01A")], _ship("FF01B"))
	await _run(16.0)
	_check("Hold Fire under missile attack: Gatlings fired at ordnance (%d rounds, %d intercepts); no shot at the launcher, no target, no movement" % [shots[1], intercepts[0]],
		shots[1] > 0 and shots[0] == 0 and _c("FF01B").target == null and _b("FF01B").move_requests == 0)


# --- Defensive + Move ----------------------------------------------------------------------

## Defensive + Move: the attacker is answered on the way; the destination never changes; no
## pursuit or local repositioning until the Move has arrived.
func _case_defensive_move() -> void:
	print("\n=== C3 Defensive + Move")
	await _load()
	_put("FF01B", Vector2(-70, 100), EAST)
	_put("HostileFF01B", Vector2(-20, 70), WEST)
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], DEFENSIVE)
	scene.orders.set_stance([_ship("HostileFF01B")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileFF01B")], _ship("FF01B"))
	var shots := _count_shots("FF01B")
	var point := Vector2(30, 105)
	scene.orders.move([_ship("FF01B")], point)
	var locomotion: Node = _ship("FF01B").get_node("Locomotion")
	var b = _b("FF01B")
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
	_put("FF01B", Vector2(-70, 100), EAST)
	_put("HostileFF01B", Vector2(0, 112), WEST) # 12 u off the route, holding fire
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], AGGRESSIVE)
	var shots := _count_shots("FF01B")
	var point := Vector2(60, 100)
	var given: int = scene.orders.attack_move([_ship("FF01B")], point)
	var b = _b("FF01B")
	var offset := [0.0]
	var done: bool = await _until(135.0, func() -> bool: # 90 s at the former escort's 4.5 u/s; the FF-01 flies 3 u/s
		if b.command == Behavior.Command.ATTACK_MOVE:
			offset[0] = maxf(offset[0], b._route_offset(b._here()))
		return b.command != Behavior.Command.ATTACK_MOVE)
	var log_text := " | ".join(b.log)
	print("  log: " + log_text)
	_check("Aggressive: an enemy close to the route interrupted travel (%d shots, %d requests), within the %.0f u leash (max %.1f u off), then travel resumed to the destination" % [shots[0], b.move_requests, Behavior.ATTACK_MOVE_LEASH, offset[0]],
		given == 1 and done and shots[0] > 0 and log_text.contains("encounter with HostileFF01B") and log_text.contains("travel on")
		and b.move_requests >= 2 and offset[0] <= Behavior.ATTACK_MOVE_LEASH + 4.0 and b._here().distance_to(point) <= Behavior.ARRIVAL + 0.5)
	# An enemy beyond reach and beyond the leash: no detour.
	await _load()
	_put("FF01B", Vector2(-70, 100), EAST)
	_put("HostileFF01B", Vector2(0, 22), WEST) # 78 u off the route
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], AGGRESSIVE)
	scene.orders.attack_move([_ship("FF01B")], point)
	b = _b("FF01B")
	done = await _until(60.0, func() -> bool: return b.command != Behavior.Command.ATTACK_MOVE)
	_check("Aggressive: an enemy 78 u off the route (positions beyond the leash) causes no detour: one request, arrived (%d)" % b.move_requests,
		done and b.move_requests == 1 and b._here().distance_to(point) <= Behavior.ARRIVAL + 0.5)
	# Passive: travels on, no offensive fire.
	await _load()
	_put("FF01B", Vector2(-70, 100), EAST)
	_put("HostileFF01B", Vector2(0, 112), WEST)
	await _sense()
	shots = _count_shots("FF01B")
	scene.orders.attack_move([_ship("FF01B")], point)
	b = _b("FF01B")
	done = await _until(60.0, func() -> bool: return b.command != Behavior.Command.ATTACK_MOVE)
	_check("Passive: Attack-Move travels straight through (%d request), no offensive shot (%d)" % [b.move_requests, shots[0]],
		done and b.move_requests == 1 and shots[0] == 0 and b._here().distance_to(point) <= Behavior.ARRIVAL + 0.5)


# --- Attack and contact loss ---------------------------------------------------------------

## Contact lost: the ship goes to the last position seen in contact (not the live one) and
## cancels the Attack there.
func _case_contact_loss() -> void:
	print("\n=== C5 Attack + contact loss")
	await _load()
	_put("FF01B", Vector2(-70, 100), EAST)
	_put("HostileFF01B", Vector2(-10, 100), WEST)
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], DEFENSIVE)
	scene.orders.attack([_ship("FF01B")], _ship("HostileFF01B"))
	await _run(1.0)
	var seen := _planar(_ship("HostileFF01B"))
	scene.contacts.set_contact(0, _ship("HostileFF01B"), false)
	_put("HostileFF01B", Vector2(-10, 40), WEST) # its live position, now hidden
	var b = _b("FF01B")
	var ended: bool = await _until(40.0, func() -> bool: return b.command != Behavior.Command.ATTACK)
	var requests := _requests("FF01B")
	var investigate: Array = requests.filter(func(line: String) -> bool: return line.contains("investigate"))
	var near_live: Array = requests.filter(func(line: String) -> bool:
		var r := RegEx.create_from_string("request \\((-?[\\d.]+), (-?[\\d.]+)\\)").search(line)
		return Vector2(float(r.get_string(1)), float(r.get_string(2))).distance_to(Vector2(-10, 40)) < 20.0)
	var point := RegEx.create_from_string("request \\((-?[\\d.]+), (-?[\\d.]+)\\)").search(investigate[0]) if not investigate.is_empty() else null
	var target_point := Vector2(float(point.get_string(1)), float(point.get_string(2))) if point != null else Vector2.INF
	_check("investigated the last known position (%.0f, %.0f) = last seen (%.0f, %.0f), never the live one" % [target_point.x, target_point.y, seen.x, seen.y],
		investigate.size() == 1 and target_point.distance_to(seen) < 1.5 and near_live.is_empty())
	_check("not reacquired there: Attack canceled, its target and authorization cleared (%s)" % b.log[b.log.size() - 2],
		ended and b.command == Behavior.Command.NONE and _c("FF01B").manual_target == null and _c("FF01B").attack_target == null
		and b.log.any(func(line: String) -> bool: return line.contains("not reacquired")))


## Contact returns during the investigation: the Attack continues.
func _case_reacquire() -> void:
	print("\n=== C6 Attack + contact regained")
	await _load()
	_put("FF01B", Vector2(-70, 100), EAST)
	_put("HostileFF01B", Vector2(-10, 100), WEST)
	await _sense()
	scene.orders.attack([_ship("FF01B")], _ship("HostileFF01B"))
	await _run(1.0)
	scene.contacts.set_contact(0, _ship("HostileFF01B"), false)
	var b = _b("FF01B")
	await _until(5.0, func() -> bool: return b.investigating)
	var was_investigating: bool = b.investigating
	scene.contacts.set_contact(0, _ship("HostileFF01B"), true)
	await _run(1.5)
	_check("investigating, then contact regained: the Attack goes on (command %s, investigating %s)" % [Behavior.COMMAND_NAMES[b.command], b.investigating],
		was_investigating and b.command == Behavior.Command.ATTACK and not b.investigating and b.log.any(func(line: String) -> bool: return line.contains("contact reacquired")))


# --- Guard ---------------------------------------------------------------------------------

## Every replacing command ends Guard for good; tactic and profile stay.
func _case_guard_cancellation() -> void:
	print("\n=== C7 Guard cancellation")
	await _load()
	_put("FF01A", Vector2(-60, 100), EAST)
	_put("FF01B", Vector2(-60, 82), EAST)
	_put("HostileFF01B", Vector2(30, 100), WEST)
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], AGGRESSIVE)
	var g := [_ship("FF01B")]
	var b = _b("FF01B")
	var o = scene.orders
	var commands := {
		"Move": func() -> void: o.move(g, Vector2(-60, 70)),
		"Attack": func() -> void: o.attack(g, _ship("HostileFF01B")),
		"Attack-Move": func() -> void: o.attack_move(g, Vector2(-70, 70)),
		"Waypoint Move": func() -> void: o.request(g, "Waypoint Move"),
		"Dock": func() -> void: o.request(g, "Dock"),
		"Cancel": func() -> void: o.cancel(g),
	}
	var results: Array[String] = []
	var all_ok := true
	for kind: String in commands:
		o.guard(g, _ship("FF01A"))
		await _run(0.6)
		var guarding: bool = b.command == Behavior.Command.GUARD
		commands[kind].call()
		await physics_frame
		var ended: bool = b.command != Behavior.Command.GUARD and b.guard_target == null
		await _run(1.5)
		var stays: bool = b.command != Behavior.Command.GUARD and b.guard_target == null
		var kept: bool = _c("FF01B").stance == AGGRESSIVE and b.requested_profile == P.MID
		results.append("%s %s" % [kind, "ok" if guarding and ended and stays and kept else "FAILED"])
		all_ok = all_ok and guarding and ended and stays and kept
		o.cancel(g)
		await _run(0.3)
	_check("Guard ended for good by %s; stance and profile kept" % ", ".join(results), all_ok)


## The protected ship's destruction ends Guard in that tick; no automatic new target.
func _case_guard_destroyed() -> void:
	print("\n=== C8 Guard target destroyed")
	await _load()
	_put("FF01A", Vector2(-60, 100), EAST)
	_put("FF01B", Vector2(-60, 82), EAST)
	_put("FF01C", Vector2(-60, 118), EAST)
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], AGGRESSIVE)
	scene.orders.guard([_ship("FF01B"), _ship("FF01C")], _ship("FF01A"))
	await _run(2.0)
	var guards := [_b("FF01B"), _b("FF01C")]
	var stances: Array = guards.map(func(g: Node) -> int: return g.combat.stance)
	var profiles: Array = guards.map(func(g: Node) -> int: return g.requested_profile)
	var guarding: bool = guards.all(func(g: Node) -> bool: return g.command == Behavior.Command.GUARD)
	_c("FF01A").destroy()
	var same_call: bool = guards.all(func(g: Node) -> bool: return g.command == Behavior.Command.NONE and g.guard_target == null)
	await _run(3.0)
	_check("both Guards ended inside the destroy() call; 3 s later still unassigned (FF01C not taken as a new target)",
		guarding and same_call and guards.all(func(g: Node) -> bool: return g.command != Behavior.Command.GUARD and g.guard_target == null))
	_check("stances and requested profiles kept", guards.map(func(g: Node) -> int: return g.combat.stance) == stances and guards.map(func(g: Node) -> int: return g.requested_profile) == profiles)


# --- Weapon Profiles -------------------------------------------------------------------------

func _case_profiles() -> void:
	print("\n=== C9 Profile availability and fallback")
	await _load()
	var ff01b = _c("FF01B")
	var ff01a = _c("FF01A")
	var refused: int = scene.orders.set_profile([_ship("FF01B")], P.SIEGE)
	_check("availability from installed weapons: FF01B %s, FF01A %s; Siege refused for the FF01B (%d taken)" % [str(Profiles.available(ff01b)), str(Profiles.available(ff01a)), refused],
		Profiles.available(ff01b) == [P.MID, P.CLOSE] and Profiles.available(ff01a) == [P.SIEGE, P.MID, P.CLOSE] and refused == 0 and _b("FF01B").requested_profile == P.MID)
	var b = _b("FF01A")
	scene.orders.set_profile([_ship("FF01A")], P.SIEGE)
	for w in ff01a.weapons:
		if Profiles.category(w) == P.SIEGE:
			w.ammo = 0
			w.magazine = 0
	var mid: int = b.effective()
	var mid_reason: String = b.fallback_reason
	for w in ff01a.weapons:
		if Profiles.category(w) == P.MID:
			w.ammo = 0
	var close: int = b.effective()
	_check("FF01A requested Siege: long-range empty -> %s (%s); cannon empty too -> %s; request still Siege" % [Profiles.NAMES[mid], mid_reason, Profiles.NAMES[close]],
		mid == P.MID and mid_reason == "no ammunition" and close == P.CLOSE and b.requested_profile == P.SIEGE)
	for w in _c("FF01C").weapons:
		if Profiles.category(w) == P.MID:
			w.enabled = false
	_check("a point-defense-only ship (cannons and rockets out of action) offers Close Quarters only: %s; fallback order from Mid-range %s" % [str(Profiles.available(_c("FF01C"))), str(Profiles.fallback_order(P.MID))],
		Profiles.available(_c("FF01C")) == [P.CLOSE] and Profiles.fallback_order(P.MID) == [P.MID, P.CLOSE, P.SIEGE])


## A profile chooses positions only: under Close Quarters the cannon still fires at 50 u.
func _case_profile_does_not_gate_fire() -> void:
	print("\n=== C10 Profiles do not gate fire")
	await _load()
	_put("FF01B", Vector2(-60, 100), EAST)
	_put("HostileFF01B", Vector2(-10, 100), WEST)
	await _sense()
	scene.orders.set_profile([_ship("FF01B")], P.CLOSE)
	scene.orders.set_stance([_ship("FF01B")], AGGRESSIVE)
	var cannon: Node = _ship("FF01B").get_node("Weapons/ForwardBastionHardpoint").weapon()
	await _run(5.0)
	_check("Close Quarters requested, target at 50 u: the cannon fired anyway (%d shots) while the ship closed in (%d requests)" % [cannon.shots, _b("FF01B").move_requests],
		cannon.shots > 0 and _b("FF01B").move_requests >= 1)


# --- Tactics ---------------------------------------------------------------------------------

## Aggressive pursuit follows the manual target, not a nearer hostile.
func _case_manual_target_pursuit() -> void:
	print("\n=== C11 Aggressive pursuit respects the manual target")
	await _load()
	_put("FF01B", Vector2(-60, 100), EAST)
	_put("HostileFF01B", Vector2(-30, 85), WEST) # 34 u, nearer
	_put("HostileFF01C", Vector2(25, 110), WEST) # 86 u, the manual target
	await _sense()
	scene.orders.assign_target([_ship("FF01B")], _ship("HostileFF01C"))
	scene.orders.set_stance([_ship("FF01B")], AGGRESSIVE)
	await _run(3.0)
	var requests := _requests("FF01B")
	_check("pursuit toward the manual target: %s" % (requests[0] if not requests.is_empty() else "no request"),
		not requests.is_empty() and requests.all(func(line: String) -> bool: return line.contains("HostileFF01C")) and _c("FF01B").target == _ship("HostileFF01C"))


## Defensive priority: an attacker of the ship itself before an attacker of an ally.
func _case_defensive_priority() -> void:
	print("\n=== C12 Defensive priority")
	await _load()
	_put("FF01B", Vector2(-60, 100), EAST)
	_put("FF01A", Vector2(-60, 118), EAST)
	_put("HostileFF01B", Vector2(-5, 122), WEST)
	_put("HostileFF01C", Vector2(-10, 82), WEST)
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], DEFENSIVE)
	scene.orders.set_stance([_ship("HostileFF01B")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileFF01B")], _ship("FF01A"))
	var g = _c("FF01B")
	var first: bool = await _until(8.0, func() -> bool: return g.target == _ship("HostileFF01B"))
	scene.orders.set_stance([_ship("HostileFF01C")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileFF01C")], _ship("FF01B"))
	var switched: bool = await _until(8.0, func() -> bool: return g.target == _ship("HostileFF01C"))
	_check("answers the ally's attacker, then switches to its own attacker once that one fires (direct threat)", first and switched and g.direct_threats.has(_ship("HostileFF01C")))


# --- Ownership, waypoints, pause, dock ---------------------------------------------------------

## A command clears only what it owns: the Attack's own manual target; never an independent one.
func _case_ownership() -> void:
	print("\n=== C15 Command ownership of the manual target")
	await _load()
	_put("FF01B", Vector2(-60, 100), EAST)
	_put("HostileFF01B", Vector2(0, 100), WEST)
	_put("HostileFF01C", Vector2(0, 80), WEST)
	await _sense()
	var g := [_ship("FF01B")]
	var c = _c("FF01B")
	var b = _b("FF01B")
	var o = scene.orders
	o.assign_target(g, _ship("HostileFF01B")) # independent targeting
	o.move(g, Vector2(-60, 90))
	await _run(0.5)
	var move_keeps: bool = c.manual_target == _ship("HostileFF01B")
	o.attack(g, _ship("HostileFF01B")) # attack on the already assigned target: not owned
	await _run(0.5)
	o.move(g, Vector2(-60, 110))
	await _run(0.5)
	var attack_end_keeps: bool = c.manual_target == _ship("HostileFF01B") and c.attack_target == null and b.command == Behavior.Command.MOVE
	o.clear_target(g)
	o.attack(g, _ship("HostileFF01B")) # sets the target itself: owned
	await _run(0.5)
	o.move(g, Vector2(-60, 100))
	await _run(0.5)
	var owned_cleared: bool = c.manual_target == null and c.attack_target == null
	o.attack(g, _ship("HostileFF01B"))
	await _run(0.5)
	o.assign_target(g, _ship("HostileFF01C")) # independent re-targeting during the Attack
	await _run(0.5)
	var retarget_kept: bool = b.command != Behavior.Command.ATTACK and c.manual_target == _ship("HostileFF01C") and c.attack_target == null
	_check("Move keeps an independent target; an Attack ending clears only a target it set; re-targeting ends the Attack and stays (%s)" % str([move_keeps, attack_end_keeps, owned_cleared, retarget_kept]),
		move_keeps and attack_end_keeps and owned_cleared and retarget_kept)


## Waypoint Move: legs in order, kept through combat, replaced by Move, cleared by Cancel.
func _case_waypoints() -> void:
	print("\n=== C16 Waypoint Move")
	await _load()
	_put("FF01B", Vector2(-80, 100), EAST)
	_put("HostileFF01B", Vector2(-20, 70), WEST)
	await _sense()
	var g := [_ship("FF01B")]
	scene.orders.set_stance(g, AGGRESSIVE)
	scene.orders.set_stance([_ship("HostileFF01B")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileFF01B")], _ship("FF01B"))
	var points := [Vector2(-40, 110), Vector2(-10, 95), Vector2(20, 115)]
	var taken := 0
	for point: Vector2 in points:
		taken += scene.orders.waypoint(g, point, true)
	var b = _b("FF01B")
	var shots := _count_shots("FF01B")
	var reached: Array[int] = []
	var done: bool = await _until(60.0, func() -> bool:
		for i in points.size():
			if not reached.has(i) and b._here().distance_to(points[i]) <= Behavior.ARRIVAL + 0.5:
				reached.append(i)
		return b.command != Behavior.Command.WAYPOINTS)
	var requests := _requests("FF01B")
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
	_put("FF01A", Vector2(-60, 100), EAST)
	_put("FF01B", Vector2(-60, 82), EAST)
	_put("FF01C", Vector2(-80, 100), EAST)
	_put("HostileFF01B", Vector2(0, 100), WEST)
	await _sense()
	scene.time_control.set_paused(true)
	await process_frame
	var o = scene.orders
	var before := _planar(_ship("FF01B"))
	o.guard([_ship("FF01B")], _ship("FF01A"))
	o.attack([_ship("FF01C")], _ship("HostileFF01B"))
	o.waypoint([_ship("FF01A")], Vector2(-40, 120), true)
	var states := [_b("FF01B").command, _b("FF01C").command, _b("FF01A").command]
	o.move([_ship("FF01B")], Vector2(-60, 60)) # as a right-click Move: announced at once (command_given)
	scene.selection().set_selection([_ship("FF01B")])
	var moved_command: int = _b("FF01B").command
	for i in 30:
		await process_frame
	var still: bool = _planar(_ship("FF01B")).distance_to(before) < 0.001
	scene.time_control.set_paused(false)
	await _run(1.0)
	_check("paused: Guard, Attack, Waypoint and then a Move registered at once (%s), nothing moved; resumed, it moves" % str(states.map(func(c: int) -> String: return Behavior.COMMAND_NAMES[c]) + [Behavior.COMMAND_NAMES[moved_command]]),
		states == [Behavior.Command.GUARD, Behavior.Command.ATTACK, Behavior.Command.WAYPOINTS] and moved_command == Behavior.Command.MOVE and still
		and _planar(_ship("FF01B")).distance_to(before) > 0.1)


## Dock: the ship's existing Docking component (from its production archetype) owns the
## movement from its dock request on; Guard ends. No combat scene has a station, so the
## component's state is set directly (its processing paused: no station to fly to).
func _case_dock() -> void:
	print("\n=== C18 Dock hand-over (the ship's Docking component, state set directly)")
	await _load()
	_put("FF01A", Vector2(-60, 100), EAST)
	_put("FF01B", Vector2(-60, 82), EAST)
	await _sense()
	var docking: Node = _ship("FF01B").get_node("Docking")
	docking.process_mode = Node.PROCESS_MODE_DISABLED
	scene.orders.guard([_ship("FF01B")], _ship("FF01A"))
	await _run(1.0)
	var b = _b("FF01B")
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
	scene.scenario_index = 0
	root.add_child(scene)
	await physics_frame
	var g := [scene.ship("FF01B")]
	var counts := [scene.orders.attack(g, scene.ship("HostileFF01B")), scene.orders.guard(g, scene.ship("FF01A")), scene.orders.cancel(g),
		scene.orders.attack_move(g, Vector2.ZERO), scene.orders.request(g, "Dock"), scene.orders.set_profile(g, P.MID)]
	_check("E05 ships take none of the behavior commands (%s); no target set, no Behavior view" % str(counts),
		counts.all(func(n: int) -> bool: return n == 0) and CombatShip.of(g[0]).manual_target == null and not scene.has_node("BehaviorView"))


## A reset rebuilds everything: no stale references.
func _case_reset() -> void:
	print("\n=== C14 Reset")
	await _load()
	scene.orders.guard([_ship("FF01B"), _ship("FF01C")], _ship("FF01A"))
	await _run(3.0)
	var first: Node = scene
	var old_behavior = _b("FF01B")
	var guarded: bool = ["FF01B", "FF01C"].all(func(n: String) -> bool: return _b(n).command == Behavior.Command.GUARD)
	# Replace the arena with a fresh one, as a reset does.
	root.remove_child(first)
	first.queue_free()
	scene = E05.instantiate()
	scene.behavior_layer = true
	root.add_child(scene)
	await process_frame
	await _run(1.0)
	var fresh: Array = ["FF01A", "FF01B", "FF01C"].map(func(n: String) -> Variant: return _b(n))
	_check("a reset rebuilds the scene: the old Behavior freed, fresh Behavior nodes without the old Guard (%s)" % guarded,
		guarded and not is_instance_valid(old_behavior) and fresh.all(func(b: Variant) -> bool: return b != null and b.command == Behavior.Command.NONE)
		and scene.has_node("BehaviorView"))
