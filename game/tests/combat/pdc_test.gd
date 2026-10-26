extends SceneTree
## PDC family: PDC-20 Kestrel configuration, the four Kestrels on FF-01, physical dispersion,
## defensive target selection (protection hierarchy, torpedo priority and the 1.5 s missile
## override, Guard, independent mounts, arcs and range), physical interception, offensive
## damage through the shared armor pipeline, and repeatable interception-throughput
## measurements (observations, no pass threshold).
## Run: <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/pdc_test.gd

const ARENA := preload("res://game/scenes/combat_test.tscn")
const UNIT := preload("res://game/ships/ff01_unit.tscn")
const KESTREL := preload("res://game/weapons/pdc20_kestrel.tres")
const KESTREL_SCENE := preload("res://game/weapons/pdc20_kestrel.tscn")
const NC90 := preload("res://game/weapons/nc90_bastion.tres")
const NC90_SCENE := preload("res://game/weapons/nc90_bastion.tscn")
const GATLING := preload("res://game/weapons/gatling.tres")
const CANNON := preload("res://game/weapons/cannon.tres")
const TORPEDO := preload("res://game/weapons/torpedo.tres")
const MISSILE := preload("res://game/weapons/missile.tres")
const Weapon := preload("res://game/weapons/weapon.gd")
const Gatling := preload("res://game/weapons/gatling.gd")
const PDC := preload("res://game/weapons/pdc.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const MOUNTS := ["ForwardPortPDCHardpoint", "ForwardStarboardPDCHardpoint", "AftPortPDCHardpoint", "AftStarboardPDCHardpoint"]
const MOUNT_ROWS := { # position, neutral yaw (deg), yaw limit (deg)
	"ForwardPortPDCHardpoint": [Vector3(-1.3, 0.55, -4), 45.0, 90.0],
	"ForwardStarboardPDCHardpoint": [Vector3(1.3, 0.55, -4), -45.0, 90.0],
	"AftPortPDCHardpoint": [Vector3(-1.3, 0.55, 4), 135.0, 90.0],
	"AftStarboardPDCHardpoint": [Vector3(1.3, 0.55, 4), -135.0, 90.0]}
const BASTIONS := ["ForwardBastionHardpoint", "AftBastionHardpoint"]
const RESERVED := ["BarrageHardpoint", "WayfarerHardpoint"]
const SITE_CLEARANCE := 85.0 # u of asteroid-free space around the test site (throughput approach corridor)
const HEIGHT := 0.7 # u, ordnance height in the targeting cases (about the PDC muzzle height)
const APPROACH := 70.0 # u, missile launch distance in the throughput scenarios
const APPROACH_BEARING := 60.0 # deg clockwise from FF-01's bow
const SEEDS := [1, 2, 3, 4, 5, 6, 7, 8]
const EPS := 0.000001
const ANGLE_EPS := 0.002 # deg, float32 direction tolerance
const HOSTILE := 1

var scene: Node3D
var ff01: Node3D
var projectiles: Node
var hostile: Node3D # Owner of the test ordnance (HostileDestroyer).
var site := Vector2.ZERO
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	_configuration()
	_dispersion()
	await _load()
	_installation()
	_geometry()
	_targeting()
	await _continuous_fire()
	await _interception()
	await _live_dispersion()
	await _throughput()
	await _offense()
	scene.free()
	await process_frame
	_check("no orphan nodes after the PDC verification", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(message: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-116s %s" % [message, "PASS" if ok else "FAIL"])


# --- C: configuration ---------------------------------------------------------------

func _configuration() -> void:
	print("\n=== C PDC-20 Kestrel configuration")
	var c := KESTREL
	_check("pdc20_kestrel.tres loads: PDC-20 Kestrel, family gatling (the PDC hardpoint classification), size small",
		c != null and c.display_name == "PDC-20 Kestrel" and c.family == &"gatling" and c.size == 0)
	_check("base hull damage 0.2, penetration 1 (explicitly configured), armor damage 0",
		c.damage == 0.2 and c.has_penetration and c.penetration == 1.0 and c.resolved_penetration() == 1.0 and c.armor_damage == 0.0)
	_check("interval 0.08 s, 70 u/s tracer, maximum range 25 u (no degradation), dispersion 2.5 deg",
		c.cooldown == 0.08 and c.projectile_speed == 70.0 and c.projectile_style == &"tracer" and c.weapon_range == 25.0
		and c.effective() == 25.0 and c.lead_quality(25.0) == 1.0 and c.dispersion_max_deg == 2.5)
	_check("magazine 40, 400 rounds per mount, reload 3 s",
		c.magazine_size == 40 and c.ammunition == 400 and c.reload_time == 3.0)
	_check("starting values copied from the Gatling: lifetime 0.45 s, travel factor 1.25, alignment 3 deg, yaw 140 / pitch 120 deg/s, idle reload 0.25 s",
		c.projectile_lifetime == GATLING.projectile_lifetime and c.travel_factor == GATLING.travel_factor
		and c.alignment_tolerance_deg == GATLING.alignment_tolerance_deg and c.yaw_speed_deg == GATLING.yaw_speed_deg
		and c.pitch_speed_deg == GATLING.pitch_speed_deg and c.idle_reload_delay == GATLING.idle_reload_delay)
	var root_node := KESTREL_SCENE.instantiate()
	_check("pdc20_kestrel.tscn: PDC-family script (extends the Gatling mount) with the Kestrel configuration and editable geometry",
		root_node.get_script() == PDC and root_node is Gatling and root_node.config == KESTREL and root_node.base_diameter == 0.36
		and root_node.body_height == 0.16 and root_node.barrel_length == 0.5)
	root_node.free()
	_check("PDC override threshold 1.5 s", PDC.MISSILE_OVERRIDE_TIME == 1.5)
	_check("legacy gatling.tres unchanged: damage 1, cooldown 0.08, range 25, 70 u/s, 400 rounds, magazine 40, reload 3 s, penetration unconfigured, armor damage 0, dispersion 0",
		GATLING.display_name == "Gatling" and GATLING.family == &"gatling" and GATLING.size == 0 and GATLING.damage == 1.0
		and GATLING.cooldown == 0.08 and GATLING.weapon_range == 25.0 and GATLING.projectile_speed == 70.0
		and GATLING.projectile_lifetime == 0.45 and GATLING.ammunition == 400 and GATLING.magazine_size == 40
		and GATLING.reload_time == 3.0 and GATLING.idle_reload_delay == 0.25 and not GATLING.has_penetration
		and GATLING.armor_damage == 0.0 and GATLING.dispersion_max_deg == 0.0 and GATLING.yaw_speed_deg == 140.0 and GATLING.pitch_speed_deg == 120.0)
	_check("NC-90 Bastion configuration unchanged: damage 12, penetration 20, armor damage 6, 2.5 s, 75 / 45 u, 40 rounds, dispersion 0.5",
		NC90.damage == 12.0 and NC90.penetration == 20.0 and NC90.armor_damage == 6.0 and NC90.cooldown == 2.5
		and NC90.weapon_range == 75.0 and NC90.effective_range == 45.0 and NC90.ammunition == 40 and NC90.dispersion_max_deg == 0.5)


# --- D: dispersion ------------------------------------------------------------------

static func _angle(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.angle_to(b))


func _dispersion() -> void:
	print("\n=== D dispersion (Weapon.disperse at 2.5 deg)")
	var rng := RandomNumberGenerator.new()
	rng.seed = 2027
	var axis := Vector3(-0.4, 0.1, -1.0).normalized()
	var samples := 20000
	var max_angle := 0.0
	var sum := 0.0
	var inner := 0
	var quadrants := [0, 0, 0, 0]
	var u := axis.cross(Vector3.UP).normalized()
	var v := axis.cross(u)
	var unit_length := true
	var seen := {}
	var limit: float = KESTREL.dispersion_max_deg
	# Uniform over the solid angle: P(theta <= x) = (1 - cos x) / (1 - cos max); the mean angle
	# and the share within half the maximum follow from it.
	var one_minus := 1.0 - cos(deg_to_rad(limit))
	var half_share := (1.0 - cos(deg_to_rad(limit * 0.5))) / one_minus
	var mean_expected := 0.0
	var steps := 2000
	for i in steps: # E[theta] = integral of P(theta > x) dx
		var x := limit * (i + 0.5) / steps
		mean_expected += (1.0 - (1.0 - cos(deg_to_rad(x))) / one_minus) * limit / steps
	for i in samples:
		var d := Weapon.disperse(axis, limit, rng)
		var angle := _angle(axis, d)
		max_angle = maxf(max_angle, angle)
		sum += angle
		if angle <= limit * 0.5:
			inner += 1
		var q := (0 if d.dot(u) >= 0.0 else 1) + (0 if d.dot(v) >= 0.0 else 2)
		quadrants[q] += 1
		unit_length = unit_length and absf(d.length() - 1.0) < 0.00001
		if i < 1000:
			seen[d] = true
	var mean := sum / samples
	var inner_share := float(inner) / samples
	print("  %d samples: max %.5f deg, mean %.5f deg (expectation %.5f), share within 1.25 deg %.4f (expectation %.4f), quadrants %s"
		% [samples, max_angle, mean, mean_expected, inner_share, half_share, str(quadrants)])
	_check("every direction stays within the 2.5 deg half-angle cone (max %.5f deg) and keeps unit length" % max_angle, max_angle <= limit + ANGLE_EPS and unit_length)
	_check("uniform over the cone's solid angle: mean %.4f within %.4f +/- 0.03, share within 1.25 deg %.4f within %.4f +/- 0.015" % [mean, mean_expected, inner_share, half_share],
		absf(mean - mean_expected) < 0.03 and absf(inner_share - half_share) < 0.015)
	_check("azimuth uniform: each quadrant %s within 25%% +/- 1.5%%" % str(quadrants),
		quadrants.all(func(n: int) -> bool: return absf(float(n) / samples - 0.25) < 0.015))
	_check("different samples give different directions (%d distinct of 1000)" % seen.size(), seen.size() == 1000)
	var first := _sequence(4242, axis)
	var again := _sequence(4242, axis)
	var other := _sequence(2424, axis)
	_check("the same seed reproduces the same sequence; another seed gives another", first == again and first != other)


static func _sequence(seed: int, axis: Vector3) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out := []
	for i in 50:
		out.append(Weapon.disperse(axis, KESTREL.dispersion_max_deg, rng))
	return out


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
	for i in 3:
		await physics_frame
	site = _clear_site()
	_place(ff01, site)
	_park_others()
	await physics_frame
	_check("test site (%.0f, %.0f) clear of asteroids for %.0f u; FF-01 placed there with its bow along -Z" % [site.x, site.y, SITE_CLEARANCE],
		Vector2(ff01.global_position.x, ff01.global_position.z).distance_to(site) < 0.01 and ff01.global_basis.z.is_equal_approx(Vector3.BACK))


func _clear_site() -> Vector2:
	var asteroids: Node = scene.get_node("Asteroids")
	var best := Vector2(-300, 300)
	var best_gap := -INF
	for x in range(-300, 301, 10):
		for z in range(-300, 301, 10):
			var point := Vector2(x, z)
			var gap := INF
			for id: int in asteroids.ids():
				var c: Vector3 = asteroids.center(id)
				gap = minf(gap, Vector2(c.x, c.z).distance_to(point) - asteroids.radius(id))
			if gap >= SITE_CLEARANCE:
				return point
			if gap > best_gap:
				best_gap = gap
				best = point
	print("  no site with %.0f u clearance; best gap %.1f u" % [SITE_CLEARANCE, best_gap])
	return best


# Every other ship well away from the site (the corridor and allies are placed per case).
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


# FF-01 back on the site, bow -Z, no route (a Guard order may have started one); prints any drift.
func _home(label: String) -> void:
	var drift := Vector2(ff01.global_position.x, ff01.global_position.z).distance_to(site)
	if drift > 0.01:
		print("  (%s: FF-01 had drifted %.2f u from the site; placed back)" % [label, drift])
	ff01.get_node("RouteFollower").clear()
	_place(ff01, site)


# World point at ship-frame offset `rel` (x starboard, y astern) from the site, FF-01 bow -Z,
# `height` above FF-01's origin (the hull boxes span -0.55 to 0.55 around it).
func _at(rel: Vector2, height := HEIGHT) -> Vector3:
	return Vector3(site.x + rel.x, ff01.global_position.y + height, site.y + rel.y)


func _bearing_point(bearing: float, distance: float) -> Vector2:
	var b := deg_to_rad(bearing)
	return site + Vector2(sin(b), -cos(b)) * distance


func _pdc(mount: String) -> Node:
	return ff01.get_node("Weapons/%s" % mount).weapon()


func _pdcs() -> Array:
	return MOUNTS.map(func(m: String) -> Node: return _pdc(m))


func _ordnance(id: int) -> Node3D:
	for node in projectiles.ordnance:
		if node.id == id:
			return node
	return null


func _clear_flight() -> void:
	for node in projectiles.ordnance.duplicate():
		projectiles._finish_ordnance(node, "cleared", "", node.global_position, "")
	for record: Dictionary in projectiles.active.duplicate():
		projectiles._finish(record, "cleared", "", record.position)


# Puts every Kestrel back to its starting state (full magazine and stock, neutral, no
# timers), with mount seeds base * 100 + index.
func _reset_pdcs(seed_base: int) -> void:
	var i := 0
	for w: Node in _pdcs():
		w.enabled = true
		w.magazine = KESTREL.magazine_size
		w.ammo = KESTREL.ammunition - KESTREL.magazine_size
		w.reload_left = 0.0
		w.cooldown_left = 0.0
		w.idle_time = 0.0
		w.yaw = 0.0
		w.pitch = 0.0
		w.wanted_yaw = 0.0
		w.wanted_pitch = 0.0
		w.yaw_pivot.rotation = Vector3.ZERO
		w.pitch_pivot.rotation = Vector3.ZERO
		w.shots = 0
		w.defense_shots = 0
		w.offense_shots = 0
		w.defense_target = null
		w.mode = "idle"
		w.rng.seed = seed_base * 100 + i
		i += 1


# --- E: installation and geometry ----------------------------------------------------

func _installation() -> void:
	print("\n=== E FF-01 installation")
	var combat = CombatShip.of(ff01)
	var installed := true
	var transforms := true
	for mount_name: String in MOUNTS:
		var mount := ff01.get_node("Weapons/%s" % mount_name)
		var weapon: Node = mount.weapon()
		installed = (installed and weapon != null and mount.get_child_count() == 1 and weapon.scene_file_path == KESTREL_SCENE.resource_path
			and weapon.get_script() == PDC and weapon.config == KESTREL and weapon.transform.is_equal_approx(Transform3D.IDENTITY)
			and mount.accepts(weapon.config) and weapon.hardpoint == mount and combat.weapons.has(weapon) and weapon.enabled)
		var row: Array = MOUNT_ROWS[mount_name]
		transforms = (transforms and mount.position.is_equal_approx(row[0]) and mount.basis.is_equal_approx(Basis(Vector3.UP, deg_to_rad(row[1])))
			and mount.yaw_limit_deg == row[2] and weapon.yaw_limit_deg() == row[2] and mount.size == 0 and mount.families == PackedStringArray(["gatling"]))
	_check("four PDC-20 Kestrels: one per PDC hardpoint, at identity, accepted, enabled, stepped by Combat", installed)
	_check("PDC hardpoint transforms and limits preserved: (+/-1.3, 0.55, -/+4), neutral yaw +45 / -45 / +135 / -135 deg, +/-90 deg", transforms)
	var bastions := true
	for mount_name: String in BASTIONS:
		var mount := ff01.get_node("Weapons/%s" % mount_name)
		var weapon: Node = mount.weapon()
		bastions = bastions and weapon != null and weapon.scene_file_path == NC90_SCENE.resource_path and weapon.config == NC90 and weapon.rounds_left() == 40
	var fwd := ff01.get_node("Weapons/ForwardBastionHardpoint")
	var aft := ff01.get_node("Weapons/AftBastionHardpoint")
	_check("two NC-90 Bastions unchanged: forward (0, 0.55, -3) yaw 0, aft (0, 0.55, 3) yaw 180, +/-120 deg, 40 rounds each", bastions
		and fwd.position.is_equal_approx(Vector3(0, 0.55, -3)) and fwd.basis.is_equal_approx(Basis.IDENTITY) and fwd.yaw_limit_deg == 120.0
		and aft.position.is_equal_approx(Vector3(0, 0.55, 3)) and aft.basis.is_equal_approx(Basis(Vector3.UP, PI)) and aft.yaw_limit_deg == 120.0)
	_check("Barrage (rocket) and Wayfarer (missile) hardpoints stay empty", RESERVED.all(func(n: String) -> bool:
		return ff01.get_node("Weapons/%s" % n).get_child_count() == 0 and ff01.get_node("Weapons/%s" % n).weapon() == null))
	_check("FF-01 Combat steps six weapons (two Bastions, four Kestrels), none incompatible", combat.weapons.size() == 6 and combat.incompatible.is_empty())
	var pdcs := _pdcs()
	var distinct := true
	for i in pdcs.size():
		for j in range(i + 1, pdcs.size()):
			distinct = distinct and pdcs[i] != pdcs[j] and pdcs[i].rng != pdcs[j].rng
	_check("each Kestrel is its own instance with its own RNG and a full 40 + 360 round stock", distinct
		and pdcs.all(func(w: Node) -> bool: return w.magazine == 40 and w.ammo == 360 and w.cooldown_left == 0.0 and w.defense_target == null))
	# Independent state: firing one mount changes only its own magazine, cooldown and RNG.
	var before := pdcs.map(func(w: Node) -> Array: return [w.magazine, w.ammo, w.cooldown_left, w.rng.state])
	var target := scene.get_node("Ships/HostileGunship") as Node3D
	pdcs[1].mode = "defense"
	pdcs[1]._fire(target)
	var after := pdcs.map(func(w: Node) -> Array: return [w.magazine, w.ammo, w.cooldown_left, w.rng.state])
	_check("one shot from the forward-starboard mount changes only its magazine (%d), cooldown (%.2f) and RNG state" % [after[1][0], after[1][2]],
		after[1][0] == 39 and after[1][2] == KESTREL.cooldown and after[1][3] != before[1][3]
		and after[0] == before[0] and after[2] == before[2] and after[3] == before[3])
	_clear_flight()
	_reset_pdcs(1)
	var gunship := scene.get_node("Ships/Gunship")
	var legacy := ["LeftHardpoint", "RightHardpoint"].all(func(n: String) -> bool:
		var w: Node = gunship.get_node("Weapons/%s" % n).weapon()
		return w.get_script() == Gatling and w.config == GATLING)
	var stern: Node = scene.get_node("Ships/Destroyer/Weapons/SternHardpoint").weapon()
	_check("legacy Gatlings (Gunship, Destroyer) keep gatling.gd and gatling.tres", legacy and stern.get_script() == Gatling and stern.config == GATLING)


func _geometry() -> void:
	print("\n=== E geometry (one muzzle per mount, gray placeholder, clear of the hull across the traverse)")
	var combat = CombatShip.of(ff01)
	var to_ship: Transform3D = ff01.global_transform.affine_inverse()
	for mount_name: String in MOUNTS:
		var weapon: Node = _pdc(mount_name)
		var meshes := weapon.find_children("*", "MeshInstance3D", true, false)
		var muzzles := weapon.find_children("*", "Marker3D", true, false)
		var neutral := true
		for mesh: MeshInstance3D in meshes:
			var color: Color = (mesh.mesh as PrimitiveMesh).material.albedo_color
			neutral = neutral and absf(color.r - color.b) < 0.03 and absf(color.r - color.g) < 0.03
		var clear := true
		for yaw_deg: float in [-90.0, -60.0, -30.0, 0.0, 30.0, 60.0, 90.0]:
			for pitch_deg: float in [-15.0, 0.0, 30.0]:
				weapon.yaw_pivot.rotation = Vector3(0, deg_to_rad(yaw_deg), 0)
				weapon.pitch_pivot.rotation = Vector3(deg_to_rad(pitch_deg), 0, 0)
				var muzzle: Vector3 = to_ship * weapon.muzzle.global_position
				for box: AABB in combat.hitboxes:
					clear = clear and not box.has_point(muzzle)
				clear = clear and combat.segment_fraction(weapon.pitch_pivot.global_position, weapon.muzzle.global_position) < 0.0
		weapon.yaw_pivot.rotation = Vector3.ZERO
		weapon.pitch_pivot.rotation = Vector3.ZERO
		_check("%s: %d meshes in neutral gray, exactly one muzzle, muzzle outside the hull at yaw -90..90 deg, pitch -15..30 deg" % [mount_name, meshes.size()],
			meshes.size() >= 4 and muzzles.size() == 1 and muzzles[0] == weapon.muzzle and neutral and clear)


# --- T: defensive target selection (PDC._choose_defense, read without stepping) -----

# Ordnance `kind` at ship-frame offset `rel`, flying straight at `target` (or along
# `heading` when given) so that its predicted impact on `target` is `time` seconds.
# Velocity and phase are set by the test (the flight mechanics are not stepped here).
func _threat(kind: StringName, rel: Vector2, target: Node3D, time: float) -> Node3D:
	var config: Resource = TORPEDO if kind == &"torpedo" else MISSILE
	var from := _at(rel)
	var offset: Vector3 = target.global_position - from
	var id: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(offset.normalized(), Vector3.UP), from), config, target)
	var node := _ordnance(id)
	node.velocity = offset.normalized() * (offset.length() / time)
	node.phase = "guided" if kind == &"torpedo" else "powered"
	node.has_goal = true
	return node


func _select(weapon: Node) -> Node3D:
	weapon.defense_target = null
	weapon.defense_category = -1
	weapon.defense_time = INF
	weapon._choose_defense()
	return weapon.defense_target


func _label(node: Node3D) -> String:
	return "none" if node == null else String(node.name)


func _targeting() -> void:
	print("\n=== T defensive target selection (each case separately; aft-starboard Kestrel unless stated)")
	var ally_a := scene.get_node("Ships/Gunship") as Node3D
	var ally_b := scene.get_node("Ships/Gunship2") as Node3D
	_place(ally_a, site + Vector2(6, 20))
	_place(ally_b, site + Vector2(20, 12))
	var subject: Node = _pdc("AftStarboardPDCHardpoint")
	subject._track(0.0, null)

	# T1: own ship before ally.
	var own := _threat(&"torpedo", Vector2(18, -2), ff01, 1.6)
	var to_ally := _threat(&"torpedo", Vector2(16, 22), ally_a, 0.5)
	var picked := _select(subject)
	_check("T1 own ship vs ally: torpedo at FF-01 (%.2f s) chosen over an earlier torpedo at the ally (%.2f s): %s, category %d" % [
		Gatling.threat_time(own, ff01), Gatling.threat_time(to_ally, ally_a), _label(picked), subject.defense_category],
		picked == own and subject.defense_category == 0 and Gatling.threat_time(to_ally, ff01) == INF)
	_clear_flight()

	# T2: two allies, no threat to the own ship: ordnance priority, then the earliest impact.
	var a := _threat(&"torpedo", Vector2(16, 22), ally_a, 1.2)
	var b := _threat(&"torpedo", Vector2(20, 2), ally_b, 0.8)
	picked = _select(subject)
	var first_ok: bool = picked == b and subject.defense_category == 1
	var line := "torpedo at B (0.8 s) over torpedo at A (1.2 s): %s" % _label(picked)
	_clear_flight()
	a = _threat(&"torpedo", Vector2(16, 22), ally_a, 0.8)
	b = _threat(&"torpedo", Vector2(20, 2), ally_b, 1.2)
	picked = _select(subject)
	var second_ok: bool = picked == a and subject.defense_category == 1
	line += "; swapped times: %s" % _label(picked)
	_clear_flight()
	a = _threat(&"missile", Vector2(16, 22), ally_a, 2.0)
	b = _threat(&"torpedo", Vector2(20, 2), ally_b, 3.0)
	picked = _select(subject)
	var kind_ok: bool = picked == b
	line += "; missile at A (2.0 s) vs torpedo at B (3.0 s): %s" % _label(picked)
	_clear_flight()
	_check("T2 two allies threatened: %s" % line, first_ok and second_ok and kind_ok)

	# T3: torpedo vs missile with similar impact times.
	var torpedo := _threat(&"torpedo", Vector2(18, -2), ff01, 2.0)
	var missile := _threat(&"missile", Vector2(14, 8), ff01, 1.9)
	picked = _select(subject)
	var above_ok: bool = picked == torpedo
	_clear_flight()
	torpedo = _threat(&"torpedo", Vector2(18, -2), ff01, 1.2)
	missile = _threat(&"missile", Vector2(14, 8), ff01, 1.25)
	var below := _select(subject)
	_clear_flight()
	_check("T3 similar impact times: torpedo 2.0 s vs missile 1.9 s -> %s; torpedo 1.2 s vs missile 1.25 s -> %s (torpedo both times)" % [
		"torpedo" if above_ok else "missile", "torpedo" if below == torpedo else "missile"], above_ok and below == torpedo)

	# T4: a missile under 1.5 s and earlier than the torpedo overrides.
	torpedo = _threat(&"torpedo", Vector2(18, -2), ff01, 1.4)
	missile = _threat(&"missile", Vector2(14, 8), ff01, 1.0)
	picked = _select(subject)
	_check("T4 missile 1.0 s (under 1.5 s, earlier than the torpedo's 1.4 s) overrides the torpedo: %s" % _label(picked), picked == missile)
	_clear_flight()
	torpedo = _threat(&"torpedo", Vector2(18, -2), ff01, 1.4)
	missile = _threat(&"missile", Vector2(14, 8), ff01, 1.4)
	# Positions give float32 times that are not exactly equal, so the tie is judged on the
	# candidate entries themselves (both orders, ids either way round).
	var tie_t := [0, 1.4, torpedo.id, torpedo]
	var tie_m := [0, 1.4, missile.id, missile]
	var tie_m_low := [0, 1.4, torpedo.id - 1, missile]
	_check("T4b exact tie at 1.4 s (not earlier than the torpedo): the torpedo keeps priority whatever the ids",
		subject._defense_before(tie_t, tie_m) and not subject._defense_before(tie_m, tie_t)
		and subject._defense_before(tie_t, tie_m_low) and not subject._defense_before(tie_m_low, tie_t))
	var deterministic := true
	for i in 5:
		deterministic = deterministic and _select(subject) == _select(subject)
	_check("T4c near-tie from positions (torpedo %.6f s, missile %.6f s): the same choice on every evaluation (%s)" % [
		Gatling.threat_time(torpedo, ff01), Gatling.threat_time(missile, ff01), _label(_select(subject))], deterministic)
	_clear_flight()

	# T5: a missile above the threshold never overrides, even when much earlier.
	torpedo = _threat(&"torpedo", Vector2(18, -2), ff01, 3.0)
	missile = _threat(&"missile", Vector2(14, 8), ff01, 1.6)
	picked = _select(subject)
	var legacy: Node = scene.get_node("Ships/Gunship/Weapons/RightHardpoint").weapon()
	_check("T5 missile 1.6 s (above 1.5 s) vs torpedo 3.0 s: the torpedo (%s)" % _label(picked), picked == torpedo)
	# Contrast: the legacy Gatling order (earliest impact) is unchanged.
	var candidates := [[0, 1.6, missile.id, missile], [0, 3.0, torpedo.id, torpedo]]
	_check("legacy Gatling ordering unchanged: earliest impact first (missile before torpedo), PDC ordering torpedo first",
		legacy._defense_before(candidates[0], candidates[1]) and not legacy._defense_before(candidates[1], candidates[0])
		and subject._defense_before(candidates[1], candidates[0]) and not subject._defense_before(candidates[0], candidates[1]))
	_clear_flight()

	# T6: Guard does not change the hierarchy.
	var results := []
	for guard: bool in [false, true]:
		if guard:
			_check("T6 setup: FF-01 accepts a Guard order on the ally", ff01.get_node("Behavior").order_guard(ally_a))
		own = _threat(&"missile", Vector2(18, -2), ff01, 2.5)
		to_ally = _threat(&"torpedo", Vector2(16, 22), ally_a, 0.6)
		picked = _select(subject)
		results.append([picked == own, subject.defense_category])
		_clear_flight()
	scene.orders.cancel([ff01])
	_home("after Guard")
	_check("T6 same ship without and under Guard of the threatened ally: the own-ship threat both times %s" % str(results),
		results[0] == [true, 0] and results[1] == [true, 0])

	# T7: several mounts select the same threat on their own.
	var beam := _threat(&"torpedo", Vector2(18, 0), ff01, 1.5)
	var fs := _select(_pdc("ForwardStarboardPDCHardpoint"))
	var as_ := _select(subject)
	_check("T7 one torpedo on the starboard beam: forward-starboard -> %s, aft-starboard -> %s (both, no reservation)" % [_label(fs), _label(as_)],
		fs == beam and as_ == beam)
	_clear_flight()

	# T8: firing arcs and authorized range.
	var port := _threat(&"torpedo", Vector2(-18, 0), ff01, 1.5)
	var picks := _pdcs().map(func(w: Node) -> String: return _label(_select(w)))
	_check("T8 torpedo on the port beam: port mounts engage, starboard mounts (outside their arc / behind the hull) do not %s" % str(picks),
		picks[0] == String(port.name) and picks[2] == String(port.name) and picks[1] == "none" and picks[3] == "none"
		and not _pdc("ForwardStarboardPDCHardpoint").engageable(port))
	_clear_flight()
	var far := _threat(&"torpedo", Vector2(30, 0), ff01, 2.5)
	picks = _pdcs().map(func(w: Node) -> String: return _label(_select(w)))
	_check("T8 torpedo 30 u out (a threat, %.2f s, beyond the 25 u range): no mount engages %s" % [Gatling.threat_time(far, ff01), str(picks)],
		Gatling.threat_time(far, ff01) < INF and picks.all(func(p: String) -> bool: return p == "none"))
	_clear_flight()
	_place(ally_a, site + Vector2(-150, 0) if site.x > 0.0 else site + Vector2(150, 0))
	_place(ally_b, site + Vector2(-170, 0) if site.x > 0.0 else site + Vector2(170, 0))


# --- F: continuous fire ---------------------------------------------------------------

func _continuous_fire() -> void:
	print("\n=== F continuous defensive fire (one mount, one torpedo)")
	_home("F")
	await physics_frame
	_reset_pdcs(3)
	for w: Node in _pdcs():
		w.enabled = w == _pdc("AftStarboardPDCHardpoint")
	var mount: Node = _pdc("AftStarboardPDCHardpoint")
	var frames: Array = []
	var frame := {"n": 0}
	var record := func(_w: Node, _id: int, _t: Node3D, _o: Transform3D) -> void: frames.append(frame.n)
	mount.shot.connect(record)
	var id: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(40, 3))), TORPEDO, ff01)
	var combat = CombatShip.of(ff01)
	combat.set_physics_process(true)
	var outcome := ""
	var engaged_frames := 0
	for i in 600:
		await physics_frame
		frame.n += 1
		if mount.defense_target != null:
			engaged_frames += 1
		var done: Array = projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.id == id)
		if not done.is_empty():
			outcome = done[0].outcome
			break
	combat.set_physics_process(false)
	mount.shot.disconnect(record)
	var gaps := {}
	for i in range(1, frames.size()):
		gaps[frames[i] - frames[i - 1]] = gaps.get(frames[i] - frames[i - 1], 0) + 1
	print("  %d rounds, gaps in ticks %s, engaged %d ticks, outcome %s" % [frames.size(), str(gaps), engaged_frames, outcome])
	# 0.08 s at 60 Hz: the shared cooldown elapses on the 5th tick (0.0833 s).
	_check("once engaged, the mount fires every cooldown (5 ticks at 60 Hz) until the threat ends: %d rounds, gaps %s, %s" % [frames.size(), str(gaps), outcome],
		frames.size() >= 2 and gaps.keys() == [5] and outcome == "intercepted")
	_clear_flight()
	await physics_frame


# --- I: physical interception ---------------------------------------------------------

func _round(from: Vector3, direction: Vector3) -> int:
	return projectiles.spawn(ff01, 0, from, direction.normalized() * KESTREL.projectile_speed, KESTREL.damage, KESTREL.max_travel(),
		KESTREL.projectile_lifetime, null, KESTREL.projectile_style, KESTREL.resolved_penetration(), KESTREL.armor_damage)


func _round_record(id: int) -> Dictionary:
	for r: Dictionary in projectiles.records:
		if r.id == id:
			return r
	return {}


func _ordnance_record(id: int) -> Dictionary:
	for r: Dictionary in projectiles.ordnance_records:
		if r.id == id:
			return r
	return {}


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _interception() -> void:
	print("\n=== I physical interception (Projectiles sweep; FF-01 Combat not stepped unless stated)")
	_home("I")
	await physics_frame
	_reset_pdcs(5)
	# One round head-on into one torpedo: intercepted by the single round.
	var t_id: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(14, 0))), TORPEDO, ff01)
	var r_id := _round(_at(Vector2(3, 0)), Vector3.RIGHT)
	await _frames(20)
	var t_rec := _ordnance_record(t_id)
	var r_rec := _round_record(r_id)
	_check("one Kestrel round destroys one torpedo: torpedo %s by %s, round %s" % [t_rec.get("outcome", "live"), t_rec.get("intercepted_by", "-"), r_rec.get("outcome", "live")],
		t_rec.get("outcome", "") == "intercepted" and t_rec.get("intercepted_by", "") == "FF01" and r_rec.get("outcome", "") == "intercept")
	_clear_flight()
	# One round into one missile in powered flight.
	var m_id: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(14, 0))), MISSILE, ff01)
	var m := _ordnance(m_id)
	m.phase = "powered"
	m.velocity = Vector3.LEFT * 10.0
	r_id = _round(_at(Vector2(3, 0)), Vector3.RIGHT)
	await _frames(20)
	var m_rec := _ordnance_record(m_id)
	r_rec = _round_record(r_id)
	_check("one Kestrel round destroys one missile: missile %s by %s, round %s" % [m_rec.get("outcome", "live"), m_rec.get("intercepted_by", "-"), r_rec.get("outcome", "live")],
		m_rec.get("outcome", "") == "intercepted" and m_rec.get("intercepted_by", "") == "FF01" and r_rec.get("outcome", "") == "intercept")
	_clear_flight()
	# One round, two torpedoes in file on its path: only the first.
	var first: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(13, 0))), TORPEDO, ff01)
	var second: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(14.5, 0))), TORPEDO, ff01)
	r_id = _round(_at(Vector2(3, 0)), Vector3.RIGHT)
	await _frames(12)
	var second_node := _ordnance(second)
	_check("one round cannot destroy two threats: first %s, second %s, round %s" % [_ordnance_record(first).get("outcome", "live"),
		"live" if second_node != null else _ordnance_record(second).get("outcome", "?"), _round_record(r_id).get("outcome", "live")],
		_ordnance_record(first).get("outcome", "") == "intercepted" and second_node != null and second_node.live and _round_record(r_id).get("outcome", "") == "intercept")
	_clear_flight()
	# A miss: a round passing 1.5 u beside a torpedo (interception radius 0.4 u).
	t_id = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(14, 0))), TORPEDO, ff01)
	r_id = _round(_at(Vector2(3, 1.5)), Vector3.RIGHT)
	await _frames(30)
	var t_node := _ordnance(t_id)
	_check("a missed round does not destroy the threat: torpedo %s, round %s" % ["live" if t_node != null and t_node.live else "gone", _round_record(r_id).get("outcome", "live")],
		t_node != null and t_node.live and _round_record(r_id).get("outcome", "") == "expired")
	_clear_flight()
	# Cannon shells are not interceptable: not selected as threats, and a round passes through.
	var combat = CombatShip.of(ff01)
	var shell_from := _at(Vector2(22, 0), 0.3)
	var shell_id: int = projectiles.spawn(hostile, HOSTILE, shell_from, Vector3.LEFT * CANNON.projectile_speed, CANNON.damage, CANNON.max_travel(),
		CANNON.projectile_lifetime, ff01, &"shell")
	r_id = _round(_at(Vector2(3, 0), 0.3), Vector3.RIGHT)
	var health_before: float = combat.health
	combat.set_physics_process(true)
	var engaged := 0
	for i in 60:
		await physics_frame
		for w: Node in _pdcs():
			if w.defense_target != null:
				engaged += 1
	combat.set_physics_process(false)
	var shots: int = _pdcs().reduce(func(n: int, w: Node) -> int: return n + w.defense_shots, 0)
	_check("cannon shells are not interceptable: no mount engages a shell (%d ticks, %d rounds); the head-on round %s, the shell %s FF-01" % [engaged, shots,
		_round_record(r_id).get("outcome", "live"), _round_record(shell_id).get("outcome", "live")],
		engaged == 0 and shots == 0 and _round_record(r_id).get("outcome", "") != "intercept" and _round_record(shell_id).get("outcome", "") == "damage")
	combat.health = health_before
	combat.armor = combat.max_armor
	_clear_flight()
	# Ammunition and reload constrain interception (FF-01 Combat stepped).
	_reset_pdcs(6)
	for w: Node in _pdcs():
		w.magazine = 0
		w.ammo = 0
	t_id = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(30, 0), 0.3)), TORPEDO, ff01)
	combat.set_physics_process(true)
	for i in 300:
		await physics_frame
		if not _ordnance_record(t_id).is_empty():
			break
	combat.set_physics_process(false)
	shots = _pdcs().reduce(func(n: int, w: Node) -> int: return n + w.shots, 0)
	_check("out of ammunition: no round fired (%d), the torpedo hits FF-01 (%s)" % [shots, _ordnance_record(t_id).get("outcome", "live")],
		shots == 0 and _ordnance_record(t_id).get("outcome", "") == "damage")
	combat.health = combat.max_health
	combat.armor = combat.max_armor
	_clear_flight()
	_reset_pdcs(7)
	for w: Node in _pdcs():
		w.magazine = 0
		w._start_reload("empty")
	var first_shot := {"t": -1.0}
	var tick := {"n": 0}
	var on_shot := func(_w: Node, _id: int, _t: Node3D, _o: Transform3D) -> void:
		if first_shot.t < 0.0:
			first_shot.t = tick.n / 60.0
	for w: Node in _pdcs():
		w.shot.connect(on_shot)
	t_id = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(30, 0), 0.3)), TORPEDO, ff01)
	combat.set_physics_process(true)
	for i in 400:
		await physics_frame
		tick.n += 1
		if not _ordnance_record(t_id).is_empty():
			break
	combat.set_physics_process(false)
	for w: Node in _pdcs():
		w.shot.disconnect(on_shot)
	_check("reloading (3 s, all magazines empty): the torpedo at 30 u reaches FF-01 before any round (first round %.2f s, torpedo %s)" % [first_shot.t,
		_ordnance_record(t_id).get("outcome", "live")], (first_shot.t < 0.0 or first_shot.t >= KESTREL.reload_time - 0.02) and _ordnance_record(t_id).get("outcome", "") == "damage")
	combat.health = combat.max_health
	combat.armor = combat.max_armor
	_clear_flight()
	await physics_frame


# --- P: dispersion on live rounds -------------------------------------------------------

func _live_dispersion() -> void:
	print("\n=== P dispersion on live defensive rounds (real direction, one projectile per shot)")
	_home("P")
	await physics_frame
	_reset_pdcs(9)
	var spawned := {}
	var on_spawn := func(record: Dictionary) -> void: spawned[record.id] = record.duplicate()
	projectiles.spawned_projectile.connect(on_spawn)
	var shots: Array = []
	var on_shot := func(w: Node, id: int, _t: Node3D, origin: Transform3D) -> void: shots.append({"w": w, "id": id, "origin": origin})
	for w: Node in _pdcs():
		w.shot.connect(on_shot)
	var combat = CombatShip.of(ff01)
	combat.set_physics_process(true)
	# A run of torpedoes from both beams keeps the mounts firing.
	for k in 6:
		var side := 1.0 if k % 2 == 0 else -1.0
		projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3(-side, 0, 0)), _at(Vector2(32.0 * side, -3.0 + k))), TORPEDO, ff01)
		await _frames(150)
	await _frames(60)
	combat.set_physics_process(false)
	projectiles.spawned_projectile.disconnect(on_spawn)
	for w: Node in _pdcs():
		w.shot.disconnect(on_shot)
	var one_each: bool = shots.all(func(s: Dictionary) -> bool: return spawned.has(s.id)) and spawned.size() == shots.size()
	var max_dev := 0.0
	var deviations := {}
	var values_ok := true
	for s: Dictionary in shots:
		var r: Dictionary = spawned.get(s.id, {})
		if r.is_empty():
			continue
		var dev := _angle(-(s.origin as Transform3D).basis.z, r.velocity)
		max_dev = maxf(max_dev, dev)
		deviations[snappedf(dev, 0.0001)] = true
		values_ok = values_ok and (r.origin as Vector3).is_equal_approx((s.origin as Transform3D).origin) and r.damage == 0.2 and r.penetration == 1.0 \
			and r.armor_damage == 0.0 and absf((r.velocity as Vector3).length() - 70.0) < 0.001 and r.style == &"tracer"
	var own_hits: Array = projectiles.records.filter(func(r: Dictionary) -> bool: return spawned.has(r.id) and r.ship == "FF01")
	_check("%d defensive shots, each exactly one physical projectile (%d spawned) at its muzzle with the Kestrel values" % [shots.size(), spawned.size()],
		one_each and values_ok and shots.size() >= 6)
	_check("live projectile velocity deviates from the barrel by at most 2.5 deg (max %.4f deg, %d distinct deviations)" % [max_dev, deviations.size()],
		max_dev <= 2.5 + ANGLE_EPS and max_dev > 0.1 and deviations.size() > shots.size() / 2)
	_check("muzzle clearance during firing: no Kestrel round hit FF-01's own hull (%d)" % own_hits.size(), own_hits.is_empty())
	CombatShip.of(ff01).health = CombatShip.of(ff01).max_health
	CombatShip.of(ff01).armor = CombatShip.of(ff01).max_armor
	_clear_flight()


# --- S: throughput measurements -------------------------------------------------------

# One run (A, B): `count` missiles launched APPROACH u out on APPROACH_BEARING, `spacing` s
# apart, offset laterally by `lateral` u each, at FF-01; the four Kestrels seeded with `seed`.
func _run_salvo(seed: int, count: int, spacing: float, lateral: Array) -> Dictionary:
	var launches: Array = []
	for k in count:
		launches.append({"bearing": APPROACH_BEARING, "distance": APPROACH, "lateral": float(lateral[k]), "frame": k * roundi(spacing * 60.0), "target": ff01})
	return await _run_launches(seed, launches)


# One run: each launch {bearing (deg from FF-01's bow), distance (u from FF-01), lateral (u,
# beside the launch axis), frame (tick of launch), target (ship)} is a missile launched at
# its target from that point; the four Kestrels seeded with `seed`; HostileDestroyer (the
# owner, for faction-shared contact) parked 10 u behind the first launch point. Every tick
# each live missile is classified per enabled mount (read-only: range, arc, engageability,
# the mount's own target, reload, alignment) for the miss causes. Returns the observations.
func _run_launches(seed: int, launches: Array) -> Dictionary:
	_clear_flight()
	_home("S")
	_reset_pdcs(seed)
	var combat = CombatShip.of(ff01)
	combat.health = combat.max_health
	combat.armor = combat.max_armor
	var lead: Dictionary = launches[0]
	_place(hostile, _bearing_point(lead.bearing, lead.distance + 10.0), deg_to_rad(lead.bearing + 180.0))
	await physics_frame
	scene.sensors.evaluate()
	var round_ids := {}
	var on_spawn := func(record: Dictionary) -> void:
		if record.owner_name == "FF01":
			round_ids[record.id] = true
	projectiles.spawned_projectile.connect(on_spawn)
	var pdcs := _pdcs()
	var at_missile := {} # missile id -> rounds fired at it
	var on_shot := func(_w: Node, _id: int, target: Node3D, _o: Transform3D) -> void:
		if target != null and is_instance_valid(target) and target.get("id") != null:
			at_missile[target.id] = at_missile.get(target.id, 0) + 1
	for w: Node in pdcs:
		w.shot.connect(on_shot)
	combat.set_physics_process(true)
	var ids: Array = []
	var targets := {}
	var diag := {} # missile id -> {in_range, arc, blocked, busy, reloading, tracking, empty} mount-ticks
	var last_frame: int = launches.reduce(func(m: int, l: Dictionary) -> int: return maxi(m, l.frame), 0)
	var frame := 0
	while frame <= last_frame + 600:
		for l: Dictionary in launches:
			if l.frame == frame:
				var at := _bearing_point(l.bearing, l.distance)
				var aim: Vector3 = l.target.global_position
				var axis := (Vector3(aim.x, 0.0, aim.z) - Vector3(at.x, 0.0, at.y)).normalized()
				var from := Vector3(at.x, ff01.global_position.y, at.y) + axis.cross(Vector3.UP) * float(l.lateral)
				var id: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(axis, Vector3.UP), from), MISSILE, l.target)
				ids.append(id)
				targets[id] = l.target
				diag[id] = {"in_range": 0, "arc": 0, "blocked": 0, "busy": 0, "reloading": 0, "tracking": 0, "empty": 0}
		await physics_frame
		frame += 1
		for node in projectiles.ordnance:
			if not diag.has(node.id) or not node.live:
				continue
			var d: Dictionary = diag[node.id]
			for w: Node in pdcs:
				if not w.enabled or w.pitch_pivot.global_position.distance_to(node.global_position) > KESTREL.weapon_range:
					continue
				d.in_range += 1
				var angles: Vector2 = w.angles_to(node.global_position)
				if absf(angles.x) > deg_to_rad(w.yaw_limit_deg()) or angles.y < deg_to_rad(w.pitch_min_deg()) or angles.y > deg_to_rad(w.pitch_max_deg()):
					d.arc += 1
				elif not w.engageable(node):
					d.blocked += 1 # In range and arc, but no intercept inside the range or the line is obstructed.
				elif w.rounds_left() <= 0:
					d.empty += 1
				elif w.reloading():
					d.reloading += 1
				elif w.defense_target != node:
					d.busy += 1
				elif w.reason.contains("Tracking (") or w.reason.contains("Aligning ("):
					d.tracking += 1
		if frame > last_frame and ids.all(func(id: int) -> bool: return not _ordnance_record(id).is_empty()):
			break
	await _frames(30)
	combat.set_physics_process(false)
	projectiles.spawned_projectile.disconnect(on_spawn)
	for w: Node in pdcs:
		w.shot.disconnect(on_shot)
	var outcomes := {}
	var distances: Array = []
	var target_distances: Array = []
	var misses: Array = []
	for id: int in ids:
		var r := _ordnance_record(id)
		var outcome: String = r.get("outcome", "live")
		outcomes[outcome] = outcomes.get(outcome, 0) + 1
		if outcome == "intercepted":
			distances.append(snappedf(Vector2(r.point.x, r.point.z).distance_to(site), 0.1))
			var t: Node3D = targets[id]
			target_distances.append(snappedf(Vector2(r.point.x, r.point.z).distance_to(Vector2(t.global_position.x, t.global_position.z)), 0.1))
		else:
			misses.append(_miss_causes(id, outcome, diag[id], at_missile.get(id, 0)))
	var intercept_rounds := 0
	for r: Dictionary in projectiles.records:
		if round_ids.has(r.id) and r.outcome == "intercept":
			intercept_rounds += 1
	var per_mount := pdcs.map(func(w: Node) -> int: return KESTREL.ammunition - w.rounds_left())
	var fired := pdcs.map(func(w: Node) -> int: return w.shots)
	var result := {"intercepted": outcomes.get("intercepted", 0), "hit": outcomes.get("damage", 0), "outcomes": outcomes,
		"distances": distances, "target_distances": target_distances, "rounds": round_ids.size(), "fired": fired, "ammo": per_mount,
		"intercept_rounds": intercept_rounds, "misses": misses, "hull_lost": snappedf(combat.max_health - combat.health, 0.01)}
	combat.health = combat.max_health
	combat.armor = combat.max_armor
	for t: Node3D in targets.values():
		CombatShip.of(t).health = CombatShip.of(t).max_health
		CombatShip.of(t).armor = CombatShip.of(t).max_armor
	_clear_flight()
	return result


# Why a missile was not intercepted, from its per-mount-tick classification: never in range
# of any mount, outside the arcs, no solution / obstructed, mounts on other threats
# (saturation), reloading, empty, still aligning (tracking), or rounds fired that all missed
# (dispersion and lead). Several causes can apply; each is listed with its mount-ticks.
static func _miss_causes(id: int, outcome: String, d: Dictionary, rounds: int) -> String:
	var causes: Array[String] = []
	if d.in_range == 0:
		causes.append("range (never within 25 u of a mount)")
	for key: String in ["arc", "blocked", "busy", "reloading", "empty", "tracking"]:
		if d[key] > 0:
			var label: String = {"arc": "firing arc", "blocked": "no solution / obstructed", "busy": "mount on another threat",
				"reloading": "reloading", "empty": "out of ammunition", "tracking": "tracking (aligning)"}[key]
			causes.append("%s %d" % [label, d[key]])
	if rounds > 0:
		causes.append("dispersion / lead: %d rounds fired at it, none hit" % rounds)
	return "missile %d %s: %s (in range %d mount-ticks)" % [id, outcome, ", ".join(causes) if not causes.is_empty() else "no cause recorded", d.in_range]


func _throughput() -> void:
	print("\n=== S interception throughput (observations; seeds %s; missiles from %.0f u on bearing %.0f deg, FF-01 stationary, four Kestrels)" % [str(SEEDS), APPROACH, APPROACH_BEARING])
	print("  Scenario A: one missile")
	var a_intercepted := 0
	var a_rounds := 0
	var consistent := true
	var first: Dictionary = {}
	for seed: int in SEEDS:
		var r: Dictionary = await _run_salvo(seed, 1, 0.0, [0.0])
		if seed == SEEDS[0]:
			first = r
		a_intercepted += r.intercepted
		a_rounds += r.rounds
		consistent = consistent and r.rounds == (r.ammo as Array).reduce(func(n: int, x: int) -> int: return n + x, 0) and r.intercept_rounds == r.intercepted
		print("    seed %d: %s, intercept distance %s u, rounds fired %d (per mount %s), ammunition used %s, hull lost %.2f" % [seed,
			"intercepted" if r.intercepted == 1 else str(r.outcomes), str(r.distances), r.rounds, str(r.fired), str(r.ammo), r.hull_lost])
	print("    A total: %d of %d intercepted, %.1f rounds per missile" % [a_intercepted, SEEDS.size(), float(a_rounds) / SEEDS.size()])
	var repeat: Dictionary = await _run_salvo(SEEDS[0], 1, 0.0, [0.0])
	_check("Scenario A repeatable: seed %d gives the same result twice" % SEEDS[0], repeat == first)
	print("  Scenario B: four-missile salvo (0.2 s apart, lateral offsets -1.8 / -0.6 / 0.6 / 1.8 u)")
	var b_intercepted := 0
	var b_hit := 0
	var b_rounds := 0
	for seed: int in SEEDS:
		var r: Dictionary = await _run_salvo(seed, 4, 0.2, [-1.8, -0.6, 0.6, 1.8])
		b_intercepted += r.intercepted
		b_hit += r.hit
		b_rounds += r.rounds
		consistent = consistent and r.rounds == (r.ammo as Array).reduce(func(n: int, x: int) -> int: return n + x, 0) and r.intercept_rounds == r.intercepted
		print("    seed %d: intercepted %d, hit %d %s, distances %s u, rounds %d, ammunition per mount %s, hull lost %.2f" % [seed, r.intercepted, r.hit,
			str(r.outcomes), str(r.distances), r.rounds, str(r.ammo), r.hull_lost])
	print("    B total: %d intercepted, %d hits of %d missiles; %.1f rounds per salvo" % [b_intercepted, b_hit, 4 * SEEDS.size(), float(b_rounds) / SEEDS.size()])
	# D: one missile at an ally 20 u ahead of FF-01, launched from bearing 120 deg: it crosses
	# FF-01's starboard coverage obliquely (closest approach about 15 u). The ally's own
	# weapons are not stepped, so only FF-01's Kestrels defend.
	var ally := scene.get_node("Ships/Gunship") as Node3D
	_place(ally, _bearing_point(0.0, 20.0))
	var d_runs: Array = []
	for seed: int in SEEDS:
		d_runs.append(await _run_launches(seed, [{"bearing": 120.0, "distance": APPROACH, "lateral": 0.0, "frame": 0, "target": ally}]))
	var d_repeat: Dictionary = await _run_launches(SEEDS[0], [{"bearing": 120.0, "distance": APPROACH, "lateral": 0.0, "frame": 0, "target": ally}])
	_place(ally, site + Vector2(-150, 0) if site.x > 0.0 else site + Vector2(150, 0))
	consistent = _report("Scenario D: one missile crossing obliquely (from 120 deg at the ally 20 u ahead; distances from FF-01 / from the ally)", d_runs, 1, true) and consistent
	_check("Scenario D repeatable: seed %d gives the same result twice" % SEEDS[0], d_repeat == d_runs[0])
	# E: two pairs from two bearings (40 deg forward-starboard, 220 deg aft-port), each pair 0.2 s apart.
	var e_runs: Array = []
	for seed: int in SEEDS:
		e_runs.append(await _run_launches(seed, [
			{"bearing": 40.0, "distance": APPROACH, "lateral": -0.6, "frame": 0, "target": ff01},
			{"bearing": 220.0, "distance": APPROACH, "lateral": -0.6, "frame": 0, "target": ff01},
			{"bearing": 40.0, "distance": APPROACH, "lateral": 0.6, "frame": 12, "target": ff01},
			{"bearing": 220.0, "distance": APPROACH, "lateral": 0.6, "frame": 12, "target": ff01}]))
	consistent = _report("Scenario E: four missiles from two bearings (40 and 220 deg, two each, 0.2 s apart)", e_runs, 4) and consistent
	# F: one missile from each of four distributed bearings, launched 0.05 s apart (overlapping arrivals).
	var f_runs: Array = []
	for seed: int in SEEDS:
		f_runs.append(await _run_launches(seed, [
			{"bearing": 20.0, "distance": APPROACH, "lateral": 0.0, "frame": 0, "target": ff01},
			{"bearing": 110.0, "distance": APPROACH, "lateral": 0.0, "frame": 3, "target": ff01},
			{"bearing": 200.0, "distance": APPROACH, "lateral": 0.0, "frame": 6, "target": ff01},
			{"bearing": 290.0, "distance": APPROACH, "lateral": 0.0, "frame": 9, "target": ff01}]))
	consistent = _report("Scenario F: four missiles from four bearings (20 / 110 / 200 / 290 deg, 0.05 s apart)", f_runs, 4) and consistent
	_check("every observed interception was made by exactly one round, and rounds fired equal ammunition consumed", consistent)
	await _scenario_c()


# Prints one line per seed (outcomes, mounts that fired, rounds per mount, interception
# distances, miss causes) and the totals; returns whether every run's rounds equal its
# ammunition used and each interception took exactly one round.
func _report(title: String, runs: Array, per_run: int, with_target := false) -> bool:
	print("  " + title)
	var short := ["FP", "FS", "AP", "AS"]
	var intercepted := 0
	var hits := 0
	var rounds := 0
	var mount_totals := [0, 0, 0, 0]
	var ok := true
	for i in runs.size():
		var r: Dictionary = runs[i]
		intercepted += r.intercepted
		hits += r.hit
		rounds += r.rounds
		var firing: Array[String] = []
		for m in 4:
			mount_totals[m] += r.ammo[m]
			if r.fired[m] > 0:
				firing.append("%s %d" % [short[m], r.fired[m]])
		ok = ok and r.rounds == (r.ammo as Array).reduce(func(n: int, x: int) -> int: return n + x, 0) and r.intercept_rounds == r.intercepted
		print("    seed %d: intercepted %d, impacts %d %s; fired: %s; rounds %d; intercept distance %s u%s" % [SEEDS[i], r.intercepted, r.hit, str(r.outcomes),
			", ".join(firing) if not firing.is_empty() else "none", r.rounds, str(r.distances), " / %s u" % str(r.target_distances) if with_target else ""])
		for line: String in r.misses:
			print("      " + line)
	print("    total: %d intercepted, %d impacts of %d missiles; %d rounds (FP %d, FS %d, AP %d, AS %d), %.1f per run" % [intercepted, hits, per_run * runs.size(),
		rounds, mount_totals[0], mount_totals[1], mount_totals[2], mount_totals[3], float(rounds) / runs.size()])
	return ok


# Scenario C: two mounts engage the same torpedo on their own, both spending rounds.
func _scenario_c() -> void:
	print("  Scenario C: two independent mounts, one torpedo on the starboard beam")
	var lines: Array[String] = []
	var both_all := true
	for seed: int in SEEDS.slice(0, 4):
		_clear_flight()
		_reset_pdcs(seed)
		for w: Node in _pdcs():
			w.enabled = w == _pdc("ForwardStarboardPDCHardpoint") or w == _pdc("AftStarboardPDCHardpoint")
		var fs: Node = _pdc("ForwardStarboardPDCHardpoint")
		var as_: Node = _pdc("AftStarboardPDCHardpoint")
		var at := {}
		var on_shot := func(w: Node, _id: int, target: Node3D, _o: Transform3D) -> void:
			at[w] = at.get(w, {})
			at[w][target] = at[w].get(target, 0) + 1
		fs.shot.connect(on_shot)
		as_.shot.connect(on_shot)
		var t_id: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3.LEFT), _at(Vector2(34, 0))), TORPEDO, ff01)
		var torpedo := _ordnance(t_id)
		var combat = CombatShip.of(ff01)
		combat.set_physics_process(true)
		for i in 400:
			await physics_frame
			if not _ordnance_record(t_id).is_empty():
				break
		combat.set_physics_process(false)
		fs.shot.disconnect(on_shot)
		as_.shot.disconnect(on_shot)
		var fs_n: int = at.get(fs, {}).get(torpedo, 0)
		var as_n: int = at.get(as_, {}).get(torpedo, 0)
		var used := [KESTREL.ammunition - fs.rounds_left(), KESTREL.ammunition - as_.rounds_left()]
		both_all = both_all and fs_n > 0 and as_n > 0 and used == [fs_n, as_n]
		lines.append("seed %d: forward-starboard %d, aft-starboard %d rounds at the same torpedo (%s), ammunition used %s" % [seed, fs_n, as_n,
			_ordnance_record(t_id).get("outcome", "live"), str(used)])
		combat.health = combat.max_health
		combat.armor = combat.max_armor
	for l in lines:
		print("    " + l)
	_check("Scenario C: both mounts fired at the same torpedo in every seed and each spent its own rounds", both_all)
	_clear_flight()
	_reset_pdcs(1)


# --- O: offensive fire and armor ------------------------------------------------------

func _offense() -> void:
	print("\n=== O physical Kestrel rounds against a fresh hostile FF-01 (Bastions disabled for the measurement)")
	_home("O")
	_place(hostile, site + Vector2(250, 0) if site.x < 0 else site - Vector2(250, 0))
	var victim: Node3D = UNIT.instantiate()
	victim.name = "HostileFF01"
	victim.get_node("Combat").faction = HOSTILE
	scene.get_node("Ships").add_child(victim)
	scene.register_ship(victim)
	victim.get_node("Combat").set_physics_process(false)
	victim.get_node("Behavior").set_physics_process(false)
	_place(victim, _bearing_point(90.0, 20.0))
	await physics_frame
	var target = CombatShip.of(victim)
	_check("fresh hostile FF-01: hull 160, armor 100 / 100, resistance 30", target.health == 160.0 and target.armor == 100.0
		and target.max_armor == 100.0 and target.armor_resistance == 30.0)
	var events: Array = []
	target.damaged.connect(func(amount: float, id: int) -> void: events.append([amount, id, target.health, target.armor]))
	_reset_pdcs(11)
	for name: String in BASTIONS:
		ff01.get_node("Weapons/%s" % name).weapon().enabled = false
	var fs: Node = _pdc("ForwardStarboardPDCHardpoint")
	var shot_ticks: Array = []
	var tick := {"n": 0}
	fs.shot.connect(func(_w: Node, _id: int, _t: Node3D, _o: Transform3D) -> void: shot_ticks.append(tick.n))
	var combat = CombatShip.of(ff01)
	combat.stance = CombatShip.Stance.AGGRESSIVE
	scene.sensors.evaluate()
	combat.assign_target(victim)
	combat.set_physics_process(true)
	for i in 8 * 60:
		await physics_frame
		tick.n += 1
	combat.set_physics_process(false)
	await _frames(30)
	var expected := 0.2 * 1.0 / (1.0 + 30.0)
	var agree := events.all(func(e: Array) -> bool: return absf(e[0] - expected) < 1e-12 and e[3] == 100.0)
	var first: Array = events[0] if not events.is_empty() else [0.0, -1, 0.0, 0.0]
	_check("first physical Kestrel round: hull damage %.10f (0.2 x 1 / (1 + 30) = 0.0064516129), armor %.1f" % [first[0], first[3]],
		absf(first[0] - 0.0064516129) < 1e-10 and first[3] == 100.0)
	_check("all %d impacts follow the shared formula at full armor; armor condition stays exactly 100 (now %.6f)" % [events.size(), target.armor],
		agree and events.size() >= 20 and target.armor == 100.0)
	var ids := {}
	for e: Array in events:
		ids[e[1]] = ids.get(e[1], 0) + 1
	_check("each round damaged at most once (%d events from %d rounds; damage_events all 1)" % [events.size(), ids.size()],
		ids.values().all(func(n: int) -> bool: return n == 1) and ids.keys().all(func(id: int) -> bool: return projectiles.damage_events.get(id, 0) == 1))
	_check("hull after %d hits: %.6f (160 - n x 0.0064516129)" % [events.size(), target.health], absf(target.health - (160.0 - events.size() * expected)) < 1e-9)
	var gaps := []
	for i in range(1, shot_ticks.size()):
		gaps.append(shot_ticks[i] - shot_ticks[i - 1])
	var reload_gap: int = gaps.max() if not gaps.is_empty() else 0
	var before_reload := gaps.find(reload_gap) + 1
	print("  forward-starboard: %d rounds in 8 s, %d before the first reload, longest gap %d ticks" % [shot_ticks.size(), before_reload, reload_gap])
	_check("magazine and reload apply to offense: 40 rounds, then a 3 s reload (gap %.2f s), then fire resumes (%d rounds in 8 s)" % [reload_gap / 60.0, shot_ticks.size()],
		before_reload == 40 and reload_gap >= 180 and reload_gap <= 186 and shot_ticks.size() > 40)
	# Armor condition zero: the full 0.2.
	target.armor = 0.0
	var count := events.size()
	combat.set_physics_process(true)
	await _frames(90)
	combat.set_physics_process(false)
	await _frames(30)
	var later := events.slice(count)
	_check("armor condition 0: each round delivers the full 0.2 hull damage (%d impacts)" % later.size(),
		not later.is_empty() and later.all(func(e: Array) -> bool: return absf(e[0] - 0.2) < 1e-12))
	var own: Array = projectiles.records.filter(func(r: Dictionary) -> bool: return r.owner_name == "FF01" and r.ship == "FF01")
	_check("no Kestrel round hit the firing FF-01", own.is_empty())
	combat.clear_target()
	_clear_flight()
