extends Node
## Phase 2 Stage 6 transport assignment of its ship (child node of a Transporter,
## next to its Cargo, Docking and Fuel). The saved configuration (`load_station`,
## `unload_station`, `required`: units per resource, Phase 3) is kept apart from the
## active operation (`status`): a manual order pauses the operation and keeps the
## configuration; Start / Resume restarts it. A station change or every requirement
## set to zero pauses it too (Phase 2.5); other requirement edits are re-read every
## tick while loading. Cargo aboard is never
## discarded: what is not required is simply carried and delivered.
##
## Cycle: dock at the loading station (Docking: slots, queue, holding positions);
## once docked, load each resource still missing with the timed transfer (one
## the station has in stock first); a resource out of stock blocks the transfer, so
## Docking keeps the request, leaves the slot for a holding position and docks
## again once that stock appears. Every requirement met (and the tank refuelled, or
## the station out of fuel): undock, and once Docking is clear of the slot dock at
## the destination; unload everything (a full station: the same blocked transfer
## waiting nearby), refuel, undock, return to the loading station; repeat. Each leg
## is one order given by Docking; this node only asks Docking to dock, transfer
## and undock, and reads the docking state from it.
##
## UX round (P4): the operation's transfers wait in the berth instead of leaving when
## blocked (Docking `wait`): loading stays docked, its berth reserved, until every
## requirement is met (switching to another missing resource that comes into stock),
## unloading until the hold is empty; then it leaves as before. A manual departure
## pauses the operation (unchanged).

enum Status { NONE, LOADING, DELIVERING, PAUSED, UNREACHABLE }

signal notice(text: String)

const DisplayName := preload("res://game/ui/display_name.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const Cargo := preload("res://game/cargo/cargo.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const Fuel := preload("res://game/fuel/fuel.gd")
const RESOURCES := Inventory.RESOURCES # Phase 3: every resource can be required (raw, ice, ingots).

var load_station: Node3D = null # Saved configuration: where the cargo is loaded.
var unload_station: Node3D = null # Saved configuration: where it is delivered.
var required := {} # Saved configuration: per resource (every resource, 0 = not required), units or a percentage.
var percent := {} # Saved configuration: true where `required` is a percentage of the hold's total capacity (Phase 3).
var status := Status.NONE # The active operation.
var deliveries := 0 # Completed deliveries since the operation was started.

var _leaving := false # Undocking; the next leg starts once Docking is clear of the slot.
var _returning := false # Back to the loading station after a delivery.

@onready var _ship := get_parent() as Node3D
@onready var _cargo := _ship.get_node("Cargo") as Cargo
@onready var _docking := _ship.get_node("Docking") as Docking
@onready var _fuel := _ship.get_node_or_null("Fuel") as Fuel


func _init() -> void:
	for resource in RESOURCES:
		required[resource] = 0
		percent[resource] = false


func _ready() -> void:
	process_physics_priority = 1 # With Docking, after Locomotion.


func is_active() -> bool:
	return status == Status.LOADING or status == Status.DELIVERING


## Two different stations and at least one unit required.
func is_configured() -> bool:
	return load_station != null and unload_station != null and load_station != unload_station \
		and RESOURCES.any(func(resource: StringName) -> bool: return required_units(resource) > 0)


func can_resume() -> bool:
	return is_configured() and not is_active()


## Units required of a resource (Phase 3): a fixed amount, or a percentage of the
## hold's total capacity rounded down (never of its free space or the station's stock).
func required_units(resource: StringName) -> int:
	return _units(required[resource], percent[resource])


## Every requirement in units together.
func total_required() -> int:
	var total := 0
	for resource in RESOURCES:
		total += required_units(resource)
	return total


## Units of a resource still to load for the requirements (0 when met or exceeded).
func missing(resource: StringName) -> int:
	return maxi(0, required_units(resource) - _cargo.inventory.quantity_of(resource))


## The requirements for the panel: "Silicon 30% (300), Ice 50", or "none".
func describe_requirements() -> String:
	var parts: Array[String] = []
	for resource in RESOURCES:
		if required[resource] > 0:
			var amount := "%d%% (%d)" % [required[resource], required_units(resource)] if percent[resource] else str(required[resource])
			parts.append("%s %s" % [Inventory.display_name(resource), amount])
	return ", ".join(parts) if not parts.is_empty() else "none"


func requirements_met() -> bool:
	return RESOURCES.all(func(resource: StringName) -> bool: return missing(resource) == 0)


## Player configuration (an existing value changes nothing). Phase 2.5: changing a
## station (also clearing it) pauses an active operation, so a trip under way is
## never redirected and Resume applies the edit; requirements stay live while they
## require some cargo, and all at zero pause it. Phase 3: a requirement is units or a
## percentage of the hold's total capacity (mixed freely); an edit that would make all
## requirements together exceed that capacity is rejected with a notice and changes
## nothing (the previous valid configuration stays).
func set_load_station(station: Node3D) -> void:
	if station == load_station:
		return
	load_station = station
	_pause("station changed")


func set_unload_station(station: Node3D) -> void:
	if station == unload_station:
		return
	unload_station = station
	_pause("station changed")


## `amount` in units, or in percent (0-100) when `as_percent`; returns false if rejected.
func set_requirement(resource: StringName, amount: int, as_percent := false) -> bool:
	amount = clampi(amount, 0, 100) if as_percent else maxi(0, amount)
	if amount == required[resource] and as_percent == percent[resource]:
		return true
	var total := total_required() - required_units(resource) + _units(amount, as_percent)
	if total > _cargo.inventory.capacity:
		notice.emit("%s: requirements would exceed the cargo capacity (%d / %d) - not changed" % [DisplayName.of(_ship), total, _cargo.inventory.capacity])
		return false
	required[resource] = amount
	percent[resource] = as_percent
	if RESOURCES.all(func(other: StringName) -> bool: return required_units(other) == 0):
		_pause("no cargo required")
	return true


## UX round (P7) transport editor: replaces every requirement at once, all or nothing.
## `amounts` and `as_percent` map resources to a requirement and its mode (a resource
## not listed: 0 units). The whole candidate is checked first with the same rules as
## set_requirement() (amounts clamped the same way; all together within the hold's
## total capacity, else the same notice and nothing changes); then it replaces the saved
## requirements in one step, with the same consequences (all at zero pauses an active
## operation; other edits stay live). Returns false if rejected.
func apply_requirements(amounts: Dictionary, as_percent: Dictionary) -> bool:
	var candidate := {}
	var modes := {}
	var total := 0
	for resource in RESOURCES:
		var in_percent: bool = as_percent.get(resource, false)
		var amount: int = amounts.get(resource, 0)
		candidate[resource] = clampi(amount, 0, 100) if in_percent else maxi(0, amount)
		modes[resource] = in_percent
		total += _units(candidate[resource], in_percent)
	if candidate == required and modes == percent:
		return true
	if total > _cargo.inventory.capacity:
		notice.emit("%s: requirements would exceed the cargo capacity (%d / %d) - not changed" % [DisplayName.of(_ship), total, _cargo.inventory.capacity])
		return false
	required = candidate
	percent = modes
	if RESOURCES.all(func(other: StringName) -> bool: return required_units(other) == 0):
		_pause("no cargo required")
	return true


## Player command (Start / Resume Transport): to the loading station.
func start() -> void:
	if not is_configured():
		notice.emit("%s: choose two different stations and a cargo requirement" % DisplayName.of(_ship))
		return
	deliveries = 0
	_returning = false
	_go_load()


## A manual order replaced the operation: it stops, the configuration is kept
## (the caller releases any dock request).
func cancel() -> void:
	_leaving = false
	if is_active():
		status = Status.PAUSED


## Stations, nearest first.
func stations_by_distance() -> Array[Node3D]:
	var found: Array[Node3D] = []
	for station: Node3D in get_tree().get_nodes_in_group(Station.GROUP):
		found.append(station)
	var at := _planar(_ship)
	found.sort_custom(func(a: Node3D, b: Node3D) -> bool: return _planar(a).distance_to(at) < _planar(b).distance_to(at))
	return found


## What the ship is doing (or why it waits), for the panel.
func activity() -> String:
	var text := ""
	match status:
		Status.NONE:
			text = "No assignment"
		Status.PAUSED:
			text = "Assignment Paused"
		Status.UNREACHABLE:
			text = "Unable to Reach Station"
		Status.LOADING:
			text = "Returning to Base" if _returning else "Traveling to Loading Base"
			if _leaving:
				text = "Leaving Loading Base"
			else:
				match _docking.state:
					Docking.State.WAITING:
						text = "Waiting for Dock"
					Docking.State.BLOCKED:
						text = "Waiting for Resources"
					Docking.State.DOCKED:
						if not requirements_met() and _cargo.inventory.free_space() == 0:
							text = "Requirements Exceed Capacity"
						elif _docking.waiting:
							text = "Waiting for Resources"
						else:
							text = "Resupplying" if requirements_met() else "Loading Cargo"
		Status.DELIVERING:
			text = "Leaving Destination" if _leaving else "Traveling to Destination"
			if not _leaving:
				match _docking.state:
					Docking.State.WAITING:
						text = "Waiting for Dock"
					Docking.State.BLOCKED:
						text = "Waiting for Storage"
					Docking.State.DOCKED:
						var unloading := _docking.transfer == Docking.Transfer.UNLOAD or _cargo.inventory.quantity() > 0
						text = "Unloading Cargo" if unloading else "Resupplying"
						if _docking.waiting:
							text = "Waiting for Storage"
	if is_active() and _fuel != null and _fuel.fuel <= 0.0:
		text += " - Out of Fuel"
	return text


func _physics_process(_delta: float) -> void:
	if not is_active():
		return
	if not is_configured():
		# Not through the setters: pause before any dock request is made with it.
		_pause("choose two different stations and a cargo requirement")
		return
	if _leaving:
		if _docking.state == Docking.State.UNDOCKING:
			return
		_leaving = false
		if status == Status.LOADING:
			_go_deliver()
		else:
			deliveries += 1
			_returning = true
			_go_load()
		return
	match _docking.state:
		Docking.State.UNABLE:
			status = Status.UNREACHABLE
		Docking.State.NONE:
			status = Status.PAUSED # The dock request was released by someone else.
		Docking.State.DOCKED:
			if status == Status.LOADING:
				_load_step()
			else:
				_unload_step()
		Docking.State.BLOCKED:
			if status == Status.LOADING:
				_recheck_blocked_load()


# A configuration edit paused an active operation (once, with a notice): docked it
# stays docked with the transfer stopped; undocking finishes its departure;
# otherwise the dock request and its reservations are released. Cargo, fuel and the
# configuration stay.
func _pause(reason: String) -> void:
	if not is_active():
		return
	cancel()
	if _docking.under_control():
		# Phase 2.5: a controlled entry finishes and the ship stays docked (no transfer
		# is running yet); a controlled exit finishes its departure.
		_docking.stop_transfer()
	else:
		match _docking.state:
			Docking.State.DOCKED:
				_docking.stop_transfer()
			Docking.State.UNDOCKING:
				pass
			_:
				_docking.cancel()
	notice.emit("%s: transport paused - %s" % [DisplayName.of(_ship), reason])


func _go_load() -> void:
	status = Status.LOADING
	_leaving = false
	_docking.dock(load_station)


func _go_deliver() -> void:
	status = Status.DELIVERING
	_leaving = false
	_docking.dock(unload_station)


# Docked at the loading station: keep one timed load running for a missing resource
# (re-sized when the requirements change), leave once every requirement is met. A
# load waiting in the berth for its resource gives way to another missing resource
# that is in stock (chosen in the next tick).
func _load_step() -> void:
	if _docking.transfer == Docking.Transfer.LOAD:
		var need := missing(_docking.load_resource)
		if need == 0:
			_docking.stop_transfer()
		elif _docking.waiting and _other_in_stock(_docking.load_resource):
			_docking.stop_transfer()
		elif _docking.load_amount - _docking.moved != need:
			_docking.load_cargo(_docking.load_resource, need, true)
		return
	if requirements_met():
		if _resupplied():
			_leave()
		return
	if _cargo.inventory.free_space() == 0:
		return # Requirements exceed the hold: waits for the player to change them.
	var storage: Inventory = (_docking.station as Station).storage
	var resource := &""
	for candidate in RESOURCES:
		if missing(candidate) > 0 and (resource == &"" or storage.quantity_of(candidate) > 0 and storage.quantity_of(resource) == 0):
			resource = candidate
	_docking.load_cargo(resource, missing(resource), true) # Out of stock: Docking waits in the berth.


# Another missing resource the docked station has in stock.
func _other_in_stock(resource: StringName) -> bool:
	var storage: Inventory = (_docking.station as Station).storage
	return RESOURCES.any(func(other: StringName) -> bool: return other != resource and missing(other) > 0 and storage.quantity_of(other) > 0)


# Waiting nearby for a resource's stock: if the requirements changed (that one no
# longer missing, or another missing resource now in stock), dock again to load what
# can be loaded; with every requirement met, deliver.
func _recheck_blocked_load() -> void:
	if requirements_met():
		_go_deliver()
		return
	var storage: Inventory = (_docking.station as Station).storage
	var waiting_for := _docking.load_resource
	var other_ready := RESOURCES.any(func(resource: StringName) -> bool: return resource != waiting_for and missing(resource) > 0 and storage.quantity_of(resource) > 0)
	if missing(waiting_for) == 0 or (storage.quantity_of(waiting_for) == 0 and other_ready):
		_docking.cancel()
		_docking.dock(load_station)


# Docked at the destination: unload everything aboard, then leave once refuelled.
func _unload_step() -> void:
	if _docking.transfer != Docking.Transfer.NONE:
		return
	if _cargo.inventory.quantity() > 0:
		_docking.unload(true) # A full station: waits in the berth until the hold is empty.
	elif _resupplied():
		_leave()


func _leave() -> void:
	_leaving = true
	_docking.undock()


func _resupplied() -> bool:
	return _fuel == null or _fuel.fuel >= _fuel.capacity or (_docking.station as Station).fuel_stock <= 0.0


func _units(amount: int, as_percent: bool) -> int:
	return _cargo.inventory.capacity * amount / 100 if as_percent else amount


static func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)
