extends RefCounted
## Behavior prototype v0.1: scenarios P01–P03 (one scene each under behavior/, for their
## asteroids; lab keys 6–8, arena scenario_index 5–7). Each places the ships at rest,
## gives the player ships a Behavior node (behavior/ship_behavior.gd) and sets their
## channels through CombatOrders; hostile and scripted friendly moves are EnemyController
## steps (CombatOrders, the same interfaces as the player; ships are looked up by name
## when a step runs, so a destroyed ship is simply skipped). Ships not involved are
## parked far away on Hold Fire. Every scene has Sensors (100 u, faction-shared, asteroid
## occlusion), so contact and the fog of war apply. Headings: Godot yaw, 0 = bow to −Z.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const Profiles := preload("res://game/behavior/weapon_profiles.gd")
const FIRST := 5 # scenario_index of P01 (after the encounters E01–E05)
const EAST := -PI * 0.5
const WEST := PI * 0.5
const NORTH := 0.0
const SOUTH := PI
const HOLD := 0
const DEFENSIVE := 1
const AGGRESSIVE := 2

const NAMES := [
	"P01 Defensive corridor: three Defensive ships hold the corridor; hostiles attack from cover, retreat and return",
	"P02 Aggressive + Siege: the Destroyer (Siege) engages a closing Gunship (holding fire) near the north boundary; an attacking one follows",
	"P03 Guard: two Gunships guard the Destroyer along its route (Gunship Aggressive, Gunship 2 Defensive); a hostile attacks",
]
const END_TIMES := [80.0, 100.0, 70.0] # s of scenario time each scenario's script covers


static func apply(arena: Node, index: int) -> String:
	var i := index - FIRST if index >= FIRST else index
	match i:
		0:
			_p01(arena)
		1:
			_p02(arena)
		2:
			_p03(arena)
	return NAMES[i]


## Gives a ship its Behavior node and the Defensive target priority (engageable attackers
## first, its own attackers before its allies').
static func attach(ship: Node3D) -> Node:
	var behavior := Behavior.new()
	behavior.name = "Behavior"
	ship.add_child(behavior)
	CombatShip.of(ship).defensive_priority = true
	return behavior


# Three Defensive ships across the corridor. HostileGunship attacks Gunship from the
# north-east cover rock, retreats, and returns later; HostileDestroyer closes to the
# corridor mouth, launches at the Destroyer and leaves; HostileGunship2 attacks the
# Destroyer from the south-east, where a small rock blocks Gunship2's line of fire (the
# Destroyer's sensors give the faction the contact).
static func _p01(arena: Node) -> void:
	var d: Node3D = arena.ship("Destroyer")
	var g: Node3D = arena.ship("Gunship")
	var g2: Node3D = arena.ship("Gunship2")
	_place(d, -20, 0, EAST); _place(g, -10, -12, EAST); _place(g2, -8, 12, EAST)
	_place(arena.ship("HostileGunship"), 88, -12, WEST)
	_place(arena.ship("HostileGunship2"), 92, 20, WEST)
	_place(arena.ship("HostileDestroyer"), 108, 2, WEST)
	for ship: Node3D in [d, g, g2]:
		attach(ship)
	arena.orders.set_stance([d, g, g2], DEFENSIVE)
	arena.orders.set_stance([arena.ship("HostileGunship"), arena.ship("HostileGunship2"), arena.ship("HostileDestroyer")], HOLD)
	var e = arena.enemy_controller
	e.at(1.0, "HostileGunship attacks Gunship from the north-east", func() -> void: _attack(arena, "HostileGunship", "Gunship", Vector2(50, -14)))
	e.at(12.0, "HostileGunship retreats behind the cover rock", func() -> void: _move(arena, "HostileGunship", Vector2(96, -14)))
	e.at(20.0, "HostileDestroyer closes to the corridor mouth", func() -> void: _attack(arena, "HostileDestroyer", "Destroyer", Vector2(70, 2)))
	e.at(34.0, "HostileGunship2 attacks the Destroyer from the south-east", func() -> void: _attack(arena, "HostileGunship2", "Destroyer", Vector2(48, 20)))
	e.at(36.0, "HostileDestroyer withdraws out of contact", func() -> void: _move(arena, "HostileDestroyer", Vector2(122, 2)))
	e.at(50.0, "HostileGunship2 retreats", func() -> void: _move(arena, "HostileGunship2", Vector2(100, 24)))
	e.at(54.0, "HostileGunship returns from the north-east", func() -> void: _move(arena, "HostileGunship", Vector2(56, -22)))
	e.at(64.0, "HostileGunship retreats again", func() -> void: _move(arena, "HostileGunship", Vector2(98, -16)))


# The Destroyer (Aggressive, Siege) faces south 40 u from the north boundary; HostileGunship
# closes on it from the south, then pushes it toward the boundary rocks, then flees;
# HostileGunship2 arrives from the east later.
static func _p02(arena: Node) -> void:
	var d: Node3D = arena.ship("Destroyer")
	_place(d, 0, -95, SOUTH)
	_place(arena.ship("HostileGunship"), 8, 15, NORTH)
	_place(arena.ship("HostileGunship2"), 128, -40, WEST)
	_park(arena, arena.ship("Gunship"), -128, 128)
	_park(arena, arena.ship("Gunship2"), -110, 128)
	_park(arena, arena.ship("HostileDestroyer"), 128, 128)
	attach(d)
	arena.orders.set_stance([d], AGGRESSIVE)
	arena.orders.set_profile([d], Profiles.Profile.SIEGE)
	arena.orders.set_stance([arena.ship("HostileGunship"), arena.ship("HostileGunship2")], HOLD)
	var e = arena.enemy_controller
	# HostileGunship holds fire: a moving target that closes in (the positioning under test);
	# HostileGunship2 fights.
	e.at(1.0, "HostileGunship (holding fire) closes on the Destroyer", func() -> void: _move(arena, "HostileGunship", Vector2(-6, -50)))
	e.at(24.0, "HostileGunship pushes toward the north boundary", func() -> void: _move(arena, "HostileGunship", Vector2(10, -100)))
	e.at(45.0, "HostileGunship flees south", func() -> void: _move(arena, "HostileGunship", Vector2(0, 60)))
	e.at(55.0, "HostileGunship2 attacks from the east", func() -> void: _attack(arena, "HostileGunship2", "Destroyer", Vector2(40, -70)))
	e.at(72.0, "HostileGunship2 presses north", func() -> void: _move(arena, "HostileGunship2", Vector2(60, -105)))
	e.at(86.0, "HostileGunship2 presses west", func() -> void: _move(arena, "HostileGunship2", Vector2(20, -110)))


# The Destroyer flies a scripted route (turns, past two rocks that block a guard position);
# Gunship (Aggressive, Mid-range) and Gunship2 (Defensive) guard it; HostileGunship attacks
# it mid-route; at 60 s the Destroyer is destroyed (test event).
static func _p03(arena: Node) -> void:
	var d: Node3D = arena.ship("Destroyer")
	var g: Node3D = arena.ship("Gunship")
	var g2: Node3D = arena.ship("Gunship2")
	_place(d, -110, 60, EAST); _place(g, -118, 47, EAST); _place(g2, -118, 73, EAST)
	_place(arena.ship("HostileGunship"), 70, -75, NORTH)
	_park(arena, arena.ship("HostileGunship2"), 128, 128)
	_park(arena, arena.ship("HostileDestroyer"), 110, 128)
	attach(g)
	attach(g2)
	var o = arena.orders
	o.set_stance([d], DEFENSIVE)
	o.set_stance([g], AGGRESSIVE)
	o.set_stance([g2], DEFENSIVE)
	o.set_profile([g], Profiles.Profile.MID)
	o.set_stance([arena.ship("HostileGunship")], HOLD)
	o.guard([g, g2], d)
	var e = arena.enemy_controller
	e.patrol(d, [Vector2(-30, 60), Vector2(10, 20), Vector2(60, 20), Vector2(80, -40), Vector2(20, -80)])
	e.at(20.0, "HostileGunship attacks the Destroyer", func() -> void: _attack(arena, "HostileGunship", "Destroyer", Vector2(20, -30)))
	e.at(60.0, "test event: the protected Destroyer is destroyed", func() -> void:
		var combat = CombatShip.of(arena.ship("Destroyer"))
		if combat != null:
			combat.destroy())


# Scripted hostile attack: Aggressive, manual target, move.
static func _attack(arena: Node, ship_name: String, target_name: String, point: Vector2) -> void:
	var ship: Node3D = arena.ship(ship_name)
	var target: Node3D = arena.ship(target_name)
	if CombatShip.of(ship) == null or not CombatShip.of(ship).alive:
		return
	arena.orders.set_stance([ship], AGGRESSIVE)
	if CombatShip.of(target) != null:
		arena.orders.assign_target([ship], target)
	arena.orders.move([ship], point)


static func _move(arena: Node, ship_name: String, point: Vector2) -> void:
	var ship: Node3D = arena.ship(ship_name)
	if CombatShip.of(ship) != null and CombatShip.of(ship).alive:
		arena.orders.move([ship], point)


static func _place(ship: Node3D, x: float, z: float, heading: float) -> void:
	ship.get_node("Locomotion").place(Vector2(x, z), heading)
	ship.get_node("Avoidance").reset()


static func _park(arena: Node, ship: Node3D, x: float, z: float) -> void:
	_place(ship, x, z, NORTH)
	arena.orders.set_stance([ship], HOLD)
