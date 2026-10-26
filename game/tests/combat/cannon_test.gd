extends SceneTree
## Cannon family: NC-90 Bastion configuration, physical dispersion (Weapon.disperse), the
## two Bastions on FF-01 (installation, geometry, mechanical coverage, live tracking and
## firing on both broadsides, ahead and astern) and physical Bastion shells against a fresh
## hostile FF-01 through the shared armor pipeline.
## Run: <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/cannon_test.gd

const ARENA := preload("res://game/scenes/combat_test.tscn")
const UNIT := preload("res://game/ships/ff01_unit.tscn")
const NC90 := preload("res://game/weapons/nc90_bastion.tres")
const NC90_SCENE := preload("res://game/weapons/nc90_bastion.tscn")
const CANNON := preload("res://game/weapons/cannon.tres")
const Weapon := preload("res://game/weapons/weapon.gd")
const Turret := preload("res://game/weapons/turret.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const BASTIONS := ["ForwardBastionHardpoint", "AftBastionHardpoint"]
const EMPTY := ["BarrageHardpoint", "WayfarerHardpoint"]
const PDC_MOUNTS := ["ForwardPortPDCHardpoint", "ForwardStarboardPDCHardpoint", "AftPortPDCHardpoint", "AftStarboardPDCHardpoint"]
const RANGE := 40.0 # u, test target distance (inside the 45 u effective range)
const EPS := 0.000001
const ANGLE_EPS := 0.0005 # deg, float32 direction tolerance
const HOSTILE := 1

var scene: Node3D
var ff01: Node3D
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
	_lead()
	await _coverage()
	await _live_fire()
	await _armor_sequence()
	scene.free()
	await process_frame
	_check("no orphan nodes after the cannon verification", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(message: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-116s %s" % [message, "PASS" if ok else "FAIL"])


# --- C: configuration ---------------------------------------------------------------

func _configuration() -> void:
	print("\n=== C NC-90 Bastion configuration")
	var c := NC90
	_check("nc90_bastion.tres loads: NC-90 Bastion, family cannon, size medium",
		c != null and c.display_name == "NC-90 Bastion" and c.family == &"cannon" and c.size == 1)
	_check("damage 12, penetration 20 (explicitly configured), armor damage 6",
		c.damage == 12.0 and c.has_penetration and c.penetration == 20.0 and c.resolved_penetration() == 20.0 and c.armor_damage == 6.0)
	_check("interval 2.5 s, 40 rounds, no magazine, shell at 40 u/s, range 75 u, effective range 45 u",
		c.cooldown == 2.5 and c.ammunition == 40 and c.magazine_size == 0 and c.projectile_speed == 40.0
		and c.weapon_range == 75.0 and c.effective_range == 45.0 and c.effective() == 45.0 and c.projectile_style == &"shell")
	_check("tracking yaw 60 deg/s, pitch 40 deg/s; dispersion 0.5 deg",
		c.yaw_speed_deg == 60.0 and c.pitch_speed_deg == 40.0 and c.dispersion_max_deg == 0.5)
	_check("full lead to the maximum range: lead_quality_at_max 1.0; travel factor 1.25, lifetime 2.5 s, alignment 3 deg",
		c.lead_quality_at_max == 1.0 and [30.0, 45.0, 46.0, 60.0, 75.0].all(func(d: float) -> bool: return c.lead_quality(d) == 1.0)
		and c.travel_factor == 1.25 and c.projectile_lifetime == 2.5 and c.alignment_tolerance_deg == 3.0)
	var scene_root := NC90_SCENE.instantiate()
	_check("nc90_bastion.tscn: Cannon-family turret script with the NC-90 configuration and editable geometry",
		scene_root.get_script() == Turret and scene_root.config == NC90 and scene_root.base_diameter == 0.5
		and scene_root.body_height == 0.25 and scene_root.barrel_length == 0.75)
	scene_root.free()
	_check("cannon.tres unchanged: damage 12, cooldown 2.5, range 75, stock 40, penetration unconfigured, armor damage 0, dispersion 0",
		CANNON.damage == 12.0 and CANNON.cooldown == 2.5 and CANNON.weapon_range == 75.0 and CANNON.ammunition == 40
		and not CANNON.has_penetration and CANNON.armor_damage == 0.0 and CANNON.dispersion_max_deg == 0.0)


# --- D: dispersion ------------------------------------------------------------------

static func _angle(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.angle_to(b))


func _dispersion() -> void:
	print("\n=== D dispersion (Weapon.disperse)")
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var state_before := rng.state
	var axis := Vector3(0.3, -0.05, -1.0).normalized()
	_check("zero dispersion returns the firing direction unchanged and draws no random number",
		Weapon.disperse(axis, 0.0, rng) == axis and rng.state == state_before)
	var samples := 20000
	var max_angle := 0.0
	var sum := 0.0
	var inner := 0
	var quadrants := [0, 0, 0, 0]
	var u := axis.cross(Vector3.UP).normalized()
	var v := axis.cross(u)
	var unit_length := true
	var seen := {}
	for i in samples:
		var d := Weapon.disperse(axis, 0.5, rng)
		var angle := _angle(axis, d)
		max_angle = maxf(max_angle, angle)
		sum += angle
		if angle <= 0.25:
			inner += 1
		var q := (0 if d.dot(u) >= 0.0 else 1) + (0 if d.dot(v) >= 0.0 else 2)
		quadrants[q] += 1
		unit_length = unit_length and absf(d.length() - 1.0) < 0.00001
		if i < 1000:
			seen[d] = true
	var mean := sum / samples
	var inner_share := float(inner) / samples
	print("  %d samples: max %.5f deg, mean %.5f deg (uniform-over-solid-angle expectation ~0.33333), share within 0.25 deg %.4f (expectation ~0.25), quadrants %s"
		% [samples, max_angle, mean, inner_share, str(quadrants)])
	_check("every direction stays within the 0.5 deg half-angle cone (max %.5f deg) and keeps unit length" % max_angle, max_angle <= 0.5 + ANGLE_EPS and unit_length)
	_check("uniform over the cone's solid angle: mean %.4f within 0.333 +/- 0.01, share within 0.25 deg %.4f within 0.25 +/- 0.015" % [mean, inner_share],
		absf(mean - 1.0 / 3.0) < 0.01 and absf(inner_share - 0.25) < 0.015)
	_check("azimuth uniform: each quadrant %s within 25%% +/- 1.5%%" % str(quadrants),
		quadrants.all(func(n: int) -> bool: return absf(float(n) / samples - 0.25) < 0.015))
	_check("different samples give different directions (%d distinct of 1000)" % seen.size(), seen.size() == 1000)
	var first := _sequence(12345, axis)
	var again := _sequence(12345, axis)
	var other := _sequence(54321, axis)
	_check("the same seed reproduces the same sequence; another seed gives another", first == again and first != other)
	var bound := true
	for direction: Vector3 in [Vector3.FORWARD, Vector3.UP, Vector3(1, 0, 0), Vector3(-0.6, 0.0, 0.8)]:
		for i in 500:
			bound = bound and _angle(direction, Weapon.disperse(direction, 0.5, rng)) <= 0.5 + ANGLE_EPS
	_check("bounded for any axis (forward, vertical, lateral, diagonal)", bound)


static func _sequence(seed: int, axis: Vector3) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out := []
	for i in 50:
		out.append(Weapon.disperse(axis, 0.5, rng))
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
	for i in 3:
		await physics_frame
	site = _clear_site()
	_place(ff01, site)
	await physics_frame
	_check("test site (%.0f, %.0f) clear of asteroids and ships; FF-01 placed there with its bow along -Z" % [site.x, site.y],
		Vector2(ff01.global_position.x, ff01.global_position.z).distance_to(site) < 0.01 and ff01.global_basis.z.is_equal_approx(Vector3.BACK))


# A point in the sector with clear lines to every test target: no asteroid within the
# 40 u ring (plus margins), far from the other ships.
func _clear_site() -> Vector2:
	var asteroids: Node = scene.get_node("Asteroids")
	var others: Array = scene.get_node("Ships").get_children().filter(func(s: Node) -> bool: return s != ff01)
	for x in range(-320, 321, 20):
		for z in range(-320, 321, 20):
			var point := Vector2(x, z)
			var ok := others.all(func(s: Node3D) -> bool: return Vector2(s.global_position.x, s.global_position.z).distance_to(point) > 90.0)
			for id: int in asteroids.ids():
				var c: Vector3 = asteroids.center(id)
				ok = ok and Vector2(c.x, c.z).distance_to(point) > RANGE + asteroids.radius(id) + 12.0
				if not ok:
					break
			if ok:
				return point
	return Vector2(-300, 300)


func _place(ship: Node3D, at: Vector2, heading := 0.0) -> void:
	ship.get_node("Locomotion").place(at, heading)
	ship.get_node("Avoidance").reset()


# Planar point at `bearing` (deg clockwise from FF-01's bow, -Z; +90 = starboard, +X).
func _bearing(bearing: float, distance := RANGE) -> Vector2:
	var b := deg_to_rad(bearing)
	return site + Vector2(sin(b), -cos(b)) * distance


func _bastion(mount: String) -> Node:
	return ff01.get_node("Weapons/%s" % mount).weapon()


# --- E: installation and geometry ----------------------------------------------------

func _installation() -> void:
	print("\n=== E FF-01 installation")
	var combat = CombatShip.of(ff01)
	var installed := true
	for mount_name: String in BASTIONS:
		var mount := ff01.get_node("Weapons/%s" % mount_name)
		var weapon: Node = mount.weapon()
		installed = (installed and weapon != null and mount.get_child_count() == 1 and weapon.scene_file_path == NC90_SCENE.resource_path
			and weapon.config == NC90 and weapon.transform.is_equal_approx(Transform3D.IDENTITY) and mount.accepts(weapon.config)
			and weapon.hardpoint == mount and weapon.yaw_limit_deg() == 120.0 and combat.weapons.has(weapon))
	_check("two NC-90 Bastions: one on each centerline hardpoint, at identity, accepted, hardpoint limits +/-120 deg (plus four Kestrels)", installed
		and combat.weapons.size() == 6 and combat.incompatible.is_empty())
	var fwd := ff01.get_node("Weapons/ForwardBastionHardpoint")
	var aft := ff01.get_node("Weapons/AftBastionHardpoint")
	_check("hardpoints unchanged: forward (0, 0.55, -3) yaw 0, aft (0, 0.55, 3) yaw 180",
		fwd.position.is_equal_approx(Vector3(0, 0.55, -3)) and fwd.basis.is_equal_approx(Basis.IDENTITY)
		and aft.position.is_equal_approx(Vector3(0, 0.55, 3)) and aft.basis.is_equal_approx(Basis(Vector3.UP, PI)))
	_check("Barrage and Wayfarer stay empty; the four PDC hardpoints carry PDC-20 Kestrels (pdc_test)", EMPTY.all(func(n: String) -> bool:
		return ff01.get_node("Weapons/%s" % n).get_child_count() == 0 and ff01.get_node("Weapons/%s" % n).weapon() == null)
		and PDC_MOUNTS.all(func(n: String) -> bool: return ff01.get_node("Weapons/%s" % n).weapon().config.display_name == "PDC-20 Kestrel"))
	var separate: bool = _bastion(BASTIONS[0]).config == _bastion(BASTIONS[1]).config and _bastion(BASTIONS[0]).rounds_left() == 40 and _bastion(BASTIONS[1]).rounds_left() == 40
	_check("both share the one NC-90 configuration with their own 40-round stock", separate)


func _geometry() -> void:
	print("\n=== E geometry (one muzzle per cannon, clear of the hull)")
	var combat = CombatShip.of(ff01)
	var to_ship: Transform3D = ff01.global_transform.affine_inverse()
	for mount_name: String in BASTIONS:
		var weapon: Node = _bastion(mount_name)
		var meshes := weapon.find_children("*", "MeshInstance3D", true, false)
		var muzzles := weapon.find_children("*", "Marker3D", true, false)
		var neutral := true
		for mesh: MeshInstance3D in meshes:
			var color: Color = (mesh.mesh as PrimitiveMesh).material.albedo_color
			neutral = neutral and absf(color.r - color.b) < 0.03 and absf(color.r - color.g) < 0.03
		var clear := true
		var heights := []
		for yaw_deg: float in [-120.0, -90.0, -45.0, 0.0, 45.0, 90.0, 120.0]:
			weapon.yaw_pivot.rotation = Vector3(0, deg_to_rad(yaw_deg), 0)
			weapon.pitch_pivot.rotation = Vector3.ZERO
			var muzzle: Vector3 = to_ship * weapon.muzzle.global_position
			var pivot: Vector3 = to_ship * weapon.pitch_pivot.global_position
			heights.append(snappedf(muzzle.y, 0.001))
			for box: AABB in combat.hitboxes:
				clear = clear and not box.has_point(muzzle)
			clear = clear and combat.segment_fraction(weapon.pitch_pivot.global_position, weapon.muzzle.global_position) < 0.0
			# A 40 u level shot from the muzzle does not cross the own hull.
			var far: Vector3 = weapon.muzzle.global_position - weapon.muzzle.global_basis.z * RANGE
			clear = clear and combat.segment_fraction(weapon.muzzle.global_position, far) < 0.0
		weapon.yaw_pivot.rotation = Vector3(0, weapon.yaw, 0)
		weapon.pitch_pivot.rotation = Vector3(weapon.pitch, 0, 0)
		_check("%s: %d visible meshes in neutral gray, exactly one muzzle; muzzle %.2f u above the hull top and clear of the hull at yaw -120..120 deg"
			% [mount_name, meshes.size(), heights[0] - 0.55], meshes.size() >= 4 and muzzles.size() == 1 and muzzles[0] == weapon.muzzle and neutral and clear)


# --- L: predictive lead -------------------------------------------------------------

# The forward Bastion's fire-control solution (Weapon._solve_for) for a target crossing
# the broadside at 8 u/s, inside and beyond the 45 u effective range up to 75 u: the full
# lead (aim = position + velocity × intercept time) and an exact straight-line intercept.
func _lead() -> void:
	print("\n=== L predictive lead (forward Bastion fire control)")
	var weapon: Node = _bastion(BASTIONS[0])
	var origin: Vector3 = weapon.muzzle.global_position
	var lines: Array[String] = []
	var ok := true
	# Crossing at 8 u/s (the aim point stays inside 75 u up to about 73 u), then 75 u closing
	# diagonally at 8 u/s.
	for row: Array in [[30.0, Vector3(0, 0, -8)], [45.0, Vector3(0, 0, -8)], [50.0, Vector3(0, 0, -8)], [60.0, Vector3(0, 0, -8)],
			[72.0, Vector3(0, 0, -8)], [75.0, Vector3(4, 0, -4) * sqrt(2.0)]]:
		var distance: float = row[0]
		var velocity: Vector3 = row[1]
		var position := origin + Vector3(-distance, 0, 0)
		var solved: bool = weapon._solve_for(position, velocity)
		var expected: Vector3 = position + velocity * weapon.flight_time
		var intercept_error := absf(origin.distance_to(weapon.aim_point) - NC90.projectile_speed * weapon.flight_time)
		ok = ok and solved and weapon.lead_factor == 1.0 and weapon.aim_point.is_equal_approx(expected) and intercept_error < 0.001 \
			and origin.distance_to(weapon.aim_point) <= NC90.weapon_range
		lines.append("%.0f u: t %.3f s, lead %.2f u, factor %.2f" % [distance, weapon.flight_time, weapon.aim_point.distance_to(position), weapon.lead_factor])
	print("  " + "; ".join(lines))
	_check("full lead inside and beyond 45 u up to 75 u: factor 1.0, aim = position + velocity x time, shell meets the aim point within range", ok)
	weapon.has_solution = false


# --- F: mechanical coverage -----------------------------------------------------------

func _target() -> Node3D:
	return scene.get_node("Ships/HostileGunship") as Node3D


func _aim_at(bearing: float) -> Node3D:
	var target := _target()
	_place(target, _bearing(bearing))
	var combat = CombatShip.of(ff01)
	combat.stance = CombatShip.Stance.AGGRESSIVE
	scene.sensors.evaluate()
	combat.assign_target(target)
	return target


func _coverage() -> void:
	print("\n=== F mechanical coverage (Weapon.assess, read-only)")
	var cases := [["ahead", 0.0, true, false], ["50 deg starboard", 50.0, true, false], ["starboard broadside", 90.0, true, true],
		["100 deg starboard", 100.0, true, true], ["130 deg starboard", 130.0, false, true], ["astern", 180.0, false, true],
		["130 deg port", -130.0, false, true], ["port broadside", -90.0, true, true], ["50 deg port", -50.0, true, false]]
	await physics_frame
	for row: Array in cases:
		var target := _aim_at(row[1])
		await physics_frame
		scene.sensors.evaluate()
		var fwd: Dictionary = _bastion(BASTIONS[0]).assess(target)
		var aft: Dictionary = _bastion(BASTIONS[1]).assess(target)
		_check("%s (%.0f u): forward %s (%s), aft %s (%s)" % [row[0], RANGE, "engages" if fwd.capable else "not", fwd.reason, "engages" if aft.capable else "not", aft.reason],
			fwd.capable == row[2] and aft.capable == row[3]
			and (fwd.capable or fwd.reason.begins_with("Outside turret coverage")) and (aft.capable or aft.reason.begins_with("Outside turret coverage")))


# --- G: live tracking and firing ------------------------------------------------------

func _live_fire() -> void:
	print("\n=== G live tracking and firing (Combat.step -> turret -> Projectiles)")
	var combat = CombatShip.of(ff01)
	var projectiles: Node = scene.projectiles
	var spawned := {}
	var record_spawn := func(record: Dictionary) -> void: spawned[record.id] = record.duplicate()
	projectiles.spawned_projectile.connect(record_spawn)
	var shots: Array = []
	for mount_name: String in BASTIONS:
		var weapon: Node = _bastion(mount_name)
		weapon.rng.seed = 7 if mount_name == BASTIONS[0] else 11
		weapon.shot.connect(func(_w: Node, id: int, _t: Node3D, origin: Transform3D) -> void:
			shots.append({"mount": mount_name, "id": id, "origin": origin}))
	combat.set_physics_process(true)
	var limit_ok := true
	for row: Array in [["port broadside", -90.0, true, true], ["starboard broadside", 90.0, true, true], ["ahead", 0.0, true, false], ["astern", 180.0, false, true]]:
		var target := _aim_at(row[1])
		CombatShip.of(target).health = CombatShip.of(target).max_health
		var before := shots.size()
		for i in 600:
			await physics_frame
			for mount_name: String in BASTIONS:
				var weapon: Node = _bastion(mount_name)
				limit_ok = limit_ok and absf(weapon.yaw) <= deg_to_rad(120.0) + EPS
			var fired := shots.slice(before)
			var fwd := fired.filter(func(s: Dictionary) -> bool: return s.mount == BASTIONS[0]).size()
			var aft := fired.filter(func(s: Dictionary) -> bool: return s.mount == BASTIONS[1]).size()
			if row[2] and row[3] and fwd > 0 and aft > 0:
				break
		var fired := shots.slice(before)
		var fwd := fired.filter(func(s: Dictionary) -> bool: return s.mount == BASTIONS[0]).size()
		var aft := fired.filter(func(s: Dictionary) -> bool: return s.mount == BASTIONS[1]).size()
		var blocked: Node = _bastion(BASTIONS[1] if row[2] and not row[3] else BASTIONS[0])
		var held := ""
		if row[2] != row[3]:
			held = " (other turret: %s at %.1f deg)" % [blocked.tracking, rad_to_deg(blocked.yaw)]
		_check("%s: forward fired %d, aft fired %d%s" % [row[0], fwd, aft, held], (fwd > 0) == row[2] and (aft > 0) == row[3]
			and (row[2] == row[3] or (blocked.tracking.begins_with("Holding at limit") and is_equal_approx(absf(rad_to_deg(blocked.yaw)), 120.0))))
		combat.clear_target() # Let the shells in flight land before the target moves.
		for i in 90:
			await physics_frame
	combat.set_physics_process(false)
	projectiles.spawned_projectile.disconnect(record_spawn)
	_check("turret yaw never exceeded the +/-120 deg hardpoint limit while tracking", limit_ok)
	var one_each := shots.all(func(s: Dictionary) -> bool: return spawned.has(s.id)) and spawned.size() == shots.size()
	var at_muzzle := true
	var max_dev := 0.0
	var deviations := {}
	var values_ok := true
	for s: Dictionary in shots:
		var r: Dictionary = spawned.get(s.id, {})
		if r.is_empty():
			continue
		at_muzzle = at_muzzle and (r.origin as Vector3).is_equal_approx((s.origin as Transform3D).origin)
		var dev := _angle(-(s.origin as Transform3D).basis.z, r.velocity)
		max_dev = maxf(max_dev, dev)
		deviations[snappedf(dev, 0.0001)] = true
		values_ok = values_ok and r.damage == 12.0 and r.penetration == 20.0 and r.armor_damage == 6.0 and absf((r.velocity as Vector3).length() - 40.0) < 0.001
	_check("%d shots, each exactly one physical shell (%d spawned), originating at its muzzle" % [shots.size(), spawned.size()], one_each and at_muzzle and shots.size() >= 6)
	_check("live shells deviate from the barrel by at most 0.5 deg (max %.4f deg, %d distinct deviations)" % [max_dev, deviations.size()],
		max_dev <= 0.5 + ANGLE_EPS and deviations.size() > 1 and max_dev > 0.001)
	_check("dispersion leaves the shell's values unchanged: damage 12, penetration 20, armor damage 6, speed 40", values_ok)
	for i in 120:
		await physics_frame
	var own: Array = projectiles.records.filter(func(r: Dictionary) -> bool: return spawned.has(r.id) and r.ship == "FF01")
	var outcomes := _outcomes(projectiles, spawned)
	_check("no Bastion shell hit FF-01's own hull; every shell hit the stationary 40 u target (outcomes %s)" % str(outcomes),
		own.is_empty() and outcomes == {"damage": spawned.size()})


static func _outcomes(projectiles: Node, ids: Dictionary) -> Dictionary:
	var out := {}
	for r: Dictionary in projectiles.records:
		if ids.has(r.id):
			out[r.outcome] = out.get(r.outcome, 0) + 1
	return out


# --- H: physical Bastion shells against a fresh FF-01 ---------------------------------

func _armor_sequence() -> void:
	print("\n=== H physical Bastion shells against a fresh hostile FF-01")
	_place(_target(), site + Vector2(250, 0) if site.x < 0 else site - Vector2(250, 0))
	var victim: Node3D = UNIT.instantiate()
	victim.name = "HostileFF01"
	victim.get_node("Combat").faction = HOSTILE
	scene.get_node("Ships").add_child(victim)
	scene.register_ship(victim)
	victim.get_node("Combat").set_physics_process(false)
	victim.get_node("Behavior").set_physics_process(false)
	_place(victim, _bearing(-90.0))
	await physics_frame
	var target = CombatShip.of(victim)
	_check("fresh hostile FF-01: hull 160 / 160, armor 100 / 100, resistance 30", target.health == 160.0 and target.max_health == 160.0
		and target.armor == 100.0 and target.max_armor == 100.0 and target.armor_resistance == 30.0)
	var events: Array = []
	var destroyed: Array = []
	target.damaged.connect(func(amount: float, id: int) -> void: events.append([amount, id, target.health, target.armor]))
	target.destroyed.connect(func(ship: Node3D) -> void: destroyed.append(ship))
	var combat = CombatShip.of(ff01)
	combat.stance = CombatShip.Stance.AGGRESSIVE
	scene.sensors.evaluate()
	combat.assign_target(victim)
	combat.set_physics_process(true)
	var fired_before: int = _bastion(BASTIONS[0]).shots + _bastion(BASTIONS[1]).shots
	for i in 60 * 60:
		await physics_frame
		if not target.alive:
			break
	for i in 180:
		await physics_frame
	combat.set_physics_process(false)
	var fired: int = _bastion(BASTIONS[0]).shots + _bastion(BASTIONS[1]).shots - fired_before
	var projectiles: Node = scene.projectiles
	# Reference: the approved formula, independently, one impact at a time.
	var hull := 160.0
	var armor := 100.0
	var agree := true
	for e: Array in events:
		var effective := 30.0 * armor / 100.0
		var damage := 12.0 * 20.0 / (20.0 + effective)
		hull = maxf(0.0, hull - damage)
		armor = maxf(0.0, armor - 6.0)
		agree = agree and absf(e[0] - damage) < 0.000000001 and absf(e[2] - hull) < 0.000000001 and absf(e[3] - armor) < 0.000000001
	var first: Array = events[0] if not events.is_empty() else [0.0, -1, 0.0, 0.0]
	_check("first physical Bastion shell: hull damage %.6f, hull %.6f, armor %.0f (4.8 / 155.2 / 94)" % [first[0], first[2], first[3]],
		absf(first[0] - 4.8) < 0.000000001 and absf(first[2] - 155.2) < 0.000000001 and first[3] == 94.0)
	_check("every physical impact follows the formula from pre-impact armor (%d impacts)" % events.size(), agree and not events.is_empty())
	var ids := {}
	for e: Array in events:
		ids[e[1]] = ids.get(e[1], 0) + 1
	_check("each shell caused at most one damage event (%d events, %d shells, damage_events all 1)" % [events.size(), ids.size()],
		ids.values().all(func(n: int) -> bool: return n == 1) and ids.keys().all(func(id: int) -> bool: return projectiles.damage_events.get(id, 0) == 1))
	_check("destroyed once, by the 21st damaging shell (events %d, %d shells fired, hull %.1f)" % [events.size(), fired, target.health],
		events.size() == 21 and destroyed.size() == 1 and not target.alive and target.health == 0.0)
