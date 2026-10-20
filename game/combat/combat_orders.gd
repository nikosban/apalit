extends Node
## The one combat command interface for player input, the hostile commander and tests
## (node `CombatOrders`, migrated from the combat prototype). Each call addresses a list of
## ships (one ship or a group) and changes exactly one channel on every addressed ship that
## can take it:
##   movement:  move() (through the scene's existing command path: RouteFollower /
##              GroupOrders);
##   targeting: assign_target(), clear_target();
##   engagement: set_stance();
##   command (behavior prototype, ships with a Behavior node only): attack(), guard(),
##              attack_move(), waypoint(), request(), cancel(), set_profile().
## A group order overwrites that channel on every addressed ship, including earlier
## individual orders; other channels stay as they are. Destroyed ships take no orders.
## Returns the number of ships that took the order (move: whether it was given).

const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")

signal issued(channel: String, ships: Array, detail: String)

var history: Array[Dictionary] = [] # {time, channel, ships, detail}

@onready var _arena := get_parent()


func move(ships: Array, point: Vector2) -> bool:
	var live := _live(ships)
	if live.is_empty():
		return false
	var given: bool = _arena.issue_move(live, point)
	_record("movement", live, "move to (%.1f, %.1f)%s" % [point.x, point.y, "" if given else " refused"])
	return given


func assign_target(ships: Array, target: Node3D) -> int:
	var count := 0
	var live := _live(ships)
	for ship: Node3D in live:
		if CombatShip.of(ship).assign_target(target):
			count += 1
	_record("targeting", live, "target %s" % (target.name if is_instance_valid(target) else "?"))
	return count


func clear_target(ships: Array) -> int:
	var live := _live(ships)
	for ship: Node3D in live:
		CombatShip.of(ship).clear_target()
	_record("targeting", live, "clear target")
	return live.size()


func set_stance(ships: Array, stance: int) -> int:
	var live := _live(ships)
	for ship: Node3D in live:
		CombatShip.of(ship).set_stance(stance)
	_record("engagement", live, CombatShip.STANCE_NAMES[stance])
	return live.size()


# --- Behavior prototype v0.1 commands (P01–P03): only ships with a `Behavior` node take
# them (behavior/ship_behavior.gd); every other ship refuses (count 0). Channel "command".

func attack(ships: Array, target: Node3D) -> int:
	return _behavior("attack %s" % (target.name if is_instance_valid(target) else "?"), ships, func(b: Node) -> bool: return b.order_attack(target))


func guard(ships: Array, protected: Node3D) -> int:
	var others := ships.filter(func(ship: Variant) -> bool: return ship != protected)
	return _behavior("guard %s" % (protected.name if is_instance_valid(protected) else "?"), others, func(b: Node) -> bool: return b.order_guard(protected))


## Attack-Move; a group gets one destination per ship around the point (GroupOrders, as a
## group MOVE; none for any ship: no order).
func attack_move(ships: Array, point: Vector2) -> int:
	var spots: Dictionary = _arena.group_destinations(_with_behavior(ships), point)
	return _behavior("attack-move to (%.1f, %.1f)" % [point.x, point.y], ships, func(b: Node) -> bool: return spots.has(b.ship) and b.order_attack_move(spots[b.ship]))


## Waypoint Move: `append` adds the point to each ship's sequence under way (a ship without
## one starts a new sequence); a group gets one spot per ship around the point (GroupOrders)
## for its first waypoint, then keeps each ship's offset from the clicked point (legs fly
## in parallel instead of crossing), unless a kept spot is blocked (then a new assignment).
func waypoint(ships: Array, point: Vector2, append: bool) -> int:
	var group := _with_behavior(ships)
	var spots := {}
	var keep: bool = append and group.size() > 1 and group.all(func(ship: Node3D) -> bool: return ship.get_node("Behavior").command == Behavior.Command.WAYPOINTS)
	for ship: Node3D in group if keep else []:
		var spot: Vector2 = point + ship.get_node("Behavior").waypoint_offset
		if not ship.get_node("Behavior")._position_ok(spot):
			keep = false
			break
		spots[ship] = spot
	if not keep:
		spots = _arena.group_destinations(group, point)
	return _behavior("waypoint (%.1f, %.1f)%s" % [point.x, point.y, " added" if append else ""], ships, func(b: Node) -> bool:
		if not spots.has(b.ship) or not b.order_waypoint(spots[b.ship], append):
			return false
		b.waypoint_offset = spots[b.ship] - point
		return true)


## Dock without a station: replacement request only (docking itself is the scene's
## existing Dock command; the Behavior picks it up from the ship's Docking node).
func request(ships: Array, kind: String) -> int:
	return _behavior("%s (replacement only)" % kind, ships, func(b: Node) -> bool: return b.request_replacement(kind))


func cancel(ships: Array) -> int:
	return _behavior("cancel", ships, func(b: Node) -> bool: return b.order_cancel())


func set_profile(ships: Array, profile: int) -> int:
	return _behavior("profile %d" % profile, ships, func(b: Node) -> bool: return b.set_profile(profile))


func _with_behavior(ships: Array) -> Array:
	return _live(ships).filter(func(ship: Node3D) -> bool: return ship.has_node("Behavior"))


func _behavior(detail: String, ships: Array, call: Callable) -> int:
	var count := 0
	var live := _live(ships)
	for ship: Node3D in live:
		var behavior := ship.get_node_or_null("Behavior")
		if behavior != null and call.call(behavior):
			count += 1
	_record("command", live, detail)
	return count


func _live(ships: Array) -> Array[Node3D]:
	var live: Array[Node3D] = []
	for ship: Variant in ships:
		var combat = CombatShip.of(ship)
		if combat != null and combat.alive:
			live.append(ship)
	return live


func _record(channel: String, ships: Array, detail: String) -> void:
	var names := ships.map(func(ship: Node) -> String: return String(ship.name))
	history.append({"time": CombatShip.now(), "channel": channel, "ships": names, "detail": detail})
	issued.emit(channel, ships, detail)
