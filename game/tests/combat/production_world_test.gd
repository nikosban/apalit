extends SceneTree
## Combat migration M2: the combat stack on real production entities and geometry, on
## main.tscn (three stations, 36 asteroids, the three starting ships), with one hostile
## FF-01 (`Raider`, the production ff01_unit with faction 1) added for the cases.
## Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/production_world_test.gd
##   W1 every ship's hull and loadout; one health owner per ship
##   W2 a civilian ship (Transporter) takes damage from hostile fire
##   W3 a station without a hull stops direct fire: the weapon holds (line of fire) and a
##      round fired at it stops there without damage
##   W4 a station with a compatible hull component takes damage once; same faction: none
##   W5 destroying a working Miner stops its work and releases every reference
##   W6 repeated scene resets with combat under way leave no projectiles or orphan nodes

const MAIN := preload("res://main.tscn")
const FF01 := preload("res://game/ships/ff01_unit.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const HOSTILE := 1
const DT := 1.0 / 60.0

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _w1_hulls()
	await _w2_civilian_damage()
	await _w3_station_blocks()
	await _w4_station_hull()
	await _w5_destruction()
	await _w6_resets()
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


func _load() -> void:
	_free()
	scene = MAIN.instantiate()
	root.add_child(scene)
	for i in 10:
		await physics_frame


func _ship(name: String) -> Node3D:
	return scene.get_node("Ships").get_node_or_null(name)


func _c(name: String) -> Variant:
	return CombatShip.of(_ship(name))


## Adds the hostile FF-01 at a point (production variant, faction set before it enters).
func _raider(point: Vector2, heading: float) -> Node3D:
	var raider: Node3D = FF01.instantiate()
	raider.name = "Raider"
	raider.get_node("Combat").faction = HOSTILE
	raider.get_node("Combat").stance = CombatShip.Stance.AGGRESSIVE
	raider.transform = Transform3D(Basis(Vector3.UP, heading), Vector3(point.x, 1.5, point.y))
	scene.get_node("Ships").add_child(raider)
	return raider


func _put(name: String, point: Vector2, heading := 0.0) -> void:
	_ship(name).get_node("Locomotion").place(point, heading)
	_ship(name).get_node("Avoidance").reset()


func _run(seconds: float, until: Callable = Callable()) -> bool:
	for i in roundi(seconds / DT):
		await physics_frame
		if until.is_valid() and until.call():
			return true
	return false


func _w1_hulls() -> void:
	print("\n=== W1 hulls and loadouts")
	await _load()
	var counts := {}
	var hulls := true
	var owners := true
	for ship: Node in scene.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		counts[String(ship.name)] = combat.weapons.size() if combat != null else -1
		hulls = hulls and combat != null and is_equal_approx(combat.health, 150.0) and combat.alive and combat.faction == 0
		for child in ship.get_children():
			if child != combat and child.get("health") != null:
				owners = false
	_check("every starting ship has a Combat hull of 150, player faction (%s weapons)" % str(counts), hulls
		and counts == {"Miner1": 0, "Miner2": 0, "Transporter": 0})
	_check("no other component of any ship holds a health value (one owner: Combat)", owners)


func _w2_civilian_damage() -> void:
	print("\n=== W2 civilian damage")
	await _load()
	var transporter := _ship("Transporter")
	var at: Vector2 = transporter.get_node("Locomotion").planar_position
	var raider := _raider(at + Vector2(0, 22), PI)
	await physics_frame
	CombatShip.of(raider).assign_target(transporter)
	var hit := await _run(20.0, func() -> bool: return _c("Transporter").health < 150.0)
	var records: Array = scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.outcome == "damage" and r.ship == "Transporter")
	_check("a hostile FF-01 damages the Transporter (hull %.0f of 150, %d damaging rounds)" % [_c("Transporter").health, records.size()], hit and records.size() > 0)
	var friendly: Array = scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.outcome == "damage" and r.ship == "Raider")
	_check("no ship of the Transporter's faction damaged the Raider (it has no weapons and no one else is in range)", friendly.is_empty())


func _w3_station_blocks() -> void:
	print("\n=== W3 station blocks fire")
	await _load()
	var station: Node3D = scene.get_node("Stations/Station")
	var centre := Vector2(station.global_position.x, station.global_position.z)
	_put("Miner2", centre + Vector2(0, 27), 0.0)
	var raider := _raider(centre + Vector2(0, -27), PI)
	# This case is about the weapon's line of fire from a fixed position: the Raider's
	# Behavior (which would correctly reposition it around the station) is taken out, and
	# its rocket and missile stocks are emptied so only direct fire remains.
	var behavior := raider.get_node("Behavior")
	raider.remove_child(behavior)
	behavior.free()
	await physics_frame
	for weapon in CombatShip.of(raider).weapons:
		if weapon.config.family in [&"rocket", &"missile"]:
			weapon.ammo = 0
			weapon.magazine = 0
	CombatShip.of(raider).assign_target(_ship("Miner2"))
	var cannon: Node = raider.get_node("Weapons/ForwardBastionHardpoint").weapon()
	var reasons := {}
	await _run(6.0, func() -> bool:
		reasons[String(cannon.reason)] = true
		return false)
	var shots_at_miner: Array = scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.owner_name == "Raider")
	_check("cannon across the Station (54 u, in range): holds fire, reason obscured by the station (%s), %d shots, Miner2 hull %.0f" % [str(reasons.keys()), cannon.shots, _c("Miner2").health],
		cannon.shots == 0 and reasons.has("Temporarily obscured (station)") and is_equal_approx(_c("Miner2").health, 150.0) and shots_at_miner.is_empty())
	var projectiles: Node = scene.get_node("Projectiles")
	var origin := Vector3(centre.x, 1.5, centre.y - 20.0)
	var id: int = projectiles.spawn(raider, HOSTILE, origin, Vector3(0, 0, 40), 12.0, 90.0, 2.5, null, &"shell")
	await _run(1.5)
	var done: Array = projectiles.records.filter(func(r: Dictionary) -> bool: return r.id == id)
	var stopped: bool = done.size() == 1 and done[0].outcome == "station" and done[0].ship == "Station" and (done[0].point as Vector3).z < centre.y
	_check("a round fired straight at the Station stops at its hull side, outcome 'station', no damage applied (%s)" % (str(done[0].outcome) + " at z %.2f" % (done[0].point as Vector3).z if not done.is_empty() else "none"),
		stopped and not projectiles.damage_events.has(id) and is_equal_approx(_c("Miner2").health, 150.0))


func _w4_station_hull() -> void:
	print("\n=== W4 station hull component (test-only)")
	await _load()
	var station: Node3D = scene.get_node("Stations/Station2")
	var script := GDScript.new()
	script.source_code = "extends Node\nvar faction := 0\nvar health := 100.0\nfunc take_hit(amount: float, _id: int) -> bool:\n\thealth -= amount\n\treturn true\n"
	script.reload()
	var hull := Node.new()
	hull.name = "TestHull"
	hull.set_script(script)
	station.add_child(hull)
	var projectiles: Node = scene.get_node("Projectiles")
	var centre := Vector2(station.global_position.x, station.global_position.z)
	var raider := _raider(centre + Vector2(0, -40), PI)
	await physics_frame
	var hostile_id: int = projectiles.spawn(raider, HOSTILE, Vector3(centre.x, 1.5, centre.y - 20.0), Vector3(0, 0, 40), 12.0, 90.0, 2.5, null, &"shell")
	var friendly_id: int = projectiles.spawn(_ship("Transporter"), 0, Vector3(centre.x, 1.5, centre.y + 20.0), Vector3(0, 0, -40), 12.0, 90.0, 2.5, null, &"shell")
	await _run(1.5)
	var outcome := func(id: int) -> String:
		var found: Array = projectiles.records.filter(func(r: Dictionary) -> bool: return r.id == id)
		return found[0].outcome if not found.is_empty() else "none"
	_check("a hostile round damages a station that has a hull component once (hull %.0f of 100, outcome %s)" % [hull.health, outcome.call(hostile_id)],
		outcome.call(hostile_id) == "damage" and is_equal_approx(hull.health, 88.0) and projectiles.damage_events.get(hostile_id, 0) == 1)
	_check("a round of the hull's own faction only stops there (outcome %s)" % outcome.call(friendly_id), outcome.call(friendly_id) == "station" and not projectiles.damage_events.has(friendly_id))
	var plain: Node3D = scene.get_node("Stations/Station")
	_check("stations without a hull component still have none (no health added)", plain.get_children().all(func(c: Node) -> bool: return not c.has_method("take_hit")))


func _w5_destruction() -> void:
	print("\n=== W5 destruction of a working Miner")
	await _load()
	var miner := _ship("Miner1")
	var asteroid_id: int = scene.get_node("Asteroids").ids()[0]
	var raider := _raider(Vector2(60, 60), PI)
	await physics_frame
	miner.get_node("Mining").assign(asteroid_id)
	await _run(2.0)
	CombatShip.of(raider).assign_target(miner)
	scene.get_node("Selection").set_selection([miner])
	CombatShip.of(miner).destroy()
	var stopped := ["Mining", "Extractor", "RouteFollower", "Docking", "Fuel"].all(func(n: String) -> bool: return not miner.get_node(n).is_physics_processing())
	_check("destroyed Miner: weapons off, its mining, extraction, route, docking and fuel stop at once; deselected", stopped
		and not CombatShip.of(miner).alive and not scene.get_node("Selection").selected.has(miner) and CombatShip.of(raider).manual_target == null)
	var gone: WeakRef = weakref(miner)
	miner = null
	var removed := await _run(4.0, func() -> bool: return gone.get_ref() == null)
	var stale := false
	for ship: Node in scene.get_node("Ships").get_children():
		var avoidance := ship.get_node("Avoidance")
		var combat = CombatShip.of(ship)
		stale = stale or avoidance.encounters.keys().any(func(k: Variant) -> bool: return not is_instance_valid(k))
		for reference in [combat.target, combat.manual_target, combat.auto_target]:
			stale = stale or (reference != null and not is_instance_valid(reference))
	var raider_target = CombatShip.of(raider).target
	_check("after the hulk delay the Miner is freed; no avoidance record or target refers to it (Raider now on %s)" % (raider_target.name if raider_target != null else "none"),
		removed and not stale and scene.get_node("Selection").registered_count() == scene.get_node("Ships").get_child_count() - 1)


func _w6_resets() -> void:
	print("\n=== W6 resets")
	var orphans := []
	var leftovers := 0
	for i in 3:
		await _load()
		var raider := _raider(Vector2(-12, -40), 0.0)
		await physics_frame
		CombatShip.of(raider).assign_target(_ship("Miner2"))
		await _run(4.0)
		leftovers += scene.get_node("Projectiles").active.size() + scene.get_node("Projectiles").ordnance.size()
		_free()
		await process_frame
		await physics_frame
		orphans.append(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	print("  in flight at each reset (freed with the scene): %d; orphan nodes after each: %s" % [leftovers, str(orphans)])
	_check("three resets with combat under way: no orphan nodes left behind", orphans.all(func(n: float) -> bool: return n == 0.0))
