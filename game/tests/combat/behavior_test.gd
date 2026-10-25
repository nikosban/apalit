extends SceneTree
## Behavior prototype v0.1: scenarios P01–P03 run in full, with their measurements and
## the brief's rejection criteria as checks. Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/behavior_test.gd
## Movement quality (whether it looks natural) is judged in play, not here.

const SCENES := [
	preload("res://game/tests/combat/fixtures/p01_defensive.tscn"),
	preload("res://game/tests/combat/fixtures/p02_siege.tscn"),
	preload("res://game/tests/combat/fixtures/p03_guard.tscn"),
]
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const Profiles := preload("res://game/behavior/weapon_profiles.gd")
const Scenarios := preload("res://game/tests/combat/fixtures/behavior_scenarios.gd")
const TS := CombatShip.TargetState
const PLAYER := 0
const SLOT_OFF := 4.0 # u from the guard position that counts as having fallen behind (measurement)

var arena: Node3D
var _checks := 0
var _failures := 0
var _requests := {} # ship name -> [{time, point, why, informed}]
var _seen := {} # ship name -> move_requests already audited


func _initialize() -> void:
	await process_frame
	await _p01()
	await _p02()
	await _p03()
	_free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _free() -> void:
	if arena != null and is_instance_valid(arena):
		root.remove_child(arena)
		arena.free()
	arena = null


func _load(index: int) -> void:
	_free()
	_requests.clear()
	_seen.clear()
	arena = SCENES[index].instantiate()
	arena.scenario_index = Scenarios.FIRST + index
	root.add_child(arena)
	await physics_frame


func _ship(name: String) -> Node3D:
	return arena.ship(name)


func _behaviors() -> Array:
	var found := []
	for ship: Node in arena.get_node("Ships").get_children():
		if Behavior.of(ship) != null:
			found.append(Behavior.of(ship))
	return found


static func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)


# Every movement request of the layer, with whether the ship it names was in the player
# faction's contact at that tick (no hidden information).
func _audit() -> void:
	for b in _behaviors():
		var name := String(b.ship.name)
		var done: int = _seen.get(name, 0)
		if b.move_requests == done:
			continue
		var entries: Array = b.log.filter(func(line: String) -> bool: return line.contains(" request ("))
		for line: String in entries.slice(entries.size() - (b.move_requests - done)):
			var regex := RegEx.create_from_string("request \\((-?[\\d.]+), (-?[\\d.]+)\\): (.*)$")
			var found := regex.search(line)
			var why := found.get_string(3)
			var informed := true
			var named := RegEx.create_from_string("(?:on|from|approach|of) (Hostile\\w+)").search(why)
			if named != null:
				var other: Node3D = _ship(named.get_string(1))
				informed = other != null and arena.contacts.observable(PLAYER, other)
				if why.begins_with("investigate"):
					informed = true # the last known position, recorded while in contact
			_requests.get_or_add(name, []).append({"time": CombatShip.now(), "point": Vector2(float(found.get_string(1)), float(found.get_string(2))), "why": why,
				"informed": informed, "command": b.command})
		_seen[name] = b.move_requests


# Requests going back to a point requested two requests earlier within 6 s (A, B, A).
func _ping_pongs(name: String) -> int:
	var list: Array = _requests.get(name, [])
	var count := 0
	for i in range(2, list.size()):
		if list[i].point.distance_to(list[i - 2].point) < 2.0 and list[i].time - list[i - 2].time < 6.0:
			count += 1
	return count


func _uninformed() -> Array[String]:
	var bad: Array[String] = []
	for name: String in _requests:
		for r: Dictionary in _requests[name]:
			if not r.informed:
				bad.append("%s %.1f %s" % [name, r.time, r.why])
	return bad


# --- P01 -------------------------------------------------------------------------------

func _p01() -> void:
	print("\n=== P01 Defensive corridor")
	await _load(0)
	var defenders := ["Destroyer", "Gunship", "Gunship2"]
	var episodes: Array[Dictionary] = [] # {attacker, start, target, health, responded, response, shot}
	var defender_shots := {"ships": 0, "at_threats": 0}
	var intercepts := [0]
	for ship: Node in arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat.faction != PLAYER:
			combat.fired.connect(func(_w: Node, at: Node3D) -> void:
				var attacked = CombatShip.of(at)
				if attacked == null or attacked.faction != PLAYER:
					return
				for e: Dictionary in episodes:
					if e.attacker == ship and CombatShip.now() - e.last <= 5.0:
						e.last = CombatShip.now()
						return
				episodes.append({"attacker": ship, "name": String(ship.name), "start": CombatShip.now(), "last": CombatShip.now(), "target": at,
					"health": attacked.health, "seen": arena.contacts.observable(PLAYER, ship), "registered": attacked.is_threat(ship),
					"response": -1.0, "undamaged": false, "shot": -1.0}))
		else:
			combat.fired.connect(func(_w: Node, at: Node3D) -> void:
				if CombatShip.of(at) == null:
					return
				defender_shots.ships += 1
				if combat.is_threat(at):
					defender_shots.at_threats += 1
				for e: Dictionary in episodes:
					if e.attacker == at and e.shot < 0.0:
						e.shot = CombatShip.now() - e.start)
	arena.projectiles.ordnance_finished.connect(func(record: Dictionary) -> void:
		if record.outcome == "intercepted" and record.intercepted_by in defenders:
			intercepts[0] += 1)
	var outside := [0.0]
	while arena.enemy_controller.time < Scenarios.END_TIMES[0]:
		await physics_frame
		_audit()
		for e: Dictionary in episodes:
			if e.response >= 0.0 or not is_instance_valid(e.attacker):
				continue
			for name: String in defenders:
				var c = CombatShip.of(_ship(name))
				if c != null and c.alive and c.target == e.attacker and c.stance_allows(e.attacker) == TS.VALID and c.target_status(e.attacker) == TS.VALID:
					e.response = CombatShip.now() - e.start
					e.undamaged = is_instance_valid(e.target) and is_equal_approx(CombatShip.of(e.target).health, e.health)
					break
		for b in _behaviors():
			if b.command == Behavior.Command.NONE and b.has_anchor and b._here().distance_to(b.anchor) > Behavior.DEFENSE_RADIUS + 1.5:
				outside[0] += 1.0 / 60.0
	print("Hostile attack episodes (first fire event -> first defender targeting the attacker in contact; first defender shot):")
	for e: Dictionary in episodes:
		print("  %6.1f s  %-16s at %-10s in contact %-5s  response %s  first shot %s  attacked ship undamaged at response: %s" % [e.start, e.name, e.target.name if is_instance_valid(e.target) else "?",
			e.seen, "%.2f s" % e.response if e.response >= 0.0 else "none", "%.2f s" % e.shot if e.shot >= 0.0 else "none", e.undamaged])
	var lines: Array[String] = []
	for b in _behaviors():
		lines.append("%s: anchor max %.1f u, %d local repositions, %d requests, firing opportunity %.1f s" % [b.ship.name, b.max_anchor_distance, b.reposition_requests, b.move_requests, b.firing_time])
	print("Defenders: " + "; ".join(lines))
	print("Defender shots at ships %d (at confirmed threats %d); hostile ordnance intercepted by defenders: %d" % [defender_shots.ships, defender_shots.at_threats, intercepts[0]])
	for name: String in _requests:
		for r: Dictionary in _requests[name]:
			print("  request %-9s %6.1f s  (%.0f, %.0f)  %s" % [name, r.time, r.point.x, r.point.y, r.why])
	var seen_episodes := episodes.filter(func(e: Dictionary) -> bool: return e.seen)
	_check("every attack makes the attacker a confirmed threat at once (the fire or launch event itself; %d episodes)" % episodes.size(),
		not episodes.is_empty() and episodes.all(func(e: Dictionary) -> bool: return e.registered))
	_check("every attack episode by a hostile in contact is engaged by a defender within 0.1 s (%d episodes, incl. launches)" % seen_episodes.size(),
		not seen_episodes.is_empty() and seen_episodes.all(func(e: Dictionary) -> bool: return e.response >= 0.0 and e.response <= 0.1))
	_check("an attack qualifies without damage: responses came before any damage to the attacked ship (%d of %d)" % [seen_episodes.filter(func(e: Dictionary) -> bool: return e.undamaged).size(), seen_episodes.size()],
		seen_episodes.all(func(e: Dictionary) -> bool: return e.undamaged))
	_check("every defender shot at a ship was at a confirmed threat (%d shots)" % defender_shots.ships, defender_shots.ships > 0 and defender_shots.at_threats == defender_shots.ships)
	var reasons_ok := true
	for name: String in _requests:
		for r: Dictionary in _requests[name]:
			if not (r.why.begins_with("firing position") or r.why.begins_with("return to the defended position")):
				reasons_ok = false
	_check("no pursuit: defenders only requested local firing positions and returns (%s)" % ", ".join(_requests.keys().map(func(n: String) -> String: return "%s %d" % [n, _requests[n].size()])), reasons_ok)
	_check("defenders stayed within the defended area (%.0f u + 1.5 u avoidance tolerance; %.2f s outside)" % [Behavior.DEFENSE_RADIUS, outside[0]], outside[0] == 0.0)
	_check("a blocked line of fire was restored by a local repositioning (Gunship2 behind the small rock)", Behavior.of(_ship("Gunship2")).reposition_requests >= 1)
	_check("no request used hidden information (every named target was in contact): %s" % str(_uninformed()), _uninformed().is_empty())
	_check("no oscillation: no defender went back and forth between two points (A-B-A within 6 s)", defenders.all(func(n: String) -> bool: return _ping_pongs(n) == 0))


# --- P02 -------------------------------------------------------------------------------

func _p02() -> void:
	print("\n=== P02 Aggressive + Siege")
	await _load(1)
	var d: Node3D = _ship("Destroyer")
	var b = Behavior.of(d)
	var c = CombatShip.of(d)
	var locomotion: Node = d.get_node("Locomotion")
	var half: float = arena.sector_half_size()
	var first_useful := -1.0
	var engaged := 0.0
	var in_band := 0.0
	var in_band_by := {}
	var off_map := false
	var shots := {}
	for w in c.weapons:
		w.shot.connect(func(_wp: Node, _id: int, t: Node3D, _o: Transform3D) -> void:
			if CombatShip.of(t) != null:
				shots[String(w.config.family)] = shots.get(String(w.config.family), 0) + 1)
	while arena.enemy_controller.time < Scenarios.END_TIMES[1] and c.alive:
		await physics_frame
		_audit()
		var t: Node3D = c.target
		if t == null or c.target_status(t) != TS.VALID:
			continue
		engaged += 1.0 / 60.0
		if first_useful < 0.0 and c.weapons.any(func(w: Node) -> bool: return w.state == TS.VALID):
			first_useful = arena.enemy_controller.time
		if b.effective_profile >= 0:
			var band := Profiles.band(c, b.effective_profile)
			var distance: float = c.distance_to(t)
			if not band.is_empty() and distance >= band.near and distance <= band.far:
				in_band += 1.0 / 60.0
				in_band_by[Profiles.NAMES[b.effective_profile]] = in_band_by.get(Profiles.NAMES[b.effective_profile], 0.0) + 1.0 / 60.0
		if absf(locomotion.planar_position.x) > half or absf(locomotion.planar_position.y) > half:
			off_map = true
	print("First useful firing position: %.1f s; engaged (target in contact) %.1f s, in the effective profile's band %.1f s %s" % [first_useful, engaged, in_band, str(in_band_by)])
	print("Requests: %d movement, %d heading; approach/open-range reversals %d; ping-pongs %d; blocked %.1f s; collisions %d" % [b.move_requests, b.heading_requests,
		b.direction_changes, _ping_pongs("Destroyer"), locomotion.blocked_time, locomotion.collision_count])
	print("Shots at ships by family: %s; firing opportunity %.1f s; rounds left %s" % [str(shots), b.firing_time, str(c.weapons.map(func(w: Node) -> String: return "%s %d" % [w.config.family, w.rounds_left()]))])
	print("Profile changes: %s" % str(b.fallbacks))
	for r: Dictionary in _requests.get("Destroyer", []):
		print("  request %6.1f s  (%.0f, %.0f)  %s" % [r.time, r.point.x, r.point.y, r.why])
	_check("a useful firing position was established and the Siege band held for a while (first %.1f s; %.1f s in band)" % [first_useful, in_band],
		first_useful >= 0.0 and in_band_by.get(Profiles.NAMES[Profiles.Profile.SIEGE], 0.0) > 5.0)
	_check("stable positioning: %d movement requests in %.0f s, %d reversals, no A-B-A ping-pong" % [b.move_requests, Scenarios.END_TIMES[1], b.direction_changes],
		b.move_requests <= 12 and b.direction_changes <= 3 and _ping_pongs("Destroyer") == 0)
	_check("stayed on the map and clear of asteroids and ships (no contact constrained its motion)", not off_map and locomotion.collision_count == 0)
	var empty: bool = c.weapons.filter(func(w: Node) -> bool: return Profiles.category(w) == Profiles.Profile.SIEGE).all(func(w: Node) -> bool: return w.offensive_reach() <= 0.0)
	var final_profile: int = b.effective() if c.alive else b.effective_profile
	_check("profile fallbacks carry their reason; with the long-range weapons empty: %s (%s)" % [Profiles.NAMES[final_profile], b.fallback_reason],
		b.fallbacks.size() >= 2 and b.fallbacks.slice(1).all(func(f: String) -> bool: return f.contains("(") or f.ends_with("Siege"))
		and (not empty or (final_profile != Profiles.Profile.SIEGE and b.fallback_reason == "no ammunition")))
	_check("the requested profile stays Siege through every fallback", b.requested_profile == Profiles.Profile.SIEGE)
	_check("other eligible weapons kept firing whatever the profile (cannon shots %d)" % shots.get("cannon", 0), shots.get("cannon", 0) > 0)
	_check("no request used hidden information: %s" % str(_uninformed()), _uninformed().is_empty())


# --- P03 -------------------------------------------------------------------------------

func _p03() -> void:
	print("\n=== P03 Guard following")
	await _load(2)
	var d: Node3D = _ship("Destroyer")
	var guards := [Behavior.of(_ship("Gunship")), Behavior.of(_ship("Gunship2"))]
	var stance_before: Array = guards.map(func(g: Node) -> int: return g.combat.stance)
	var profile_before: Array = guards.map(func(g: Node) -> int: return g.requested_profile)
	var ratio := [INF, 0.0, 0.0, 0] # min, max, sum, samples
	var separation := INF
	var away := [{}, {}] # guard index -> {start: time} while outside proximity
	var catch_up := [0.0, 0.0]
	var slot_off := [[0.0, 0.0, 0], [0.0, 0.0, 0]] # per guard: sum, max, samples of the distance to its guard position
	var shots_at_hostile := [0, 0]
	var guarding_when_firing := [true, true]
	for i in 2:
		var gc = guards[i].combat
		gc.fired.connect(func(_w: Node, at: Node3D) -> void:
			if CombatShip.of(at) != null and CombatShip.of(at).faction != PLAYER:
				shots_at_hostile[i] += 1
				if guards[i].command != Behavior.Command.GUARD:
					guarding_when_firing[i] = false)
	var ended_same_tick := [false]
	var after_end := [true]
	var destroyed_at := -1.0
	while arena.enemy_controller.time < Scenarios.END_TIMES[2]:
		await physics_frame
		_audit()
		if destroyed_at < 0.0 and (not is_instance_valid(d) or not CombatShip.of(d).alive):
			destroyed_at = arena.enemy_controller.time
			ended_same_tick[0] = guards.all(func(g: Node) -> bool: return g.command == Behavior.Command.NONE and g.guard_target == null)
		if destroyed_at >= 0.0:
			after_end[0] = after_end[0] and guards.all(func(g: Node) -> bool: return g.command != Behavior.Command.GUARD and g.guard_target == null)
			continue
		for i in 2:
			var g = guards[i]
			var distance: float = g._here().distance_to(_planar(d))
			var r: float = distance / g.guard_distance()
			ratio[0] = minf(ratio[0], r)
			ratio[1] = maxf(ratio[1], r)
			ratio[2] += r
			ratio[3] += 1
			# Catch-up: stretches more than SLOT_OFF from the chosen guard position.
			var off: float = g._here().distance_to(g.slot_point(g.guard_slot)) if g.guard_slot >= 0 else 0.0
			slot_off[i][0] += off
			slot_off[i][1] = maxf(slot_off[i][1], off)
			slot_off[i][2] += 1
			if off > SLOT_OFF and away[i].is_empty():
				away[i] = {"start": arena.enemy_controller.time}
			elif off <= SLOT_OFF and not away[i].is_empty():
				catch_up[i] = maxf(catch_up[i], arena.enemy_controller.time - away[i].start)
				away[i] = {}
		var a: Node3D = guards[0].ship
		var b2: Node3D = guards[1].ship
		separation = minf(separation, _planar(a).distance_to(_planar(b2)) - a.get_node("RouteFollower").ship_radius - b2.get_node("RouteFollower").ship_radius)
	var lines: Array[String] = []
	for i in 2:
		var g = guards[i]
		var loco: Node = g.ship.get_node("Locomotion")
		lines.append("%s: %d requests, %d reassignments, in proximity %.1f of %.1f s (%.0f%%), off its guard position mean %.1f u / max %.1f u, longest stretch > %.0f u off %.1f s, collisions %d, shots at the hostile %d" % [g.ship.name,
			g.move_requests, g.guard_reassignments, g.guard_near_time, g.guard_time, 100.0 * g.guard_near_time / maxf(g.guard_time, 0.001),
			slot_off[i][0] / maxf(slot_off[i][2], 1.0), slot_off[i][1], SLOT_OFF, catch_up[i], loco.collision_count, shots_at_hostile[i]])
	print("\n".join(lines))
	print("Guard distance / (both hull radii + %.0f u buffer): min %.2f, mean %.2f, max %.2f; minimum hull gap between the guards %.1f u" % [Behavior.GUARD_BUFFER, ratio[0], ratio[2] / maxf(ratio[3], 1.0), ratio[1], separation])
	for g in guards:
		print("  %s log: %s" % [g.ship.name, " | ".join(g.log.filter(func(l: String) -> bool: return not l.contains(" request (")))])
	_check("both guards kept useful proximity at least 85%% of the time (%s)" % ", ".join(guards.map(func(g: Node) -> String: return "%.0f%%" % (100.0 * g.guard_near_time / maxf(g.guard_time, 0.001)))),
		guards.all(func(g: Node) -> bool: return g.guard_time > 30.0 and g.guard_near_time / g.guard_time >= 0.85))
	_check("guards never overlapped (minimum hull gap %.1f u > 0) and had no collisions" % separation,
		separation > 0.0 and guards.all(func(g: Node) -> bool: return g.ship.get_node("Locomotion").collision_count == 0))
	_check("an obstructed guard position was replaced, without swapping back and forth (reassignments %s)" % str(guards.map(func(g: Node) -> int: return g.guard_reassignments)),
		guards.any(func(g: Node) -> bool: return g.guard_reassignments >= 1) and guards.all(func(g: Node) -> bool: return g.guard_reassignments <= 3))
	var guard_only := true
	var guarding := 0
	for name: String in _requests:
		for r: Dictionary in _requests[name]:
			if r.command == Behavior.Command.GUARD:
				guarding += 1
				guard_only = guard_only and r.why.begins_with("guard position")
	_check("while guarding, every movement request (%d) was a guard position (no pursuit, no profile repositioning)" % guarding, guarding > 0 and guard_only)
	_check("Aggressive guard attacked and Defensive guard retaliated while guarding (shots %s)" % str(shots_at_hostile),
		shots_at_hostile[0] > 0 and shots_at_hostile[1] > 0 and guarding_when_firing[0] and guarding_when_firing[1])
	_check("destroying the protected Destroyer (at %.1f s) ended both Guards in the same tick, with no new assignment afterwards" % destroyed_at,
		destroyed_at >= 0.0 and ended_same_tick[0] and after_end[0])
	_check("tactics and requested profiles unchanged by the cancellation", guards.map(func(g: Node) -> int: return g.combat.stance) == stance_before
		and guards.map(func(g: Node) -> int: return g.requested_profile) == profile_before)
