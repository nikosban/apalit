extends SceneTree
## Physical FF-01 launch profiles on the production Combat Test scene.
## --headless --path . --fixed-fps 60 -s res://game/tests/combat/launch_profiles_test.gd
## Omit --headless and append -- --visual for a repeating rendered inspection.

const ARENA := preload("res://game/scenes/combat_test.tscn")
const UNIT := preload("res://game/ships/ff01_unit.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const SITE := Vector2(-260, -260)
const DT := 1.0 / 60.0

var scene: Node3D
var attacker: Node3D
var victim: Node3D
var projectiles: Node
var barrage: Node
var wayfarer: Node
var releases: Array[Dictionary] = []
var checks := 0
var failures := 0
var physical := true
var release_momentum := true
var clearances := {"rocket": 0, "missile": 0}
var max_heights := {"rocket": 0.0, "missile": 0.0}
var visual := false


func _initialize() -> void:
	await process_frame
	visual = "--visual" in OS.get_cmdline_user_args()
	if visual:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(1600, 900))
		await _preview()
		return
	for side in [-1.0, 1.0]:
		await _load(45.0, side)
		await _run(9.0)
		_check("both weapons authorize broadside %+.0f without hull rotation" % side,
			barrage.shots == 8 and wayfarer.shots == 4 and absf(attacker.rotation.y) < 0.00001)
		_check("full profiles keep finite turns, clearance and physical position sweeps", physical and clearances.rocket == 8 and clearances.missile == 4)
		_check("Wayfarer flies higher than Barrage", max_heights.missile > max_heights.rocket + 4.0)
	await _motion()
	await _timeouts()
	await _range_measurements()
	await _load(55.0)
	await _run(6.0, false, false, true)
	var interceptions: Array = scene.projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.outcome == "intercepted")
	_check("production Kestrels physically intercept launched ordnance", not interceptions.is_empty())
	for kind: String in ["rocket", "missile"]:
		await _load(45.0)
		barrage.step(DT) if kind == "rocket" else wayfarer.step(DT)
		var node: Node3D = projectiles.ordnance[0]
		var id: int = node.id
		projectiles.spawn(victim, 1, node.global_position + Vector3.UP, Vector3.DOWN * 70.0, 0.2, 10.0, 1.0, attacker, &"tracer", 1.0, 0.0, true)
		projectiles._physics_process(DT)
		_check("%s is interceptable during clearance" % kind,
			projectiles.ordnance_records.any(func(r: Dictionary) -> bool: return r.id == id and r.outcome == "intercepted" and r.phase == "eject"))
	scene.free()
	await process_frame
	_check("no orphan nodes", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if failures == 0 else "FAIL", failures, checks])
	quit(1 if failures else 0)


func _check(message: String, passed: bool) -> void:
	checks += 1
	failures += int(not passed)
	print("%s %s" % [message, "PASS" if passed else "FAIL"])


func _quiet(node: Node) -> void:
	node.set_physics_process(false)
	for child: Node in node.get_children():
		_quiet(child)


func _place(ship: Node3D, at: Vector2) -> void:
	ship.get_node("Locomotion").place(at, 0.0)
	ship.get_node("Avoidance").reset()


func _load(distance: float, side := 1.0, seed_value := 1) -> void:
	if scene != null:
		scene.free()
		await process_frame
	scene = ARENA.instantiate()
	root.add_child(scene)
	_quiet(scene)
	attacker = scene.get_node("Ships/FF01")
	var index := 0
	for ship: Node3D in scene.get_node("Ships").get_children():
		_place(ship, Vector2(1000 + index * 40, 1000))
		var combat = CombatShip.of(ship)
		combat.stance = CombatShip.Stance.HOLD_FIRE
		for weapon in combat.weapons:
			weapon.enabled = false
		index += 1
	victim = UNIT.instantiate()
	victim.name = "ProfileTarget"
	victim.position.y = 1.5
	victim.get_node("Combat").faction = 1
	scene.get_node("Ships").add_child(victim)
	scene.register_ship(victim)
	_quiet(victim)
	for weapon in CombatShip.of(victim).weapons:
		weapon.enabled = false
	_place(attacker, SITE)
	_place(victim, SITE + Vector2(distance * side, 0))
	barrage = attacker.get_node("Weapons/BarrageHardpoint").weapon()
	wayfarer = attacker.get_node("Weapons/WayfarerHardpoint").weapon()
	for weapon in [barrage, wayfarer]:
		weapon.enabled = true
		weapon.rng.seed = seed_value
	var combat = CombatShip.of(attacker)
	combat.stance = CombatShip.Stance.AGGRESSIVE
	scene.sensors.evaluate()
	combat.assign_target(victim)
	combat.target = victim
	projectiles = scene.projectiles
	releases.clear()
	physical = true
	release_momentum = true
	clearances = {"rocket": 0, "missile": 0}
	max_heights = {"rocket": 0.0, "missile": 0.0}
	projectiles.ordnance_launched.connect(func(n: Node3D) -> void:
		var owner_velocity: Vector3 = CombatShip.of(attacker).velocity()
		release_momentum = release_momentum and n.inherited_velocity.is_equal_approx(owner_velocity) and n.velocity.is_equal_approx(Vector3.UP * n.config.eject_speed + owner_velocity)
		releases.append({"id": n.id, "kind": String(n.kind), "origin": n.launch_point, "momentum": n.inherited_velocity, "point": n.locked_point, "spread": n.dispersion, "time": scene.get_node("SimClock").time}))
	if visual:
		var rig := scene.get_node("CameraRig")
		rig.position = Vector3(SITE.x + distance * side * 0.35, 0, SITE.y)
		rig.rotation.y = 0.0
		rig.zoom_distance = 65.0
		rig._apply_zoom()
		var label := Label.new()
		label.name = "VisualInfo"
		label.position = Vector2(40, 100)
		label.text = "FF-01 profiles | %+.0f u broadside | Barrage 4 u / Wayfarer 8 u" % (distance * side)
		label.add_theme_font_size_override("font_size", 24)
		scene.add_child(label)


func _tick(move_owner := false, move_target := false, defend := false) -> void:
	scene.get_node("SimClock").time += DT
	if move_owner:
		attacker.get_node("Locomotion")._physics_process(DT)
	if move_target:
		victim.get_node("Locomotion")._physics_process(DT)
	scene.sensors._physics_process(DT)
	if barrage.shots < 8:
		barrage.step(DT)
	if wayfarer.shots < 4:
		wayfarer.step(DT)
	if defend:
		for mount in ["ForwardPortPDCHardpoint", "ForwardStarboardPDCHardpoint", "AftPortPDCHardpoint", "AftStarboardPDCHardpoint"]:
			var weapon: Node = victim.get_node("Weapons/" + mount).weapon()
			weapon.enabled = true
			weapon.step(DT)
	var before := {}
	for node in projectiles.ordnance:
		before[node.id] = {"phase": node.phase, "position": node.global_position, "velocity": node.velocity, "point": node.locked_point}
	projectiles._physics_process(DT)
	for node in projectiles.ordnance:
		var was: Dictionary = before[node.id]
		var kind := String(node.kind)
		max_heights[kind] = maxf(max_heights[kind], node.global_position.y - node.launch_point.y)
		physical = physical and node.prev_position == was.position and node.transition_elapsed <= node.config.transition_timeout + 0.000001
		physical = physical and CombatShip.of(attacker).segment_fraction(was.position, node.global_position) < 0.0
		if was.phase == "eject":
			physical = physical and node.turn_last < 0.00001
			if node.phase != "eject":
				clearances[kind] += 1
				physical = physical and was.position.y - node.launch_point.y >= node.config.clearance - 0.00001 and node.transition_elapsed == 0.0
		elif was.phase == "orient":
			physical = physical and node.turn_last <= deg_to_rad(node.config.orient_rate_deg) * DT + 0.00001
			if node.kind == &"rocket":
				physical = physical and node.velocity.angle_to(was.velocity) <= deg_to_rad(node.config.orient_rate_deg) * DT + 0.00001
				physical = physical and absf(node.velocity.length() - (was.velocity as Vector3).length()) < 0.0001
		if node.kind == &"rocket":
			physical = physical and not node.homing() and node.locked_point == was.point and node.traveled <= node.config.max_travel + 0.00001 and node.age <= 4.00001
			if was.phase == "flight":
				physical = physical and node.velocity.distance_to(was.velocity) <= node.config.acceleration * DT + 0.0001 and node.turn_last < 0.00001
				physical = physical and node.velocity.angle_to(was.velocity) < 0.0001
		else:
			physical = physical and node.age <= 9.00001


func _run(seconds: float, move_owner := false, move_target := false, defend := false) -> void:
	for tick in int(ceil(seconds / DT)):
		_tick(move_owner, move_target, defend)
		if visual:
			# Inspection runs at one quarter speed; simulation and physical path are identical.
			scene.get_node("VisualInfo").text = "FF-01 launch inspection (0.25 speed) | t=%.2f s | %s" % [tick * DT, scene.get_meta("visual_case", "")]
			for frame in 4:
				await physics_frame


func _motion() -> void:
	for mode in ["moving", "rotating", "steady target", "abrupt target"]:
		await _load(55.0)
		var locomotion := attacker.get_node("Locomotion")
		var initial_cells: Array[Vector3] = []
		for cell: Node3D in barrage.muzzles:
			initial_cells.append(cell.global_position)
		if mode == "moving":
			locomotion.move_to(SITE + Vector2(0, -80))
			for tick in 120:
				locomotion._physics_process(DT)
		elif mode == "rotating":
			locomotion.face(PI * 0.5)
		if mode in ["steady target", "abrupt target"]:
			victim.get_node("Locomotion").move_to(SITE + Vector2(45, -80))
		var captured := Vector3.ZERO
		var missile_corrected := false
		for tick in 540:
			_tick(mode in ["moving", "rotating"], mode in ["steady target", "abrupt target"])
			if tick == 0:
				captured = barrage.salvo_point
			if tick == 60 and mode == "abrupt target":
				victim.get_node("Locomotion").move_to(SITE + Vector2(100, 40))
			for n in projectiles.ordnance:
				if n.kind == &"missile" and n.has_contact and n.last_known.distance_to(captured) > 0.5:
					missile_corrected = true
		var rockets := releases.filter(func(r: Dictionary) -> bool: return r.kind == "rocket")
		var locked := rockets.size() == 8 and rockets.all(func(r: Dictionary) -> bool: return r.point == captured)
		var cadence := rockets.size() == 8
		for i in rockets.size():
			cadence = cadence and absf(rockets[i].time - rockets[0].time - i * 0.12) <= DT + 0.000001
		_check("%s: locked salvo, release momentum, cadence, bounded physical flight" % mode, locked and release_momentum and cadence and physical)
		if mode == "moving":
			_check("moving owner contributes nonzero world-space release velocity", releases.all(func(r: Dictionary) -> bool: return r.momentum.length() > 1.0))
		if mode in ["moving", "rotating"]:
			var changed := false
			var distinct := {}
			for i in rockets.size():
				changed = changed or rockets[i].origin.distance_to(initial_cells[i]) > 0.05
				distinct[rockets[i].origin] = true
			_check("%s: later rockets use changed, distinct world-space cell positions" % mode, changed and distinct.size() == 8)
		else:
			_check("%s: Wayfarer follows observed target movement" % mode, missile_corrected)
		if mode == "abrupt target":
			var hits: Array = projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.kind == "rocket" and r.outcome == "damage")
			_check("abrupt target movement can defeat committed Barrage", hits.size() < 8)


func _timeouts() -> void:
	await _load(45.0)
	barrage.enabled = false
	wayfarer.enabled = false
	for weapon in [barrage, wayfarer]:
		var from := Vector3(SITE.x, 50, SITE.y)
		_place(victim, SITE)
		scene.sensors.evaluate()
		var origin := Transform3D(Basis.looking_at(Vector3.UP, Vector3.FORWARD), from)
		var memory := {"locked_point": from + Vector3.DOWN * 100} if weapon == barrage else {}
		var id: int = projectiles.launch(attacker, 0, origin, weapon.config, victim, memory)
		var node: Node3D = projectiles.ordnance.back()
		while node.phase == "eject":
			projectiles._physics_process(DT)
		_check("%s: transition timer begins after full vertical clearance" % weapon.config.display_name, node.transition_elapsed == 0.0 and node.global_position.y - from.y >= weapon.config.ordnance.clearance)
		while node.phase == "orient":
			projectiles._physics_process(DT)
		_check("%s: timeout commits achieved heading without snapping" % weapon.config.display_name, absf(node.transition_elapsed - node.config.transition_timeout) < 0.000001 and node.forward().angle_to(Vector3.DOWN) > deg_to_rad(20) and node.turn_last <= deg_to_rad(node.config.orient_rate_deg) * DT + 0.00001)
		projectiles._finish_ordnance(node, "cleared", "", node.global_position, "")
		_check("timeout fixture uses a distinct projectile", id > 0)
	# Isolate the lifetime bound from the configured distance expiry. A step crossing
	# the deadline may advance only the remaining lifetime, with the same collision sweep.
	var from := Vector3(SITE.x, 50, SITE.y)
	var id: int = projectiles.launch(attacker, 0, Transform3D(Basis.looking_at(Vector3.RIGHT), from), barrage.config, null)
	var rocket: Node3D = projectiles.ordnance.back()
	rocket.phase = "flight"
	rocket.velocity = Vector3.RIGHT * 30.0
	rocket.age = 3.99
	projectiles._physics_process(0.017)
	var record: Dictionary = projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.id == id)[0]
	_check("Barrage lifetime clips a non-divisible step at four seconds", record.outcome == "expired" and record.age == 4.0 and absf(record.traveled - 0.3) < 0.00001)


func _range_measurements() -> void:
	# 50/55 u bound the remaining useful band between the requested range samples.
	for distance in [25.0, 45.0, 50.0, 55.0, 60.0]:
		for side in [-1.0, 1.0]:
			await _load(distance, side)
			await _run(9.1)
			for kind: String in ["rocket", "missile"]:
				var records: Array = projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.kind == kind)
				var hits: Array = records.filter(func(r: Dictionary) -> bool: return r.outcome == "damage")
				var times := hits.map(func(r: Dictionary) -> float: return r.age)
				var travel := records.map(func(r: Dictionary) -> float: return r.traveled)
				var ages := records.map(func(r: Dictionary) -> float: return r.age)
				print("RANGE %s %+.0f u: %d/%d hits; hit ages %s; end ages %s; total paths %s; peak +%.3f u" % [kind, distance * side, hits.size(), records.size(), times, ages, travel, max_heights[kind]])
				var expected := 8 if kind == "rocket" else 4
				if kind == "rocket" and distance == 60.0:
					# Mount is 6.28 u ahead of the ship center: a target at 60 u broadside
					# lies outside the unchanged 60 u muzzle-to-target authorization range.
					expected = 0
					print("  Barrage authorization: %s; ammunition %d" % [barrage.reason, barrage.rounds_left()])
				_check("range measurement accounts for every %s at %+.0f u" % [kind, distance * side], records.size() == expected and physical)
	# Also sample exactly 60 u from the fire-control muzzle, removing the center/mount
	# offset ambiguity: authorization permits it, but launch travel still consumes reach.
	await _load(60.0)
	_place(victim, Vector2(barrage.muzzle.global_position.x + 60.0, barrage.muzzle.global_position.z))
	scene.sensors.evaluate()
	await _run(9.1)
	var records: Array = projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.kind == "rocket")
	var hits: Array = records.filter(func(r: Dictionary) -> bool: return r.outcome == "damage")
	print("RANGE rocket 60 u from muzzle: %d launched, %d hits; %.0f u total travel allowance" % [barrage.shots, hits.size(), barrage.config.ordnance.max_travel])
	_check("exact muzzle-range probe accounts for every rocket within physical limits", barrage.shots == 8 and records.size() == 8 and physical)


func _preview() -> void:
	while true:
		for side in [-1.0, 1.0]:
			await _load(45.0, side)
			scene.set_meta("visual_case", "%+.0f u, stationary" % (45 * side))
			await _run(10.0)
			await _load(45.0, side)
			scene.set_meta("visual_case", "%+.0f u, moving launcher / target" % (45 * side))
			attacker.get_node("Locomotion").move_to(SITE + Vector2(0, -80))
			victim.get_node("Locomotion").move_to(SITE + Vector2(45 * side, -40))
			await _run(10.0, true, true)
			await _load(45.0, side)
			scene.set_meta("visual_case", "%+.0f u, rotating launcher" % (45 * side))
			attacker.get_node("Locomotion").face(PI * 0.5)
			await _run(10.0, true)
