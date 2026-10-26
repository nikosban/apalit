extends SceneTree
## Guided cruise missiles: production FF-01s/services with explicitly stepped simulation
## time. No guidance statistics or hull hitboxes are changed to manufacture outcomes.
## Run: Godot --headless --path . --fixed-fps 60 -s res://game/tests/combat/guided_missile_test.gd

const ARENA := preload("res://game/scenes/combat_test.tscn")
const UNIT := preload("res://game/ships/ff01_unit.tscn")
const WAYFARER := preload("res://game/weapons/gcm4_wayfarer.tres")
const WAYFARER_SCENE := preload("res://game/weapons/gcm4_wayfarer.tscn")
const GuidedConfig := preload("res://game/weapons/guided_missile_config.gd")
const GuidedLauncher := preload("res://game/weapons/guided_missile_launcher.gd")
const MISSILE := preload("res://game/weapons/missile.tres")
const TORPEDO := preload("res://game/weapons/torpedo.tres")
const KESTREL := preload("res://game/weapons/pdc20_kestrel.tres")
const GATLING := preload("res://game/weapons/gatling.tres")
const CANNON := preload("res://game/weapons/nc90_bastion.tres")
const ROCKET := preload("res://game/weapons/rl8_barrage.tres")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const DT := 1.0 / 60.0
const SITE := Vector2(-260, -260)
const PDCS := ["ForwardPortPDCHardpoint", "ForwardStarboardPDCHardpoint", "AftPortPDCHardpoint", "AftStarboardPDCHardpoint"]

var scene: Node3D
var attacker: Node3D
var victim: Node3D
var launcher: Node
var projectiles: Node
var _checks := 0
var _failures := 0
var _launches: Array[Dictionary] = []
var _max_turn := 0.0
var _max_dv := 0.0
var _max_speed := 0.0
var _limits_ok := true
var _avoid_ticks := 0
var _own_hull_clear := true


func _initialize() -> void:
	await process_frame
	_configuration()
	await _load()
	_installation()
	await _scheduling()
	await _commitment()
	await _reusability()
	await _guidance()
	await _flight()
	await _expiry()
	await _impacts()
	await _obstacles()
	await _overshoot()
	await _interception()
	await _throughput()
	scene.free()
	await process_frame
	_check("no orphan nodes after guided-missile verification", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(message: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [message, "PASS" if ok else "FAIL"])


func _configuration() -> void:
	var c := WAYFARER
	var o: Resource = c.ordnance
	_check("GCM-4 Wayfarer uses the resource-configured missile family", c is GuidedConfig and c.display_name == "GCM-4 Wayfarer" and c.family == &"missile")
	_check("4 cells, 4 missiles, 12 total, interval 0.2 s, cooldown 6 s", c.cells == 4 and c.cell_columns == 2 and c.salvo_size == 4 and c.ammunition == 12 and c.salvo_interval == 0.2 and c.cooldown == 6.0)
	_check("35 hull damage, explicit penetration 45, armor damage 2, launch range 90", c.damage == 35.0 and c.resolved_penetration() == 45.0 and c.armor_damage == 2.0 and c.weapon_range == 90.0)
	_check("missile: speed 32, acceleration 18, powered turning 40 deg/s, endurance 9 s", o.kind == &"missile" and o.max_speed == 32.0 and o.acceleration == 18.0 and o.turn_rate_deg == 40.0 and o.flight_time == 9.0)
	_check("approved provisional ejection, clearance and orientation values", o.eject_speed == 5.0 and o.clearance == 8.0 and o.transition_timeout == 1.5 and o.hull_margin == 0.5 and o.orient_rate_deg == 75.0 and o.powered_within_deg == 15.0)
	_check("approved provisional guidance, avoidance and secondary safety limits", o.steering_deadband_deg == 3.0 and o.arrival_distance == 2.0 and o.avoidance and o.avoid_lookahead == 1.4 and o.avoid_margin == 1.0 and o.lifetime == 30.0 and o.max_travel == 400.0)
	_check("approved provisional interception and presentation values", o.radius == 0.3 and o.length == 0.6 and o.body_radius == 0.06 and o.trail_time == 0.35 and o.thruster_scale == 0.25 and o.thruster_length == 1.0 and o.rcs_scale == 0.25)
	_check("legacy missile and torpedo resource values unchanged", MISSILE.damage == 30.0 and MISSILE.cooldown == 4.0 and MISSILE.ammunition == 6 and not MISSILE.has_penetration and MISSILE.ordnance.turn_rate_deg == 40.0 and TORPEDO.damage == 40.0 and TORPEDO.cooldown == 6.0 and TORPEDO.ammunition == 4 and not TORPEDO.has_penetration)


func _silence(node: Node) -> void:
	node.process_mode = Node.PROCESS_MODE_DISABLED
	for child: Node in node.get_children():
		_silence(child)


func _load() -> void:
	if scene != null:
		scene.free()
		await process_frame
	scene = ARENA.instantiate()
	scene.get_node("Asteroids").session_seed = 5005
	root.add_child(scene)
	_silence(scene)
	attacker = scene.get_node("Ships/FF01")
	var index := 0
	for ship: Node3D in scene.get_node("Ships").get_children():
		_place(ship, Vector2(1000 + 40 * index, 1000))
		index += 1
	victim = UNIT.instantiate()
	victim.name = "MissileTarget"
	victim.position.y = 1.5
	victim.get_node("Combat").faction = 1
	scene.get_node("Ships").add_child(victim)
	scene.register_ship(victim)
	_silence(victim)
	for ship: Node in scene.get_node("Ships").get_children():
		var c = CombatShip.of(ship)
		c.stance = CombatShip.Stance.HOLD_FIRE
		for weapon in c.weapons:
			weapon.enabled = false
	_place(attacker, SITE)
	_place(victim, SITE + Vector2(60, 0))
	launcher = attacker.get_node("Weapons/WayfarerHardpoint").weapon()
	projectiles = scene.get_node("Projectiles")
	_reset(launcher)
	scene.sensors.evaluate()
	var c = CombatShip.of(attacker)
	c.stance = CombatShip.Stance.AGGRESSIVE
	c.target = victim
	c.manual_target = victim
	_launches.clear()
	launcher.shot.connect(func(_w: Node, id: int, target: Node3D, origin: Transform3D) -> void:
		_launches.append({"id": id, "time": scene.get_node("SimClock").time, "target": target, "origin": origin, "cooldown": launcher.cooldown_left}))
	_max_turn = 0.0
	_max_dv = 0.0
	_max_speed = 0.0
	_limits_ok = true
	_avoid_ticks = 0
	_own_hull_clear = true


func _place(ship: Node3D, point: Vector2, heading := 0.0) -> void:
	ship.get_node("Locomotion").place(point, heading)
	ship.get_node("Avoidance").reset()


func _reset(w: Node) -> void:
	w.enabled = true
	w.ammo = w.config.ammunition
	w.cooldown_left = 0.0
	w.salvo_left = 0
	w.salvo_launched = 0
	w.salvos = 0
	w.salvos_cancelled = 0
	w.shots = 0


func _node(id: int) -> Node3D:
	for node in projectiles.ordnance:
		if node.id == id:
			return node
	return null


func _record(id: int) -> Dictionary:
	for record: Dictionary in projectiles.ordnance_records:
		if record.id == id:
			return record
	return {}


func _direct(config: Resource = WAYFARER, origin: Transform3D = Transform3D.IDENTITY) -> Node3D:
	if origin == Transform3D.IDENTITY:
		origin = launcher.muzzles[0].global_transform
	return _node(projectiles.launch(attacker, 0, origin, config, victim))


func _tick(delta := DT, launch := false, defend := false, move := false) -> void:
	scene.get_node("SimClock").time += delta
	if move:
		victim.get_node("Locomotion")._physics_process(delta)
	scene.sensors._physics_process(delta)
	if launch:
		launcher.step(delta)
	if defend:
		for mount: String in PDCS:
			victim.get_node("Weapons/" + mount).weapon().step(delta)
	var before := {}
	for node in projectiles.ordnance:
		if node.strict_flight_expiration:
			before[node.id] = {"phase": node.phase, "velocity": node.velocity, "position": node.global_position, "age": node.age}
	projectiles._physics_process(delta)
	for node in projectiles.ordnance:
		if not before.has(node.id):
			continue
		var was: Dictionary = before[node.id]
		var dt: float = node.age - was.age
		var turn: float = rad_to_deg(node.turn_last)
		_max_speed = maxf(_max_speed, node.speed())
		if was.phase == "powered":
			_max_turn = maxf(_max_turn, turn / maxf(dt, 0.000001))
			_max_dv = maxf(_max_dv, node.velocity.distance_to(was.velocity) / maxf(dt, 0.000001))
			_limits_ok = _limits_ok and turn <= 40.0 * dt + 0.005 and node.velocity.distance_to(was.velocity) <= 18.0 * dt + 0.0001
		elif was.phase == "eject":
			_limits_ok = _limits_ok and turn < 0.005 and node.velocity.distance_to(was.velocity) < 0.00001 and not node.thrusting
		elif was.phase == "orient":
			_limits_ok = _limits_ok and turn <= 75.0 * dt + 0.005 and node.velocity.distance_to(was.velocity) < 0.00001
		_limits_ok = _limits_ok and node.speed() <= 32.0001
		if node.avoiding:
			_avoid_ticks += 1
		if node.owner_ship == attacker:
			_own_hull_clear = _own_hull_clear and CombatShip.of(attacker).segment_fraction(was.position, node.global_position) < 0.0


func _installation() -> void:
	var c = CombatShip.of(attacker)
	var mount := attacker.get_node("Weapons/WayfarerHardpoint")
	var counts := {}
	for w in c.weapons:
		counts[w.config.display_name] = counts.get(w.config.display_name, 0) + 1
	_check("FF-01: two Bastions, four Kestrels, one Barrage, one Wayfarer; eight compatible weapons", counts == {"NC-90 Bastion": 2, "PDC-20 Kestrel": 4, "RL-8 Barrage": 1, "GCM-4 Wayfarer": 1} and c.incompatible.is_empty())
	_check("Wayfarer at (0, 0.55, 0), neutral housing orientation, one reusable scene at identity", mount.position.is_equal_approx(Vector3(0, 0.55, 0)) and mount.basis.is_equal_approx(Basis.IDENTITY) and launcher.scene_file_path == WAYFARER_SCENE.resource_path and launcher.transform.is_equal_approx(Transform3D.IDENTITY) and launcher.get_script() == GuidedLauncher)
	var distinct := {}
	var clear := true
	for muzzle: Node3D in launcher.muzzles:
		var local: Vector3 = attacker.global_transform.affine_inverse() * muzzle.global_position
		print("  cell %s: ship frame %s" % [muzzle.name, local])
		distinct[local] = true
		clear = clear and (-muzzle.global_basis.z).is_equal_approx(Vector3.UP)
		clear = clear and c.segment_fraction(muzzle.global_position, muzzle.global_position + Vector3.UP * 3.0) < 0.0
		# Include the entire missile's length, not just the collision centre.
		clear = clear and local.y - WAYFARER.ordnance.length * 0.5 > 0.55
	_check("four distinct vertical cells; every ejection trajectory and missile tail clears the FF-01 hull", launcher.muzzles.size() == 4 and distinct.size() == 4 and clear)
	_check("existing seven ships plus test target, 36 asteroids and Combat Test +/-380 preserved", scene.get_node("Ships").get_child_count() == 8 and scene.get_node("Asteroids").ids().size() == 36 and scene.get_node("StaticNavigation").map_half_size == 380.0)
	var bearings := true
	for direction: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		_place(victim, SITE + direction * 60)
		scene.sensors.evaluate()
		bearings = bearings and launcher.assess(victim).capable
	_place(victim, SITE + Vector2(92, 0))
	scene.sensors.evaluate()
	_check("all horizontal bearings authorized, no hull-facing request; out of 90 u range rejected", bearings and not launcher.fixed and not launcher.assess(victim).capable)


func _scheduling() -> void:
	for dt: float in [DT, 1.0 / 30.0, 1.0 / 120.0, 0.017, 0.07]:
		await _load()
		for i in ceili(7.0 / dt):
			scene.get_node("SimClock").time += dt
			launcher.step(dt)
		var ok := _launches.size() >= 5
		var first: float = _launches[0].time
		for i in 4:
			var elapsed: float = _launches[i].time - first
			ok = ok and elapsed >= i * 0.2 - 0.000000001 and elapsed < i * 0.2 + dt + 0.000000001
			if i < 3:
				ok = ok and _launches[i].cooldown == 0.0
		var gap: float = _launches[4].time - _launches[3].time
		ok = ok and _launches[3].cooldown == 6.0 and gap >= 6.0 - 0.000000001 and gap < 6.0 + dt + 0.000000001
		print("  dt %.6f, salvo span %.6f, final-to-next %.6f" % [dt, _launches[3].time - first, gap])
		_check("salvo launches on first eligible ticks; cooldown starts on final launch (dt %.6f)" % dt, ok)
	await _load()
	for i in 1500:
		launcher.step(DT)
	_check("three complete salvos consume exactly 12 missiles; no fourth salvo", _launches.size() == 12 and launcher.salvos == 3 and launcher.rounds_left() == 0)
	await _load()
	launcher.ammo = 3
	for i in 500:
		launcher.step(DT)
	_check("three missiles cannot initiate a partial salvo", _launches.is_empty() and launcher.rounds_left() == 3)


func _commitment() -> void:
	for change: String in ["contact", "stance", "target", "destroyed", "freed", "direction"]:
		await _load()
		launcher.step(DT)
		var identity := victim.get_instance_id()
		var remembered: Vector3 = launcher.salvo_last_known
		match change:
			"contact":
				scene.contacts.set_contact(0, victim, false)
				_place(victim, SITE + Vector2(70, 15))
			"stance": CombatShip.of(attacker).stance = CombatShip.Stance.HOLD_FIRE
			"target": CombatShip.of(attacker).target = scene.get_node("Ships/HostileGunship")
			"destroyed": CombatShip.of(victim).destroy()
			"freed":
				# Production removal clears ship-level references before freeing the node.
				CombatShip.of(attacker).forget(victim)
				victim.free()
			"direction": victim.get_node("Locomotion").move_to(SITE + Vector2(60, 50))
		for i in 40:
			if change == "direction":
				victim.get_node("Locomotion")._physics_process(DT)
			launcher.step(DT)
		if change in ["contact", "destroyed", "freed"]:
			_tick() # Existing missiles also tolerate loss/destruction/removal in flight.
		var nodes: Array = projectiles.ordnance
		var ok: bool = _launches.size() == 4 and launcher.ammo == 8 and nodes.all(func(n: Node3D) -> bool: return n.target_id == identity)
		if change in ["contact", "destroyed", "freed"]:
			ok = ok and nodes.all(func(n: Node3D) -> bool: return n.last_known.is_equal_approx(remembered) and n.has_goal)
		_check("committed salvo preserves original identity after %s change" % change, ok)
	await _load()
	launcher.step(DT)
	CombatShip.of(attacker).destroy()
	for i in 50:
		launcher.step(DT)
	_check("destroyed firing ship cancels unlaunched missiles; consumed round stays consumed", _launches.size() == 1 and launcher.rounds_left() == 11 and launcher.salvo_left == 0 and launcher.salvos_cancelled == 1)


func _reusability() -> void:
	await _load()
	var second := UNIT.instantiate()
	second.name = "VariantCarrier"
	second.position = Vector3(SITE.x, 1.5, SITE.y + 120)
	var alternate: Resource = WAYFARER.duplicate(true)
	alternate.cells = 2
	alternate.cell_columns = 1
	alternate.salvo_size = 2
	alternate.salvo_interval = 0.13
	alternate.ammunition = 8
	alternate.cooldown = 2.0
	alternate.damage = 17.0
	var w: Node = second.get_node("Weapons/WayfarerHardpoint").weapon()
	w.config = alternate
	scene.get_node("Ships").add_child(second)
	scene.register_ship(second)
	_silence(second)
	var c = CombatShip.of(second)
	c.stance = CombatShip.Stance.AGGRESSIVE
	_place(victim, SITE + Vector2(20, 70))
	scene.sensors.evaluate()
	c.target = victim
	for i in 12:
		w.step(DT)
	_check("second resource uses same launcher behavior: two cells, two launches, changed timing/ammo/damage", w.get_script() == launcher.get_script() and w.muzzles.size() == 2 and w.shots == 2 and w.rounds_left() == 6 and is_equal_approx(w.launch_times[1], 8.0 * DT) and projectiles.ordnance.all(func(n: Node3D) -> bool: return n.damage == 17.0))
	_check("launcher ammo/cooldown independent; original shared Wayfarer resource unchanged", launcher.ammo == 12 and launcher.cooldown_left == 0.0 and w.cooldown_left > 0.0 and WAYFARER.damage == 35.0 and WAYFARER.cells == 4 and WAYFARER.salvo_interval == 0.2)


func _guidance() -> void:
	await _load()
	var node := _direct()
	victim.get_node("Locomotion").move_to(SITE + Vector2(60, 60))
	for i in 45:
		_tick(DT, false, false, true)
	_check("active tracking updates observed position and uses target velocity for lead", node.has_contact and node.last_known.is_equal_approx(victim.global_position) and node.goal.distance_to(node.last_known) > 0.1)
	var known: Vector3 = node.last_known
	scene.contacts.set_contact(0, victim, false)
	_place(victim, SITE + Vector2(70, 20))
	for i in 15:
		_tick()
	_check("contact loss freezes last-known position; hidden live position/velocity do not alter goal", not node.has_contact and node.last_known.is_equal_approx(known) and node.goal.is_equal_approx(known))
	scene.contacts.set_contact(0, victim, true)
	scene.sensors.evaluate()
	_tick()
	_check("same-target reacquisition resumes active guidance", node.has_contact and node.target == victim and node.target_id == victim.get_instance_id() and node.last_known.is_equal_approx(victim.global_position))
	CombatShip.of(attacker).target = scene.get_node("Ships/HostileGunship")
	_tick()
	_check("changing the ship's selected target never retargets an in-flight missile", node.target == victim)
	scene.contacts.set_contact(0, victim, false)
	node.global_position = node.last_known
	node._update_contact()
	_check("reaching a last-known destination ends that goal without acquiring another ship", not node.has_goal and node.target == victim)


func _flight() -> void:
	await _load()
	launcher.step(DT)
	var distinct_flight := false
	for i in 540:
		_tick(DT, i < 40)
		if i == 45:
			var positions := {}
			for missile in projectiles.ordnance:
				positions[missile.global_position] = true
			distinct_flight = positions.size() == 4
	var done: Array = projectiles.ordnance_records
	var identities := {}
	var from_cells := _launches.size() == 4
	for i in _launches.size():
		identities[_launches[i].id] = true
		from_cells = from_cells and (_launches[i].origin as Transform3D).origin.is_equal_approx(launcher.muzzles[i].global_position)
	_check("all four cells launch independent missiles from their own muzzles; all finish", from_cells and done.size() == 4 and identities.size() == 4 and distinct_flight)
	_check("every traced ejection/orientation/powered tick respects physical limits and clears own hull", _limits_ok and _own_hull_clear)
	print("  flight max speed %.5f u/s, powered turn %.5f deg/s, acceleration %.5f u/s^2" % [_max_speed, _max_turn, _max_dv])
	_check("powered speed <=32, nose turn <=40 deg/s, velocity change <=18 u/s^2", _max_speed <= 32.0001 and _max_turn <= 40.3 and _max_dv <= 18.01)
	await _load()
	var node := _direct()
	var id: int = node.id
	scene.contacts.set_contact(0, victim, false)
	_place(victim, SITE + Vector2(100, 100))
	for i in 600:
		_tick(0.017)
	_check("non-divisible simulation step still expires at exactly nine seconds", _record(id).get("outcome") == "self_destruct" and _record(id).get("age") == 9.0)


func _expiry() -> void:
	for distance: float in [0.25, 0.5, 0.75]:
		await _load()
		_place(victim, Vector2.ZERO)
		scene.sensors.evaluate()
		# Probe the existing hull, including its side jet at z=0. Exact binary distances
		# and dt isolate the deadline without changing any physical geometry.
		var probe := Vector3(-10, 1.5, 0)
		var fraction: float = CombatShip.of(victim).segment_fraction(probe, Vector3(0, 1.5, 0))
		var face: float = probe.lerp(Vector3(0, 1.5, 0), fraction).x
		var origin := Transform3D(Basis.looking_at(Vector3.RIGHT), Vector3(face - distance, 1.5, 0))
		var node := _direct(WAYFARER, origin)
		node.phase = "powered"
		node.velocity = Vector3.RIGHT * 32.0
		node.age = 9.0 - 1.0 / 64.0
		var id: int = node.id
		_tick(1.0 / 32.0)
		var r := _record(id)
		var before := distance < 0.5
		_check("deadline: impact %s nine seconds (%s, age %.9f)" % ["before" if before else ("at" if distance == 0.5 else "after"), r.get("outcome", "live"), r.get("age", -1.0)], (r.get("outcome") == "damage" and r.age < 9.0) if before else (r.get("outcome") == "self_destruct" and r.age == 9.0))
		_check("deadline damage allowed only before expiration", CombatShip.of(victim).health == (139.0 if before else 160.0))
	await _load()
	_place(victim, Vector2.ZERO)
	var legacy := _direct(MISSILE, Transform3D(Basis.looking_at(Vector3.RIGHT), Vector3(-1.9, 1.5, 0)))
	legacy.phase = "powered"
	legacy.velocity = Vector3.RIGHT * 32
	legacy.age = 9.0 - 1.0 / 64.0
	var id: int = legacy.id
	_tick(1.0 / 32.0)
	_check("legacy missile keeps collision-before-expiration semantics", not legacy.strict_flight_expiration and _record(id).get("outcome") == "damage")


func _impacts() -> void:
	await _load()
	var node := _direct()
	var id: int = node.id
	victim.get_node("Locomotion").move_to(SITE + Vector2(60, 60))
	for i in 540:
		_tick(DT, false, false, true)
	_check("full vertical-launch missile physically strikes a moving FF-01", _record(id).get("outcome") == "damage" and victim.get_node("Locomotion").planar_position.distance_to(SITE + Vector2(60, 0)) > 1.0)
	_check("one impact applies damage exactly once: hull 139, armor 98", projectiles.damage_events.get(id) == 1 and CombatShip.of(victim).health == 139.0 and CombatShip.of(victim).armor == 98.0)
	# A second physical impact uses the pre-impact 98 armor, without resetting durability.
	var direction: Vector3 = Vector3.RIGHT
	var from: Vector3 = victim.global_position - direction * 4.0
	node = _direct(WAYFARER, Transform3D(Basis.looking_at(direction), from))
	node.phase = "powered"
	node.velocity = direction * 32.0
	id = node.id
	for i in 20:
		_tick()
	var expected := 139.0 - 35.0 * 45.0 / (45.0 + 30.0 * 0.98)
	_check("subsequent physical hit uses pre-impact armor condition", projectiles.damage_events.get(id) == 1 and absf(CombatShip.of(victim).health - expected) < 0.000001 and CombatShip.of(victim).armor == 96.0)


func _rock(point: Vector3, radius: float) -> void:
	var rock := MeshInstance3D.new()
	rock.name = "MissileTestRock"
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	rock.mesh = mesh
	rock.set_meta("asteroid_id", 999)
	var field: Node = scene.get_node("Asteroids")
	field.add_child(rock)
	rock.global_position = point
	# Register this test geometry in the production field's cached geometry, unchanged
	# in size/position between guidance and physical collision queries.
	field._nodes[999] = rock
	field._centers[999] = point
	field._radii[999] = radius


func _obstacles() -> void:
	await _load()
	_rock(Vector3(SITE.x + 30, 1.5, SITE.y), 9.0)
	# A same-faction observer beyond the rock provides legitimate shared contact.
	_place(scene.get_node("Ships/Gunship"), SITE + Vector2(60, 30))
	scene.sensors.evaluate()
	var node := _direct()
	var id: int = node.id
	for i in 540:
		_tick()
	print("  asteroid negotiation: %s; avoidance ticks %d" % [_record(id).get("outcome", "live"), _avoid_ticks])
	_check("missile negotiates an asteroid using existing bounded avoidance", _record(id).get("outcome") == "damage" and _avoid_ticks > 0 and _limits_ok)
	await _load()
	var origin := Transform3D(Basis.looking_at(Vector3.RIGHT), Vector3(SITE.x + 15, 1.5, SITE.y))
	_rock(origin.origin + Vector3.RIGHT * 2.5, 2.0)
	node = _direct(WAYFARER, origin)
	node.phase = "powered"
	node.velocity = Vector3.RIGHT * 32.0
	id = node.id
	for i in 10:
		_tick()
	_check("late obstacle cannot be avoided with finite steering; physical collision wins", _record(id).get("outcome") == "asteroid" and projectiles.damage_events.get(id, 0) == 0 and _limits_ok)
	await _load()
	var station := Node3D.new()
	station.name = "MissileTestStation"
	station.add_to_group("station")
	scene.get_node("Stations").add_child(station)
	var part := MeshInstance3D.new()
	part.mesh = BoxMesh.new()
	part.mesh.size = Vector3(2, 4, 4)
	part.add_to_group("static_obstacle")
	station.add_child(part)
	part.global_position = Vector3(SITE.x + 18, 1.5, SITE.y)
	node = _direct(WAYFARER, Transform3D(Basis.looking_at(Vector3.RIGHT), part.global_position - Vector3.RIGHT * 1.2))
	node.phase = "powered"
	node.velocity = Vector3.RIGHT * 32
	id = node.id
	_tick()
	_check("station geometry remains authoritative", _record(id).get("outcome") == "station")


func _overshoot() -> void:
	await _load()
	# A missed missile's nose has turned back while momentum still carries it away.
	# These are initial kinematic states, not changes to guidance values or hulls.
	_place(victim, SITE + Vector2(30, 0))
	scene.sensors.evaluate()
	var node := _direct(WAYFARER, Transform3D(Basis.looking_at(Vector3.LEFT), Vector3(SITE.x + 40, 1.5, SITE.y)))
	node.phase = "powered"
	node.velocity = Vector3.RIGHT * 12
	var id: int = node.id
	var farthest := 0.0
	for i in 540:
		if _node(id) != null:
			farthest = maxf(farthest, node.global_position.distance_to(victim.global_position))
		_tick()
	_check("overshoot recovery: momentum initially carries missile away, then it returns and hits", farthest > 12.0 and _record(id).get("outcome") == "damage" and _limits_ok)
	await _load()
	_place(victim, SITE + Vector2(30, 0))
	scene.sensors.evaluate()
	node = _direct(WAYFARER, Transform3D(Basis.looking_at(Vector3.RIGHT), Vector3(SITE.x + 40, 1.5, SITE.y)))
	node.phase = "powered"
	node.velocity = Vector3.RIGHT * 32
	node.age = 8.5
	id = node.id
	for i in 40:
		_tick()
	_check("insufficient turn/time prevents recovery: no forced reversal or hit", _record(id).get("outcome") == "self_destruct" and _record(id).age == 9.0 and _limits_ok)


func _interception() -> void:
	for round_config: Resource in [KESTREL, GATLING, CANNON]:
		await _load()
		var from := Vector3(SITE.x + 20, 1.5, SITE.y)
		var node := _direct(WAYFARER, Transform3D(Basis.looking_at(Vector3.RIGHT), from))
		node.phase = "powered"
		node.velocity = Vector3.RIGHT * 10
		var id: int = node.id
		projectiles.spawn(victim, 1, from + Vector3.RIGHT * 4, Vector3.LEFT * round_config.projectile_speed, round_config.damage, 30, 1, attacker, round_config.projectile_style, round_config.resolved_penetration(), round_config.armor_damage, round_config != CANNON)
		for i in 20:
			_tick()
		_check("one successful %s round destroys a Wayfarer" % round_config.display_name, _record(id).get("outcome") == "intercepted" and projectiles.damage_events.get(id, 0) == 0)
	await _load()
	var from := Vector3(SITE.x + 20, 1.5, SITE.y)
	var node := _direct(WAYFARER, Transform3D(Basis.looking_at(Vector3.RIGHT), from))
	node.phase = "powered"
	node.velocity = Vector3.RIGHT * 10
	var id: int = node.id
	projectiles.spawn(victim, 1, from + Vector3(4, 2, 0), Vector3.LEFT * 70, 0.2, 15, 0.2, attacker, &"tracer", 1, 0, true)
	for i in 20:
		_tick()
	_check("a missed interception leaves the missile operational", _node(id) != null and _node(id).live)
	await _load()
	node = _direct()
	id = node.id
	projectiles.spawn(victim, 1, node.global_position + Vector3.UP, Vector3.DOWN * 70, 0.2, 10, 1, attacker, &"tracer", 1, 0, true)
	_tick()
	_check("one-hit interception is available during vertical ejection", _record(id).get("outcome") == "intercepted" and _record(id).get("phase") == "eject")


func _throughput_run(kind: String, seed: int) -> Dictionary:
	await _load()
	_place(victim, SITE + Vector2(0, -60))
	var c = CombatShip.of(victim)
	for i in PDCS.size():
		var w: Node = victim.get_node("Weapons/" + PDCS[i]).weapon()
		w.enabled = true
		w.rng.seed = seed * 100 + i
	var moving := kind == "maneuvering"
	if moving:
		victim.get_node("Locomotion").move_to(SITE + Vector2(50, -60))
	if kind == "asteroid":
		_rock(Vector3(SITE.x, 1.5, SITE.y - 30), 9.0)
		_place(scene.get_node("Ships/Gunship"), SITE + Vector2(30, -60))
	scene.sensors.evaluate()
	var barrage: Node = attacker.get_node("Weapons/BarrageHardpoint").weapon()
	_reset(barrage)
	barrage.rng.seed = seed
	for i in 620:
		if kind == "combined" and barrage.shots < 8:
			barrage.step(DT)
		_tick(DT, launcher.shots < 4, true, moving)
	var result := {"missile_launches": _launches.size(), "intercepted": 0, "impacts": 0, "misses": 0, "obstacle_hits": 0, "avoidance_ticks": _avoid_ticks, "missile_ammo": launcher.rounds_left(), "rocket_launches": barrage.shots, "rocket_ammo": barrage.rounds_left(), "rocket_hits": 0, "rocket_intercepts": 0, "rocket_misses": 0, "pdc_rounds": 0}
	for r: Dictionary in projectiles.ordnance_records:
		if r.kind == "rocket":
			result.rocket_hits += int(r.outcome == "damage")
			result.rocket_intercepts += int(r.outcome == "intercepted")
			result.rocket_misses += int(r.outcome not in ["damage", "intercepted"])
			continue
		match r.outcome:
			"intercepted": result.intercepted += 1
			"damage": result.impacts += 1
			"asteroid": result.obstacle_hits += 1
			_: result.misses += 1
	for mount: String in PDCS:
		result.pdc_rounds += victim.get_node("Weapons/" + mount).weapon().shots
	result["hull"] = c.health
	return result


func _throughput() -> void:
	for kind: String in ["stationary", "maneuvering", "asteroid", "combined"]:
		for seed: int in [1, 2, 3]:
			var first: Dictionary = await _throughput_run(kind, seed)
			var again: Dictionary = await _throughput_run(kind, seed)
			print("  throughput %s seed %d: %s" % [kind, seed, first])
			_check("repeatable %s throughput seed %d; all four missiles accounted for, four ammo consumed" % [kind, seed], first == again and first.missile_launches == 4 and first.intercepted + first.impacts + first.misses + first.obstacle_hits == 4 and first.missile_ammo == 8 and (kind != "combined" or first.rocket_launches == 8))
