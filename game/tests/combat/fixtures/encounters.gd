extends RefCounted
## Combat fixture: the fleet encounter E05 (e05_fleet.tscn: encounter_arena.tscn plus a
## third FF-01 per side, its asteroids and its own controller nodes), three FF-01s per
## side. It places the ships at rest (Locomotion.place(), set-up only) and sets their
## channels through CombatOrders. Headings: Godot yaw, 0 = bow to −Z.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const EAST := -PI * 0.5
const WEST := PI * 0.5
const NORTH := 0.0
const SOUTH := PI
const HOLD := 0
const DEFENSIVE := 1
const AGGRESSIVE := 2

const NAMES := [
	"E05 Fleet combat 3 v 3 (three FF-01s each, equal stocks): destroy the hostile fleet",
]


static func count() -> int:
	return NAMES.size()


static func apply(arena: Node, index: int) -> String:
	var a: Node3D = arena.ship("FF01A")
	var b: Node3D = arena.ship("FF01B")
	var c: Node3D = arena.ship("FF01C")
	var ha: Node3D = arena.ship("HostileFF01A")
	var hb: Node3D = arena.ship("HostileFF01B")
	var hc: Node3D = arena.ship("HostileFF01C")
	var o = arena.orders
	# Player column in the west, slightly south; hostile wedge in the east, slightly
	# north. 172 u between the column and wedge leads (beyond every weapon's range); the
	# line between the fleets runs through the central rock. Both sides start Aggressive;
	# the hostile fleet's orders come from HostileFleet.
	# Rocks (x, z, radius): 1 (0, 0, 10) central, blocks the direct line; 2 (-6, -42, 6)
	# and 3 (8, 40, 7) split the middle into four approach routes (north of 2, between 2
	# and 1, between 1 and 3, south of 3); 4 (-50, -12, 5) cover in front of the player, 5
	# (46, 16, 5) its counterpart in front of the hostile fleet; 6 (-32, 58, 6) and 7 (34,
	# -62, 6) flank rocks. Rocks and fleets are roughly point-symmetric about the centre
	# (balanced); the formations differ (column vs wedge) and are offset north / south
	# (asymmetric).
	_place(a, -85, 12, EAST); _place(b, -74, 0, EAST); _place(c, -76, 26, EAST)
	_place(ha, 88, -16, WEST); _place(hb, 76, -30, WEST); _place(hc, 74, -4, WEST)
	o.set_stance([a, b, c, ha, hb, hc], AGGRESSIVE)
	# Played with the Behavior layer, the player ships get their Behavior node (commands,
	# tactics, weapon profiles). The hostile fleet stays under HostileFleet, its commander:
	# autonomous Behavior movement would compete with its station orders.
	if arena.behavior_layer:
		for ship: Node3D in [a, b, c]:
			attach(ship)
	return NAMES[index]


## Gives a ship its Behavior node and the Defensive target priority (engageable attackers
## first, its own attackers before its allies').
static func attach(ship: Node3D) -> Node:
	var behavior := Behavior.new()
	behavior.name = "Behavior"
	ship.add_child(behavior)
	CombatShip.of(ship).defensive_priority = true
	return behavior


static func _place(ship: Node3D, x: float, z: float, heading: float) -> void:
	ship.get_node("Locomotion").place(Vector2(x, z), heading)
	ship.get_node("Avoidance").reset()
