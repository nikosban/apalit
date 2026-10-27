extends SceneTree
## Stage 1 armor: DurabilityConfig validation, the shared armor resolution
## (Combat.resolve_hit, checked against an independent copy of the approved formula), FF-01
## durability and hull display, legacy damage, physical impacts (a round and a guided
## missile) applied exactly once, a synthetic sequence to destruction, and the two-argument
## station receiver. The Bastion-like values (12 / 20 / 6) are synthetic test inputs only.
## An unarmored Miner is added to the arena as the ship without durability.
## Run: <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/armor_test.gd

const ARENA := preload("res://game/scenes/combat_test.tscn")
const UNIT := preload("res://game/ships/ff01_unit.tscn")
const FF01_DURABILITY := preload("res://game/ships/ff01_durability.tres")
const Durability := preload("res://game/combat/durability_config.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const CombatHud := preload("res://game/ui/combat_hud.gd")
const WAYFARER := preload("res://game/weapons/gcm4_wayfarer.tres")
const MINER := preload("res://game/ships/miner_unit.tscn")
const BASE := 12.0
const PEN := 20.0
const ARMOR_DAMAGE := 6.0
const HULL := 160.0
const ARMOR := 100.0
const RESISTANCE := 30.0
const TABLE := [[155.2, 94.0], [150.220747, 88.0], [145.048333, 82.0]] # Approved hull / armor after impacts 1-3.
const EPS := 0.000001
const TIGHT := 0.000000001
const HOSTILE := 1

var scene: Node3D
var ff01: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	_validation()
	_formula()
	await _load()
	_configuration()
	_legacy()
	await _physical_round()
	await _physical_ordnance()
	await _station()
	_non_finite()
	_sequence()
	await _invalid_runtime()
	scene.free()
	await process_frame
	_check("no orphan nodes after the armor verification", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(message: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-116s %s" % [message, "PASS" if ok else "FAIL"])


## The approved formula written out independently of Combat.resolve_hit: [hull damage, new armor].
static func _reference(armor: float, penetration: float, maximum := ARMOR) -> Array:
	var effective := RESISTANCE * armor / maximum
	return [BASE * penetration / (penetration + effective), maxf(0.0, armor - ARMOR_DAMAGE)]


static func _near(a: float, b: float, tolerance := EPS) -> bool:
	return absf(a - b) <= tolerance


func _durability(hull: float, armor: float, resistance: float) -> Resource:
	var config: Resource = Durability.new()
	config.max_hull = hull
	config.max_armor = armor
	config.armor_resistance = resistance
	return config


# --- V: configuration validation ----------------------------------------------------

func _validation() -> void:
	print("\n=== V durability validation")
	_check("FF-01 durability resource: 160 / 100 / 30, valid", FF01_DURABILITY.errors().is_empty()
		and FF01_DURABILITY.max_hull == HULL and FF01_DURABILITY.max_armor == ARMOR and FF01_DURABILITY.armor_resistance == RESISTANCE)
	_check("a default DurabilityConfig is valid", Durability.new().errors().is_empty())
	var invalid := {"max_hull 0": [0.0, 0.0, 0.0], "max_hull -10": [-10.0, 0.0, 0.0], "max_hull NAN": [NAN, 0.0, 0.0],
		"max_hull INF": [INF, 0.0, 0.0], "max_armor -1": [160.0, -1.0, 30.0], "max_armor NAN": [160.0, NAN, 30.0],
		"armor_resistance -1": [160.0, 100.0, -1.0], "armor_resistance INF": [160.0, 100.0, INF]}
	for label: String in invalid:
		var v: Array = invalid[label]
		var errors: PackedStringArray = _durability(v[0], v[1], v[2]).errors()
		_check("invalid configuration reported (%s): %s" % [label, "; ".join(errors)], errors.size() == 1)


# --- A: the shared resolution against the independent formula ----------------------

func _formula() -> void:
	print("\n=== A armor resolution (Combat.resolve_hit vs the independent formula)")
	# A1: the complete Bastion-like sequence on 160 / 100 / 30, until the hull reaches 0.
	var hull := HULL
	var armor := ARMOR
	var hits := 0
	var agree := true
	var after: Array = []
	var damage: Array = []
	while hull > 0.0 and hits < 100:
		var want := _reference(armor, PEN)
		var got := CombatShip.resolve_hit(BASE, PEN, ARMOR_DAMAGE, armor, ARMOR, RESISTANCE)
		agree = agree and _near(got.hull_damage, want[0], TIGHT) and _near(got.armor, want[1], TIGHT)
		hull = maxf(0.0, hull - want[0])
		armor = want[1]
		hits += 1
		after.append([hull, armor])
		damage.append(want[0])
	_check("A1 every impact of the sequence equals the independent formula within 1e-9 (%d impacts)" % hits, agree)
	var table_ok := true
	for i in TABLE.size():
		table_ok = table_ok and _near(after[i][0], TABLE[i][0]) and _near(after[i][1], TABLE[i][1], 0.0)
	_check("A1 impacts 1-3: hull %.6f / %.6f / %.6f, armor %.0f / %.0f / %.0f (approved table)" % [after[0][0], after[1][0], after[2][0], after[0][1], after[1][1], after[2][1]], table_ok)
	var depleted := after.map(func(r: Array) -> float: return r[1]).find(0.0) + 1
	print("  Bastion-like sequence: %d impacts to destroy FF-01; armor reaches 0 on impact %d; hull after impact %d: %.6f; damage of impacts 16 / 17 / 18: %.6f / %.6f / %.6f"
		% [hits, depleted, hits - 1, after[hits - 2][0], damage[15], damage[16], damage[17]])
	_check("A1 recorded result: FF-01 is destroyed by impact %d (armor depleted on impact %d)" % [hits, depleted], hits == 21 and depleted == 17)
	# A2: hull damage uses the pre-impact armor condition.
	var second := CombatShip.resolve_hit(BASE, PEN, ARMOR_DAMAGE, 94.0, ARMOR, RESISTANCE)
	_check("A2 impact 2 uses pre-impact armor 94 (%.9f = 240 / 48.2), not post-impact 88" % second.hull_damage,
		_near(second.hull_damage, 240.0 / 48.2, TIGHT) and not _near(second.hull_damage, 240.0 / 46.4, 0.001) and second.armor == 88.0)
	# A3: full, partial and zero armor condition.
	var full := CombatShip.resolve_hit(BASE, PEN, 0.0, 100.0, ARMOR, RESISTANCE)
	var half := CombatShip.resolve_hit(BASE, PEN, 0.0, 50.0, ARMOR, RESISTANCE)
	var none := CombatShip.resolve_hit(BASE, PEN, 0.0, 0.0, ARMOR, RESISTANCE)
	_check("A3 armor 100 / 50 / 0: hull damage %.6f / %.6f / %.6f (4.8, 240 / 35, 12)" % [full.hull_damage, half.hull_damage, none.hull_damage],
		_near(full.hull_damage, 4.8, TIGHT) and _near(half.hull_damage, 240.0 / 35.0, TIGHT) and _near(none.hull_damage, 12.0, TIGHT))
	# A4: fractional damage preserved.
	_check("A4 fractional hull damage is kept (%.12f, not rounded)" % second.hull_damage,
		second.hull_damage != roundf(second.hull_damage) and _near(second.hull_damage, 4.979253112033195, TIGHT))
	# A5: armor clamped to [0, max].
	var last := CombatShip.resolve_hit(BASE, PEN, ARMOR_DAMAGE, 4.0, ARMOR, RESISTANCE)
	var over := CombatShip.resolve_hit(BASE, PEN, ARMOR_DAMAGE, 150.0, ARMOR, RESISTANCE)
	var under := CombatShip.resolve_hit(BASE, PEN, ARMOR_DAMAGE, -10.0, ARMOR, RESISTANCE)
	var repair := CombatShip.resolve_hit(BASE, PEN, -6.0, 50.0, ARMOR, RESISTANCE)
	_check("A5 armor 4 - 6 -> 0 (not negative); 150 is read as the maximum 100 (-> 94, damage 4.8); -10 as 0 (-> 0, damage 12); negative armor damage never repairs",
		last.armor == 0.0 and over.armor == 94.0 and _near(over.hull_damage, 4.8, TIGHT) and under.armor == 0.0 and _near(under.hull_damage, 12.0, TIGHT)
		and repair.armor == 50.0)
	# A6: explicit zero (and negative) penetration deals no hull damage, with or without armor.
	var zero := CombatShip.resolve_hit(BASE, 0.0, 0.0, 100.0, ARMOR, RESISTANCE)
	var zero_bare := CombatShip.resolve_hit(BASE, 0.0, 0.0, 0.0, 0.0, RESISTANCE)
	var negative := CombatShip.resolve_hit(BASE, -5.0, 0.0, 100.0, ARMOR, RESISTANCE)
	_check("A6 explicit penetration 0: hull damage 0 with armor 100 and with maximum armor 0 (finite, no NaN); negative penetration also 0",
		zero.hull_damage == 0.0 and zero_bare.hull_damage == 0.0 and is_finite(zero.hull_damage) and is_finite(zero_bare.hull_damage) and negative.hull_damage == 0.0)
	# A7: zero maximum armor.
	var bare := CombatShip.resolve_hit(BASE, PEN, ARMOR_DAMAGE, 0.0, 0.0, RESISTANCE)
	var stale := CombatShip.resolve_hit(BASE, PEN, ARMOR_DAMAGE, 50.0, 0.0, RESISTANCE)
	_check("A7 maximum armor 0: effective armor 0, full 12 damage, armor stays 0 (also with a stale condition 50)",
		_near(bare.hull_damage, 12.0, TIGHT) and bare.armor == 0.0 and _near(stale.hull_damage, 12.0, TIGHT) and stale.armor == 0.0 and is_finite(bare.hull_damage))
	# A8 / A9: armor degradation is independent of penetration.
	_check("A8 armor damage 0 never degrades armor (100 stays 100)", full.armor == 100.0)
	var zero_pen := CombatShip.resolve_hit(BASE, 0.0, ARMOR_DAMAGE, 100.0, ARMOR, RESISTANCE)
	_check("A9 penetration 0 with armor damage 6: hull damage 0, armor 100 -> 94", zero_pen.hull_damage == 0.0 and zero_pen.armor == 94.0)
	# A10: unconfigured penetration bypasses armor.
	var legacy := CombatShip.resolve_hit(BASE, null, 0.0, 100.0, ARMOR, RESISTANCE)
	var legacy_ad := CombatShip.resolve_hit(BASE, null, ARMOR_DAMAGE, 100.0, ARMOR, RESISTANCE)
	_check("A10 unconfigured penetration: the full 12 at armor 100, armor unchanged; a configured armor damage still applies (-> 94)",
		legacy.hull_damage == 12.0 and legacy.armor == 100.0 and legacy_ad.hull_damage == 12.0 and legacy_ad.armor == 94.0)


# --- Arena ------------------------------------------------------------------------

func _load() -> void:
	scene = ARENA.instantiate()
	var miner: Node3D = MINER.instantiate()
	miner.name = "Miner"
	miner.position = Vector3(0, 1.5, 60)
	scene.get_node("Ships").add_child(miner)
	root.add_child(scene)
	for ship in scene.get_node("Ships").get_children():
		ship.get_node("Combat").stance = CombatShip.Stance.HOLD_FIRE
		ship.get_node("Combat").set_physics_process(false)
		if ship.has_node("Behavior"):
			ship.get_node("Behavior").set_physics_process(false)
	ff01 = scene.get_node("Ships/FF01")
	for i in 3:
		await physics_frame


func _reset_ff01() -> Node:
	var combat = CombatShip.of(ff01)
	combat.health = combat.max_health
	combat.armor = combat.max_armor
	return combat


func _configuration() -> void:
	print("\n=== B1 configuration and hull display")
	var combat = CombatShip.of(ff01)
	_check("FF-01 Combat uses the shared ff01_durability.tres: hull 160 / 160, armor 100 / 100, resistance 30 (hull text '%s')" % CombatHud.hull_text(combat),
		combat.durability == FF01_DURABILITY and combat.durability_errors.is_empty() and combat.health == HULL and combat.max_health == HULL
		and combat.armor == ARMOR and combat.max_armor == ARMOR and combat.armor_resistance == RESISTANCE and CombatHud.hull_text(combat) == "Hull 160 / 160")
	var mounts := ff01.get_node("Weapons").get_children()
	var bastions := ["ForwardBastionHardpoint", "AftBastionHardpoint"]
	_check("FF-01: two Bastions, four Kestrels, one Barrage and one Wayfarer", mounts.size() == 8
		and mounts.all(func(m: Node) -> bool: return m.weapon() != null)
		and bastions.all(func(n: String) -> bool: return ff01.get_node("Weapons/%s" % n).weapon().config.display_name == "NC-90 Bastion")
		and ff01.get_node("Weapons/WayfarerHardpoint").weapon().config.display_name == "GCM-4 Wayfarer"
		and combat.weapons.size() == 8 and combat.incompatible.is_empty())
	var c = CombatShip.of(scene.get_node("Ships/Miner"))
	_check("a ship without durability (Miner): hull 150 / 150 (rules.hull_health), no armor",
		c.durability == null and c.max_health == 150.0 and c.health == 150.0 and c.armor == 0.0 and c.max_armor == 0.0 and CombatHud.hull_text(c) == "Hull 150 / 150")


func _legacy() -> void:
	print("\n=== B2 legacy damage")
	var unarmored = CombatShip.of(scene.get_node("Ships/Miner"))
	unarmored.take_hit(12.0, -1)
	var two_args: float = unarmored.health
	unarmored.take_hit(12.0, -1, PEN, ARMOR_DAMAGE)
	_check("unarmored Miner: two-argument hit 150 -> %.1f; a penetration-20 hit -> %.1f (full 12, no armor to degrade)" % [two_args, unarmored.health],
		two_args == 138.0 and unarmored.health == 126.0 and unarmored.armor == 0.0 and unarmored.alive)
	unarmored.health = unarmored.max_health
	var combat = _reset_ff01()
	var amounts: Array = []
	var record := func(amount: float, _id: int) -> void: amounts.append(amount)
	combat.damaged.connect(record)
	combat.take_hit(12.0, -1)
	combat.damaged.disconnect(record)
	_check("FF-01, legacy two-argument hit: full 12 (160 -> %.1f), armor stays %.0f, damaged reports %s" % [combat.health, combat.armor, str(amounts)],
		combat.health == 148.0 and combat.armor == ARMOR and amounts == [12.0])


# --- Physical impacts -------------------------------------------------------------

func _physical_round() -> void:
	print("\n=== B7 physical rounds (Projectiles.spawn -> sweep -> take_hit)")
	var combat = _reset_ff01()
	var projectiles: Node = scene.projectiles
	var hostile := scene.get_node("Ships/HostileFF01") as Node3D
	var damaged: Array = []
	var record := func(amount: float, id: int) -> void: damaged.append([amount, id])
	combat.damaged.connect(record)
	var origin := ff01.global_position + Vector3(0, 0, -16)
	var armored: int = projectiles.spawn(hostile, HOSTILE, origin, Vector3(0, 0, 40), BASE, 90.0, 2.5, ff01, &"shell", PEN, ARMOR_DAMAGE)
	for i in 60:
		await physics_frame
	var done: Array = projectiles.records.filter(func(r: Dictionary) -> bool: return r.id == armored)
	var mine: Array = damaged.filter(func(e: Array) -> bool: return e[1] == armored)
	_check("a penetration-20 round hits FF-01 once: outcome %s, damage applications %d, damaged events %s, hull %.6f, armor %.0f" % [
		done[0].outcome if not done.is_empty() else "none", projectiles.damage_events.get(armored, 0), str(mine), combat.health, combat.armor],
		done.size() == 1 and done[0].outcome == "damage" and done[0].ship == "FF01" and projectiles.damage_events.get(armored, 0) == 1
		and mine.size() == 1 and _near(mine[0][0], 4.8, TIGHT) and _near(combat.health, 155.2, TIGHT) and combat.armor == 94.0
		and projectiles.active.filter(func(r: Dictionary) -> bool: return r.id == armored).is_empty())
	var legacy: int = projectiles.spawn(hostile, HOSTILE, origin, Vector3(0, 0, 40), BASE, 90.0, 2.5, ff01, &"shell")
	for i in 60:
		await physics_frame
	var legacy_done: Array = projectiles.records.filter(func(r: Dictionary) -> bool: return r.id == legacy)
	mine = damaged.filter(func(e: Array) -> bool: return e[1] == legacy)
	_check("a round without penetration (existing spawn call) bypasses armor once: hull %.6f (-12), armor %.0f unchanged" % [combat.health, combat.armor],
		legacy_done.size() == 1 and legacy_done[0].outcome == "damage" and projectiles.damage_events.get(legacy, 0) == 1
		and mine.size() == 1 and mine[0][0] == 12.0 and _near(combat.health, 143.2, TIGHT) and combat.armor == 94.0)
	combat.damaged.disconnect(record)


func _physical_ordnance() -> void:
	print("\n=== B7 physical ordnance (Projectiles.launch -> ordnance -> take_hit)")
	var combat = _reset_ff01()
	var projectiles: Node = scene.projectiles
	var hostile := scene.get_node("Ships/HostileFF01") as Node3D
	var config: Resource = WAYFARER.duplicate()
	config.damage = BASE
	config.has_penetration = true
	config.penetration = PEN
	config.armor_damage = ARMOR_DAMAGE
	var damaged: Array = []
	var record := func(amount: float, id: int) -> void: damaged.append([amount, id])
	combat.damaged.connect(record)
	var at := ff01.global_position + Vector3(0, 0, -30)
	var id: int = projectiles.launch(hostile, HOSTILE, Transform3D(Basis.looking_at(Vector3(0, 0, 1)), at), config, ff01)
	var done: Array = []
	for i in 360:
		await physics_frame
		done = projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.id == id)
		if not done.is_empty():
			break
	for i in 10:
		await physics_frame
	var mine: Array = damaged.filter(func(e: Array) -> bool: return e[1] == id)
	_check("a penetration-20 guided missile hits FF-01 once: outcome %s, damage applications %d, damaged events %s, hull %.6f, armor %.0f" % [
		done[0].outcome if not done.is_empty() else "none", projectiles.damage_events.get(id, 0), str(mine), combat.health, combat.armor],
		done.size() == 1 and done[0].outcome == "damage" and done[0].ship == "FF01" and projectiles.damage_events.get(id, 0) == 1
		and mine.size() == 1 and _near(mine[0][0], 4.8, TIGHT) and _near(combat.health, 155.2, TIGHT) and combat.armor == 94.0)
	_check("the shared gcm4_wayfarer.tres is unchanged by the test copy", WAYFARER.has_penetration and WAYFARER.penetration == 45.0
		and WAYFARER.damage == 35.0 and WAYFARER.armor_damage == 2.0)
	combat.damaged.disconnect(record)


func _station() -> void:
	print("\n=== B9 station receiver with a two-argument take_hit")
	var station := Node3D.new()
	station.name = "ArmorTestStation"
	station.add_to_group(&"station")
	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(6, 6, 6)
	part.mesh = box
	part.add_to_group(&"static_obstacle")
	station.add_child(part)
	var script := GDScript.new()
	script.source_code = "extends Node\nvar faction := 0\nvar health := 100.0\nfunc take_hit(amount: float, _id: int) -> bool:\n\thealth -= amount\n\treturn true\n"
	script.reload()
	var hull := Node.new()
	hull.set_script(script)
	station.add_child(hull)
	scene.add_child(station)
	station.global_position = Vector3(-120, 1.5, 120)
	var projectiles: Node = scene.projectiles
	var hostile := scene.get_node("Ships/HostileFF01") as Node3D
	var id: int = projectiles.spawn(hostile, HOSTILE, Vector3(-120, 1.5, 100), Vector3(0, 0, 40), BASE, 90.0, 2.5, null, &"shell", PEN, ARMOR_DAMAGE)
	for i in 60:
		await physics_frame
	var done: Array = projectiles.records.filter(func(r: Dictionary) -> bool: return r.id == id)
	_check("a penetration-20 round on a two-argument station hull: outcome %s, base 12 applied once (hull %.1f of 100), no error" % [done[0].outcome if not done.is_empty() else "none", hull.health],
		done.size() == 1 and done[0].outcome == "damage" and projectiles.damage_events.get(id, 0) == 1 and hull.health == 88.0)
	station.queue_free()
	await physics_frame


# --- N: non-finite hit inputs ------------------------------------------------------

func _non_finite() -> void:
	print("\n=== N non-finite hit inputs are rejected (errors below are expected)")
	var combat = _reset_ff01()
	combat.health = 150.0
	combat.armor = 50.0
	var events: Array = []
	var record := func(amount: float, _id: int) -> void: events.append(amount)
	combat.damaged.connect(record)
	var cases := {"penetration NAN": [BASE, NAN, ARMOR_DAMAGE], "penetration INF": [BASE, INF, ARMOR_DAMAGE],
		"penetration -INF": [BASE, -INF, ARMOR_DAMAGE], "armor damage NAN": [BASE, PEN, NAN], "armor damage INF": [BASE, PEN, INF],
		"armor damage -INF": [BASE, PEN, -INF], "armor damage NAN, penetration unset": [BASE, null, NAN],
		"damage NAN": [NAN, PEN, ARMOR_DAMAGE], "damage INF": [INF, null, 0.0], "penetration not a number": [BASE, "20", ARMOR_DAMAGE]}
	for label: String in cases:
		var v: Array = cases[label]
		var applied: bool = combat.take_hit(v[0], -1, v[1], v[2])
		_check("%s: rejected (%s); hull %.1f, armor %.1f unchanged, no damaged event" % [label, CombatShip.hit_input_error(v[0], v[1], v[2]), combat.health, combat.armor],
			not applied and combat.health == 150.0 and combat.armor == 50.0 and events.is_empty() and combat.alive)
	var zero: bool = combat.take_hit(BASE, -1, 0.0, ARMOR_DAMAGE)
	_check("explicit penetration 0 still applies (hull 150.0, armor 50 -> 44)", zero and combat.health == 150.0 and combat.armor == 44.0 and events == [0.0])
	var unset: bool = combat.take_hit(BASE, -1)
	_check("unset penetration still bypasses armor (hull 150 -> 138, armor 44)", unset and combat.health == 138.0 and combat.armor == 44.0 and events == [0.0, 12.0])
	combat.damaged.disconnect(record)


# --- Synthetic sequence to destruction ----------------------------------------------

func _sequence() -> void:
	print("\n=== B4 synthetic Bastion-like sequence on FF-01 (Combat.take_hit)")
	var combat = _reset_ff01()
	var effects: Node = scene.get_node("Effects")
	var damaged: Array = []
	var destroyed: Array = []
	combat.damaged.connect(func(amount: float, _id: int) -> void: damaged.append(amount))
	combat.destroyed.connect(func(ship: Node3D) -> void: destroyed.append(ship))
	var effects_before: int = effects.active_count()
	var hits := 0
	var agree := true
	var destroyed_at := -1
	var table_ok := true
	while combat.alive and hits < 100:
		var want := _reference(combat.armor, PEN)
		var hull_before: float = combat.health
		var applied: bool = combat.take_hit(BASE, -1, PEN, ARMOR_DAMAGE)
		hits += 1
		agree = agree and applied and _near(combat.health, maxf(0.0, hull_before - want[0]), TIGHT) and _near(combat.armor, want[1], TIGHT) \
			and _near(damaged[-1], want[0], TIGHT)
		if hits <= TABLE.size():
			table_ok = table_ok and _near(combat.health, TABLE[hits - 1][0]) and combat.armor == TABLE[hits - 1][1]
		if not combat.alive and destroyed_at < 0:
			destroyed_at = hits
			agree = agree and destroyed.size() == 1
	_check("every take_hit matches the independent formula (hull, armor, damaged amount); impacts 1-3 match the approved table", agree and table_ok)
	_check("destroyed once, by impact %d, at hull 0 (armor %.0f); one destruction effect" % [destroyed_at, combat.armor],
		destroyed_at == 21 and destroyed.size() == 1 and destroyed[0] == ff01 and combat.health == 0.0 and not combat.alive
		and effects.active_count() == effects_before + 1 and damaged.size() == 21)
	var hull_after: float = combat.health
	var armor_after: float = combat.armor
	var again: bool = combat.take_hit(BASE, -1, PEN, ARMOR_DAMAGE)
	var legacy_again: bool = combat.take_hit(BASE, -1)
	_check("hits after destruction have no effect (return false; hull, armor, damaged and destroyed counts unchanged)",
		not again and not legacy_again and combat.health == hull_after and combat.armor == armor_after and damaged.size() == 21 and destroyed.size() == 1)


# --- Invalid configuration at runtime ----------------------------------------------

func _invalid_runtime() -> void:
	print("\n=== V2 invalid durability at runtime (errors below are expected)")
	var cases := {"max_hull 0": _durability(0.0, 100.0, 30.0), "max_hull -10": _durability(-10.0, 100.0, 30.0),
		"max_hull NAN": _durability(NAN, 100.0, 30.0), "max_armor -1": _durability(160.0, -1.0, 30.0)}
	for label: String in cases:
		var unit: Node3D = UNIT.instantiate()
		unit.name = "InvalidFF01"
		unit.get_node("Combat").durability = cases[label]
		unit.position = Vector3(200, 1.5, 200)
		scene.get_node("Ships").add_child(unit)
		unit.get_node("Behavior").set_physics_process(false)
		unit.get_node("Combat").set_physics_process(false)
		await physics_frame
		var combat = CombatShip.of(unit)
		var text: String = CombatHud.hull_text(combat)
		_check("%s: rejected and reported (%s); keeps rules.hull_health 150 and no armor; hull text '%s'" % [label, "; ".join(combat.durability_errors), text],
			not combat.durability_errors.is_empty() and combat.max_health == 150.0 and combat.health == 150.0 and combat.armor == 0.0
			and combat.max_armor == 0.0 and combat.armor_resistance == 0.0 and is_finite(combat.health) and text == "Hull 150 / 150")
		scene.get_node("Ships").remove_child(unit)
		unit.free()
