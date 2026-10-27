extends SceneTree
## Combat prototype v0.3: E05 fleet combat checks and validation runs. Uninterrupted game
## loop, one fresh scene per case; run with a fixed physics step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/fleet_test.gd
## Optional: `-- <case prefix>` runs matching cases only. Every check is PASS/FAIL; the
## validation cases (V1–V6) also print their measurements.
##
## Independent checks in every case: every offensive shot or launch is at the shooter's
## manual target whenever one is set (strict focus), at a live hostile ship; every missile
## tick in powered flight changes velocity by at most acceleration × dt, turns the nose by
## at most turn rate × dt and stays at or below its maximum speed.
##
## Player behaviour in the validation runs (through CombatOrders, as player input would):
##   passive:   no orders (Aggressive stance from the encounter, automatic targets);
##   intervene: FF01B and FF01C pulled in beside FF01A, all three focus HostileFF01A,
##              then the hostile ship nearest FF01A after each kill;
##   far:       as intervene, but FF01B and FF01C are sent 60–70 u away from FF01A.

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const CombatHud := preload("res://game/ui/combat_hud.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const DT := 1.0 / 60.0
const EPS := 0.0001
const PLAYER := 0
const HOSTILE := 1
const EAST := -PI * 0.5
const WEST := PI * 0.5

var scene: Node3D
var _checks := 0
var _failures := 0
var _only := ""
var _bad_shots: Array[String] = []
var _shots: Array[Dictionary] = [] # current scene: {time, ship, faction, family, target, defense}
var _total_shots := 0
var _missile_ticks := 0
var _missile_bad: Array[String] = []
var _missiles := {} # id -> {prev_velocity, prev_nose, phase, launched, record}
var _player := {"focus": null}


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	_only = args[0] if args.size() > 0 else ""
	var cases := [
		["S1 composition, factions and loadouts", _case_composition],
		["S2 equal stocks", _case_stocks],
		["S3 selection and group orders", _case_selection],
		["S4 layout: routes, cover and no immediate exchange", _case_layout],
		["S5 hostile controller uses navigation and CombatOrders", _case_navigation],
		["S6 asteroid line of sight", _case_line_of_sight],
		["S7 victory and defeat detection", _case_victory],
		["S8 repeated resets", _case_resets],
		["V1 player intervention vs none", _case_intervention],
		["V2 escort near vs far", _case_escort],
		["V3 strict focus fire", _case_focus],
		["V4 missile feel in the fleet fight", _case_missiles],
		["V5 repositioning changes weapon coverage", _case_reposition],
		["V6 pacing", _case_pacing],
	]
	for entry in cases:
		if _only != "" and not String(entry[0]).begins_with(_only):
			continue
		print("\n=== %s" % entry[0])
		await entry[1].call()
	_free()
	print("\nShots and launches checked: %d, outside strict focus or at an invalid target: %d" % [_total_shots, _bad_shots.size()])
	for line in _bad_shots.slice(0, 20):
		print("  BAD SHOT: " + line)
	_check("every offensive shot at the manual target when one is set, at a live hostile ship", _bad_shots.is_empty() and _total_shots > 0)
	print("Missile ticks checked: %d" % _missile_ticks)
	for line in _missile_bad.slice(0, 20):
		print("  BAD MISSILE TICK: " + line)
	_check("every powered missile tick within acceleration, turn rate and maximum speed (%d violations)" % _missile_bad.size(), _missile_bad.is_empty() and _missile_ticks > 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


# --- Harness --------------------------------------------------------------------------

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


## v0.4 test condition: E05 without its Sensors (no fog of war), so this suite stays the
## v0.3 fleet-combat regression (contact by the manual board only); fog_test covers the fog.
func _without_sensors(arena: Node) -> void:
	var sensors := arena.get_node_or_null("Sensors")
	if sensors != null:
		arena.remove_child(sensors)
		sensors.free()


## Loads E05; `prepare` applies test conditions after its set-up, before the first tick.
func _load(prepare: Callable = Callable()) -> Node3D:
	_free()
	scene = E05.instantiate()
	scene.scenario_index = 0
	_without_sensors(scene)
	root.add_child(scene)
	if prepare.is_valid():
		prepare.call()
	_hook()
	_player.focus = null
	await physics_frame
	while not scene.enemy_controller.started:
		await _step("passive")
	return scene


func _hook() -> void:
	_shots.clear()
	_missiles.clear()
	for ship: Node3D in scene.get_node("Ships").get_children():
		for weapon in CombatShip.of(ship).weapons:
			weapon.shot.connect(_on_shot)
	scene.get_node("Projectiles").ordnance_finished.connect(func(record: Dictionary) -> void:
		if _missiles.has(record.id):
			_missiles[record.id]["record"] = record)


func _on_shot(weapon: Node, _id: int, target: Node3D, _origin: Transform3D) -> void:
	var combat = weapon.combat
	var defense := target != null and is_instance_valid(target) and CombatShip.of(target) == null
	_total_shots += 1
	_shots.append({"time": scene.enemy_controller.time, "ship": String(weapon.ship.name), "faction": combat.faction, "family": String(weapon.config.family),
		"target": String(target.name) if target != null and is_instance_valid(target) else "", "defense": defense,
		"fleet_focus": String(scene.get_node("HostileFleet").focus.name) if is_instance_valid(scene.get_node("HostileFleet").focus) else ""})
	if defense:
		return
	# A later launch of a committed salvo (Barrage, Wayfarer) belongs to the firing action
	# authorized at its first launch, against the target valid then.
	if weapon.get("salvo_size") != null and weapon.salvo_size > 1 and weapon.salvo_launched > 1:
		return
	var problems: Array[String] = []
	var target_combat = CombatShip.of(target)
	if target_combat == null or not target_combat.alive or target_combat.faction == combat.faction:
		problems.append("not a live hostile ship")
	if combat.manual_target != null and combat.manual_target != target:
		problems.append("not the manual target %s" % combat.manual_target.name)
	if not problems.is_empty():
		_bad_shots.append("%.2f %s %s -> %s: %s" % [scene.enemy_controller.time, weapon.ship.name, weapon.name, target.name if is_instance_valid(target) else "?", ", ".join(problems)])


func _step(mode: String) -> void:
	_steer_player(mode)
	await physics_frame
	_sample()


func _ship(ship_name: String) -> Node3D:
	return scene.get_node("Ships").get_node_or_null(ship_name)


func _alive(faction: int) -> Array[Node3D]:
	return scene.get_node("HostileFleet").ships_of(faction)


func _place(ship_name: String, x: float, z: float, heading: float) -> void:
	_ship(ship_name).get_node("Locomotion").place(Vector2(x, z), heading)
	_ship(ship_name).get_node("Avoidance").reset()


func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)


# Player orders of the validation runs (see the header); only through CombatOrders.
func _steer_player(mode: String) -> void:
	if mode == "passive" or scene == null or not scene.enemy_controller.started:
		return
	var orders = scene.orders
	if _player.focus == null:
		var escorts := {"intervene": [Vector2(-79, 2), Vector2(-79, 22)], "far": [Vector2(-80, -55), Vector2(-75, 80)]}
		orders.move([_ship("FF01B")], escorts[mode][0])
		orders.move([_ship("FF01C")], escorts[mode][1])
	var focus: Variant = _player.focus
	if focus != null and is_instance_valid(focus) and CombatShip.of(focus).alive:
		return
	var hostiles := _alive(HOSTILE)
	var players := _alive(PLAYER)
	if hostiles.is_empty() or players.is_empty():
		return
	var pick: Node3D = null
	for ship: Node3D in hostiles:
		if ship.name == "HostileFF01A":
			pick = ship
	if pick == null:
		var best := INF
		for ship: Node3D in hostiles:
			var distance := _planar(ship).distance_to(_planar(players[0]))
			if distance < best:
				best = distance
				pick = ship
	_player.focus = pick
	orders.assign_target(players, pick)


## Runs until the battle ends or `limit` seconds pass; returns the FleetBattle node.
func _battle(mode: String, limit: float) -> Node:
	var battle := scene.get_node("FleetBattle")
	for i in roundi(limit / DT):
		await _step(mode)
		if battle.finished:
			break
	return battle


# Per-tick missile audit (powered flight limits).
func _sample() -> void:
	if scene == null or not is_instance_valid(scene):
		return
	for node in scene.get_node("Projectiles").ordnance:
		if node.kind != &"missile":
			continue
		var id: int = node.id
		var c: Resource = node.config
		if not _missiles.has(id):
			_missiles[id] = {"prev_velocity": node.velocity, "prev_nose": node.forward(), "phase": node.phase, "max_cruise_nv": 0.0,
				"reversals": 0, "axis": Vector3.ZERO, "powered_at": -1.0, "max_at": -1.0}
			continue
		var s: Dictionary = _missiles[id]
		if s.phase == "powered":
			_missile_ticks += 1
			var dv: float = node.velocity.distance_to(s.prev_velocity)
			var turn: float = (s.prev_nose as Vector3).angle_to(node.forward())
			if dv > c.acceleration * DT + EPS:
				_missile_bad.append("missile %d: velocity change %.3f u/s in one tick" % [id, dv])
			if turn > deg_to_rad(c.turn_rate_deg) * DT + 0.000001:
				_missile_bad.append("missile %d: turn %.3f deg in one tick" % [id, rad_to_deg(turn)])
			if node.velocity.length() > c.max_speed + EPS:
				_missile_bad.append("missile %d: above maximum speed" % id)
			if s.powered_at < 0.0:
				s.powered_at = node.age
			if s.max_at < 0.0 and node.velocity.length() >= c.max_speed * 0.98:
				s.max_at = node.age
			if s.max_at >= 0.0:
				s.max_cruise_nv = maxf(s.max_cruise_nv, rad_to_deg(node.forward().angle_to(node.velocity)))
			if turn / DT > deg_to_rad(5.0):
				var axis: Vector3 = (s.prev_nose as Vector3).cross(node.forward()).normalized()
				if (s.axis as Vector3) != Vector3.ZERO and axis.dot(s.axis) < 0.0:
					s.reversals += 1
				s.axis = axis
		s.prev_velocity = node.velocity
		s.prev_nose = node.forward()
		s.phase = node.phase
		s.avoided = (node.avoided as Array).duplicate()


# --- Structure --------------------------------------------------------------------------

func _case_composition() -> void:
	await _load()
	var by_faction := {PLAYER: [], HOSTILE: []}
	var ids := {}
	for ship: Node3D in scene.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		by_faction[combat.faction].append(ship)
		ids[combat.combat_id] = true
	for faction in [PLAYER, HOSTILE]:
		var ff01s := (by_faction[faction] as Array).filter(func(s: Node3D) -> bool: return s.scene_file_path == "res://game/ships/ff01_unit.tscn")
		_check("%s fleet: 3 FF-01s (%s)" % [CombatShip.FACTION_NAMES[faction], str((by_faction[faction] as Array).map(func(s: Node3D) -> String: return String(s.name)))],
			(by_faction[faction] as Array).size() == 3 and ff01s.size() == 3)
	_check("combat ids unique (%d ships)" % ids.size(), ids.size() == 6)
	var loadouts := {}
	var compatible := true
	for ship: Node3D in scene.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		compatible = compatible and combat.incompatible.is_empty()
		var families: Array = combat.weapons.map(func(w: Node) -> String: return String(w.config.family))
		loadouts[String(ship.name)] = families
	print("  loadouts %s" % str(loadouts))
	_check("every FF-01: 2 cannons, 4 point-defense guns, a rocket launcher and a missile launcher; all on compatible hardpoints",
		compatible and loadouts.FF01A == ["cannon", "cannon", "gatling", "gatling", "gatling", "gatling", "rocket", "missile"]
		and loadouts.values().all(func(families: Array) -> bool: return families == loadouts.FF01A))
	var stances := scene.get_node("Ships").get_children().map(func(s: Node) -> int: return CombatShip.of(s).stance)
	var focus: Node3D = scene.get_node("HostileFleet").focus
	_check("every ship Aggressive at full hull, no scenario conditions; player ships without a manual target, hostiles on the controller's focus (%s)" % (focus.name if focus else "none"),
		stances.all(func(v: int) -> bool: return v == 2) and scene.conditions.is_empty()
		and scene.get_node("Ships").get_children().all(func(s: Node) -> bool: return CombatShip.of(s).health == CombatShip.of(s).max_health)
		and _alive(PLAYER).all(func(s: Node3D) -> bool: return CombatShip.of(s).manual_target == null)
		and focus != null and _alive(HOSTILE).all(func(s: Node3D) -> bool: return CombatShip.of(s).manual_target == focus))


func _case_stocks() -> void:
	await _load()
	var stock := {PLAYER: {}, HOSTILE: {}}
	for ship: Node3D in scene.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		for weapon in combat.weapons:
			var family := String(weapon.config.family)
			stock[combat.faction][family] = stock[combat.faction].get(family, 0) + weapon.rounds_left()
	print("  player %s; hostile %s" % [str(stock[PLAYER]), str(stock[HOSTILE])])
	_check("equal ammunition stocks per weapon family on both sides", stock[PLAYER] == stock[HOSTILE] and not stock[PLAYER].is_empty())


func _case_selection() -> void:
	await _load()
	var selection = scene.selection()
	selection.set_selection(scene.get_node("Ships").get_children())
	var names: Array = selection.selected.map(func(s: Node3D) -> String: return String(s.name))
	_check("selecting every ship keeps only the 3 player ships (%s)" % str(names), names.size() == 3 and not names.any(func(n: String) -> bool: return n.begins_with("Hostile")))
	_check("all 6 ships registered for picking", selection.registered_count() == 6)
	var given: bool = scene.orders.move(selection.selected, Vector2(-60, 12))
	var destinations := {}
	for ship: Node3D in selection.selected:
		var locomotion = ship.get_node("Locomotion")
		if locomotion.has_destination or ship.get_node("RouteFollower").status == RouteFollower.RouteStatus.WAITING:
			destinations[String(ship.name)] = locomotion.destination
	var distinct := true
	var points: Array = destinations.values()
	for i in points.size():
		for j in range(i + 1, points.size()):
			distinct = distinct and (points[i] as Vector2).distance_to(points[j]) > 2.0
	print("  group MOVE destinations %s" % str(destinations))
	_check("group MOVE through CombatOrders gives each of the 3 its own destination", given and destinations.size() == 3 and distinct)
	var count: int = scene.orders.assign_target(selection.selected, _ship("HostileFF01C"))
	_check("group target order: all 3 take the manual target", count == 3 and selection.selected.all(func(s: Node3D) -> bool: return CombatShip.of(s).manual_target == _ship("HostileFF01C")))
	_check("hostile ships are not selectable", not selection.selectable(_ship("HostileFF01A")))


func _case_layout() -> void:
	await _load()
	var fleet = scene.get_node("HostileFleet")
	var asteroids := scene.get_node("Asteroids")
	var nearest := INF
	for p: Node3D in _alive(PLAYER):
		for h: Node3D in _alive(HOSTILE):
			nearest = minf(nearest, _planar(p).distance_to(_planar(h)))
	var blocked: bool = not fleet.line_clear(_planar(_ship("FF01A")), _planar(_ship("HostileFF01A")))
	print("  %d asteroids; nearest opposing ships %.1f u apart; leads (FF01A, HostileFF01A) %.1f u" % [asteroids.ids().size(), nearest, _planar(_ship("FF01A")).distance_to(_planar(_ship("HostileFF01A")))])
	_check("several asteroids (%d); fleets start beyond every weapon's range (nearest pair %.1f u > Wayfarer 90 u)" % [asteroids.ids().size(), nearest], asteroids.ids().size() >= 5 and nearest > 90.0)
	_check("the line between the leads runs through an asteroid (no head-on line of fire)", blocked)
	# Approach routes: gates on the middle line (x 0), separated from each other by rocks:
	# north of rock 2, between rocks 2 and 1, between rocks 1 and 3, south of rock 3. A gate
	# counts when a FF01A fits there and routes from the hostile start through it to the
	# player start exist.
	var navigation := scene.get_node("StaticNavigation")
	var radius: float = _ship("HostileFF01A").get_node("RouteFollower").planning_radius()
	var gates := {"north (0, -80)": Vector2(0, -80), "centre-north (0, -24)": Vector2(0, -24), "centre-south (0, 24)": Vector2(0, 24), "south (0, 80)": Vector2(0, 80)}
	var start := _planar(_ship("HostileFF01A"))
	var goal := _planar(_ship("FF01A"))
	var open := []
	for gate: String in gates:
		var point: Vector2 = gates[gate]
		var fits: bool = navigation.closest_point(radius, point).distance_to(point) < 0.01
		var there: PackedVector2Array = navigation.plan(radius, start, point)
		var on: PackedVector2Array = navigation.plan(radius, point, goal)
		if fits and there.size() >= 2 and on.size() >= 2 and there[-1].distance_to(point) < 0.01 and on[-1].distance_to(goal) < 0.5:
			open.append(gate)
	var separated := true
	var names: Array = gates.keys()
	for i in names.size() - 1:
		separated = separated and not navigation.segment_clear(gates[names[i]], gates[names[i + 1]], radius)
	print("  approach gates open for the FF01A: %s; neighbouring gates separated by rock: %s" % [str(open), str(separated)])
	_check("multiple approach routes: 4 separate gates on the middle line, each routable for a FF01A (%d)" % open.size(), open.size() == 4 and separated)


func _case_navigation() -> void:
	await _load()
	var history_before := 0
	var routes := {"bent": 0, "max_points": 0}
	var inside := {"worst": INF}
	var asteroids := scene.get_node("Asteroids")
	for i in roundi(45.0 / DT):
		await _step("passive")
		for ship: Node3D in _alive(HOSTILE):
			var route: PackedVector2Array = ship.get_node("RouteFollower").route
			routes.max_points = maxi(routes.max_points, route.size())
			for id: int in asteroids.ids():
				var c: Vector3 = asteroids.center(id)
				var gap: float = _planar(ship).distance_to(Vector2(c.x, c.z)) - asteroids.radius(id) - ship.get_node("RouteFollower").ship_radius
				inside.worst = minf(inside.worst, gap)
	var hostile_orders: Array = scene.orders.history.slice(history_before).filter(func(h: Dictionary) -> bool:
		return h.channel == "movement" and (h.ships as Array).any(func(n: String) -> bool: return n.begins_with("Hostile")))
	var fleet = scene.get_node("HostileFleet")
	print("  hostile movement orders %d; longest route %d points; closest hull-to-asteroid gap %.2f u; log %s" % [hostile_orders.size(), routes.max_points, inside.worst, str(fleet.log.slice(0, 6))])
	_check("hostile ships move only through CombatOrders (%d movement orders recorded)" % hostile_orders.size(), hostile_orders.size() >= 3)
	_check("their routes are planned by the static navigation around asteroids (a route with %d points)" % routes.max_points, routes.max_points >= 3)
	_check("no hostile footprint enters an asteroid (closest gap %.2f u)" % inside.worst, inside.worst > 0.0)
	# v0.4 (owner-approved): live hostile ships only (a destroyed ship's targets are cleared).
	var targets: Array = scene.get_node("Ships").get_children().filter(func(s: Node) -> bool: return CombatShip.of(s).faction == HOSTILE and CombatShip.of(s).alive).map(
		func(s: Node) -> Variant: return CombatShip.of(s).manual_target)
	_check("one focus target for the live hostile fleet (%s)" % str(targets.map(func(t: Variant) -> String: return String(t.name) if t != null else "none")),
		targets[0] != null and targets.all(func(t: Variant) -> bool: return t == targets[0]))


func _case_line_of_sight() -> void:
	# HostileFF01B parked directly behind the central rock from the player FF01B (test
	# condition: the controller is off, both on Hold Fire except the shooter).
	await _load(func() -> void:
		scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
		_place("FF01B", -30, 0, EAST)
		_place("HostileFF01B", 30, 0, WEST)
		_place("FF01A", -100, 100, EAST); _place("FF01C", -100, 120, EAST)
		_place("HostileFF01A", 100, -100, WEST); _place("HostileFF01C", 100, -120, WEST)
		scene.orders.set_stance(scene.get_node("Ships").get_children(), 0)
		scene.orders.set_stance([_ship("FF01B")], 2)
		scene.orders.assign_target([_ship("FF01B")], _ship("HostileFF01B")))
	await _run("passive", 6.0)
	var cannon = _ship("FF01B").get_node("Weapons/ForwardBastionHardpoint").weapon()
	var blocked_reason: String = cannon.reason
	var shots_blocked := _shots.filter(func(s: Dictionary) -> bool: return s.ship == "FF01B" and s.family == "cannon").size()
	_check("cannon behind the central rock: '%s', no shots (%d)" % [blocked_reason, shots_blocked], blocked_reason.contains("asteroid") and shots_blocked == 0)
	scene.orders.move([_ship("FF01B")], Vector2(-30, -32))
	await _run("passive", 14.0)
	var shots_clear := _shots.filter(func(s: Dictionary) -> bool: return s.ship == "FF01B" and s.family == "cannon").size()
	_check("moved clear of the rock the same cannon fires (%d shots; '%s')" % [shots_clear, cannon.reason], shots_clear > 0)


func _run(mode: String, seconds: float) -> void:
	for i in roundi(seconds / DT):
		await _step(mode)


func _case_victory() -> void:
	await _load()
	var battle := scene.get_node("FleetBattle")
	await _run("passive", 1.0)
	_check("battle running: no result while both fleets have ships", not battle.finished and scene.result_text == "")
	CombatShip.of(_ship("FF01B")).health = 37.0
	for ship: Node3D in _alive(HOSTILE):
		CombatShip.of(ship).destroy()
	await _run("passive", 0.5)
	var time_at: float = battle.elapsed
	print("  " + battle.result.replace("\n", "\n  "))
	_check("all hostiles destroyed: VICTORY once, with elapsed time and every survivor's hull", battle.finished and battle.winner == PLAYER
		and battle.survivors.size() == 3 and battle.result.contains("VICTORY") and battle.result.contains("FF-01  hull 37 / %d" % roundi(CombatShip.of(_ship("FF01B")).max_health))
		and battle.result.contains("Elapsed 0:0"))
	CombatShip.of(_ship("FF01B")).destroy()
	await _run("passive", 0.5)
	_check("the result is fixed once decided (later losses change nothing)", battle.elapsed == time_at and battle.winner == PLAYER and battle.survivors.size() == 3)
	_check("the HUD shows the result (arena result_text)", scene.result_text == battle.result)
	await _load()
	battle = scene.get_node("FleetBattle")
	for ship: Node3D in _alive(PLAYER):
		CombatShip.of(ship).destroy()
	await _run("passive", 0.5)
	_check("all player ships destroyed: DEFEAT, the 3 hostile survivors listed", battle.finished and battle.winner == HOSTILE and battle.survivors.size() == 3 and battle.result.contains("DEFEAT"))
	await _load()
	battle = scene.get_node("FleetBattle")
	for ship: Node3D in scene.get_node("Ships").get_children():
		CombatShip.of(ship).destroy()
	await _run("passive", 0.5)
	_check("both fleets gone in the same tick: DRAW, no survivors", battle.finished and battle.winner == 2 and battle.survivors.is_empty() and battle.result.contains("No survivors"))


func _case_resets() -> void:
	await _load()
	var olds := []
	var counts: Array[float] = []
	var orphans: Array[float] = []
	var clean := true
	for i in 6:
		olds.append(weakref(scene))
		# Replace the arena with a fresh E05, as a reset does: the old one is freed with its
		# ships, ordnance, effects and navigation maps.
		var old := scene
		root.remove_child(old)
		old.queue_free()
		scene = E05.instantiate()
		root.add_child(scene)
		await process_frame
		var a: Node3D = scene
		clean = clean and a.projectiles.ordnance.is_empty() and a.projectiles.active.is_empty() and a.effects.active_count() == 0 			and a.get_node("OrdnanceTrails").trail_count() == 0 and a.result_text == "" and a.get_node("FleetBattle").pacing.first_shot < 0.0
		# Long enough for the first launches so ordnance is in flight at the next reset.
		for k in roundi(40.0 / DT):
			await physics_frame
		await process_frame
		counts.append(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		orphans.append(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var in_flight: int = scene.projectiles.ordnance.size() + scene.projectiles.active.size()
	_free()
	await physics_frame
	await process_frame
	var freed := olds.all(func(w: WeakRef) -> bool: return w.get_ref() == null)
	print("  node counts after 40 s: %s; orphans %s; projectiles in flight at the last reset %d" % [str(counts), str(orphans), in_flight])
	_check("resets of E05: previous arenas freed (%d)" % olds.size(), freed)
	_check("every reset starts with no ordnance, rounds, effects, trails or result", clean)
	_check("orphan node count stays 0", orphans.all(func(n: float) -> bool: return n == 0.0))
	_check("node count does not grow across resets (spread %.0f)" % (counts.max() - counts.min()), counts.max() - counts.min() <= 120)


# --- Validation ---------------------------------------------------------------------------

func _summary(battle: Node) -> Dictionary:
	var hull := 0.0
	for s: Dictionary in battle.survivors:
		if s.faction == PLAYER:
			hull += s.hull
	return {"winner": battle.winner, "elapsed": battle.elapsed, "player_hull": hull, "survivors": battle.survivors.map(func(s: Dictionary) -> String: return "%s %d" % [s.name, roundi(s.hull)]),
		"pacing": battle.pacing.duplicate(), "kills": battle.kills.map(func(k: Dictionary) -> String: return "%.1f %s" % [k.time, k.ship])}


var _runs := {}


func _full(mode: String) -> Dictionary:
	if _runs.has(mode):
		return _runs[mode]
	await _load()
	var battle := await _battle(mode, 300.0)
	var result := _summary(battle)
	result.finished = battle.finished
	result.shots = _shots.duplicate()
	result.missiles = _missiles.duplicate(true)
	result.records = scene.get_node("Projectiles").ordnance_records.duplicate()
	result.repositions = scene.get_node("HostileFleet").repositions
	_runs[mode] = result
	print("  [%s] %s in %.1f s; survivors %s; kills %s" % [mode, ["VICTORY", "DEFEAT", "DRAW", "unfinished"][battle.winner if battle.finished else 3], battle.elapsed, str(result.survivors), str(result.kills)])
	return result


func _case_intervention() -> void:
	var passive := await _full("passive")
	var intervene := await _full("intervene")
	# The outcome and duration expectations were balanced for the retired legacy fleet; both
	# runs are measured only (they feed V4 and V6).
	print("  passive %s (player hull left %.0f); intervene %s (%.0f)" % [
		["VICTORY", "DEFEAT", "DRAW", "unfinished"][passive.winner if passive.finished else 3], passive.player_hull,
		["VICTORY", "DEFEAT", "DRAW", "unfinished"][intervene.winner if intervene.finished else 3], intervene.player_hull])


func _case_escort() -> void:
	var results := {}
	# Test conditions: the player FF01A cannot be destroyed (damage is measured) and is
	# the hostile fleet's focus throughout (the controller keeps a live focus).
	for mode in ["intervene", "far"]:
		await _load(func() -> void:
			CombatShip.of(_ship("FF01A")).health = 100000.0
			var fleet = scene.get_node("HostileFleet")
			fleet.focus = _ship("FF01A")
			scene.orders.assign_target(fleet.ships_of(HOSTILE), _ship("FF01A")))
		await _run(mode, 75.0)
		var to_lead: Array = scene.get_node("Projectiles").ordnance_records.filter(func(r: Dictionary) -> bool: return r.target_name == "FF01A")
		var defense := _shots.filter(func(s: Dictionary) -> bool: return s.defense and s.faction == PLAYER and s.ship in ["FF01B", "FF01C"]).size()
		results[mode] = {"damage": 100000.0 - CombatShip.of(_ship("FF01A")).health, "intercepted": to_lead.filter(func(r: Dictionary) -> bool: return r.outcome == "intercepted").size(),
			"hits": to_lead.filter(func(r: Dictionary) -> bool: return r.outcome == "damage").size(), "escort_pd": defense,
			"by_escorts": to_lead.filter(func(r: Dictionary) -> bool: return r.outcome == "intercepted" and r.get("intercepted_by", "") in ["FF01B", "FF01C"]).size()}
		print("  escort %-9s: FF01A took %.0f damage in 75 s; ordnance at it: %d intercepted (%d by the escorts), %d hit; escort point-defense rounds %d" % [
			"near" if mode == "intervene" else "far", results[mode].damage, results[mode].intercepted, results[mode].by_escorts, results[mode].hits, results[mode].escort_pd])
	# FF01A has its own Kestrels, so the escorts' share is counted by interceptor.
	_check("escorts near the FF01A intercept more ordnance aimed at it (%d vs %d)" % [results.intervene.by_escorts, results.far.by_escorts], results.intervene.by_escorts > results.far.by_escorts)
	_check("and it takes less damage (%.0f vs %.0f)" % [results.intervene.damage, results.far.damage], results.intervene.damage < results.far.damage)


func _case_focus() -> void:
	var run := await _full("intervene")
	var shots: Array = run.shots
	var player_offense := shots.filter(func(s: Dictionary) -> bool: return s.faction == PLAYER and not s.defense)
	var hd_death := INF
	for k: String in run.kills:
		if k.ends_with("HostileFF01A"):
			hd_death = float(k.split(" ")[0])
	var before := player_offense.filter(func(s: Dictionary) -> bool: return s.time < hd_death - 0.05)
	var off_focus := before.filter(func(s: Dictionary) -> bool: return s.target != "HostileFF01A")
	var hostile_offense := shots.filter(func(s: Dictionary) -> bool: return s.faction == HOSTILE and not s.defense)
	var hostile_targets := {}
	for s: Dictionary in hostile_offense:
		hostile_targets[s.target] = hostile_targets.get(s.target, 0) + 1
	print("  player offensive shots before the hostile FF01A fell (%.1f s): %d, at other ships %d; hostile shots by target %s" % [hd_death, before.size(), off_focus.size(), str(hostile_targets)])
	_check("player focus: every offensive shot at the hostile FF01A until it was destroyed (%d shots)" % before.size(), before.size() > 0 and off_focus.is_empty())
	var off_fleet_focus := hostile_offense.filter(func(s: Dictionary) -> bool: return s.target != s.fleet_focus)
	_check("hostile focus: every hostile offensive shot (%d) at the controller's focus of that moment (%d elsewhere)" % [hostile_offense.size(), off_fleet_focus.size()],
		not hostile_offense.is_empty() and off_fleet_focus.is_empty())


func _case_missiles() -> void:
	for mode in ["passive", "intervene"]:
		var run := await _full(mode)
		var outcomes := {}
		var ages: Array[float] = []
		var cruise: Array[float] = []
		var reversals := 0
		var boost: Array[float] = []
		var steered := 0
		for r: Dictionary in run.records:
			if r.kind != "missile":
				continue
			outcomes[r.outcome] = outcomes.get(r.outcome, 0) + 1
			if r.outcome == "damage":
				ages.append(r.age)
			var m: Dictionary = run.missiles.get(r.id, {})
			if not m.is_empty():
				cruise.append(m.max_cruise_nv)
				reversals += m.reversals
				if (m.get("avoided", []) as Array).any(func(a: String) -> bool: return a.begins_with("asteroid")):
					steered += 1
				if m.max_at >= 0.0:
					boost.append(m.max_at - m.powered_at)
		print("  [%s] missiles %s; time to impact %s s; time to max speed %s s; max cruise nose-velocity angle %s deg; steering reversals %d; steered around an asteroid %d" % [mode, str(outcomes),
			str(ages.map(func(a: float) -> String: return "%.1f" % a)), str(boost.map(func(a: float) -> String: return "%.2f" % a)),
			str(cruise.map(func(a: float) -> String: return "%.0f" % a)), reversals, steered])
		_check("[%s] missiles launched and resolved in the fleet fight (%d; flight limits audited every tick, see the end)" % [mode, outcomes.values().reduce(func(a: int, b: int) -> int: return a + b, 0)],
			not outcomes.is_empty() and outcomes.get("asteroid", 0) == 0)


func _case_reposition() -> void:
	# HostileFF01B starts behind the central rock relative to the focus target; the
	# controller (the only one giving its orders) must move it to a clear station.
	await _load(func() -> void:
		_place("FF01B", -30, 0, EAST)
		_place("HostileFF01B", 20, 0, WEST)
		_place("FF01A", -110, 100, EAST); _place("FF01C", -110, 120, EAST)
		_place("HostileFF01A", 110, -110, WEST); _place("HostileFF01C", 110, -130, WEST)
		CombatShip.of(_ship("FF01B")).health = 100000.0
		scene.orders.set_stance([_ship("FF01B"), _ship("FF01A"), _ship("FF01C")], 0))
	var fleet = scene.get_node("HostileFleet")
	var cannon = _ship("HostileFF01B").get_node("Weapons/ForwardBastionHardpoint").weapon()
	var obscured := {"before": 0, "after": 0, "ticks_before": 0, "ticks_after": 0}
	var moved_at := -1.0
	for i in roundi(30.0 / DT):
		await _step("passive")
		var phase := "before" if fleet.repositions == 0 or _ship("HostileFF01B").get_node("Locomotion").has_destination else "after"
		if fleet.repositions > 0 and moved_at < 0.0:
			moved_at = scene.enemy_controller.time
		obscured["ticks_" + phase] += 1
		if String(cannon.reason).contains("asteroid"):
			obscured[phase] += 1
	var fired := _shots.filter(func(s: Dictionary) -> bool: return s.ship == "HostileFF01B" and s.family == "cannon").size()
	var clear: bool = fleet.line_clear(Vector2(_ship("HostileFF01B").global_position.x, _ship("HostileFF01B").global_position.z), Vector2(-30, 0))
	print("  focus %s; repositions %d (first at %.1f s); cannon obscured %d of %d ticks before / %d of %d after; cannon shots %d; log %s" % [fleet.focus.name if fleet.focus else "-",
		fleet.repositions, moved_at, obscured.before, obscured.ticks_before, obscured.after, obscured.ticks_after, fired, str(fleet.log.slice(0, 4))])
	_check("blocked line of fire: the controller repositions the FF01B through CombatOrders (%d)" % fleet.repositions, fleet.repositions >= 1)
	_check("after repositioning its line of fire is clear and the cannon is no longer obscured (%d obscured ticks after; %d shots)" % [obscured.after, fired],
		clear and obscured.after == 0 and fired > 0 and obscured.before > 0)


func _case_pacing() -> void:
	for mode in ["passive", "intervene"]:
		var run := await _full(mode)
		var p: Dictionary = run.pacing
		print("  [%s] first shot %.1f s, first guided launch %.1f s, first impact %.1f s, first kill %.1f s, end %.1f s; kills %s" % [mode, p.first_shot, p.first_launch,
			p.first_impact, p.first_kill, p.end, str(run.kills)])
		print("  [%s] window before any weapon fires %.1f s; first impact to first kill %.1f s; first kill to end %.1f s" % [mode, p.first_shot, p.first_kill - p.first_impact, p.end - p.first_kill])
		_check("[%s] no immediate exchange: first shot after %.1f s (>= 20 s)" % [mode, p.first_shot], p.first_shot >= 20.0)
