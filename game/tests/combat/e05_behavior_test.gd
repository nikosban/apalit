extends SceneTree
## Behavior prototype: E05 validation situations V1–V6 and V8 with the Behavior layer on the
## player ships (as the lab plays E05). Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/e05_behavior_test.gd
## Battle runs use the scripted hostile fleet; the focused cases switch it off and place
## the ships. Measurements are printed; movement quality is judged in play.

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const TS := CombatShip.TargetState
const EAST := -PI * 0.5
const WEST := PI * 0.5
const HOLD := 0
const DEFENSIVE := 1
const AGGRESSIVE := 2
const PLAYER := 0
const PLAYER_SHIPS := ["FF01A", "FF01B", "FF01C"]

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	var only := OS.get_cmdline_user_args()
	if only.size() == 1: # one situation (diagnostics): -- _v4_guard_in_battle
		await call(only[0])
		_free()
		quit(0)
		return
	await _v1_aggressive_battle()
	await _v2_defensive()
	await _v3_passive_attack()
	await _v4_guard_in_battle()
	await _v5_attack_move()
	await _v6_waypoints()
	await _v8_contact_loss()
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


## E05 with the Behavior layer. `quiet`: hostile fleet off, every ship holding fire in a
## far corner (the player ships keep their Behavior nodes).
func _load(quiet: bool) -> void:
	_free()
	scene = E05.instantiate()
	scene.scenario_index = 0
	scene.behavior_layer = true
	root.add_child(scene)
	if quiet:
		scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
	while not scene.enemy_controller.started:
		await physics_frame
	if not quiet:
		return
	var corners := {"FF01A": Vector2(-130, -130), "FF01B": Vector2(-130, 130), "FF01C": Vector2(-110, 130),
		"HostileFF01B": Vector2(130, -130), "HostileFF01C": Vector2(130, -110), "HostileFF01A": Vector2(130, 130)}
	for name: String in corners:
		_put(name, corners[name], EAST)
		scene.orders.set_stance([_ship(name)], HOLD)
	# Test conditions (quiet cases). FF01B and FF01C stand in for the former escorts: their
	# Wayfarer launcher is out of action, so their longest reach is the cannons'. The player
	# ships outlast hostile fire: the cases check behavior, not damage.
	for name: String in ["FF01B", "FF01C"]:
		_ship(name).get_node("Weapons/WayfarerHardpoint").weapon().enabled = false
	for name: String in ["FF01A", "FF01B", "FF01C"]:
		CombatShip.of(_ship(name)).health = 100000.0
	await _sense()


func _ship(name: String) -> Node3D:
	return scene.ship(name)


func _c(name: String) -> Variant:
	return CombatShip.of(_ship(name))


func _b(name: String) -> Variant:
	return Behavior.of(_ship(name))


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


func _until(seconds: float, condition: Callable) -> bool:
	var end := CombatShip.now() + seconds
	while CombatShip.now() < end:
		await physics_frame
		if condition.call():
			return true
	return false


func _run(seconds: float, each: Callable = Callable()) -> void:
	await _until(seconds, func() -> bool:
		if each.is_valid():
			each.call()
		return false)


static func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)


func _requests(b: Node) -> Array:
	return b.log.filter(func(line: String) -> bool: return line.contains(" request ("))


func _shots_at_ships(name: String) -> Array:
	var counts := [0]
	for w in _c(name).weapons:
		w.shot.connect(func(_wp: Node, _id: int, t: Node3D, _o: Transform3D) -> void:
			if CombatShip.of(t) != null:
				counts[0] += 1)
	return counts


# Per-ship sampler for a battle: target switches, time engaged and in band, every
# accepted combat objective with whether its engaged target was in contact.
class Stats:
	var name := ""
	var switches := 0
	var engaged := 0.0
	var in_band := 0.0
	var informed := true
	var seen_requests := 0
	var objectives := 0
	var last_objective := -INF


func _sample(stats: Dictionary) -> void:
	for name: String in stats:
		var b = _b(name)
		var c = _c(name)
		if b == null or c == null or not c.alive:
			continue
		var s: Stats = stats[name]
		var t: Node3D = c.target
		if t != null and c.target_status(t) == TS.VALID:
			s.engaged += 1.0 / 60.0
			var band: Dictionary = b.combat_band()
			var d: float = c.distance_to(t)
			if not band.is_empty() and d >= band.near and d <= band.far:
				s.in_band += 1.0 / 60.0
		if not b.combat_objectives.is_empty() and b.combat_objectives.back().time > s.last_objective:
			var other = b._combat_target # Untyped: a freed engaged ship stays a checkable value.
			s.informed = s.informed and is_instance_valid(other) and scene.contacts.observable(PLAYER, other)
			s.objectives += 1
			s.last_objective = b.combat_objectives.back().time
		s.seen_requests = b.move_requests


# --- V1 ----------------------------------------------------------------------------------

## The full E05 battle: the player ships Aggressive with the Behavior layer, no orders;
## then, mid-battle, a Move for one FF01B must hold against autonomous pursuit.
func _v1_aggressive_battle() -> void:
	print("\n=== V1 Aggressive pursuit (full E05 battle)")
	await _load(false)
	var stats := {}
	for name: String in PLAYER_SHIPS:
		var s := Stats.new()
		s.name = name
		stats[name] = s
		_c(name).target_changed.connect(func() -> void: s.switches += 1)
	var battle: Node = scene.get_node("FleetBattle")
	var moved := [false, true, Vector2.ZERO] # given, destination held, point
	var start: float = scene.enemy_controller.time
	while not battle.finished and scene.enemy_controller.time < 240.0:
		await physics_frame
		_sample(stats)
		if not moved[0] and battle.pacing.first_shot >= 0.0 and scene.enemy_controller.time > battle.pacing.first_shot + 5.0 and _c("FF01B").alive:
			moved[0] = true
			moved[2] = _planar(_ship("FF01B")) + Vector2(-25, 0)
			scene.orders.move([_ship("FF01B")], moved[2])
		if moved[0] and _c("FF01B") != null and _c("FF01B").alive and _b("FF01B").command == Behavior.Command.MOVE:
			var loco: Node = _ship("FF01B").get_node("Locomotion")
			moved[1] = moved[1] and (not loco.has_destination or loco.destination.distance_to(moved[2]) < 0.5)
	var elapsed: float = scene.enemy_controller.time - start
	print("Battle: %s; first shot %.1f s" % [battle.result.replace("\n", " | ") if battle.finished else "unfinished at %.0f s" % elapsed, battle.pacing.first_shot])
	var lines: Array[String] = []
	var all_requests := 0
	var objectives := 0
	var informed := true
	for name: String in PLAYER_SHIPS:
		var s: Stats = stats[name]
		var b = _b(name)
		var requests: int = b.move_requests if b != null else s.seen_requests
		all_requests += requests
		informed = informed and s.informed
		objectives += s.objectives
		lines.append("%s: %d requests (%.2f /min), %d target switches, engaged %.0f s, in band %.0f s" % [name, requests,
			requests * 60.0 / maxf(elapsed, 1.0), s.switches, s.engaged, s.in_band])
	print("\n".join(lines))
	_check("the player ships pursued and fought on their own (%d requests over %.0f s); all %d combat objectives were for a hostile in contact" % [all_requests, elapsed, objectives],
		battle.pacing.first_shot >= 0.0 and all_requests > 0 and objectives > 0 and informed)
	_check("a Move given mid-battle kept its destination against autonomous pursuit", moved[0] and moved[1])


# --- V2 ----------------------------------------------------------------------------------

## Defensive holding in E05: attacked, it answers from its area; the attacker retreats and
## is not chased.
func _v2_defensive() -> void:
	print("\n=== V2 Defensive holding")
	await _load(true)
	_put("FF01A", Vector2(-70, 60), EAST)
	_put("HostileFF01B", Vector2(-10, 75), WEST)
	await _sense()
	scene.orders.set_stance([_ship("FF01A")], DEFENSIVE)
	scene.orders.set_stance([_ship("HostileFF01B")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileFF01B")], _ship("FF01A"))
	var shots := _shots_at_ships("FF01A")
	var b = _b("FF01A")
	var anchor: Vector2 = b.anchor
	var farthest := [0.0]
	await _run(10.0, func() -> void: farthest[0] = maxf(farthest[0], b._here().distance_to(anchor)))
	scene.orders.move([_ship("HostileFF01B")], Vector2(60, 90)) # retreats
	await _run(20.0, func() -> void: farthest[0] = maxf(farthest[0], b._here().distance_to(anchor)))
	var requests := _requests(b)
	_check("answered the attack (%d shots) without chasing the retreating attacker: farthest %.1f u from its position, requests %s" % [shots[0], farthest[0], str(requests)],
		shots[0] > 0 and farthest[0] <= Behavior.DEFENSE_RADIUS + 1.5 and requests.all(func(l: String) -> bool: return l.contains("firing position") or l.contains("return to")))


# --- V3 ----------------------------------------------------------------------------------

func _v3_passive_attack() -> void:
	print("\n=== V3 Passive explicit Attack")
	await _load(true)
	_put("FF01B", Vector2(-80, 30), EAST)
	_put("HostileFF01B", Vector2(-80, -60), WEST) # 90 u north, holding fire
	_put("HostileFF01C", Vector2(-30, 60), WEST) # unrelated hostile
	await _sense()
	var shots := _shots_at_ships("FF01B")
	var unrelated := [0]
	for w in _c("FF01B").weapons:
		w.shot.connect(func(_wp: Node, _id: int, t: Node3D, _o: Transform3D) -> void:
			if t == _ship("HostileFF01C"):
				unrelated[0] += 1)
	scene.orders.attack([_ship("FF01B")], _ship("HostileFF01B"))
	var b = _b("FF01B")
	var stance_kept := [true]
	var killed: bool = await _until(90.0, func() -> bool:
		stance_kept[0] = stance_kept[0] and _c("FF01B").stance == HOLD
		return not _c("HostileFF01B").alive)
	await _run(1.5)
	var after := [shots[0], b.move_requests]
	await _run(4.0)
	_check("Passive Attack: pursued and destroyed its target (%d shots, %d requests), stance Passive throughout, none at the unrelated hostile; afterwards Passive (no fire, no movement)" % [shots[0], b.move_requests],
		killed and stance_kept[0] and unrelated[0] == 0 and b.command == Behavior.Command.NONE and _c("FF01B").manual_target == null
		and shots[0] == after[0] and b.move_requests == after[1])


# --- V4 ----------------------------------------------------------------------------------

## FF01C guards the FF01A through the E05 battle; the FF01A fights on its own.
func _v4_guard_in_battle() -> void:
	print("\n=== V4 Guard during combat")
	await _load(false)
	scene.orders.guard([_ship("FF01C")], _ship("FF01A"))
	var g = _b("FF01C")
	var intercepts := [0]
	scene.projectiles.ordnance_finished.connect(func(record: Dictionary) -> void:
		if record.outcome == "intercepted" and record.intercepted_by == "FF01C":
			intercepts[0] += 1)
	var shots := _shots_at_ships("FF01C")
	var only_guard := [true]
	var seen := [0]
	var battle: Node = scene.get_node("FleetBattle")
	var guarded := [0.0]
	while not battle.finished and scene.enemy_controller.time < 200.0 and g.command == Behavior.Command.GUARD:
		await physics_frame
		guarded[0] += 1.0 / 60.0
		if g.move_requests > seen[0]:
			only_guard[0] = only_guard[0] and _requests(g).back().contains("guard position")
			seen[0] = g.move_requests
	var ended: String = "the FF01A was destroyed" if not CombatShip.of(_ship("FF01A")) or not _c("FF01A").alive else ("the battle ended" if battle.finished else "time")
	print("Guarded %.0f s until %s: in proximity %.0f of %.0f s, %d requests (%.2f /s), %d reassignments, %d shots at ships, %d ordnance intercepted, guard log: %s" % [guarded[0], ended,
		g.guard_near_time, g.guard_time, g.move_requests, g.move_requests / maxf(guarded[0], 1.0), g.guard_reassignments, shots[0], intercepts[0],
		" | ".join(g.log.filter(func(l: String) -> bool: return not l.contains(" request (")))])
	_check("Guard held through the battle: in proximity %.0f%% of the time, every request a guard position, fought (%d shots) and intercepted (%d) without leaving" % [100.0 * g.guard_near_time / maxf(g.guard_time, 0.001), shots[0], intercepts[0]],
		g.guard_time > 30.0 and g.guard_near_time / g.guard_time >= 0.85 and only_guard[0] and shots[0] + intercepts[0] > 0)


# --- V5 ----------------------------------------------------------------------------------

## Attack-Move across E05, past a hostile near the route.
func _v5_attack_move() -> void:
	print("\n=== V5 Attack-Move across the arena")
	await _load(true)
	_put("FF01B", Vector2(-110, 90), EAST)
	_put("HostileFF01B", Vector2(-20, 100), WEST) # 10 u off the route, holding fire
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], AGGRESSIVE)
	var shots := _shots_at_ships("FF01B")
	var point := Vector2(100, 90)
	scene.orders.attack_move([_ship("FF01B")], point)
	var b = _b("FF01B")
	var offset := [0.0]
	var done: bool = await _until(200.0, func() -> bool: # FF-01 (3 u/s) crosses 210 u with two encounters in about 150 s
		if b.command == Behavior.Command.ATTACK_MOVE:
			offset[0] = maxf(offset[0], b._route_offset(b._here()))
		return b.command != Behavior.Command.ATTACK_MOVE)
	var text := " | ".join(b.log.filter(func(l: String) -> bool: return not l.contains(" request (")))
	print("  %s" % " | ".join(b.log))
	_check("engaged the hostiles met on the way (%d shots), at most %.1f u off its planned route, then resumed and arrived (%.1f u from the destination)" % [shots[0], offset[0], b._here().distance_to(point)],
		done and shots[0] > 0 and text.contains("encounter with") and text.contains("travel on") and offset[0] <= Behavior.ATTACK_MOVE_LEASH + 4.0
		and b._here().distance_to(point) <= Behavior.ARRIVAL + 0.5)


# --- V6 ----------------------------------------------------------------------------------

## FF01B and FF01C as a group fly three waypoints past an attacking hostile.
func _v6_waypoints() -> void:
	print("\n=== V6 Waypoint sequence (group of two)")
	await _load(true)
	_put("FF01B", Vector2(-110, 80), EAST)
	_put("FF01C", Vector2(-110, 96), EAST)
	_put("HostileFF01B", Vector2(-40, 125), WEST)
	await _sense()
	var group := [_ship("FF01B"), _ship("FF01C")]
	scene.orders.set_stance(group, AGGRESSIVE)
	scene.orders.set_stance([_ship("HostileFF01B")], AGGRESSIVE)
	scene.orders.assign_target([_ship("HostileFF01B")], _ship("FF01B"))
	var points := [Vector2(-70, 95), Vector2(-60, 60), Vector2(-100, 50)]
	var taken := []
	for point: Vector2 in points:
		taken.append(scene.orders.waypoint(group, point, true))
	var bs := [_b("FF01B"), _b("FF01C")]
	var gap := [INF]
	var contacts: Array[String] = []
	var done: bool = await _until(90.0, func() -> bool:
		gap[0] = minf(gap[0], _planar(group[0]).distance_to(_planar(group[1])) - 6.8)
		for s: Node3D in group:
			for contact: Dictionary in s.get_node("Locomotion").contacts:
				var text := "%s-%s" % [s.name, contact.blocker.name if contact.blocker is Node else str(contact.blocker)]
				if not contacts.has(text):
					contacts.append(text)
					print("    contact %s at %.1f s, legs left %s" % [text, CombatShip.now(), str(bs.map(func(b: Node) -> int: return b.waypoints.size()))])
		return bs.all(func(b: Node) -> bool: return b.command != Behavior.Command.WAYPOINTS))
	var legs: Array = bs.map(func(b: Node) -> int: return _requests(b).size())
	var only_legs: bool = bs.all(func(b: Node) -> bool: return _requests(b).all(func(l: String) -> bool: return l.contains("waypoint")))
	var ends: Array = bs.map(func(b: Node) -> String: return "%.0f u" % b._here().distance_to(points[2]))
	var collisions: Array = group.map(func(s: Node3D) -> int: return s.get_node("Locomotion").collision_count)
	_check("the group flew all 3 waypoints (orders %s, legs %s, every request a leg) and ended near the last one (%s); closest bounding circles %.1f u apart, collisions %s" % [str(taken), str(legs), ", ".join(ends), gap[0], str(collisions)],
		done and taken == [2, 2, 2] and legs == [3, 3] and only_legs and bs.all(func(b: Node) -> bool: return b._here().distance_to(points[2]) < 12.0) and collisions == [0, 0])


# --- V8 ----------------------------------------------------------------------------------

## Attack: investigates the last known position. Aggressive pursuit: stops on contact loss.
func _v8_contact_loss() -> void:
	print("\n=== V8 Contact loss")
	await _load(true)
	_put("FF01B", Vector2(-100, 100), EAST)
	_put("HostileFF01B", Vector2(-20, 100), WEST) # 80 u
	await _sense()
	scene.orders.attack([_ship("FF01B")], _ship("HostileFF01B"))
	await _run(1.0)
	var seen := _planar(_ship("HostileFF01B"))
	scene.contacts.set_contact(PLAYER, _ship("HostileFF01B"), false)
	_put("HostileFF01B", Vector2(-20, 40), WEST)
	var b = _b("FF01B")
	var ended: bool = await _until(40.0, func() -> bool: return b.command != Behavior.Command.ATTACK)
	var investigate: Array = _requests(b).filter(func(l: String) -> bool: return l.contains("investigate"))
	_check("Attack: investigated the last position seen (%.0f, %.0f) and ended there: %s" % [seen.x, seen.y, investigate[0] if not investigate.is_empty() else "no request"],
		ended and investigate.size() == 1 and investigate[0].contains("(%d, %d)" % [roundi(seen.x), roundi(seen.y)]) and b.log.any(func(l: String) -> bool: return l.contains("not reacquired")))
	# Aggressive pursuit: contact lost during the approach.
	await _load(true)
	_put("FF01B", Vector2(-100, 100), EAST)
	_put("HostileFF01B", Vector2(-10, 100), WEST) # 90 u: beyond the cannon, an approach
	await _sense()
	scene.orders.set_stance([_ship("FF01B")], AGGRESSIVE)
	b = _b("FF01B")
	await _until(5.0, func() -> bool: return b.move_requests > 0)
	var approached: int = b.move_requests
	var objectives: int = b.combat_objectives.size()
	scene.contacts.set_contact(PLAYER, _ship("HostileFF01B"), false)
	_put("HostileFF01B", Vector2(-10, 40), WEST)
	await _run(8.0)
	_check("Aggressive pursuit after contact loss: nothing requested toward the hidden live position (%d request(s) before, %d after)" % [approached, b.move_requests - approached],
		approached >= 1 and objectives >= 1 and b.move_requests == approached and b.combat_objectives.size() == objectives)
