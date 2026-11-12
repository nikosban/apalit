extends Node
## Dispatches resolved orders and tracks intent deferred by station control.

const DisplayName := preload("res://game/ui/display_name.gd")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const GroupOrders := preload("res://game/orders/group_orders.gd")
const Station := preload("res://game/stations/station.gd")

## Shared intent kinds. Player handles TARGET through CombatOrders.
enum CommandKind { DOCK, MINE, MOVE, GROUP_MOVE, GROUP, TARGET }

const GROUP_NOTICE := "Not enough space for the group - no orders given"

signal command_given(ship: Node3D, kind: int)
signal notice_requested(text: String)

var _group_orders: GroupOrders
var _navigation: StaticNavigation
var _asteroids: AsteroidField
var _sector_half_size: Callable
var _pending := {} # Ship to its held intent and the callback registered with Docking.
var _silent := false # Availability checks suppress notices.


func configure(group_orders: GroupOrders, navigation: StaticNavigation,
		asteroids: AsteroidField, sector_half_size: Callable) -> void:
	_group_orders = group_orders
	_navigation = navigation
	_asteroids = asteroids
	_sector_half_size = sector_half_size


## Submit an already resolved movement, docking or mining order for the supplied recipients.
## Returns true when at least one recipient accepted it, including a queued or held order.
func submit_intent(ships: Array, command: Dictionary) -> bool:
	if ships.is_empty() or command.is_empty() or command.kind == CommandKind.TARGET:
		return false
	if command.kind != CommandKind.GROUP:
		return _order(ships[0], command)
	var point: Vector2 = command.point
	# Only the ships that get a destination are ordered; the others keep their orders,
	# assignments and commands.
	if not ships.any(func(ship: Node3D) -> bool: return _held(ship)):
		return _dispatch_group(ships, point)
	# Some ships are under station control or docked: the same assignment; each such
	# ship keeps its own destination (the others go now).
	var destinations := _group_orders.assign(ships, point)
	if destinations.is_empty():
		_show_notice(GROUP_NOTICE)
		return false
	var accepted := 0
	for ship: Node3D in destinations:
		if _order(ship, {"kind": CommandKind.GROUP_MOVE, "point": destinations[ship]}):
			accepted += 1
	_notice_partial(accepted, ships.size())
	return accepted > 0


## Checks availability without issuing orders or notices.
## Under station control, only the intent is checked. Group MOVE uses the same
## destination solver as submission.
func can_submit_intent(ships: Array, command: Dictionary) -> bool:
	if ships.is_empty() or command.is_empty() or command.kind == CommandKind.TARGET:
		return false
	if command.kind == CommandKind.GROUP:
		return _group_orders.can_assign(ships, command.point)
	var ship: Node3D = ships[0]
	var docking := _docking_of(ship)
	if command.kind == CommandKind.DOCK and docking != null and docking.is_docking_at(command.station):
		return false
	_silent = true
	var available := _intent_valid(ship, command) if docking != null and docking.under_control() else _check(ship, command)
	_silent = false
	return available


## Returns the held MOVE destination and removes entries Docking no longer holds.
func held_move(ship: Node3D) -> Variant:
	if not _pending.has(ship):
		return null
	var docking := _docking_of(ship)
	if docking == null or docking.held_command() != _pending[ship].callable:
		_pending.erase(ship)
		return null
	var command: Dictionary = _pending[ship].command
	if command.kind == CommandKind.MOVE or command.kind == CommandKind.GROUP_MOVE:
		return command.point
	return null


## Scripted MOVE through CombatOrders. A single ship can hold the order during station
## control. A group uses direct dispatch through GroupOrders, as before.
func issue_move(ships: Array, point: Vector2) -> bool:
	if ships.size() == 1:
		return _order(ships[0], {"kind": CommandKind.MOVE, "point": point})
	return _dispatch_group(ships, point)


## Drops Command's pending entry when the arena reports that a ship was destroyed.
func forget_ship(ship: Node3D) -> void:
	_pending.erase(ship)


func _dispatch_group(ships: Array, point: Vector2) -> bool:
	var given := _group_orders.command(ships, point)
	if given.is_empty():
		_show_notice(GROUP_NOTICE)
		return false
	for ship: Node3D in given:
		_release_assignments(ship)
		command_given.emit(ship, CommandKind.GROUP_MOVE)
	_notice_partial(given.size(), ships.size())
	return true


# A group MOVE accepted by only some of the ships says so (accepted: executed, or held
# until station control or the controlled exit ends).
func _notice_partial(accepted: int, total: int) -> void:
	if accepted < total:
		_show_notice("%d of %d ships ordered; %d not ordered" % [accepted, total, total - accepted])


# Gives a resolved command to one ship. Under station control it is checked in two
# stages: now only its intent (_intent_valid: the target exists and the ship can carry
# it out; no route is planned from the guided position), a refused one changing
# nothing, so the last valid command stays held; an accepted one is held (newest valid
# wins) and given again when control ends, checked then from the ship's actual
# position (refused: its notice, and the held command is gone). Dock at the station
# it is already docking at changes nothing. Docked (anything but its own station): it
# is checked first; refused, nothing changes; accepted, automation is paused (as the
# panel's Undock does), the command held and the controlled exit started. Otherwise
# it is executed now (with its own checks). A held MOVE shows its destination marker.
# Returns whether the command was accepted: executed, or held for station control or
# the controlled exit (accepted, not necessarily under way yet).
func _order(ship: Node3D, command: Dictionary) -> bool:
	var docking := _docking_of(ship)
	var own_station: bool = command.kind == CommandKind.DOCK and docking != null and docking.is_docking_at(command.station)
	if docking != null and docking.under_control():
		if own_station or not _intent_valid(ship, command):
			return false
		_hold(ship, docking, command)
		_show_notice("%s: order after station control" % DisplayName.of(ship))
		return true
	if docking != null and docking.state == Docking.State.DOCKED and not own_station:
		if not _check(ship, command):
			return false
		_pause_automation(ship)
		_hold(ship, docking, command)
		docking.undock()
		if docking.state == Docking.State.DOCKED:
			docking.hold_command(Callable()) # No clear exit (its notice): nothing else changes.
			_pending.erase(ship)
			return false
		return true
	return _execute(ship, command)


# Holds a command until station control ends (replacing any held one) and remembers it
# for the destination marker.
func _hold(ship: Node3D, docking: Docking, command: Dictionary) -> void:
	var release := _release.bind(ship, command)
	_pending[ship] = {"command": command, "callable": release}
	docking.hold_command(release)


# Station control ended: the held command is given (checked from where the ship is now).
func _release(ship: Node3D, command: Dictionary) -> void:
	_pending.erase(ship)
	_order(ship, command)


# The command's intent, independent of where the ship is: its target exists and the
# ship has what the command needs. Refused: a notice, nothing changes.
func _intent_valid(ship: Node3D, command: Dictionary) -> bool:
	var valid := true
	match command.kind:
		CommandKind.DOCK:
			valid = _docking_of(ship) != null and is_instance_valid(command.station) and (command.station as Node).is_in_group(Station.GROUP)
		CommandKind.MINE:
			valid = _mining_of(ship) != null and _asteroids != null and _asteroids.ids().has(command.asteroid)
		CommandKind.MOVE, CommandKind.GROUP_MOVE:
			var point: Vector2 = command.point
			var half_size: float = _sector_half_size.call()
			valid = ship.get_node_or_null("RouteFollower") != null and absf(point.x) <= half_size and absf(point.y) <= half_size
	if not valid:
		_show_notice("%s: order not possible - held order kept" % DisplayName.of(ship))
	return valid


# Returns whether the command was accepted (executed).
func _execute(ship: Node3D, command: Dictionary) -> bool:
	match command.kind:
		CommandKind.DOCK:
			var docking := _docking_of(ship)
			if docking.is_docking_at(command.station):
				return false # Already docking there: nothing to change.
			if not _check(ship, command):
				return false
			_pause_automation(ship)
			docking.dock(command.station)
			command_given.emit(ship, command.kind)
			return true
		CommandKind.MINE:
			if not _check(ship, command):
				return false
			if _docking_of(ship) != null:
				_docking_of(ship).cancel()
			_mining_of(ship).assign(command.asteroid)
			command_given.emit(ship, command.kind)
			return true
		CommandKind.MOVE:
			if _move_single(ship, command.point):
				_release_assignments(ship)
				command_given.emit(ship, command.kind)
				return true
		CommandKind.GROUP_MOVE:
			if (ship.get_node("RouteFollower") as RouteFollower).order(command.point):
				_release_assignments(ship)
				command_given.emit(ship, command.kind)
				return true
	return false


# The refusal checks of each command, with their notices; nothing changes.
func _check(ship: Node3D, command: Dictionary) -> bool:
	match command.kind:
		CommandKind.DOCK:
			if _map_ready(ship) and not _docking_of(ship).can_dock(command.station):
				_show_notice("%s: unable to dock - no reachable docking position" % DisplayName.of(ship))
				return false
		CommandKind.MINE:
			if not _mining_of(ship).can_mine(command.asteroid):
				_show_notice("%s: no reachable working position at the asteroid" % DisplayName.of(ship))
				return false
		CommandKind.MOVE, CommandKind.GROUP_MOVE:
			var point: Vector2 = command.point
			if command.kind == CommandKind.MOVE:
				var occupied := _group_orders.resolve_occupied(ship, point)
				if not occupied.is_empty():
					if not occupied.has("point"):
						_show_notice("No free position near %s - no order given" % DisplayName.of(occupied.blocker))
						return false
					point = occupied.point
			if _map_ready(ship):
				var follower := ship.get_node("RouteFollower") as RouteFollower
				var position := (ship.get_node("Locomotion") as ShipLocomotion).planar_position
				if _navigation.plan(follower.planning_radius(), position, point).size() < 2:
					_show_notice("No route found")
					return false
	return true


# Under station control, or docked (a command for it starts the controlled exit first).
func _held(ship: Node3D) -> bool:
	var docking := _docking_of(ship)
	return docking != null and (docking.under_control() or docking.state == Docking.State.DOCKED)


func _pause_automation(ship: Node3D) -> void:
	if _mining_of(ship) != null:
		_mining_of(ship).cancel()
	if _transport_of(ship) != null:
		_transport_of(ship).cancel()


# A manual MOVE replaced the ship's assignments: mining and transport pause (settings
# kept), the dock request is released.
func _release_assignments(ship: Node3D) -> void:
	_pause_automation(ship)
	if _docking_of(ship) != null:
		_docking_of(ship).cancel()


# Single-ship MOVE. A point inside a stationary ship's clearance is replaced by the
# nearest valid destination outside it (GroupOrders.resolve_occupied), shown by the
# destination ring and a notice; none: a notice and no order (the current order and
# assignments stay). An order counts only once RouteFollower has taken it (or queued
# it); one it refuses (no route) changes nothing. Returns whether an order was given.
func _move_single(ship: Node3D, point: Vector2) -> bool:
	var follower := ship.get_node("RouteFollower") as RouteFollower
	var occupied := _group_orders.resolve_occupied(ship, point)
	if occupied.is_empty():
		return follower.order(point, PackedVector2Array(), true) # Refused (no route): its notice, nothing changed.
	var blocker: Node = occupied.blocker
	if not occupied.has("point"):
		_show_notice("No free position near %s - no order given" % DisplayName.of(blocker))
		return false
	if not follower.order(occupied.point, PackedVector2Array(), true):
		return false
	_show_notice("Destination occupied by %s - moved beside it" % DisplayName.of(blocker))
	return true


func _map_ready(ship: Node) -> bool:
	return _navigation.is_ready((ship.get_node("RouteFollower") as RouteFollower).planning_radius())


func _mining_of(ship: Node) -> MiningOperation:
	return ship.get_node_or_null("Mining") as MiningOperation


func _docking_of(ship: Node) -> Docking:
	return ship.get_node_or_null("Docking") as Docking


func _transport_of(ship: Node) -> TransportOperation:
	return ship.get_node_or_null("Transport") as TransportOperation


func _show_notice(text: String) -> void:
	if not _silent:
		notice_requested.emit(text)
