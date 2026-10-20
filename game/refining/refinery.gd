extends Node
## Phase 3 refinery of its station (child node of a Station; Station2 in main.tscn):
## two processing slots, each configured on its own (a mineral and enabled / disabled;
## both may take the same mineral). An enabled slot turns one raw unit of its mineral
## into one ingot of that mineral (no losses, no byproducts) in the station's shared
## storage, at the mineral's rate (units per second, per slot).
##
## A unit is consumed only when it is completed, so nothing is ever held "in
## process": without input a slot waits and consumes nothing (its fraction of the
## next unit is kept); disabling a slot or changing its mineral resets that fraction
## and loses no raw material. Raw and ingots share the station's capacity, and a
## completed unit removes one raw unit before adding its ingot, so the output always
## fits. Slots run in order (slot 1, then slot 2) after the ships' Docking and the
## station in each tick: stock delivered or loaded that tick is seen, and two slots
## on the same mineral draw from the one stock without duplication (the first takes
## the last unit). No reservations against transport loading: stock goes to whoever
## takes it first in the simulation order.

const Inventory := preload("res://game/cargo/inventory.gd")
const SLOT_COUNT := 2
const EPSILON := 1e-6 # Of a unit: summed per-tick fractions (e.g. 600 x 2.5 / 60) complete on time.

## Units per second, per slot (provisional test parameters, not final balance).
@export var rates := {&"iron": 4.0, &"nickel": 3.0, &"silicon": 2.5, &"cobalt": 2.0, &"titanium": 1.5, &"gold": 1.0}

var slots: Array[Slot] = []


class Slot:
	var mineral := &"" # Raw mineral processed (&"" = none chosen).
	var enabled := false
	var progress := 0.0 # Share of the next unit done (0..1).
	var processed := 0 # Units refined since the start of the game.
	var assignment_processed := 0 # Units refined since the current mineral was chosen (the panel's count).


func _init() -> void:
	for i in SLOT_COUNT:
		slots.append(Slot.new())


func _ready() -> void:
	process_physics_priority = 3 # After Docking (1) and the station (2).


## The station whose storage the refinery uses.
func station() -> Node3D:
	return get_parent() as Node3D


## Chooses a slot's mineral (&"" for none); a change resets its progress and its
## count since the mineral was chosen.
func set_mineral(index: int, mineral: StringName) -> void:
	var slot := slots[index]
	if mineral == slot.mineral:
		return
	slot.mineral = mineral
	slot.progress = 0.0
	slot.assignment_processed = 0


## Enables or disables a slot; a change resets its progress.
func set_enabled(index: int, enabled: bool) -> void:
	var slot := slots[index]
	if enabled == slot.enabled:
		return
	slot.enabled = enabled
	slot.progress = 0.0


## The slot's rate (units per second; 0 without a mineral).
func rate(index: int) -> float:
	return rates.get(slots[index].mineral, 0.0)


## What the slot is doing, for the panel and the hover text.
func status(index: int) -> String:
	var slot := slots[index]
	if slot.mineral == &"":
		return "No mineral selected"
	if not slot.enabled:
		return "Disabled"
	if _storage().quantity_of(slot.mineral) == 0:
		return "Waiting for %s" % Inventory.display_name(slot.mineral)
	return "Processing"


func _physics_process(delta: float) -> void:
	for slot in slots:
		_run(slot, delta)


func _run(slot: Slot, delta: float) -> void:
	if not slot.enabled or slot.mineral == &"":
		return
	var storage := _storage()
	if storage.quantity_of(slot.mineral) == 0:
		return # Waits; nothing consumed.
	slot.progress += rates.get(slot.mineral, 0.0) * delta
	while slot.progress >= 1.0 - EPSILON and storage.quantity_of(slot.mineral) > 0:
		storage.remove(slot.mineral, 1)
		storage.add(Inventory.ingot_of(slot.mineral), 1) # Always fits: one raw unit was just removed.
		slot.progress -= 1.0
		slot.processed += 1
		slot.assignment_processed += 1
	slot.progress = clampf(slot.progress, 0.0, 1.0) # Input ran out: at most one completed unit waits for it.


func _storage() -> Inventory:
	return station().storage
