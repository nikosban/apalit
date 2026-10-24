extends SceneTree
## Combat prototype v0.4 (B1, B2): multi-cell missile launchers and staggered salvos, on E05
## (both Destroyers: four cells in two columns, 4-missile salvos every 0.2 s, 12 missiles).
## Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/salvo_test.gd

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const LAB := preload("res://game/tests/combat/fixtures/combat_lab.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const WeaponGeometry := preload("res://game/weapons/weapon_geometry.gd")
const Launcher := preload("res://game/weapons/launcher.gd")
const DT := 1.0 / 60.0
const EAST := -PI * 0.5
const WEST := PI * 0.5

var scene: Node3D
var _checks := 0
var _failures := 0
var _launches: Array[Dictionary] = [] # {time, cell, origin, id}


func _initialize() -> void:
	await process_frame
	_case_layouts()
	await _case_e05_cells()
	await _case_timing()
	await _case_ammunition()
	await _case_destroyed()
	await _case_contact_lost()
	await _case_pause()
	await _case_fast()
	await _case_reset()
	await _case_interception()
	_free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _free() -> void:
	Engine.time_scale = 1.0
	paused = false
	if scene != null and is_instance_valid(scene):
		root.remove_child(scene)
		scene.free()
	scene = null


## E05 with the scripted fleet off, every ship holding fire and parked in a corner; the
## player's Destroyer fires only its missiles (other weapons off), at a placed target.
func _load() -> void:
	_free()
	scene = E05.instantiate()
	scene.scenario_index = 4
	root.add_child(scene)
	scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
	scene.enemy_controller._steps.clear()
	scene.enemy_controller._patrols.clear()
	for ship: Node in scene.get_node("Ships").get_children():
		CombatShip.of(ship).stance = CombatShip.Stance.HOLD_FIRE
	await physics_frame
	while not scene.enemy_controller.started:
		await physics_frame
	var corners := {"Gunship": Vector2(-140, -140), "Gunship2": Vector2(-140, 140), "HostileGunship2": Vector2(140, -140), "HostileDestroyer": Vector2(140, 140)}
	for name: String in corners:
		_place(name, corners[name], EAST)
	_place("Destroyer", Vector2(-60, 110), EAST)
	_place("HostileGunship", Vector2(0, 110), WEST)
	for w in CombatShip.of(scene.ship("Destroyer")).weapons:
		if String(w.config.family) != "missile":
			w.enabled = false
	_launches.clear()
	cells().shot.connect(func(_w: Node, id: int, _t: Node3D, origin: Transform3D) -> void:
		var index := -1
		for i in cells().muzzles.size():
			if cells().muzzles[i].global_transform.origin.distance_to(origin.origin) < 0.0001:
				index = i
		_launches.append({"time": CombatShip.now(), "cell": index, "origin": origin, "id": id}))
	await physics_frame
	scene.sensors.evaluate()


func _place(name: String, point: Vector2, heading: float) -> void:
	var ship: Node3D = scene.ship(name)
	ship.get_node("Locomotion").place(point, heading)
	ship.get_node("Avoidance").reset()


func cells() -> Node:
	return scene.ship("Destroyer").get_node("Weapons/DeckHardpoint/MissileCells")


func _engage() -> void:
	CombatShip.of(scene.ship("Destroyer")).stance = CombatShip.Stance.AGGRESSIVE
	scene.orders.assign_target([scene.ship("Destroyer")], scene.ship("HostileGunship"))


func _until(condition: Callable, limit: int) -> void:
	for i in limit:
		if condition.call():
			return
		await physics_frame


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


## B1: every supported layout gives as many distinct cells as configured.
func _case_layouts() -> void:
	print("\n=== L1 launcher configurations")
	var ok := true
	var lines: Array[String] = []
	for count in Launcher.VALID_CELLS:
		for columns in [1, 2]:
			var holder := Node3D.new()
			var muzzles := WeaponGeometry.build_cells(holder, 1.0, 0.22, 1.4, count, columns)
			var distinct := {}
			for m in muzzles:
				distinct[str(m.position.snapped(Vector3.ONE * 0.0001))] = true
			var up := muzzles.all(func(m: Node3D) -> bool: return (-m.basis.z).is_equal_approx(Vector3.UP))
			var inside := muzzles.all(func(m: Node3D) -> bool: return absf(m.position.x) < 0.5 and absf(m.position.z) < 0.7)
			ok = ok and muzzles.size() == count and distinct.size() == count and up and inside
			lines.append("%d×%d col: %d cells, %d distinct" % [count, columns, muzzles.size(), distinct.size()])
			holder.free()
	print("  " + ", ".join(lines))
	_check("2, 4, 6 and 8 cells in one or two columns: the configured number of cells, distinct, vertical, inside the housing", ok)


## B1: the E05 overrides give each Destroyer four distinct cells on its fore deck.
func _case_e05_cells() -> void:
	print("\n=== L2 E05 four-cell launchers")
	await _load()
	var ok := true
	for name in ["Destroyer", "HostileDestroyer"]:
		var launcher: Node = scene.ship(name).get_node("Weapons/DeckHardpoint/MissileCells")
		var ship: Node3D = scene.ship(name)
		var points: Array = launcher.muzzles.map(func(m: Node3D) -> Vector3: return ship.global_transform.affine_inverse() * m.global_position)
		var distinct := {}
		for p: Vector3 in points:
			distinct[str(p.snapped(Vector3.ONE * 0.001))] = true
		var deck: bool = points.all(func(p: Vector3) -> bool: return absf(p.x) <= 0.55 and p.z > -2.5 and p.z < -0.3 and p.y > 0.4)
		print("  %s: %d cells, salvo %d every %.2f s, %d missiles; cell points in the ship frame %s" % [name, launcher.muzzles.size(), launcher.salvo_size, launcher.salvo_interval, launcher.rounds_left(), str(points.map(func(p: Vector3) -> String: return "(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z]))])
		ok = ok and launcher.cells == 4 and launcher.muzzles.size() == 4 and distinct.size() == 4 and deck and launcher.salvo_size == 4 and launcher.rounds_left() == 12
	# Production port: the E05 launcher is the production Destroyer's (destroyer_unit.tscn);
	# the E01–E04 / P01–P03 fixture base keeps the 2-cell single-launch deck they were
	# authored with (encounter_arena.tscn overrides it).
	var shared: Node = load("res://game/ships/destroyer_unit.tscn").instantiate()
	var shared_launcher: Node = shared.get_node("Weapons/DeckHardpoint/MissileCells")
	var production: bool = shared_launcher.cells == 4 and shared_launcher.cell_columns == 2 and shared_launcher.salvo_size == 4 and shared_launcher.ammunition_override == 12
	shared.free()
	var base: Node = load("res://game/tests/combat/fixtures/encounter_arena.tscn").instantiate()
	var base_launcher: Node = base.get_node("Ships/Destroyer/Weapons/DeckHardpoint/MissileCells")
	var fixture: bool = base_launcher.cells == 2 and base_launcher.salvo_size == 1 and base_launcher.ammunition_override < 0
	base.free()
	_check("E05: both Destroyers have four distinct cells on the fore deck (within the hull's 1.1 u width), 4-missile salvos and 12 missiles", ok)
	_check("the production Destroyer carries the E05 launcher; the E01–E04 fixture base keeps 2 cells, single launches, the configuration's 6 missiles", production and fixture)


## B2: one firing action = four launches from cells 1-4, 0.2 s apart; one salvo per cycle.
func _case_timing() -> void:
	print("\n=== L3 staggered salvo")
	await _load()
	_engage()
	await _until(func() -> bool: return _launches.size() >= 4, 300)
	await _ticks(30)
	var first := _launches.slice(0, 4)
	var gaps := []
	for i in range(1, first.size()):
		gaps.append(snappedf(first[i].time - first[i - 1].time, 0.0001))
	print("  launches: %s; gaps %s" % [str(first.map(func(l: Dictionary) -> String: return "cell %d at %.3f" % [l.cell + 1, l.time])), str(gaps)])
	var cells_ok := first.size() == 4 and first.map(func(l: Dictionary) -> int: return l.cell) == [0, 1, 2, 3]
	var gaps_ok := gaps.size() == 3 and gaps.all(func(g: float) -> bool: return absf(g - 0.2) <= DT * 0.5 + 0.0001)
	_check("one firing action: four launches, cells 1, 2, 3, 4 in order, each from its own cell, 0.2 s apart (one tick tolerance)", cells_ok and gaps_ok)
	var nodes: Array = scene.projectiles.ordnance.filter(func(n: Node3D) -> bool: return n.faction == 0)
	await _ticks(90)
	var spread := INF
	for a in nodes.size():
		for b in range(a + 1, nodes.size()):
			if is_instance_valid(nodes[a]) and is_instance_valid(nodes[b]):
				spread = minf(spread, nodes[a].global_position.distance_to(nodes[b].global_position))
	_check("four independent missiles in flight, 1.5 s after the salvo still apart (closest pair %.2f u, separate ids %s)" % [spread, str(first.map(func(l: Dictionary) -> int: return l.id))],
		nodes.size() == 4 and spread > 0.5 and first.map(func(l: Dictionary) -> int: return l.id).size() == 4)
	await _until(func() -> bool: return _launches.size() >= 5, 600)
	var second: float = _launches[4].time - _launches[0].time if _launches.size() >= 5 else -1.0
	_check("the next salvo starts only after the 4 s cooldown from the first launch, never overlapping (%.3f s later)" % second, second >= cells().config.cooldown - 0.0001 and second <= cells().config.cooldown + 0.1)


## B2: exact ammunition; no salvo without four missiles.
func _case_ammunition() -> void:
	print("\n=== L4 ammunition")
	await _load()
	_engage()
	await _until(func() -> bool: return _launches.size() >= 12, 60 * 20)
	await _ticks(60 * 6)
	var launcher := cells()
	_check("three full salvos use exactly the 12 missiles (%d launches, %d left, %d salvos)" % [_launches.size(), launcher.rounds_left(), launcher.salvos], _launches.size() == 12 and launcher.rounds_left() == 0 and launcher.salvos == 3)
	await _load()
	cells().ammo = 3
	_engage()
	await _ticks(60 * 6)
	_check("with 3 missiles left no salvo is authorized: '%s', no launch" % cells().reason, _launches.is_empty() and cells().reason.begins_with("Salvo needs 4 missiles") and cells().rounds_left() == 3)


## B2: the target destroyed during the salvo cancels the remaining launches.
func _case_destroyed() -> void:
	print("\n=== L5 target destroyed during a salvo")
	await _load()
	_engage()
	await _until(func() -> bool: return _launches.size() >= 1, 300)
	CombatShip.of(scene.ship("HostileGunship")).destroy()
	await _ticks(60)
	_check("destroyed after the first launch: the other three cancelled (%d launched, %d missiles left, reason '%s'), no launch at another ship" % [_launches.size(), cells().rounds_left(), cells().salvo_cancel_reason],
		_launches.size() == 1 and cells().rounds_left() == 11 and cells().salvos_cancelled == 1 and cells().salvo_left == 0)


## B2: live contact lost during the salvo stops new launches; launched missiles go on.
func _case_contact_lost() -> void:
	print("\n=== L6 contact lost during a salvo")
	await _load()
	_engage()
	await _until(func() -> bool: return _launches.size() >= 2, 300)
	scene.contacts.set_contact(0, scene.ship("HostileGunship"), false)
	await _ticks(60)
	var live: int = scene.projectiles.ordnance.filter(func(n: Node3D) -> bool: return n.faction == 0).size()
	_check("contact lost after two launches: no further launch (%d launched, %d left, '%s'); the two missiles still fly (%d)" % [_launches.size(), cells().rounds_left(), cells().salvo_cancel_reason, live],
		_launches.size() == 2 and cells().rounds_left() == 10 and live == 2)


## B2: a pause freezes the sequence; nothing is lost or launched twice.
func _case_pause() -> void:
	print("\n=== L7 pause during a salvo")
	await _load()
	_engage()
	await _until(func() -> bool: return _launches.size() >= 1, 300)
	var left: int = cells().salvo_left
	var next: float = cells().salvo_next
	scene.time_control.set_paused(true)
	for i in 180:
		await process_frame
	var frozen: bool = _launches.size() == 1 and cells().salvo_left == left and cells().salvo_next == next
	scene.time_control.set_paused(false)
	await _ticks(60)
	var gaps := []
	for i in range(1, _launches.size()):
		gaps.append(snappedf(_launches[i].time - _launches[i - 1].time, 0.0001))
	_check("paused 180 frames after launch 1: nothing launched, the schedule unchanged; resumed: exactly three more, 0.2 s of simulation time apart %s" % str(gaps),
		frozen and _launches.size() == 4 and gaps.all(func(g: float) -> bool: return absf(g - 0.2) <= DT * 0.5 + 0.0001) and cells().rounds_left() == 8)


## B2: at 2x the interval is 0.2 s of simulation time (half the real ticks).
func _case_fast() -> void:
	print("\n=== L8 salvo at 2x")
	await _load()
	scene.time_control.step_speed(1)
	var frames := []
	cells().shot.connect(func(_w: Node, _id: int, _t: Node3D, _o: Transform3D) -> void: frames.append(Engine.get_physics_frames()))
	_engage()
	await _until(func() -> bool: return _launches.size() >= 4, 300)
	scene.time_control.step_speed(-1)
	var gaps := []
	var tick_gaps := []
	for i in range(1, 4):
		gaps.append(snappedf(_launches[i].time - _launches[i - 1].time, 0.0001))
		tick_gaps.append(frames[i] - frames[i - 1])
	_check("2x: four launches 0.2 s of simulation time apart %s (%s real ticks)" % [str(gaps), str(tick_gaps)],
		gaps.all(func(g: float) -> bool: return absf(g - 0.2) <= 2.0 * DT * 0.5 + 0.0001) and tick_gaps.all(func(t: int) -> bool: return t == 6))


## B2: a reset during a salvo leaves no pending launch, ordnance or orphan nodes.
func _case_reset() -> void:
	print("\n=== L9 reset during a salvo")
	_free()
	var lab: Node = LAB.instantiate()
	lab.encounter_index = 4
	root.add_child(lab)
	await _ticks(5)
	var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var launched_old := 0
	for attempt in 2:
		var arena: Node = lab.arena
		while not arena.enemy_controller.started:
			await physics_frame
		var d: Node3D = arena.ship("Destroyer")
		var h: Node3D = arena.ship("HostileGunship")
		d.get_node("Locomotion").place(Vector2(-60, 110), EAST)
		h.get_node("Locomotion").place(Vector2(0, 110), WEST)
		await physics_frame
		arena.sensors.evaluate()
		var launcher: Node = d.get_node("Weapons/DeckHardpoint/MissileCells")
		for w in CombatShip.of(d).weapons:
			if w != launcher:
				w.enabled = false
		CombatShip.of(d).stance = CombatShip.Stance.AGGRESSIVE
		arena.orders.assign_target([d], h)
		await _until(func() -> bool: return launcher.salvo_left > 0, 300)
		launched_old = launcher.salvo_launched
		arena._combat_key(KEY_F5)
		await _ticks(3)
	var fresh: Node = lab.arena
	var launcher: Node = fresh.ship("Destroyer").get_node("Weapons/DeckHardpoint/MissileCells")
	await _ticks(30)
	var orphans := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - orphans_before
	_check("F5 twice mid-salvo (%d of 4 launched): the new encounter has no salvo pending, no ordnance, 12 missiles, %d new orphan nodes" % [launched_old, orphans],
		launcher.salvo_left == 0 and fresh.projectiles.ordnance.is_empty() and launcher.rounds_left() == 12 and orphans == 0)
	root.remove_child(lab)
	lab.free()


## B2: every missile of a salvo is a separate target for point defense.
func _case_interception() -> void:
	print("\n=== L10 point defense against a salvo")
	await _load()
	var escort: Node3D = scene.ship("HostileGunship")
	var defended: Node3D = scene.ship("HostileDestroyer")
	_place("HostileDestroyer", Vector2(10, 110), WEST)
	_place("HostileGunship", Vector2(4, 104), WEST)
	await physics_frame
	scene.sensors.evaluate()
	CombatShip.of(scene.ship("Destroyer")).stance = CombatShip.Stance.AGGRESSIVE
	scene.orders.assign_target([scene.ship("Destroyer")], defended)
	var gatlings := []
	for ship in [escort, defended]:
		for w in CombatShip.of(ship).weapons:
			if w.get("defense_shots") != null:
				gatlings.append(w)
	var engaged := {}
	var stock0 := gatlings.map(func(w: Node) -> int: return w.rounds_left())
	for i in 60 * 12:
		await physics_frame
		for w in gatlings:
			if w.defense_target != null and is_instance_valid(w.defense_target):
				engaged[w.defense_target.id] = true
	var outcomes := {}
	for record in scene.projectiles.ordnance_records:
		if record.kind == "missile":
			outcomes[record.outcome] = outcomes.get(record.outcome, 0) + 1
	var intercept_rounds: int = scene.projectiles.records.filter(func(r: Dictionary) -> bool: return r.outcome == "intercept").size()
	var shots := 0
	var ledger := true
	for i in gatlings.size():
		shots += gatlings[i].defense_shots + gatlings[i].offense_shots
		ledger = ledger and stock0[i] - gatlings[i].rounds_left() == gatlings[i].defense_shots + gatlings[i].offense_shots
	var reloads: int = gatlings.reduce(func(a: int, w: Node) -> int: return a + w.reloads, 0)
	print("  missiles %d: outcomes %s; Gatlings engaged %d different missiles, %d rounds, %d interception hits, %d magazine reloads" % [_launches.size(), str(outcomes), engaged.size(), shots, intercept_rounds, reloads])
	_check("point defense engaged several missiles of the salvo one after another (%d different missiles)" % engaged.size(), engaged.size() >= 2)
	_check("every missile intercepted was hit by a round of its own (%d intercepted, %d interception hits): no chain loss" % [outcomes.get("intercepted", 0), intercept_rounds],
		outcomes.get("intercepted", 0) <= intercept_rounds)
	_check("Gatling ammunition exact: rounds used = rounds fired for each mount (magazine reloads %d)" % reloads, ledger)
