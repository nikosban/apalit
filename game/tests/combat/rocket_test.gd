extends SceneTree
## Rocket family: RL-8 Barrage configuration and reusability, salvo scheduling at several
## simulation steps, complete-salvo ammunition, the locked world-space direction and
## per-rocket dispersion, unguided flight, physical collisions and expiry, own-hull clearance,
## damage through the shared armor pipeline, physical interception (PDC and legacy Gatling
## rounds; cannon shells pass through rockets), the missile-rule threat order, the FF-01
## installation and a salvo-versus-Kestrels measurement (observation, no pass threshold).
## Run: <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/rocket_test.gd

const ARENA := preload("res://game/scenes/combat_test.tscn")
const UNIT := preload("res://game/ships/ff01_unit.tscn")
const RL8 := preload("res://game/weapons/rl8_barrage.tres")
const RL8_SCENE := preload("res://game/weapons/rl8_barrage.tscn")
const KESTREL := preload("res://game/weapons/pdc20_kestrel.tres")
const KESTREL_SCENE := preload("res://game/weapons/pdc20_kestrel.tscn")
const NC90 := preload("res://game/weapons/nc90_bastion.tres")
const NC90_SCENE := preload("res://game/weapons/nc90_bastion.tscn")
const GATLING := preload("res://game/weapons/gatling.tres")
const CANNON := preload("res://game/weapons/cannon.tres")
const TORPEDO := preload("res://game/weapons/torpedo.tres")
const MISSILE := preload("res://game/weapons/missile.tres")
const OrdnanceConfig := preload("res://game/weapons/ordnance_config.gd")
const RocketLauncher := preload("res://game/weapons/rocket_launcher.gd")
const Weapon := preload("res://game/weapons/weapon.gd")
const Gatling := preload("res://game/weapons/gatling.gd")
const PDC := preload("res://game/weapons/pdc.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const KESTRELS := ["ForwardPortPDCHardpoint", "ForwardStarboardPDCHardpoint", "AftPortPDCHardpoint", "AftStarboardPDCHardpoint"]
const BASTIONS := ["ForwardBastionHardpoint", "AftBastionHardpoint"]
const COMBAT_TEST_SHIPS := ["Gunship", "Destroyer", "Gunship2", "HostileDestroyer", "HostileGunship", "HostileGunship2", "FF01"]
const SITE_CLEARANCE := 85.0
const HOSTILE := 1
const TICK := 1.0 / 60.0
const EPS := 0.000001
const ANGLE_EPS := 0.002 # deg, float32 direction tolerance
const BOW_FRONT := -6.0 # FF-01 bow hit box front face (ship frame z)

var scene: Node3D
var ff01: Node3D
var projectiles: Node
var hostile: Node3D # Owner of hostile test ordnance (HostileDestroyer).
var victim: Node3D # A hostile FF-01 (target and damage subject).
var barrage: Node
var site := Vector2.ZERO
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	_configuration()
	await _load()
	_installation()
	_scheduling()
	_ammunition()
	await _commitment()
	await _reusability()
	await _flight()
	await _collisions()
	await _damage()
	await _interception()
	await _selection()
	await _measurement()
	scene.free()
	await process_frame
	_check("no orphan nodes after the Rocket verification", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(message: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-116s %s" % [message, "PASS" if ok else "FAIL"])


static func _angle(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.angle_to(b))


# --- C: configuration ---------------------------------------------------------------

func _configuration() -> void:
	print("\n=== C RL-8 Barrage configuration")
	var c := RL8
	var o: Resource = c.ordnance
	_check("rl8_barrage.tres loads: RL-8 Barrage, family rocket, medium",
		c != null and c.display_name == "RL-8 Barrage" and c.family == &"rocket" and c.size == 1)
	_check("hull damage 4, penetration 8 (explicitly configured), armor damage 1",
		c.damage == 4.0 and c.has_penetration and c.penetration == 8.0 and c.resolved_penetration() == 8.0 and c.armor_damage == 1.0)
	_check("48 rockets, no magazine, 5 s cooldown after the salvo, authorized range 60 u, unused alignment value 3 deg, dispersion 3 deg",
		c.ammunition == 48 and c.magazine_size == 0 and c.cooldown == 5.0 and c.weapon_range == 60.0
		and c.alignment_tolerance_deg == 3.0 and c.dispersion_max_deg == 3.0)
	_check("rocket ordnance: kind rocket, 30 u/s, 70 u travel, lifetime 4 s (includes launch), interception radius 0.3",
		o != null and o.get_script() == OrdnanceConfig and o.kind == &"rocket" and o.speed == 30.0 and o.max_travel == 70.0
		and o.lifetime == 4.0 and o.clearance == 4.0 and o.eject_speed == 8.0 and o.orient_rate_deg == 100.0 and o.transition_timeout == 1.5 and o.acceleration == 30.0 and o.radius == 0.3)
	_check("rocket model 0.6 u long, 0.06 u body diameter",
		o.length == 0.6 and is_equal_approx(o.body_radius * 2.0, 0.06))
	var node := RL8_SCENE.instantiate()
	_check("rl8_barrage.tscn: Rocket-family script, RL-8 configuration, 8 rockets per salvo every 0.12 s, 4 x 2 tubes 0.3 u apart",
		node.get_script() == RocketLauncher and node.config == RL8 and node.salvo_size == 8 and node.salvo_interval == 0.12
		and node.tube_columns == 4 and node.tube_rows == 2 and node.tube_spacing == 0.3 and node.tube_length > 0.0 and node.tube_radius > 0.0)
	node.free()
	_check("six complete salvos in the stock (48 / 8)", c.ammunition % 8 == 0 and c.ammunition / 8 == 6)
	_check("Kestrel, legacy Gatling, NC-90, torpedo and missile configurations unchanged",
		KESTREL.damage == 0.2 and KESTREL.penetration == 1.0 and KESTREL.cooldown == 0.08 and KESTREL.weapon_range == 25.0
		and GATLING.damage == 1.0 and GATLING.family == &"gatling" and NC90.damage == 12.0 and NC90.penetration == 20.0
		and NC90.weapon_range == 75.0 and TORPEDO.ordnance.kind == &"torpedo" and TORPEDO.ordnance.radius == 0.4
		and MISSILE.ordnance.kind == &"missile" and MISSILE.ordnance.radius == 0.3)


# --- Arena --------------------------------------------------------------------------

func _load() -> void:
	scene = ARENA.instantiate()
	root.add_child(scene)
	scene.get_node("HostileCommander").set_physics_process(false)
	for ship in scene.get_node("Ships").get_children():
		ship.get_node("Combat").stance = CombatShip.Stance.HOLD_FIRE
		ship.get_node("Combat").set_physics_process(false)
		ship.get_node("Behavior").set_physics_process(false)
	ff01 = scene.get_node("Ships/FF01")
	projectiles = scene.projectiles
	hostile = scene.get_node("Ships/HostileDestroyer")
	barrage = ff01.get_node("Weapons/BarrageHardpoint").weapon()
	for i in 3:
		await physics_frame
	site = _clear_site()
	_place(ff01, site)
	_park_others()
	victim = UNIT.instantiate()
	victim.name = "HostileFF01"
	victim.get_node("Combat").faction = HOSTILE
	victim.position.y = ff01.global_position.y # The scene's ship plane (Locomotion keeps Y).
	scene.get_node("Ships").add_child(victim)
	scene.register_ship(victim)
	victim.get_node("Combat").set_physics_process(false)
	victim.get_node("Behavior").set_physics_process(false)
	_place(victim, site + Vector2(0, 150))
	await physics_frame
	_check("test site (%.0f, %.0f) clear of asteroids for %.0f u; FF-01 there, bow -Z" % [site.x, site.y, SITE_CLEARANCE],
		Vector2(ff01.global_position.x, ff01.global_position.z).distance_to(site) < 0.01 and ff01.global_basis.z.is_equal_approx(Vector3.BACK))


func _clear_site() -> Vector2:
	var asteroids: Node = scene.get_node("Asteroids")
	for x in range(-300, 301, 10):
		for z in range(-300, 301, 10):
			var point := Vector2(x, z)
			var gap := INF
			for id: int in asteroids.ids():
				var c: Vector3 = asteroids.center(id)
				gap = minf(gap, Vector2(c.x, c.z).distance_to(point) - asteroids.radius(id))
			if gap >= SITE_CLEARANCE:
				return point
	return Vector2(-300, 300)


func _park_others() -> void:
	var i := 0
	for ship: Node3D in scene.get_node("Ships").get_children():
		if ship == ff01:
			continue
		var away := site + Vector2(-1.0 if site.x > 0.0 else 1.0, 0.0) * (200.0 + 30.0 * i)
		_place(ship, Vector2(away.x, clampf(away.y, -300.0, 300.0)))
		i += 1


func _place(ship: Node3D, at: Vector2, heading := 0.0) -> void:
	ship.get_node("Locomotion").place(at, heading)
	ship.get_node("Avoidance").reset()


func _home() -> void:
	ff01.get_node("RouteFollower").clear()
	_place(ff01, site)


# Site point ahead (−Z) / starboard (+X) of FF-01 at heading 0, in the X/Z plane.
func _ahead(distance: float, lateral := 0.0) -> Vector2:
	return site + Vector2(lateral, -distance)


func _ordnance(id: int) -> Node3D:
	for node in projectiles.ordnance:
		if node.id == id:
			return node
	return null


func _ordnance_record(id: int) -> Dictionary:
	for r: Dictionary in projectiles.ordnance_records:
		if r.id == id:
			return r
	return {}


func _round_record(id: int) -> Dictionary:
	for r: Dictionary in projectiles.records:
		if r.id == id:
			return r
	return {}


func _clear_flight() -> void:
	for node in projectiles.ordnance.duplicate():
		projectiles._finish_ordnance(node, "cleared", "", node.global_position, "")
	for record: Dictionary in projectiles.active.duplicate():
		projectiles._finish(record, "cleared", "", record.position)


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _reset_launcher(w: Node, seed: int, rounds := -1) -> void:
	w.enabled = true
	w.ammo = w.config.ammunition if rounds < 0 else rounds
	w.magazine = 0
	w.cooldown_left = 0.0
	w.salvo_left = 0
	w.salvo_launched = 0
	w.salvo_target = null
	w.salvos = 0
	w.salvos_cancelled = 0
	w.shots = 0
	w.launch_times.clear()
	w.rng.seed = seed


func _reset_victim() -> void:
	var c = CombatShip.of(victim)
	c.health = c.max_health
	c.armor = c.max_armor


# FF-01 targets the hostile FF-01 placed at `at` (Aggressive, in contact). FF-01's Combat is
# not stepped: the launcher is stepped by hand.
func _arm(at: Vector2, heading := 0.0) -> void:
	_place(victim, at, heading)
	var combat = CombatShip.of(ff01)
	combat.stance = CombatShip.Stance.AGGRESSIVE
	scene.sensors.evaluate()
	combat.assign_target(victim)
	combat.target = victim


func _disarm() -> void:
	var combat = CombatShip.of(ff01)
	combat.clear_target()
	combat.target = null
	combat.stance = CombatShip.Stance.HOLD_FIRE
	_place(victim, site + Vector2(0, 150))


# Steps `w` by hand `steps` times at `delta`; returns the clock time of every launch.
func _run(w: Node, delta: float, steps: int) -> Array:
	var times := []
	var clock := {"t": 0.0}
	var on_shot := func(_w: Node, _id: int, _t: Node3D, _o: Transform3D) -> void: times.append(clock.t)
	w.shot.connect(on_shot)
	for i in steps:
		clock.t = i * delta
		w.step(delta)
	w.shot.disconnect(on_shot)
	return times


# --- E: installation ---------------------------------------------------------------

func _mounted(mount: String, config: Resource) -> bool:
	var weapon: Node = ff01.get_node("Weapons/%s" % mount).weapon()
	return weapon != null and weapon.config == config


func _installation() -> void:
	print("\n=== E FF-01 installation")
	var combat = CombatShip.of(ff01)
	var mount := ff01.get_node("Weapons/BarrageHardpoint")
	_check("Barrage hardpoint unchanged in place: (0, 0, -5.85), neutral yaw 0, fixed (yaw 0, pitch 0..0), medium, accepts rocket",
		mount.position.is_equal_approx(Vector3(0, 0, -5.85)) and mount.basis.is_equal_approx(Basis.IDENTITY) and mount.yaw_limit_deg == 0.0
		and mount.pitch_min_deg == 0.0 and mount.pitch_max_deg == 0.0 and mount.size == 1 and mount.families == PackedStringArray(["rocket"]))
	_check("one RL-8 Barrage installed at identity, accepted, stepped by Combat, enabled",
		barrage != null and mount.get_child_count() == 1 and barrage.scene_file_path == RL8_SCENE.resource_path and barrage.config == RL8
		and barrage.transform.is_equal_approx(Transform3D.IDENTITY) and mount.accepts(RL8) and combat.weapons.has(barrage) and barrage.enabled)
	_check("not a fixed-axis weapon for Combat (no automatic hull facing)", barrage.fixed == false)
	_check("existing tube-axis marker stays along mount -Z (release profile is vertical)", barrage.forward().is_equal_approx(-ff01.global_basis.z))
	var bastions := BASTIONS.all(func(n: String) -> bool: return _mounted(n, NC90))
	var kestrels := KESTRELS.all(func(n: String) -> bool: return _mounted(n, KESTREL))
	var wayfarer := ff01.get_node("Weapons/WayfarerHardpoint")
	_check("FF-01: two Bastions, four Kestrels, one Barrage, one Wayfarer; Combat steps eight weapons, none incompatible",
		bastions and kestrels and wayfarer.get_child_count() == 1 and wayfarer.weapon().config.display_name == "GCM-4 Wayfarer"
		and combat.weapons.size() == 8 and combat.incompatible.is_empty())
	# Tubes: eight distinct mouths beyond the bow hit box, every trajectory in the cone clear of the own hull.
	var to_ship: Transform3D = ff01.global_transform.affine_inverse()
	var local := []
	var distinct := {}
	for m: Node3D in barrage.muzzles:
		var p: Vector3 = to_ship * m.global_position
		local.append(p)
		distinct[p.snapped(Vector3.ONE * 0.001)] = true
		print("  muzzle %s: ship frame (%.3f, %.3f, %.3f)" % [m.name, p.x, p.y, p.z])
	_check("eight tubes with distinct muzzle positions, 4 x 2 at 0.3 u spacing", barrage.muzzles.size() == 8 and distinct.size() == 8)
	var outside := true
	for p: Vector3 in local:
		outside = outside and p.z < BOW_FRONT
		for box: AABB in combat.hitboxes:
			outside = outside and not box.has_point(p)
	_check("every muzzle lies outside every FF-01 hit box, forward of the bow box front (z %.2f)" % BOW_FRONT, outside)
	var clear := true
	var axis: Vector3 = barrage.forward()
	var u := axis.cross(Vector3.UP).normalized()
	var v := axis.cross(u)
	for m: Node3D in barrage.muzzles:
		for k in 8:
			var phi := TAU * k / 8.0
			var dir := (axis * cos(deg_to_rad(3.0)) + (u * cos(phi) + v * sin(phi)) * sin(deg_to_rad(3.0))).normalized()
			clear = clear and combat.segment_fraction(m.global_position, m.global_position + dir * 60.0) < 0.0
		clear = clear and combat.segment_fraction(m.global_position, m.global_position + axis * 60.0) < 0.0
	_check("legacy tube-axis geometry rays still clear FF-01 (physical dorsal clearance tested separately)", clear)
	_check("the fire-control reference (aim muzzle) also lies ahead of the bow box", (to_ship * barrage.muzzle.global_position).z < BOW_FRONT)


# --- S: scheduling ------------------------------------------------------------------

func _scheduling() -> void:
	print("\n=== S salvo scheduling (launcher stepped by hand; the rockets are not flown here)")
	_home()
	_arm(_ahead(40.0))
	for delta: float in [1.0 / 120.0, TICK, 1.0 / 30.0, 0.05]:
		_reset_launcher(barrage, 11)
		var steps := int(ceil(11.0 / delta))
		var times := _run(barrage, delta, steps)
		var first: Array = times.slice(0, 8)
		var on_time := first.size() == 8
		for j in first.size():
			var late: float = first[j] - first[0] - j * barrage.salvo_interval
			on_time = on_time and late >= -EPS and late < delta + EPS
		var span: float = first[7] - first[0] if first.size() == 8 else -1.0
		var gap: float = times[8] - times[7] if times.size() > 8 else -1.0
		print("  step %.4f s: launches %s; first-to-last %.4f s; final launch to next salvo %.4f s" % [delta,
			str(first.map(func(t: float) -> String: return "%.3f" % (t - first[0]))), span, gap])
		_check("step %.4f s: 8 launches, each on the first tick on or after k x 0.12 s; first-to-last %.3f s (0.84 within one tick)" % [delta, span],
			on_time and absf(span - 0.84) < delta + EPS)
		_check("step %.4f s: the next salvo begins %.4f s after the eighth launch (5 s cooldown within one tick), 16 launches in 11 s" % [delta, gap],
			gap >= 5.0 - EPS and gap < 5.0 + delta + EPS and times.size() == 16 and barrage.rounds_left() == 32 and barrage.salvos == 2)
	_reset_launcher(barrage, 11)
	var times := _run(barrage, TICK, 1)
	var first_tick: bool = times.size() == 1 and barrage.salvo_left == 7 and barrage.cooldown_left == 0.0
	_run(barrage, TICK, 1)
	_check("first rocket launches in the authorizing tick, no cooldown yet; next tick reads the salvo under way (%s)" % barrage.reason,
		first_tick and barrage.reason.begins_with("Salvo under way (1 of 8"))
	times = _run(barrage, TICK, 60)
	_check("the cooldown starts with the eighth launch (%.3f s left after it)" % barrage.cooldown_left,
		times.size() == 7 and barrage.cooldown_left > 4.0 and barrage.cooldown_left <= 5.0)
	_clear_flight()
	_disarm()


func _ammunition() -> void:
	print("\n=== A complete salvos only")
	_home()
	_arm(_ahead(40.0))
	_reset_launcher(barrage, 12)
	var times := _run(barrage, TICK, int(60.0 / TICK))
	_check("six salvos consume all 48 rockets (%d launches, %d salvos, %d left); no seventh salvo" % [times.size(), barrage.salvos, barrage.rounds_left()],
		times.size() == 48 and barrage.salvos == 6 and barrage.rounds_left() == 0 and barrage.reason == "Out of ammunition"
		and barrage.offensive_reach() == 0.0)
	_clear_flight()
	_reset_launcher(barrage, 12, 15)
	times = _run(barrage, TICK, int(14.0 / TICK))
	_check("15 rockets: one salvo, then no partial salvo with 7 left (%d launches; %s)" % [times.size(), barrage.reason],
		times.size() == 8 and barrage.rounds_left() == 7 and barrage.reason == "Salvo needs 8 rockets (7 left)" and barrage.offensive_reach() == 0.0)
	_reset_launcher(barrage, 12, 7)
	times = _run(barrage, TICK, 30)
	var assessed: Dictionary = barrage.assess(victim)
	_check("7 rockets: no salvo begins (%d launches); assessment not capable (%s)" % [times.size(), assessed.reason],
		times.is_empty() and not assessed.capable)
	_reset_launcher(barrage, 12, 8)
	times = _run(barrage, TICK, 120)
	_check("exactly 8: one full salvo (%d launches, %d left)" % [times.size(), barrage.rounds_left()], times.size() == 8 and barrage.rounds_left() == 0)
	# Ammunition is used per launch, not at commitment.
	_reset_launcher(barrage, 12)
	_run(barrage, TICK, 1)
	var after_first: int = barrage.rounds_left()
	_run(barrage, TICK, 8)
	_check("ammunition is used as each rocket leaves: 47 after the first, %d after 9 ticks (two launched)" % barrage.rounds_left(),
		after_first == 47 and barrage.rounds_left() == 46)
	_clear_flight()
	_disarm()


# --- L: committed salvo, locked direction and dispersion ------------------------------

func _launched_ids(w: Node, steps: int, between: Callable = Callable()) -> Array:
	var ids := []
	var on_shot := func(_w: Node, id: int, _t: Node3D, _o: Transform3D) -> void: ids.append(id)
	w.shot.connect(on_shot)
	for i in steps:
		w.step(TICK)
		if between.is_valid():
			between.call(i)
	w.shot.disconnect(on_shot)
	return ids


func _commitment() -> void:
	print("\n=== L committed salvo, locked world-space direction, per-rocket dispersion")
	_home()
	_arm(_ahead(40.0))
	_reset_launcher(barrage, 21)
	var forward_at_start: Vector3 = barrage.forward()
	# The ship turns 40 deg and moves; the target moves sideways every tick.
	var moving := func(i: int) -> void:
		_place(ff01, site + Vector2(0.05 * i, 0.02 * i), deg_to_rad(40.0 * minf(1.0, i / 30.0)))
		_place(victim, _ahead(40.0, 0.3 * i))
	var ids := _launched_ids(barrage, 60, moving)
	var locked: Vector3 = barrage.salvo_direction
	var angles := []
	var dirs := {}
	for id: int in ids:
		var node := _ordnance(id)
		if node != null:
			angles.append(_angle(locked, node.dispersion * locked))
			dirs[(node.dispersion * locked).snapped(Vector3.ONE * 0.000001)] = true
	var max_angle: float = angles.max() if not angles.is_empty() else INF
	_check("8 rockets launched while the ship turned 40 deg and moved and the target moved", ids.size() == 8 and angles.size() == 8)
	_check("locked solution points ahead at salvo start (%.4f deg), not the current one (%.1f deg off now)" % [
		_angle(locked, forward_at_start), _angle(locked, barrage.forward())],
		_angle(locked, forward_at_start) < ANGLE_EPS and _angle(locked, barrage.forward()) > 30.0)
	_check("every fixed dispersion draw within 3 deg of the locked direction (max %.4f deg); eight independent directions (%d distinct)" % [max_angle, dirs.size()],
		max_angle <= 3.0 + ANGLE_EPS and dirs.size() == 8)
	_clear_flight()
	# Target changed and cleared, contact lost, stance changed, target destroyed: the salvo continues.
	_home()
	_arm(_ahead(40.0))
	_reset_launcher(barrage, 22)
	var combat = CombatShip.of(ff01)
	ids = _launched_ids(barrage, 1)
	combat.clear_target()
	combat.target = null
	combat.stance = CombatShip.Stance.HOLD_FIRE
	_place(victim, site + Vector2(0, 150))
	ids += _launched_ids(barrage, 60)
	_check("target cleared, stance Passive and target out of contact after rocket 1: all %d rockets launch along the locked direction" % ids.size(),
		ids.size() == 8 and ids.all(func(id: int) -> bool: return _ordnance(id) != null and _ordnance(id).locked_point == barrage.salvo_point))
	_clear_flight()
	var doomed: Node3D = UNIT.instantiate()
	doomed.name = "DoomedFF01"
	doomed.get_node("Combat").faction = HOSTILE
	doomed.position.y = ff01.global_position.y
	scene.get_node("Ships").add_child(doomed)
	scene.register_ship(doomed)
	doomed.get_node("Behavior").set_physics_process(false)
	_place(doomed, _ahead(45.0))
	_home()
	combat.stance = CombatShip.Stance.AGGRESSIVE
	scene.sensors.evaluate()
	combat.assign_target(doomed)
	combat.target = doomed
	_reset_launcher(barrage, 23)
	ids = _launched_ids(barrage, 2)
	CombatShip.of(doomed).destroy()
	ids += _launched_ids(barrage, 60)
	_check("target destroyed during the salvo: the remaining rockets still launch (%d of 8)" % ids.size(), ids.size() == 8)
	_clear_flight()
	await _frames(150) # The hulk's 2 s, then removal.
	_check("the destroyed target was removed", not is_instance_valid(doomed) or not doomed.is_inside_tree())
	# Owner destroyed: the launches left are cancelled (disable(), as Combat.destroy() calls it).
	_home()
	_arm(_ahead(40.0))
	_reset_launcher(barrage, 24)
	ids = _launched_ids(barrage, 9)
	barrage.disable()
	ids += _launched_ids(barrage, 60)
	_check("owner destroyed during the salvo: unlaunched rockets cancelled (%d launched, %d left in stock, %d cancelled)" % [ids.size(), barrage.rounds_left(), barrage.salvos_cancelled],
		ids.size() == 2 and barrage.salvo_left == 0 and barrage.salvos_cancelled == 1 and barrage.rounds_left() == 46)
	_clear_flight()
	# Deterministic seeds.
	var first := await _salvo_directions(31)
	var again := await _salvo_directions(31)
	var other := await _salvo_directions(32)
	_check("the same seed reproduces identical dispersion draws; another seed gives others", first.size() == 8 and first == again and first != other)
	# Many salvos: dispersion bound and independence.
	var worst := 0.0
	var all_distinct := true
	for seed in range(100, 130):
		var v := await _salvo_directions(seed)
		var seen := {}
		for d: Vector3 in v:
			worst = maxf(worst, _angle(Vector3.FORWARD, d))
			seen[d] = true
		all_distinct = all_distinct and seen.size() == 8
	_check("30 seeded salvos (240 rockets): dispersion never exceeds 3 deg (max %.4f deg); every salvo has eight different offsets" % worst,
		worst <= 3.0 + ANGLE_EPS and all_distinct)
	_disarm()


# Fixed dispersion directions of one salvo from the site, bow -Z, seeded.
func _salvo_directions(seed: int) -> Array:
	_home()
	_arm(_ahead(40.0))
	_reset_launcher(barrage, seed)
	var ids := _launched_ids(barrage, 60)
	var out := []
	for id: int in ids:
		out.append(_ordnance(id).dispersion * barrage.salvo_direction)
	_clear_flight()
	return out


# --- R: reusability -----------------------------------------------------------------

func _reusability() -> void:
	print("\n=== R the same family code with another configuration")
	var config: Resource = RL8.duplicate(true)
	config.display_name = "Test rocket pod"
	config.ammunition = 8
	config.cooldown = 1.0
	config.dispersion_max_deg = 1.0
	config.damage = 2.0
	config.penetration = 4.0
	config.ordnance.speed = 20.0
	config.ordnance.max_travel = 40.0
	config.ordnance.lifetime = 3.0 # Test variant: allow clearance, turning and the slower ramp.
	var pod: Node = RocketLauncher.new()
	pod.name = "TestPod"
	pod.config = config
	pod.salvo_size = 3
	pod.salvo_interval = 0.3
	pod.tube_columns = 3
	pod.tube_rows = 1
	pod.position = Vector3(0, 0, -6.2)
	ff01.get_node("Weapons").add_child(pod)
	_home()
	_arm(_ahead(30.0))
	_reset_launcher(pod, 41)
	var times := _run(pod, TICK, int(4.0 / TICK))
	var schedule: bool = times.size() == 6 and absf(times[1] - times[0] - 0.3) < TICK + EPS and absf(times[2] - times[0] - 0.6) < TICK + EPS \
		and times[3] - times[2] >= 1.0 - EPS and times[3] - times[2] < 1.0 + TICK + EPS
	_check("3-rocket salvos every 0.3 s, 1 s cooldown, 8 rockets: two salvos in 4 s, then no partial one (%d launches, %d left)" % [times.size(), pod.rounds_left()],
		schedule and pod.rounds_left() == 2 and pod.muzzles.size() == 3 and pod.reason == "Salvo needs 3 rockets (2 left)")
	var rockets: Array = projectiles.ordnance.filter(func(n: Node3D) -> bool: return n.owner_name == "FF01")
	_check("its rockets configure 20 u/s cruise with independent damage and penetration; RL-8 values untouched",
		not rockets.is_empty() and rockets.all(func(n: Node3D) -> bool: return n.config.speed == 20.0 and n.phase == "eject" and n.damage == 2.0 and n.penetration == 4.0)
		and RL8.ammunition == 48 and RL8.ordnance.speed == 30.0 and RL8.dispersion_max_deg == 3.0)
	# Step the alternate variant through its own launch phases, independently of collision.
	for rocket: Node3D in rockets:
		for tick in 180:
			rocket.step(TICK, projectiles)
	_check("alternate variant actually commits at its configured 20 u/s", rockets.all(func(n: Node3D) -> bool: return n.phase == "flight" and absf(n.velocity.length() - 20.0) < 0.001))
	_clear_flight()
	ff01.get_node("Weapons").remove_child(pod)
	pod.free()
	_check("RL-8's own script is the family script (no RL-8-specific code)", barrage.get_script() == RocketLauncher)
	_disarm()


# --- F: unguided flight -------------------------------------------------------------

func _launch_rocket(owner_ship: Node3D, faction: int, from: Vector3, direction: Vector3, target: Node3D) -> Node3D:
	var id: int = projectiles.launch(owner_ship, faction, Transform3D(Basis.looking_at(direction.normalized(), Vector3.UP), from), RL8, target)
	# Collision/defense fixtures start in committed flight; full launch is covered separately.
	var node := _ordnance(id)
	node.phase = "flight"
	node.velocity = direction.normalized() * RL8.ordnance.speed
	return node


func _flight() -> void:
	print("\n=== F unguided flight")
	_home()
	_place(victim, _ahead(40.0, 12.0), PI * 0.5)
	scene.sensors.evaluate()
	var from := Vector3(site.x, ff01.global_position.y, site.y - 7.0)
	var rocket := _launch_rocket(ff01, 0, from, Vector3.FORWARD, victim)
	var start_velocity: Vector3 = rocket.velocity
	var straight := true
	var steady := true
	var id: int = rocket.id
	for i in 60:
		_place(victim, _ahead(40.0, 12.0 - 0.4 * i), PI * 0.5) # Crossing ahead of it.
		await physics_frame
		var node := _ordnance(id)
		if node == null:
			break
		steady = steady and node.velocity == start_velocity and not node.homing() and not node.launching()
		var off := Geometry3D.get_closest_point_to_segment_uncapped(node.global_position, from, from + Vector3.FORWARD)
		straight = straight and off.distance_to(node.global_position) < 0.0001
	_check("speed 30 u/s along the launch axis (%.4f u/s)" % start_velocity.length(),
		absf(start_velocity.length() - 30.0) < 0.0001 and _angle(start_velocity, Vector3.FORWARD) < ANGLE_EPS)
	_check("no homing, steering or acceleration: constant velocity, straight line while its target crosses ahead", steady and straight)
	_clear_flight()


# --- K: collisions ------------------------------------------------------------------

func _collisions() -> void:
	print("\n=== K physical collisions")
	_home()
	_reset_victim()
	_place(victim, _ahead(20.0), PI * 0.5)
	var rocket := _launch_rocket(ff01, 0, Vector3(site.x, ff01.global_position.y, site.y - 7.0), Vector3.FORWARD, victim)
	var id: int = rocket.id
	await _frames(60)
	var rec := _ordnance_record(id)
	_check("a rocket strikes a hostile ship: %s on %s, damage applied once" % [rec.get("outcome", "live"), rec.get("ship", "-")],
		rec.get("outcome", "") == "damage" and rec.get("ship", "") == "HostileFF01" and projectiles.damage_events.get(id, 0) == 1)
	_reset_victim()
	_place(victim, site + Vector2(0, 150))
	# Asteroid: aim at the nearest asteroid from 20 u.
	var asteroids: Node = scene.get_node("Asteroids")
	var best := -1
	var best_d := INF
	for a: int in asteroids.ids():
		var d: float = Vector2(asteroids.center(a).x, asteroids.center(a).z).distance_to(site)
		if d < best_d:
			best_d = d
			best = a
	var center: Vector3 = asteroids.center(best)
	var toward := Vector3(site.x - center.x, 0.0, site.y - center.z).normalized()
	var start: Vector3 = Vector3(center.x, center.y, center.z) + toward * (asteroids.radius(best) + 20.0)
	id = _launch_rocket(ff01, 0, start, -toward, null).id
	await _frames(90)
	rec = _ordnance_record(id)
	_check("a rocket strikes an asteroid: %s at %.1f u" % [rec.get("outcome", "live"), rec.get("traveled", -1.0)], rec.get("outcome", "") == "asteroid")
	# Expiry after 70 u, independently of the unchanged 60 u acquisition range.
	id = _launch_rocket(ff01, 0, Vector3(site.x, ff01.global_position.y, site.y - 7.0), Vector3.FORWARD, null).id
	await _frames(150)
	rec = _ordnance_record(id)
	_check("a rocket that hits nothing expires after its travel: %s at %.3f u, %.3f s" % [rec.get("outcome", "live"), rec.get("traveled", -1.0), rec.get("age", -1.0)],
		rec.get("outcome", "") == "expired" and absf(rec.get("traveled", 0.0) - 70.0) < 0.0001 and rec.get("traveled", 0.0) >= 70.0 - EPS)
	# A real salvo from FF-01: no own-hull hit, at most one damage event per rocket.
	_reset_victim()
	_arm(_ahead(55.0), PI * 0.5)
	_reset_launcher(barrage, 51)
	var ids := _launched_ids(barrage, 1)
	await _frames(1)
	for i in 60:
		ids += _launched_ids(barrage, 1)
		await physics_frame
	await _frames(240)
	var outcomes := {}
	var own := 0
	var once := true
	for rid: int in ids:
		var r := _ordnance_record(rid)
		outcomes[r.get("outcome", "live")] = outcomes.get(r.get("outcome", "live"), 0) + 1
		if r.get("ship", "") == "FF01":
			own += 1
		once = once and projectiles.damage_events.get(rid, 0) <= 1
	print("  salvo at a broadside hostile FF-01 55 u ahead: %s" % str(outcomes))
	_check("live salvo: 8 rockets, none touches FF-01, each at most one damage event", ids.size() == 8 and own == 0 and once and outcomes.get("damage", 0) >= 1)
	_clear_flight()
	_disarm()
	_reset_victim()


# --- D: damage ----------------------------------------------------------------------

func _damage() -> void:
	print("\n=== D damage through the shared armor pipeline")
	_home()
	_reset_victim()
	var target = CombatShip.of(victim)
	_place(victim, _ahead(15.0), PI * 0.5)
	_check("fresh hostile FF-01: hull 160, armor 100 / 100, resistance 30", target.health == 160.0 and target.armor == 100.0 and target.armor_resistance == 30.0)
	var events: Array = []
	var on_damage := func(amount: float, id: int) -> void: events.append([amount, id, target.health, target.armor])
	target.damaged.connect(on_damage)
	_launch_rocket(ff01, 0, Vector3(site.x, ff01.global_position.y, site.y - 7.0), Vector3.FORWARD, victim)
	await _frames(40)
	var first: Array = events[0] if not events.is_empty() else [0.0, -1, 0.0, 0.0]
	_check("first rocket: hull damage %.10f (4 x 8 / (8 + 30) = 0.8421052632), hull %.10f, armor %.1f" % [first[0], first[2], first[3]],
		events.size() == 1 and absf(first[0] - 0.8421052632) < 1e-9 and absf(first[2] - 159.1578947368) < 1e-9 and first[3] == 99.0)
	_launch_rocket(ff01, 0, Vector3(site.x, ff01.global_position.y, site.y - 7.0), Vector3.FORWARD, victim)
	await _frames(40)
	var second: Array = events[1] if events.size() > 1 else [0.0, -1, 0.0, 0.0]
	var expected := 4.0 * 8.0 / (8.0 + 30.0 * 0.99)
	_check("second rocket uses the pre-impact condition 99: %.10f (32 / 37.7 = %.10f), armor 98" % [second[0], expected],
		absf(second[0] - expected) < 1e-9 and second[3] == 98.0)
	# A live salvo: every impact follows the formula from its own pre-impact condition.
	_reset_victim()
	events.clear()
	_arm(_ahead(55.0), PI * 0.5)
	_reset_launcher(barrage, 61)
	for i in 70:
		_launched_ids(barrage, 1)
		await physics_frame
	await _frames(240)
	var ok := not events.is_empty()
	var armor := 100.0
	for e: Array in events:
		ok = ok and absf(e[0] - 32.0 / (8.0 + 30.0 * armor / 100.0)) < 1e-9 and e[3] == armor - 1.0
		armor -= 1.0
	var ids := {}
	for e: Array in events:
		ids[e[1]] = ids.get(e[1], 0) + 1
	_check("live salvo: %d impacts, each with penetration 8 and armor damage 1 from its pre-impact condition; one event per rocket" % events.size(),
		ok and ids.values().all(func(n: int) -> bool: return n == 1))
	target.damaged.disconnect(on_damage)
	_clear_flight()
	_disarm()
	_reset_victim()


# --- I: interception ----------------------------------------------------------------

func _at(rel: Vector2, height := 0.0) -> Vector3:
	return Vector3(site.x + rel.x, ff01.global_position.y + height, site.y + rel.y)


func _round(config: Resource, from: Vector3, direction: Vector3, intercepts: bool) -> int:
	return projectiles.spawn(ff01, 0, from, direction.normalized() * config.projectile_speed, config.damage, config.max_travel(),
		config.projectile_lifetime, null, config.projectile_style, config.resolved_penetration(), config.armor_damage, intercepts)


func _hostile_rocket(rel: Vector2, direction: Vector3) -> Node3D:
	return _launch_rocket(hostile, HOSTILE, _at(rel), direction, ff01)


func _interception() -> void:
	print("\n=== I physical interception of rockets")
	_home()
	await physics_frame
	var rocket := _hostile_rocket(Vector2(14, 0), Vector3.LEFT)
	var r_id := _round(KESTREL, _at(Vector2(3, 0)), Vector3.RIGHT, true)
	var k_id: int = rocket.id
	await _frames(20)
	_check("one Kestrel round destroys one rocket: rocket %s by %s, round %s" % [_ordnance_record(k_id).get("outcome", "live"),
		_ordnance_record(k_id).get("intercepted_by", "-"), _round_record(r_id).get("outcome", "live")],
		_ordnance_record(k_id).get("outcome", "") == "intercepted" and _ordnance_record(k_id).get("intercepted_by", "") == "FF01"
		and _round_record(r_id).get("outcome", "") == "intercept")
	_clear_flight()
	var first: int = _hostile_rocket(Vector2(13, 0), Vector3.LEFT).id
	var second: int = _hostile_rocket(Vector2(14.5, 0), Vector3.LEFT).id
	r_id = _round(KESTREL, _at(Vector2(3, 0)), Vector3.RIGHT, true)
	await _frames(10)
	_check("one round cannot destroy two rockets: first %s, second %s" % [_ordnance_record(first).get("outcome", "live"), "live" if _ordnance(second) != null else "gone"],
		_ordnance_record(first).get("outcome", "") == "intercepted" and _ordnance(second) != null and _round_record(r_id).get("outcome", "") == "intercept")
	_clear_flight()
	k_id = _hostile_rocket(Vector2(14, 0), Vector3.LEFT).id
	r_id = _round(KESTREL, _at(Vector2(3, 1.5)), Vector3.RIGHT, true)
	await _frames(12)
	var alive: bool = _ordnance(k_id) != null and _ordnance(k_id).live
	await _frames(20) # The round's 0.45 s lifetime.
	_check("a round passing 1.5 u beside a rocket leaves it alive (rocket %s after the pass, round %s)" % ["live" if alive else "gone", _round_record(r_id).get("outcome", "live")],
		alive and _round_record(r_id).get("outcome", "") == "expired")
	_clear_flight()
	k_id = _hostile_rocket(Vector2(14, 0), Vector3.LEFT).id
	r_id = _round(GATLING, _at(Vector2(3, 0)), Vector3.RIGHT, true)
	await _frames(20)
	_check("a legacy Gatling round destroys a rocket: %s" % _ordnance_record(k_id).get("outcome", "live"),
		_ordnance_record(k_id).get("outcome", "") == "intercepted" and _round_record(r_id).get("outcome", "") == "intercept")
	_clear_flight()
	for shell: Resource in [NC90, CANNON]:
		k_id = _hostile_rocket(Vector2(14, 0), Vector3.LEFT).id
		r_id = _round(shell, _at(Vector2(3, 0)), Vector3.RIGHT, false)
		await _frames(12)
		_check("a %s shell passes through a rocket: rocket %s, shell %s" % [shell.display_name, "live" if _ordnance(k_id) != null else _ordnance_record(k_id).get("outcome", "?"),
			_round_record(r_id).get("outcome", "live")], _ordnance(k_id) != null and _ordnance(k_id).live and _round_record(r_id).get("outcome", "live") != "intercept")
		_clear_flight()
	# Missile and torpedo collision semantics unchanged: a cannon shell still intercepts them.
	var unchanged := true
	for config: Resource in [TORPEDO, MISSILE]:
		var id: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(14, 0))), config, ff01)
		var node := _ordnance(id)
		if config == MISSILE:
			node.phase = "powered"
			node.velocity = Vector3.LEFT * 10.0
		r_id = _round(NC90, _at(Vector2(3, 0)), Vector3.RIGHT, false)
		await _frames(20)
		unchanged = unchanged and _ordnance_record(id).get("outcome", "") == "intercepted" and _round_record(r_id).get("outcome", "") == "intercept"
		_clear_flight()
	_check("torpedoes and missiles are still intercepted by any hostile round (an NC-90 shell)", unchanged)
	# Live weapons mark their rounds: Kestrels (defense and offense) and Gatlings yes, NC-90 no.
	var flags := {}
	var on_spawn := func(record: Dictionary) -> void: flags[record.owner_name + ":" + str(record.style)] = record.intercepts_rockets
	projectiles.spawned_projectile.connect(on_spawn)
	var combat = CombatShip.of(ff01)
	_place(victim, _ahead(20.0, 8.0), PI * 0.5)
	combat.stance = CombatShip.Stance.AGGRESSIVE
	scene.sensors.evaluate()
	combat.assign_target(victim)
	combat.target = victim
	barrage.enabled = false
	for n: String in KESTRELS + BASTIONS:
		ff01.get_node("Weapons/%s" % n).weapon().cooldown_left = 0.0
	for i in 180:
		for n: String in KESTRELS + BASTIONS:
			ff01.get_node("Weapons/%s" % n).weapon().step(TICK)
		await physics_frame
	projectiles.spawned_projectile.disconnect(on_spawn)
	_check("live fire: Kestrel tracers carry rocket interception, NC-90 shells do not (%s)" % str(flags),
		flags.get("FF01:tracer", false) == true and flags.has("FF01:shell") and flags.get("FF01:shell", true) == false)
	barrage.enabled = true
	_clear_flight()
	_disarm()
	_reset_victim()


# --- T: threat evaluation and the missile rule ----------------------------------------

func _select(weapon: Node) -> Node3D:
	weapon.defense_target = null
	weapon.defense_category = -1
	weapon.defense_time = INF
	weapon._choose_defense()
	return weapon.defense_target


# Hostile ordnance at `rel`, 0.7 u up (about the PDC muzzle height, clear of the hull
# boxes), aimed at FF-01 arriving in `time` s.
func _threat(config: Resource, rel: Vector2, time: float) -> Node3D:
	var from := _at(rel, 0.7)
	var offset: Vector3 = ff01.global_position - from
	var node: Node3D = _ordnance(projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(offset.normalized(), Vector3.UP), from), config, ff01))
	node.velocity = offset.normalized() * (offset.length() / time)
	if config == RL8:
		node.phase = "flight"
	else:
		node.phase = "guided" if config == TORPEDO else "powered"
		node.has_goal = true
	return node


func _selection() -> void:
	print("\n=== T Kestrel selection of rockets (missile rule)")
	_home()
	await physics_frame
	var subject: Node = ff01.get_node("Weapons/AftStarboardPDCHardpoint").weapon()
	subject._track(0.0, null)
	var inbound := _hostile_rocket(Vector2(18, 4), (ff01.global_position - _at(Vector2(18, 4))).normalized())
	var passing := _hostile_rocket(Vector2(18, 8), Vector3.LEFT)
	_check("rocket threat time: straight-line approach (inbound %.3f s, unguided), a rocket passing 8 u wide is no threat" % Gatling.threat_time(inbound, ff01),
		absf(Gatling.threat_time(inbound, ff01) - _at(Vector2(18, 4)).distance_to(ff01.global_position) / 30.0) < 0.05
		and Gatling.threat_time(passing, ff01) == INF and not inbound.homing())
	_check("a Kestrel selects the inbound rocket", _select(subject) == inbound)
	_clear_flight()
	var torpedo := _threat(TORPEDO, Vector2(18, -2), 2.0)
	var rocket := _threat(RL8, Vector2(14, 8), 1.7)
	var picked := _select(subject)
	var torpedo_ok := picked == torpedo
	_clear_flight()
	torpedo = _threat(TORPEDO, Vector2(18, -2), 1.4)
	rocket = _threat(RL8, Vector2(14, 8), 1.2)
	var urgent := _select(subject)
	var urgent_ok := urgent == rocket
	_clear_flight()
	torpedo = _threat(TORPEDO, Vector2(18, -2), 1.2)
	rocket = _threat(RL8, Vector2(14, 8), 1.25)
	var later := _select(subject)
	var later_ok := later == torpedo
	_clear_flight()
	var missile := _threat(MISSILE, Vector2(18, -2), 2.4)
	rocket = _threat(RL8, Vector2(14, 8), 1.8)
	var with_missile := _select(subject)
	var missile_ok := with_missile == rocket
	_clear_flight()
	missile = _threat(MISSILE, Vector2(18, -2), 1.8)
	rocket = _threat(RL8, Vector2(14, 8), 2.2 * 0.9)
	var missile_first := _select(subject) == missile
	_clear_flight()
	_check("missile rule: torpedo 2.0 s before rocket 1.7 s (%s); rocket 1.2 s (< 1.5 s, earlier) before torpedo 1.4 s (%s); torpedo 1.2 s before rocket 1.25 s (%s); rocket and missile by impact time (1.8 vs 2.4: %s, 1.8 vs 1.98: %s)" % [
		"torpedo" if torpedo_ok else "rocket", "rocket" if urgent_ok else "torpedo", "torpedo" if later_ok else "rocket", "rocket" if missile_ok else "missile",
		"missile" if missile_first else "rocket"], torpedo_ok and urgent_ok and later_ok and missile_ok and missile_first)
	# Own ship before ally, with rockets.
	var ally := scene.get_node("Ships/Gunship") as Node3D
	_place(ally, site + Vector2(6, 20))
	var own := _threat(RL8, Vector2(18, -2), 1.6)
	var at_ally_from := _at(Vector2(16, 22))
	var at_ally: Node3D = _ordnance(projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at((ally.global_position - at_ally_from).normalized(), Vector3.UP), at_ally_from), RL8, ally))
	picked = _select(subject)
	_check("protection order kept: a rocket at FF-01 (1.6 s) before an earlier rocket at the ally (%.2f s)" % Gatling.threat_time(at_ally, ally),
		picked == own and subject.defense_category == 0 and Gatling.threat_time(at_ally, ally) < 1.6)
	_clear_flight()
	_park_others()
	_place(victim, site + Vector2(0, 150))
	# Independent mounts: two Kestrels both select the same single rocket (no reservation).
	var lone := _hostile_rocket(Vector2(0, -22), Vector3.BACK)
	var fp := _select(ff01.get_node("Weapons/ForwardPortPDCHardpoint").weapon())
	var fs := _select(ff01.get_node("Weapons/ForwardStarboardPDCHardpoint").weapon())
	_check("Kestrels select independently: both forward mounts choose the one rocket ahead", fp == lone and fs == lone)
	_clear_flight()
	# Live: FF-01's Kestrels shoot down an inbound rocket.
	var combat = CombatShip.of(ff01)
	barrage.enabled = false
	for n: String in BASTIONS:
		ff01.get_node("Weapons/%s" % n).weapon().enabled = false
	var id: int = _hostile_rocket(Vector2(16, -16), (ff01.global_position - _at(Vector2(16, -16))).normalized()).id
	combat.set_physics_process(true)
	for i in 120:
		await physics_frame
		if not _ordnance_record(id).is_empty():
			break
	combat.set_physics_process(false)
	var shots: int = KESTRELS.reduce(func(n: int, m: String) -> int: return n + ff01.get_node("Weapons/%s" % m).weapon().defense_shots, 0)
	_check("FF-01's Kestrels engage and destroy an inbound rocket (%s by %s, %d defensive rounds)" % [_ordnance_record(id).get("outcome", "live"),
		_ordnance_record(id).get("intercepted_by", "-"), shots], _ordnance_record(id).get("outcome", "") == "intercepted" and shots > 0)
	for n: String in BASTIONS:
		ff01.get_node("Weapons/%s" % n).weapon().enabled = true
	barrage.enabled = true
	_clear_flight()
	await physics_frame


# --- M: measurement -----------------------------------------------------------------

func _measurement() -> void:
	print("\n=== M measurement: a hostile RL-8 salvo against FF-01's four Kestrels (observation, no threshold)")
	var combat = CombatShip.of(ff01)
	var shooter = CombatShip.of(victim)
	var launcher: Node = victim.get_node("Weapons/BarrageHardpoint").weapon()
	for n: String in BASTIONS + KESTRELS:
		victim.get_node("Weapons/%s" % n).weapon().enabled = false
	for n: String in BASTIONS:
		ff01.get_node("Weapons/%s" % n).weapon().enabled = false
	barrage.enabled = false
	var totals := {}
	for distance: float in [25.0, 45.0, 60.0]:
		var line := []
		for seed in [1, 2, 3, 4, 5]:
			_home()
			_place(victim, site + Vector2(0, -distance), PI) # Bow toward FF-01.
			_reset_victim()
			combat.health = combat.max_health
			combat.armor = combat.max_armor
			for i in KESTRELS.size():
				var w: Node = ff01.get_node("Weapons/%s" % KESTRELS[i]).weapon()
				w.magazine = KESTREL.magazine_size
				w.ammo = KESTREL.ammunition - KESTREL.magazine_size
				w.reload_left = 0.0
				w.cooldown_left = 0.0
				w.rng.seed = seed * 100 + i
			_reset_launcher(launcher, seed)
			shooter.stance = CombatShip.Stance.AGGRESSIVE
			scene.sensors.evaluate()
			shooter.assign_target(ff01)
			shooter.target = ff01
			var ids := []
			var on_shot := func(_w: Node, rid: int, _t: Node3D, _o: Transform3D) -> void: ids.append(rid)
			launcher.shot.connect(on_shot)
			combat.set_physics_process(true)
			for i in 320:
				if ids.size() < 8:
					launcher.step(TICK)
				await physics_frame
			combat.set_physics_process(false)
			launcher.shot.disconnect(on_shot)
			var counts := {"intercepted": 0, "damage": 0, "other": 0}
			for rid: int in ids:
				var outcome: String = _ordnance_record(rid).get("outcome", "live")
				var key := outcome if counts.has(outcome) else "other"
				counts[key] += 1
			line.append("%d/%d/%d" % [counts.intercepted, counts.damage, counts.other])
			for k: String in counts:
				totals["%d_%s" % [int(distance), k]] = totals.get("%d_%s" % [int(distance), k], 0) + counts[k]
			_clear_flight()
			shooter.clear_target()
			shooter.target = null
		print("  %2.0f u, seeds 1-5 (intercepted / hit / missed): %s; total %d / %d / %d of 40" % [distance, " ".join(line),
			totals.get("%d_intercepted" % int(distance), 0), totals.get("%d_damage" % int(distance), 0), totals.get("%d_other" % int(distance), 0)])
	for n: String in BASTIONS:
		ff01.get_node("Weapons/%s" % n).weapon().enabled = true
	barrage.enabled = true
	combat.health = combat.max_health
	combat.armor = combat.max_armor
	_check("measurement ran: every launched rocket ended intercepted, on a hull or missed", totals.size() == 9)
	# Arena unchanged.
	var names := scene.get_node("Ships").get_children().map(func(s: Node) -> String: return String(s.name))
	_check("Combat Test ships unchanged (plus the test's own hostile FF-01), 36 asteroids, navigation half-size 380",
		COMBAT_TEST_SHIPS.all(func(n: String) -> bool: return names.has(n)) and names.size() == COMBAT_TEST_SHIPS.size() + 1
		and scene.get_node("Asteroids").ids().size() == 36 and scene.get_node("StaticNavigation").map_half_size == 380.0)
