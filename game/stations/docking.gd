extends Node
## Phase 2 Stage 3 docking of its ship (child node of every ship): Dock and Undock
## at a station, and for ships with a Cargo hold the manual Unload / Load request.
## The station owns berths (their geometry), reservations, the queue and holding
## positions.
##
## Dock: the berths this ship can use are requested (a route reaches the berth's
## handover point, the straight entry is clear for the hull, and at least one exit
## side is clear); none: Unable to Dock, no order. Granted: an ordinary order to the
## handover point. Phase 2.5 stage 2b: once the ship has arrived there at rest with
## the berth reserved, the station takes over (ENTRY phase, still Approaching
## Station): Locomotion's guided mode turns it to the berth's final heading and moves
## it straight to the parking pose; Docked once that has finished on the pose.
## Queued: to a free holding position, keeping the request until the station grants
## a berth. Undock (and a transfer that cannot go on): the controlled exit (EXIT
## phase, Undocking): straight back, turn toward the exit side the station chooses,
## forward to the exit point; the reservation ends when the ship's circle leaves the
## rectangle, Undocking (or, for a blocked transfer, the wait at a holding position)
## once the exit has finished. Mining and Transport read only the states.
##
## Station control (either phase): the ship has no ordinary order; cancel() and
## dock() are refused (counted in `refused_during_control`; legitimate callers never
## send them: commands are held, the panel disables conflicting actions);
## control_ended is emitted when it finishes, then the one held command (a newer one
## replaces it) runs. cancel() outside station control releases the request as
## before and never moves the ship (also while Docked: the reservation is then
## released once the ship has left the rectangle); departure is always undock().
## A blocked transfer keeps its request and undelivered cargo: the ship leaves the
## berth, waits at a holding position and docks again once it can go on. UX round
## (P4): a request made with `wait` (automated Transport only) instead stays in the
## berth, Docked with its reservation (`waiting`, one notice per wait), and goes on
## transferring as stock or storage room appears.

enum State { NONE, REQUESTING, WAITING, APPROACHING, DOCKED, UNDOCKING, BLOCKED, UNABLE }
enum Transfer { NONE, UNLOAD, LOAD }
enum Phase { NONE, ENTRY, EXIT } # Station control within APPROACHING / UNDOCKING.

signal notice(text: String)
signal control_ended

const DisplayName := preload("res://game/ui/display_name.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const Station := preload("res://game/stations/station.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const STATE_NAMES := ["Not docked", "Requesting Dock", "Waiting for Dock", "Approaching Station", "Docked", "Undocking",
	"Waiting to Continue Transfer", "Unable to Dock"]
const RESOLVE_TOLERANCE := 0.25 # u; navigation precision (the maps' cell size).
const DOCK_TOLERANCE := 0.25 # u from the handover point and from the parking pose.
const POSE_HEADING := 0.5 # deg from the berth's final heading at the parking pose.
const SHIP_GAP := 1.5 # u between footprints at holding points (as GroupOrders' margin + buffer).

@export var navigation_path := NodePath("../../../StaticNavigation")

var station: Station = null # The station of the current dock request.
var state := State.NONE
var phase := Phase.NONE
var slot := -1
var dock_point := Vector2.ZERO # The parking point of the granted berth.
var transfer := Transfer.NONE
var load_resource := &"" # Inventory resource of the current Load.
var load_amount := 0
var moved := 0 # Units moved by the current transfer request.
var exit_side := 0 # Side of the current or last exit (+1 ExitA, -1 ExitB).
var refused_during_control := 0 # cancel() / dock() calls refused during station control (should stay 0).
var waiting := false # The current transfer is blocked and waits in the berth (request made with `wait`).

var _approach_point := Vector2.ZERO # The handover point of the granted berth.
var _leaving := -1 # Berth being left.
var _after_exit := State.NONE # NONE (undock) or BLOCKED (blocked transfer, then a holding position).
var _held := Callable() # The one command held until station control ends.
var _carry := 0.0
var _wait_in_berth := false # The current transfer request waits in the berth when blocked.

@onready var _ship := get_parent() as Node3D
@onready var _locomotion := _ship.get_node("Locomotion") as ShipLocomotion
@onready var _follower := _ship.get_node("RouteFollower") as RouteFollower
@onready var _cargo := _ship.get_node_or_null("Cargo")
@onready var _navigation := get_node(navigation_path) as StaticNavigation


func _ready() -> void:
	process_physics_priority = 1 # After Locomotion: reads this tick's position.


func state_name() -> String:
	return STATE_NAMES[state]


func has_cargo_hold() -> bool:
	return _cargo != null


## The station is moving the ship (controlled entry or exit).
func under_control() -> bool:
	return phase != Phase.NONE


## Keeps `command` until station control ends, then runs it (a newer one replaces it).
func hold_command(command: Callable) -> void:
	_held = command


func has_held_command() -> bool:
	return _held.is_valid()


## The command held until station control ends (read-only; empty if none).
func held_command() -> Callable:
	return _held


## Player command: dock at a station (replaces any dock request elsewhere).
func dock(target: Node3D) -> void:
	if under_control():
		_refuse("dock")
		return
	if is_docking_at(target):
		return
	cancel()
	station = target as Station
	state = State.REQUESTING
	if _navigation.is_ready(_follower.planning_radius()):
		_request() # Now, so the station's queue follows the order of the commands.


## Already requesting, waiting for, approaching or docked at this station (a Dock
## command there changes nothing).
func is_docking_at(target: Node3D) -> bool:
	return target == station and state in [State.REQUESTING, State.WAITING, State.APPROACHING, State.DOCKED]


## Player command: leave the berth through the controlled exit.
func undock() -> void:
	if state != State.DOCKED:
		return
	transfer = Transfer.NONE
	waiting = false
	_start_exit(State.NONE)


## The dock request is released: reservation, queue entry, holding position and
## transfer request (units already moved stay moved). Never moves the ship; refused
## during station control.
func cancel() -> void:
	if under_control():
		_refuse("cancel")
		return
	if station != null:
		station.depart(_ship)
	station = null
	state = State.NONE
	slot = -1
	transfer = Transfer.NONE
	waiting = false


## Combat migration: the ship was destroyed. Every station record of it goes at once, in
## any state and also during station control: reservation, queue entry, holding position
## and exit corridor; the held command is dropped. Nothing moves the ship (the hulk still
## occupies the berth physically until it is removed, and berths are granted only when
## physically empty). Docking stops processing with the ship.
func abandon() -> void:
	if station != null:
		station.withdraw(_ship)
		station.release_hold(_ship)
		station.end_exit(_ship)
	_held = Callable()
	station = null
	state = State.NONE
	phase = Phase.NONE
	slot = -1
	_leaving = -1
	transfer = Transfer.NONE
	waiting = false


## Player command (docked, cargo hold): move the ship's cargo into the station.
## `wait` (automated Transport): a full storage keeps the ship in the berth.
func unload(wait := false) -> void:
	if state == State.DOCKED and _cargo != null and _cargo.inventory.quantity() > 0:
		_start(Transfer.UNLOAD, &"", 0, wait)


## Player command (docked, cargo hold): take `amount` units of one resource from the station.
## `wait` (automated Transport): a resource out of stock keeps the ship in the berth.
func load_cargo(resource: StringName, amount: int, wait := false) -> void:
	if state == State.DOCKED and _cargo != null and amount > 0:
		_start(Transfer.LOAD, resource, amount, wait)


## Ends the current transfer request (units already moved stay moved).
func stop_transfer() -> void:
	transfer = Transfer.NONE
	waiting = false


## [moved, total] of the current transfer request.
func progress() -> Array:
	if transfer == Transfer.UNLOAD:
		return [moved, moved + _cargo.inventory.quantity()]
	return [moved, load_amount]


func _start(kind: Transfer, resource: StringName, amount: int, wait := false) -> void:
	transfer = kind
	load_resource = resource
	load_amount = amount
	moved = 0
	_carry = 0.0
	_wait_in_berth = wait
	waiting = false


func _refuse(what: String) -> void:
	refused_during_control += 1
	push_error("%s: %s() refused during station control" % [_ship.name, what])


func _physics_process(delta: float) -> void:
	match state:
		State.REQUESTING:
			if _navigation.is_ready(_follower.planning_radius()):
				_request()
		State.WAITING:
			var granted: int = station.slot_of(_ship)
			if granted >= 0:
				_approach(granted)
		State.APPROACHING:
			_update_approach()
		State.DOCKED:
			if transfer != Transfer.NONE:
				_transfer_step(delta)
		State.UNDOCKING:
			if not _locomotion.guided:
				phase = Phase.NONE
				station.end_exit(_ship)
				state = _after_exit
				if state == State.BLOCKED:
					_go_to_hold()
				_end_control()
		State.BLOCKED:
			if _transfer_possible():
				state = State.REQUESTING


## Whether this ship could dock at a station from where it is (at least one berth it
## can use); a full station still counts.
func can_dock(target: Node3D) -> bool:
	return not _allowed_slots(target as Station).is_empty()


func _allowed_slots(target: Station) -> Array:
	var allowed := []
	var radius := _follower.ship_radius
	for i in target.berths.size():
		var berth: Node3D = target.berths[i]
		var handover: Vector2 = berth.handover_point(radius)
		if _reachable(_locomotion.planar_position, handover) and _navigation.segment_clear(handover, berth.park_point(radius), radius) \
				and not target.exit_sides(i, radius).is_empty():
			allowed.append(i)
	return allowed


func _request() -> void:
	var allowed := _allowed_slots(station)
	if allowed.is_empty():
		station.withdraw(_ship)
		station.release_hold(_ship)
		state = State.UNABLE
		notice.emit("%s: unable to dock - no reachable docking position" % DisplayName.of(_ship))
		return
	var granted: int = station.request(_ship, allowed)
	if granted >= 0:
		_approach(granted)
		return
	state = State.WAITING
	_go_to_hold()


func _approach(index: int) -> void:
	slot = index
	station.release_hold(_ship)
	dock_point = station.berths[index].park_point(_follower.ship_radius)
	_approach_point = station.berths[index].handover_point(_follower.ship_radius)
	phase = Phase.NONE
	state = State.APPROACHING
	_follower.order(_approach_point)


func _update_approach() -> void:
	var berth: Node3D = station.berths[slot]
	if phase == Phase.ENTRY:
		if _locomotion.guided:
			return
		phase = Phase.NONE
		var error := absf(rad_to_deg(wrapf(_locomotion.heading - berth.park_heading(), -PI, PI)))
		if _locomotion.planar_position.distance_to(dock_point) <= DOCK_TOLERANCE and error <= POSE_HEADING:
			state = State.DOCKED
		else:
			# A contact stopped the entry short: reported, nothing recovered.
			notice.emit("%s: entry stopped short of the berth" % DisplayName.of(_ship))
		_end_control()
		return
	if _locomotion.has_destination:
		return
	# Station handover: arrived at the handover point, at rest, with the berth reserved.
	if _locomotion.planar_position.distance_to(_approach_point) <= DOCK_TOLERANCE and _locomotion.velocity == Vector2.ZERO \
			and station.slots[slot].ship == _ship:
		_follower.clear()
		phase = Phase.ENTRY
		_locomotion.guide(berth.entry_legs(_follower.ship_radius), station.guide_speed, station.guide_accel,
			station.guide_turn_rate_deg, station.guide_turn_accel_deg)
		return
	station.depart(_ship)
	slot = -1
	state = State.UNABLE
	notice.emit("%s: unable to dock - stopped short of the handover point" % DisplayName.of(_ship))


# The controlled exit toward the side the station chooses; false (stays docked) if
# no side is clear.
func _start_exit(after: State) -> bool:
	exit_side = station.choose_exit_side(slot, _ship)
	if exit_side == 0:
		notice.emit("%s: no clear exit - stays docked" % DisplayName.of(_ship))
		return false
	_after_exit = after
	var legs: Array = station.berths[slot].exit_legs(_follower.ship_radius, exit_side)
	station.depart(_ship) # The reservation ends once the circle leaves the rectangle.
	station.begin_exit(_ship)
	_leaving = slot
	slot = -1
	state = State.UNDOCKING
	phase = Phase.EXIT
	_follower.clear()
	_locomotion.guide(legs, station.guide_speed, station.guide_accel, station.guide_turn_rate_deg, station.guide_turn_accel_deg)
	return true


func _end_control() -> void:
	control_ended.emit()
	if _held.is_valid():
		var command := _held
		_held = Callable()
		command.call()


# The nearest free holding position the ship can reach (kept if it already has one); none:
# it waits where it is.
func _go_to_hold() -> void:
	if station.hold_of(_ship) >= 0:
		return
	var position := _locomotion.planar_position
	var nearest := range(station.holds.size())
	nearest.sort_custom(func(a: int, b: int) -> bool: return station.holds[a].point.distance_to(position) < station.holds[b].point.distance_to(position))
	for i: int in nearest:
		var hold: Dictionary = station.holds[i]
		if hold.ship == null and not _occupied(hold.point) and _reachable(_locomotion.planar_position, hold.point):
			station.reserve_hold(_ship, i)
			_follower.order(hold.point)
			return
	notice.emit("%s: no free holding position - waiting here" % DisplayName.of(_ship))


func _transfer_step(delta: float) -> void:
	_carry += station.transfer_rate * delta
	var whole := floori(_carry)
	_carry -= whole
	var hold: Inventory = _cargo.inventory
	var storage: Inventory = station.storage
	var before := moved
	if transfer == Transfer.UNLOAD:
		moved += hold.transfer_to(storage, whole)
		if moved > before:
			waiting = false # Going on: a later block is a new wait.
		if hold.quantity() == 0:
			_finish("unloaded %d units" % moved)
		elif storage.free_space() == 0:
			_block("station storage full")
	else:
		moved += storage.transfer_to(hold, mini(whole, load_amount - moved), load_resource)
		if moved > before:
			waiting = false
		if moved >= load_amount:
			_finish("loaded %d units" % moved)
		elif hold.free_space() == 0:
			_finish("cargo hold full after %d units" % moved)
		elif storage.quantity_of(load_resource) == 0:
			_block("no %s in stock" % Inventory.display_name(load_resource))


func _transfer_possible() -> bool:
	if transfer == Transfer.UNLOAD:
		return station.storage.free_space() > 0 and _cargo.inventory.quantity() > 0
	return station.storage.quantity_of(load_resource) > 0 and _cargo.inventory.free_space() > 0


func _finish(text: String) -> void:
	transfer = Transfer.NONE
	waiting = false
	notice.emit("%s: %s" % [DisplayName.of(_ship), text])


# Keeps the transfer request; leaves the berth through the controlled exit for a
# holding position (no clear exit: the request ends and the ship stays docked).
# A request made with `wait` stays in the berth instead (one notice per wait).
func _block(reason: String) -> void:
	if _wait_in_berth:
		if not waiting:
			waiting = true
			notice.emit("%s: %s - waiting in the berth" % [DisplayName.of(_ship), reason])
		return
	notice.emit("%s: %s - waiting nearby" % [DisplayName.of(_ship), reason])
	if not _start_exit(State.BLOCKED):
		transfer = Transfer.NONE


# Another ship at, or heading for, a point too close for this ship (a ship that is
# leaving a point still occupies it).
func _occupied(point: Vector2) -> bool:
	for other: Node in _ship.get_parent().get_children():
		if other == _ship or other.get_node_or_null("Locomotion") == null:
			continue
		var locomotion := other.get_node("Locomotion") as ShipLocomotion
		var gap := _follower.ship_radius + (other.get_node("RouteFollower") as RouteFollower).ship_radius + SHIP_GAP
		if locomotion.planar_position.distance_to(point) < gap or (locomotion.has_destination and locomotion.destination.distance_to(point) < gap):
			return true
	return false


# A route for this ship's planning radius from `from` ends at `point`.
func _reachable(from: Vector2, point: Vector2) -> bool:
	var radius := _follower.planning_radius()
	if _navigation.closest_point(radius, point).distance_to(point) > RESOLVE_TOLERANCE:
		return false
	if from.distance_to(point) <= RESOLVE_TOLERANCE:
		return true
	var route := _navigation.plan(radius, from, point)
	return route.size() >= 2 and route[route.size() - 1].distance_to(point) <= RESOLVE_TOLERANCE
