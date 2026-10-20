extends RefCounted
## Combat prototype v0.3: tactical encounters E01–E05 (one scene each under encounters/,
## for their asteroids; the same four ships, experimental v0.3 loadouts; E05 adds a
## second Gunship per side and its own controller nodes). Each places the
## ships at rest (Locomotion.place(), set-up only), sets their channels through
## CombatOrders and registers scripted orders with the EnemyController. Ships not involved
## are parked far away on Hold Fire. Scenario conditions (listed in the HUD): a few
## weapons start with an empty stock to isolate one weapon family; that is a property
## of the encounter, not of the ship's loadout. Headings: Godot yaw, 0 = bow to −Z.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const BehaviorScenarios := preload("res://game/tests/combat/fixtures/behavior_scenarios.gd")
const EAST := -PI * 0.5
const WEST := PI * 0.5
const NORTH := 0.0
const SOUTH := PI
const HOLD := 0
const DEFENSIVE := 1
const AGGRESSIVE := 2

const NAMES := [
	"E01 Cannon positioning: close from beyond maximum range (75 u) into the effective range (45 u); use the asteroid",
	"E02 Torpedo evasion: dodge across the torpedo's path or put an asteroid between you",
	"E03 Gatling escort: keep the Gunship near the Destroyer while it fights the hostile Gunship",
	"E04 Missile guidance: launches over the asteroid; contact lost 9-13 s while the target moves; lost for good at 17.5 s as it flees",
	"E05 Fleet combat 3 v 3 (Destroyer + 2 Gunships each, equal stocks): destroy the hostile fleet",
]


static func count() -> int:
	return NAMES.size()


static func apply(arena: Node, index: int) -> String:
	var g: Node3D = arena.ship("Gunship")
	var d: Node3D = arena.ship("Destroyer")
	var hg: Node3D = arena.ship("HostileGunship")
	var hd: Node3D = arena.ship("HostileDestroyer")
	var o = arena.orders
	var e = arena.enemy_controller
	match index:
		0:
			_place(g, -80, 0, EAST); _place(hg, 30, -20, NORTH); _park(arena, d, -120, 120); _park(arena, hd, 120, 120)
			o.set_stance([g], AGGRESSIVE)
			o.set_stance([hg], HOLD)
			o.assign_target([g], hg)
			_empty(arena, g, &"gatling")
			_empty(arena, hg, &"gatling")
			e.patrol(hg, [Vector2(30, 20), Vector2(30, -20)])
		1:
			_place(hd, 55, 0, WEST); _place(g, -20, 0, EAST); _park(arena, d, -120, -120); _park(arena, hg, 120, -120)
			o.set_stance([hd], AGGRESSIVE)
			o.set_stance([g], HOLD)
			o.assign_target([hd], g)
			_empty(arena, hd, &"cannon")
			_empty(arena, hd, &"missile")
			_empty(arena, hd, &"gatling")
			_empty(arena, g, &"gatling")
		2:
			_place(d, -25, 0, EAST); _place(g, -14, 6, EAST); _place(hg, -4, -12, WEST); _place(hd, 55, 0, WEST)
			o.set_stance([d, hg], HOLD)
			o.set_stance([g, hd], AGGRESSIVE)
			o.assign_target([g], hg)
			o.assign_target([hd], d)
			_empty(arena, hd, &"cannon")
			_empty(arena, hd, &"gatling")
			CombatShip.of(hg).health = 400.0
			arena.conditions.append("HostileGunship: hull 400 (outlasts the ordnance waves)")
		3:
			_place(d, -45, 0, EAST); _place(hg, 35, 0, WEST); _park(arena, g, -120, 120); _park(arena, hd, 120, 120)
			o.set_stance([d], AGGRESSIVE)
			o.set_stance([hg], HOLD)
			o.assign_target([d], hg)
			_empty(arena, d, &"torpedo")
			_empty(arena, d, &"cannon")
			e.at(9.0, "test event: Destroyer's contact on HostileGunship lost; it moves north", func() -> void:
				arena.contacts.set_contact(0, hg, false)
				o.move([hg], Vector2(35, 30)))
			e.at(13.0, "test event: contact on HostileGunship restored", func() -> void: arena.contacts.set_contact(0, hg, true))
			e.at(17.5, "test event: contact lost for good; HostileGunship flees", func() -> void:
				arena.contacts.set_contact(0, hg, false)
				o.move([hg], Vector2(35, 110)))
		4:
			# E05 (encounters/e05_fleet.tscn adds Gunship2 and HostileGunship2, the asteroids,
			# HostileFleet and FleetBattle). Player column in the west, slightly south;
			# hostile wedge in the east, slightly north. 172 u between the Destroyers (beyond
			# every weapon's range: torpedo 110, missiles 90); the line between the fleets
			# runs through the central rock. Both sides start Aggressive; the hostile fleet's
			# orders come from HostileFleet.
			# Rocks (x, z, radius): 1 (0, 0, 10) central, blocks the direct line (its top,
			# 11.5 u, is above the missiles' cruise height); 2 (-6, -42, 6) and 3 (8, 40, 7)
			# split the middle into four approach routes (north of 2, between 2 and 1, between
			# 1 and 3, south of 3); 4 (-50, -12, 5) cover in front of the player, 5 (46, 16, 5)
			# its counterpart in front of the hostile fleet; 6 (-32, 58, 6) and 7 (34, -62, 6)
			# flank rocks. Rocks and fleets are roughly point-symmetric about the centre
			# (balanced); the formations differ (column vs wedge) and are offset north / south
			# (asymmetric).
			var g2: Node3D = arena.ship("Gunship2")
			var hg2: Node3D = arena.ship("HostileGunship2")
			_place(d, -85, 12, EAST); _place(g, -74, 0, EAST); _place(g2, -76, 26, EAST)
			_place(hd, 88, -16, WEST); _place(hg, 76, -30, WEST); _place(hg2, 74, -4, WEST)
			o.set_stance([d, g, g2, hd, hg, hg2], AGGRESSIVE)
			# Behavior prototype: played from the lab, the player ships get the Behavior layer
			# (commands, tactics, weapon profiles). The hostile fleet stays under HostileFleet,
			# its commander: autonomous Behavior movement would compete with its station orders.
			if arena.behavior_layer:
				for ship: Node3D in [d, g, g2]:
					BehaviorScenarios.attach(ship)
	return NAMES[index]


static func _place(ship: Node3D, x: float, z: float, heading: float) -> void:
	ship.get_node("Locomotion").place(Vector2(x, z), heading)
	ship.get_node("Avoidance").reset()


static func _park(arena: Node, ship: Node3D, x: float, z: float) -> void:
	_place(ship, x, z, NORTH)
	arena.orders.set_stance([ship], HOLD)


## Scenario condition: every weapon of `family` on `ship` starts with an empty stock.
static func _empty(arena: Node, ship: Node3D, family: StringName) -> void:
	var emptied := 0
	for weapon in CombatShip.of(ship).weapons:
		if weapon.config.family == family:
			weapon.ammo = 0
			weapon.magazine = 0
			emptied += 1
	if emptied > 0:
		arena.conditions.append("%s: %s stock empty" % [ship.name, String(family).capitalize()])
