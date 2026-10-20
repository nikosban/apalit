extends Node
## Phase 2 mining assignment of its ship (child node of a miner, next to its
## Extractor, Cargo, Docking and Fuel). The saved configuration (`target`, the
## assigned asteroid, and `base`, the chosen station or null for the nearest) is
## kept apart from the active operation (`status`): a manual order cancels the
## operation and keeps the configuration; Resume restarts it.
##
## Stage 2: on (re)starting at the asteroid it picks a working point once: around
## the asteroid, at its outline plus a working distance inside the Extractor's
## range, the candidates nearest the ship's side first; a point is accepted when
## the ship's planning radius fits there (navigation map), no other ship is parked
## at or heading for it, and a route from the ship ends there. It then gives one
## RouteFollower order (none if there is no such point: UNREACHABLE). Extraction
## runs while the ship holds position (nearly stopped) within working range and (UX
## round) faces the asteroid: once arrived it turns toward the asteroid's centre
## through Locomotion.face() and extracts only within ALIGN_TOLERANCE.
##
## Stage 5 cycle: when the cargo is full (or the asteroid depleted) it returns to
## the base: the explicit base if this ship can dock there, else (no explicit
## base) the nearest station it can dock at; none: it waits (CARGO_FULL / DEPLETED).
## It asks its Docking node to dock (the station's slots, queue and holding
## positions as for any ship), to unload once docked (the timed transfer; a full
## station keeps the request and waits nearby), then waits while Fuel refuels
## (until full or the station has none left) and undocks. Once Docking is clear of
## the slot it returns to the same asteroid (a new working point), or after a
## depletion it stops (DEPLETED). Each leg is one order, given by Docking or by
## this node, never both: the docking state is read from Docking, not duplicated.
## Low or empty fuel changes nothing here (Fuel immobilizes an empty ship).

enum Status { NONE, TRAVELING, MINING, CARGO_FULL, DEPLETED, UNREACHABLE, CANCELED, RETURNING }

signal notice(text: String)

const DisplayName := preload("res://game/ui/display_name.gd")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const Extractor := preload("res://game/mining/extractor.gd")
const Cargo := preload("res://game/cargo/cargo.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const Fuel := preload("res://game/fuel/fuel.gd")
const CANDIDATES := 16 # Working points tried around the asteroid.
const WORK_MARGIN := 0.75 # u the working point lies inside the working range.
const RESOLVE_TOLERANCE := 0.25 # u; navigation precision (the maps' cell size).
const SHIP_GAP := 1.5 # u kept between ship footprints at working points (as GroupOrders' margin + buffer).
const HOLD_SPEED := 0.2 # u/s; slower than this counts as holding position.
const ALIGN_TOLERANCE := 1.0 # deg; extraction runs only while the bow is this close to the asteroid's centre.
const STATUS_NAMES := ["No assignment", "Traveling", "Mining", "Cargo Full - No Eligible Base", "Asteroid Depleted",
	"Unreachable", "Assignment Paused", "Returning to Base"]

@export var field_path := NodePath("../../../Asteroids")
@export var navigation_path := NodePath("../../../StaticNavigation")
@export var ships_path := NodePath("../..")

var target := -1 # Saved configuration: the assigned asteroid (kept after cancellation).
var base: Node3D = null # Saved configuration: the chosen base station, or null for the nearest.
var status := Status.NONE # The active operation.
var work_point := Vector2.ZERO
var trip_base: Node3D = null # The station of the current (or last) return trip.
var extracting := false # Extracted this tick (in range, holding position, facing the asteroid).

var _route_pending := false
var _depleted := false # The current return is the final one (asteroid depleted).
var _resuming := false # Traveling back after a trip to the base.
var _leaving := false # Undocking after unloading and refueling.

@onready var _ship := get_parent() as Node3D
@onready var _locomotion := _ship.get_node("Locomotion") as ShipLocomotion
@onready var _follower := _ship.get_node("RouteFollower") as RouteFollower
@onready var _extractor := _ship.get_node("Extractor") as Extractor
@onready var _cargo := _ship.get_node("Cargo") as Cargo
@onready var _docking := _ship.get_node_or_null("Docking") as Docking
@onready var _fuel := _ship.get_node_or_null("Fuel") as Fuel
@onready var _field := get_node(field_path) as AsteroidField
@onready var _navigation := get_node(navigation_path) as StaticNavigation
@onready var _ships := get_node(ships_path)


func _ready() -> void:
	process_physics_priority = 1 # After Locomotion: reads this tick's position.


func status_name() -> String:
	return STATUS_NAMES[status]


func is_active() -> bool:
	return status == Status.TRAVELING or status == Status.MINING or status == Status.RETURNING


## What the ship is doing (or why it waits), for the panel.
func activity() -> String:
	var text := status_name()
	match status:
		Status.TRAVELING:
			text = "Returning to Asteroid" if _resuming else "Traveling to Asteroid"
		Status.DEPLETED:
			text = "Asteroid Depleted - select a new target"
		Status.RETURNING:
			if _leaving:
				text = "Leaving Base"
			else:
				match _docking.state:
					Docking.State.WAITING:
						text = "Waiting for Dock"
					Docking.State.BLOCKED:
						text = "Waiting for Storage"
					Docking.State.DOCKED:
						var unloading := _docking.transfer == Docking.Transfer.UNLOAD or _cargo.inventory.quantity() > 0
						text = "Unloading" if unloading else "Resupplying"
			if _depleted:
				text += " (asteroid depleted)"
	if is_active() and _fuel != null and _fuel.fuel <= 0.0:
		text += " - Out of Fuel"
	return text


## Player command: mine this asteroid (replaces any current operation and its dock request).
func assign(asteroid: int) -> void:
	target = asteroid
	if _docking != null:
		_docking.cancel()
	_extractor.reset()
	_depleted = false
	_resuming = false
	_leaving = false
	if _cargo.inventory.free_space() == 0:
		_return_to_base() # Already full: unload first.
		return
	status = Status.TRAVELING
	_route_pending = true


## Player command (Start / Resume Mining): restart the saved assignment. Refused
## with a notice, nothing changed, if no working position is reachable (can_mine).
func resume() -> bool:
	if not can_resume():
		return false
	if not can_mine(target):
		notice.emit("%s: no reachable working position at the asteroid" % DisplayName.of(_ship))
		return false
	assign(target)
	return true


## Whether a working position at the asteroid is reachable from where the ship is
## (the check the operation makes before its order); read-only. Player commands ask
## it first so that a refused command changes nothing. True while the navigation map
## is not ready yet (decided once it is, as before).
func can_mine(asteroid: int) -> bool:
	if not _navigation.is_ready(_follower.planning_radius()):
		return true
	return _find_work_point(asteroid) != null


## A saved, inactive assignment whose asteroid still has reserves.
func can_resume() -> bool:
	return target >= 0 and not is_active() and _field.deposit(target).reserves > 0


## Player choice of base (null: the nearest); applies from the next return trip.
func set_base(station: Node3D) -> void:
	base = station


## Stations this ship can dock at from where it is, nearest first.
func eligible_bases() -> Array[Node3D]:
	var found: Array[Node3D] = []
	if _docking == null:
		return found
	for station: Node3D in get_tree().get_nodes_in_group(Station.GROUP):
		if _docking.can_dock(station):
			found.append(station)
	var at := _locomotion.planar_position
	found.sort_custom(func(a: Node3D, b: Node3D) -> bool: return _planar(a).distance_to(at) < _planar(b).distance_to(at))
	return found


## A manual order replaced the operation: it stops, the configuration is kept
## (the caller releases any dock request).
func cancel() -> void:
	_route_pending = false
	_leaving = false
	if is_active():
		status = Status.CANCELED


func _physics_process(delta: float) -> void:
	extracting = false
	if _route_pending:
		if not _navigation.is_ready(_follower.planning_radius()):
			return
		if _docking != null and _docking.under_control():
			return # Phase 2.5: the station is moving the ship; the order waits for control to end.
		_route_pending = false
		var point: Variant = _find_work_point()
		if point == null:
			status = Status.UNREACHABLE
			notice.emit("%s: no reachable working position at the asteroid" % DisplayName.of(_ship))
			return
		work_point = point
		_follower.order(work_point)
	if status == Status.RETURNING:
		_update_return()
		return
	if not is_active():
		return
	if not _extractor.in_range(target) or _locomotion.velocity.length() > HOLD_SPEED:
		status = Status.TRAVELING
		return
	if _finished():
		return
	status = Status.MINING
	_resuming = false
	# UX round (P3): the ship turns to face the asteroid through Locomotion once its
	# arrival is complete, and extracts only while facing it (within ALIGN_TOLERANCE).
	var center := _field.center(target)
	var bearing := _locomotion.bearing_heading(Vector2(center.x, center.z) - _locomotion.planar_position)
	_locomotion.face(bearing) # Refused while the arrival is still completing.
	if absf(rad_to_deg(wrapf(bearing - _locomotion.heading, -PI, PI))) > ALIGN_TOLERANCE:
		return
	extracting = true
	_extractor.extract(target, _cargo.inventory, delta)
	_finished()


# A full cargo or a depleted asteroid ends the extraction and starts the return
# (cargo stays aboard); true if it ended.
func _finished() -> bool:
	if _cargo.inventory.free_space() == 0:
		notice.emit("%s: cargo full - returning to base" % DisplayName.of(_ship))
		_depleted = _field.deposit(target).reserves == 0 # The last load: no trip back.
	elif _field.deposit(target).reserves == 0:
		notice.emit("%s: asteroid depleted - returning to base" % DisplayName.of(_ship))
		_depleted = true
	else:
		return false
	_return_to_base()
	return true


func _return_to_base() -> void:
	trip_base = _choose_base()
	if trip_base == null:
		status = Status.DEPLETED if _depleted else Status.CARGO_FULL
		notice.emit("%s: no eligible base - waiting" % DisplayName.of(_ship))
		return
	status = Status.RETURNING
	_leaving = false
	_docking.dock(trip_base)


# The explicit base if this ship can dock there (no silent change), else the nearest
# station it can dock at; null if none.
func _choose_base() -> Node3D:
	if _docking == null:
		return null
	if base != null:
		return base if _docking.can_dock(base) else null
	var found := eligible_bases()
	return found[0] if not found.is_empty() else null


# Follows Docking through the trip; gives the unload request, undocks once unloaded
# and resupplied, and leaves for the asteroid once Docking is clear of the slot.
func _update_return() -> void:
	if _leaving:
		if _docking.state == Docking.State.UNDOCKING:
			return
		_leaving = false
		if _depleted:
			status = Status.DEPLETED
			notice.emit("%s: asteroid depleted - waiting for a new target" % DisplayName.of(_ship))
			return
		_resuming = true
		status = Status.TRAVELING
		_route_pending = true
		return
	match _docking.state:
		Docking.State.UNABLE:
			status = Status.DEPLETED if _depleted else Status.CARGO_FULL
		Docking.State.NONE:
			status = Status.CANCELED # The dock request was released by someone else.
		Docking.State.DOCKED:
			if _docking.transfer != Docking.Transfer.NONE:
				return
			if _cargo.inventory.quantity() > 0:
				_docking.unload()
			elif _resupplied():
				_leaving = true
				_docking.undock()


func _resupplied() -> bool:
	return _fuel == null or _fuel.fuel >= _fuel.capacity or (_docking.station as Station).fuel_stock <= 0.0


func _find_work_point(asteroid := target) -> Variant:
	var center3 := _field.center(asteroid)
	var center := Vector2(center3.x, center3.z)
	var distance := _field.radius(asteroid) + _extractor.working_range - WORK_MARGIN
	var radius := _follower.planning_radius()
	var position := _locomotion.planar_position
	var toward := position - center
	var start := toward.angle() if toward.length() > 0.001 else 0.0
	for k in CANDIDATES:
		# Nearest the ship's side first: 0, +1, -1, +2, -2, ... steps.
		var step := int((k + 1) / 2.0) * (1 if k % 2 == 1 else -1)
		var point := center + Vector2.from_angle(start + TAU * step / CANDIDATES) * distance
		if _navigation.closest_point(radius, point).distance_to(point) > RESOLVE_TOLERANCE:
			continue
		if _occupied(point):
			continue
		var route := _navigation.plan(radius, position, point)
		if route.size() >= 2 and route[route.size() - 1].distance_to(point) <= RESOLVE_TOLERANCE:
			return point
	return null


# Another ship parked at, or heading for, a point too close to this one.
func _occupied(point: Vector2) -> bool:
	for other: Node in _ships.get_children():
		if other == _ship or other.get_node_or_null("Locomotion") == null:
			continue
		var locomotion := other.get_node("Locomotion") as ShipLocomotion
		var at := locomotion.destination if locomotion.has_destination else locomotion.planar_position
		var gap := _follower.ship_radius + (other.get_node("RouteFollower") as RouteFollower).ship_radius + SHIP_GAP
		if at.distance_to(point) < gap:
			return true
	return false


static func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)
