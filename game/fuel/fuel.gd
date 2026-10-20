extends Node
## Phase 2 Stage 4 fuel of its ship (child node of every ship): tank, consumption
## by distance traveled, warnings, and automatic refueling while docked.
##
## Consumption reads Locomotion's committed displacement of the tick (after
## collision), so route, direct, avoidance and blocked movement all follow the same
## rule; standing still and rotation use none. At zero fuel Locomotion's
## propulsion is switched off: the ship is immobilized (no translation or
## rotation; available speed reported as 0, so other ships' avoidance treats it as
## stationary) with its orders kept, and can still be given new ones; restored
## fuel switches it back on. Warnings are given
## once per threshold as the fuel falls below it; fuel rising back above a
## threshold re-arms it. Docked at a station (Docking state Docked), the ship takes
## fuel from the station's stock at the station's rate, up to its capacity.

signal notice(text: String)

const DisplayName := preload("res://game/ui/display_name.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const Docking := preload("res://game/stations/docking.gd")
const THRESHOLDS := [0.15, 0.10, 0.05] # Share of capacity; a warning below each.
const WARNING_NAMES := ["Low Fuel", "Fuel Warning", "Critical Fuel"]

@export var capacity := 100.0 # Fuel units (provisional).
@export var consumption := 0.25 # Fuel units per u traveled (provisional).
@export_range(0.0, 1.0) var start_level := 1.0 # Share of the tank filled at start.

var fuel := 0.0
var warned := 0 # Thresholds notified in the current depletion cycle (0-3).
var refueling := false # Fuel was taken from a station in the last tick.

@onready var _ship := get_parent() as Node3D
@onready var _locomotion := _ship.get_node("Locomotion") as ShipLocomotion
@onready var _docking := _ship.get_node_or_null("Docking") as Docking


func _ready() -> void:
	process_physics_priority = 1 # After Locomotion: reads this tick's committed motion.
	fuel = capacity * start_level
	warned = level()
	_locomotion.propulsion = fuel > 0.0


## Share of the tank filled (0-1).
func ratio() -> float:
	return fuel / capacity if capacity > 0.0 else 0.0


## Thresholds the fuel is below (0-3).
func level() -> int:
	var count := 0
	for threshold: float in THRESHOLDS:
		if ratio() < threshold:
			count += 1
	return count


## The current warning ("" above 15 %, "Out of Fuel" when empty).
func warning() -> String:
	if fuel <= 0.0:
		return "Out of Fuel"
	return WARNING_NAMES[level() - 1] if level() > 0 else ""


func _physics_process(delta: float) -> void:
	var traveled := _locomotion.committed_motion.length()
	if traveled > 0.0 and fuel > 0.0:
		_set_fuel(fuel - traveled * consumption)
	refueling = false
	if _docking != null and _docking.state == Docking.State.DOCKED:
		_refuel(delta)


# Takes what the station can give this tick: never beyond its stock or the tank's free
# space; the station loses exactly what the tank gains.
func _refuel(delta: float) -> void:
	var station := _docking.station
	var amount := minf(minf(station.refuel_rate * delta, capacity - fuel), station.fuel_stock)
	if amount <= 0.0:
		return
	station.fuel_stock -= amount
	_set_fuel(fuel + amount)
	refueling = true


func _set_fuel(value: float) -> void:
	fuel = clampf(value, 0.0, capacity)
	var now := level()
	if now > warned:
		notice.emit("%s: %s (%d%%)" % [DisplayName.of(_ship), WARNING_NAMES[now - 1], floori(ratio() * 100.0)])
	warned = now
	var powered := fuel > 0.0
	if not powered and _locomotion.propulsion:
		notice.emit("%s: out of fuel - stopped" % DisplayName.of(_ship))
	_locomotion.propulsion = powered
