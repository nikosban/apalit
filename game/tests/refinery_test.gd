extends SceneTree
## Headless Phase 3 checks on the playable main scene: Station2's two-slot refinery
## (stage 3) and the station selection and panel (stage 4). One raw unit gives one
## ingot at the mineral's rate per slot; slots are independent (same mineral allowed,
## drawing from one stock without duplication); no input: waits, consumes nothing;
## disabling or changing the mineral resets the partial unit without losing raw
## material; new stock is used as it arrives; raw + ingots are conserved every tick
## and the shared storage never overflows. The refinery is stepped manually at 60 Hz
## (as the other suites step ships), plus a check in the real game loop.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/refinery_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const Inventory := preload("res://game/cargo/inventory.gd")
const Refinery := preload("res://game/refining/refinery.gd")
const Station := preload("res://game/stations/station.gd")
const DT := 1.0 / 60.0
const RATES := {&"iron": 4.0, &"nickel": 3.0, &"silicon": 2.5, &"cobalt": 2.0, &"titanium": 1.5, &"gold": 1.0}
const SILICON := &"silicon"
const INGOT := &"silicon_ingot"

var _failures := 0
var _checks := 0
var _main: Node
var _station: Station # Station2, with the refinery.
var _refinery: Refinery
var _storage: Inventory
var _conserved := true # raw + ingots of every mineral constant on every manual tick.


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_station = _main.get_node("Stations/Station2")
	_refinery = _station.get_node("Refinery")
	_storage = _station.storage
	_main.get_node("Survey").set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		for child in ship.get_children():
			child.set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	_refinery.set_physics_process(false)

	_test_setup()
	_test_processing()
	_test_no_input()
	_test_same_mineral()
	_test_disable_and_change()
	_test_rates_and_independence()
	_test_new_stock()
	_test_full_storage()
	await _test_game_loop()
	await _test_panel()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _test_setup() -> void:
	var defaults := _refinery.slots.size() == 2 and _refinery.slots.all(func(slot: Refinery.Slot) -> bool: return slot.mineral == &"" and not slot.enabled)
	_check("Station2 has the refinery (2 slots, both off, no mineral); Station has none", defaults
		and _main.get_node("Stations/Station").get_node_or_null("Refinery") == null and _refinery.station() == _station)
	_check("provisional rates per slot: Iron 4, Nickel 3, Silicon 2.5, Cobalt 2, Titanium 1.5, Gold 1", _refinery.rates == RATES)
	_check("both stations share the station layout (Station2: refinery_station.tscn inheriting Station's station.tscn)",
		_station.scene_file_path == "res://game/stations/refinery_station.tscn"
		and (load(_station.scene_file_path) as PackedScene).get_state().get_node_instance(0).resource_path == _main.get_node("Stations/Station").scene_file_path)


# One slot, Silicon: 2.5 per second, one raw unit -> one ingot.
func _test_processing() -> void:
	_reset()
	_storage.add(SILICON, 100)
	_storage.add(&"iron", 40)
	_refinery.set_mineral(0, SILICON)
	_check("a slot with a mineral but disabled does nothing (status Disabled)", _steps(60) and _storage.quantity_of(INGOT) == 0
		and _refinery.status(0) == "Disabled")
	_refinery.set_enabled(0, true)
	_steps(60 * 10)
	_check("10 s at 2.5 / s: %d Silicon Ingots, %d Silicon left; Iron untouched; status Processing" % [_storage.quantity_of(INGOT), _storage.quantity_of(SILICON)],
		_storage.quantity_of(INGOT) == 25 and _storage.quantity_of(SILICON) == 75 and _storage.quantity_of(&"iron") == 40
		and _refinery.status(0) == "Processing" and _refinery.slots[0].processed == 25)
	_check("raw + ingots conserved every tick; storage total unchanged (140)", _conserved and _storage.quantity() == 140)


func _test_no_input() -> void:
	_reset()
	_refinery.set_mineral(0, SILICON)
	_refinery.set_enabled(0, true)
	_steps(60 * 10)
	_check("no Silicon: waits (Waiting for Silicon), nothing consumed or produced, no progress", _storage.quantity() == 0
		and _refinery.status(0) == "Waiting for Silicon" and _refinery.slots[0].progress == 0.0 and _refinery.slots[0].processed == 0)


# Both slots on Silicon: twice the rate from one stock; never more than the stock.
func _test_same_mineral() -> void:
	_reset()
	_storage.add(SILICON, 100)
	for index in 2:
		_refinery.set_mineral(index, SILICON)
		_refinery.set_enabled(index, true)
	_steps(60 * 4)
	_check("both slots on Silicon, 4 s: %d ingots (2 x 2.5 x 4)" % _storage.quantity_of(INGOT), _storage.quantity_of(INGOT) == 20
		and _storage.quantity_of(SILICON) == 80 and _refinery.slots[0].processed == 10 and _refinery.slots[1].processed == 10)
	_reset()
	_storage.add(SILICON, 3)
	for index in 2:
		_refinery.set_mineral(index, SILICON)
		_refinery.set_enabled(index, true)
	_steps(60 * 10)
	_check("only 3 Silicon for both slots: exactly 3 ingots, none duplicated, both waiting (slot 1 %d, slot 2 %d)" % [_refinery.slots[0].processed,
		_refinery.slots[1].processed], _storage.amounts == {INGOT: 3} and _refinery.slots[0].processed + _refinery.slots[1].processed == 3
		and _refinery.status(0) == "Waiting for Silicon" and _refinery.status(1) == "Waiting for Silicon" and _conserved)


# Disabling or changing the mineral resets the partial unit; no raw material is lost.
func _test_disable_and_change() -> void:
	_reset()
	_storage.add(SILICON, 10)
	_storage.add(&"gold", 10)
	_refinery.set_mineral(0, SILICON)
	_refinery.set_enabled(0, true)
	_steps(18) # 0.3 s: 0.75 of a unit.
	var partial := _refinery.slots[0].progress
	var before := _storage.amounts.duplicate()
	_refinery.set_enabled(0, false)
	_check("disabled mid-unit (%.2f done): progress reset, storage unchanged (%s)" % [partial, _storage.describe()], partial > 0.7 and partial < 0.8
		and _refinery.slots[0].progress == 0.0 and _storage.amounts == before)
	_steps(60 * 5)
	_check("disabled: nothing processed for 5 s", _storage.amounts == before)
	_refinery.set_enabled(0, true)
	_steps(18)
	_check("enabled again: starts from 0 (no unit after 0.3 s)", _storage.amounts == before and absf(_refinery.slots[0].progress - partial) < 0.0001)
	_refinery.set_mineral(0, &"gold")
	_check("mineral changed mid-unit: progress reset, storage unchanged", _refinery.slots[0].progress == 0.0 and _storage.amounts == before)
	_steps(60 * 3)
	_check("now Gold at 1 / s: 3 Gold Ingots in 3 s, Silicon untouched (%s)" % _storage.describe(), _storage.quantity_of(&"gold_ingot") == 3
		and _storage.quantity_of(&"gold") == 7 and _storage.quantity_of(SILICON) == 10 and _conserved)
	_refinery.set_mineral(0, &"")
	_steps(60)
	_check("no mineral chosen: status No mineral selected, nothing processed", _refinery.status(0) == "No mineral selected"
		and _storage.quantity_of(&"gold_ingot") == 3)


func _test_rates_and_independence() -> void:
	var results: Array[String] = []
	var ok := true
	for mineral: StringName in RATES:
		_reset()
		_storage.add(mineral, 100)
		_refinery.set_mineral(0, mineral)
		_refinery.set_enabled(0, true)
		_steps(60 * 4)
		var made := _storage.quantity_of(Inventory.ingot_of(mineral))
		results.append("%s %d" % [Inventory.display_name(mineral), made])
		ok = ok and made == roundi(RATES[mineral] * 4.0) and is_equal_approx(_refinery.rate(0), RATES[mineral])
	_check("each mineral at its own rate, 4 s: %s" % ", ".join(results), ok and _conserved)
	_reset()
	_storage.add(&"iron", 100)
	_storage.add(&"gold", 100)
	_refinery.set_mineral(0, &"iron")
	_refinery.set_mineral(1, &"gold")
	_refinery.set_enabled(0, true)
	_refinery.set_enabled(1, true)
	_steps(60 * 5)
	_check("independent slots: Iron 4 / s and Gold 1 / s together, 5 s: %s" % _storage.describe(), _storage.quantity_of(&"iron_ingot") == 20
		and _storage.quantity_of(&"gold_ingot") == 5 and _storage.quantity_of(&"iron") == 80 and _storage.quantity_of(&"gold") == 95)


# Stock delivered while a slot waits is processed from the next tick.
func _test_new_stock() -> void:
	_reset()
	_refinery.set_mineral(0, SILICON)
	_refinery.set_enabled(0, true)
	_steps(60)
	_storage.add(SILICON, 5)
	_steps(60 * 4)
	_check("Silicon delivered while waiting: processed as it arrives (5 ingots in 4 s, at most 2.5 / s)", _storage.amounts == {INGOT: 5}
		and _refinery.status(0) == "Waiting for Silicon")


# Raw and ingots share the station's capacity: a full storage still refines (1 for 1).
func _test_full_storage() -> void:
	_reset()
	_storage.add(SILICON, 2000)
	_storage.add(&"ice", _storage.free_space())
	_refinery.set_mineral(0, SILICON)
	_refinery.set_enabled(0, true)
	var most := 0
	for tick in 60 * 4:
		_steps(1)
		most = maxi(most, _storage.quantity())
	_check("full storage (5000 / 5000): refining goes on, never beyond the capacity (at most %d), 10 ingots" % most, most == _storage.capacity
		and _storage.quantity() == _storage.capacity and _storage.quantity_of(INGOT) == 10)


# The refinery also runs by itself in the game loop (after the ships and stations).
func _test_game_loop() -> void:
	_reset()
	_storage.add(SILICON, 50)
	_refinery.set_mineral(0, SILICON)
	_refinery.set_enabled(0, true)
	_refinery.set_physics_process(true)
	for frame in 120:
		await physics_frame
	_refinery.set_physics_process(false)
	var made := _storage.quantity_of(INGOT)
	_check("in the game loop: %d ingots after 120 physics frames, raw + ingots = 50, priority after Docking and stations (3)" % made, made >= 4
		and made <= 5 and made + _storage.quantity_of(SILICON) == 50 and _refinery.process_physics_priority == 3)


# Stage 4: station selection by click and the station panel's refinery controls.
func _test_panel() -> void:
	_reset()
	var rig: Node3D = _main.get_node("CameraRig")
	var camera: Camera3D = _main.get_node("CameraRig/Camera3D")
	var selection := _main.get_node("Selection")
	var layer := _main.get_node("StationPanel")
	var panel: Control = layer.get_node("Panel")
	rig.global_position = Vector3(_station.global_position.x, 0, _station.global_position.z)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = 40.0
	rig._apply_zoom()
	await process_frame
	var on_station := camera.unproject_position(_station.global_position)
	var ground := camera.unproject_position(_station.global_position + Vector3(0, -1.5, 22))
	selection.set_selection([_main.get_node("Ships/Transporter")])
	_check("layout: Station2 under its screen point, open ground below it", _main.get_node("AsteroidHover").station_at(on_station) == _station
		and _main.get_node("AsteroidHover").station_at(ground) == null and not panel.visible)
	_storage.add(SILICON, 100)
	_storage.add(INGOT, 5)
	_click(on_station)
	await process_frame
	await process_frame
	var rows := panel.get_node("Layout/Scroll/Body")
	_check("click on Station2: selected, panel shown (name, storage, storage tiles Silicon 100 / Silicon Ingots 5, refinery); ships deselected, ship panel hidden",
		layer.station == _station and panel.visible and selection.selected.is_empty() and not _main.get_node("ShipPanel/Panel").visible
		and panel.get_node("Layout/Header/StationName").text == "Station2" and rows.get_node("Storage/Summary").text == "Storage: 105 / 5000"
		and _tiles(rows.get_node("Storage/Tiles")) == {SILICON: 100, INGOT: 5}
		and rows.get_node("Refinery").visible)
	var mineral: OptionButton = rows.get_node("Refinery/Slot1/Header/Mineral")
	var enabled: CheckButton = rows.get_node("Refinery/Slot1/Header/Enabled")
	var status: Label = rows.get_node("Refinery/Slot1/Status")
	_check("slot rows: No mineral + the six minerals, off; status No mineral selected", mineral.item_count == 7 and mineral.selected == 0
		and not enabled.button_pressed and status.text == "No mineral selected")
	mineral.select(3)
	mineral.item_selected.emit(3)
	enabled.button_pressed = true
	var mineral2: OptionButton = rows.get_node("Refinery/Slot2/Header/Mineral")
	mineral2.select(3)
	mineral2.item_selected.emit(3)
	_steps(30)
	await process_frame
	_check("choosing Silicon and Enabled in slot 1 configures it; slot 2 Silicon but off (%s | %s)" % [status.text, rows.get_node("Refinery/Slot2/Status").text],
		_refinery.slots[0].mineral == SILICON and _refinery.slots[0].enabled and _refinery.slots[1].mineral == SILICON and not _refinery.slots[1].enabled
		and status.text == "Processing - 2.5 units/s, 1 refined" and rows.get_node("Refinery/Slot2/Status").text == "Disabled - 2.5 units/s, 0 refined"
		and absf((rows.get_node("Refinery/Slot1/Progress") as ProgressBar).value - _refinery.slots[0].progress) < 0.001
		and _tiles(rows.get_node("Storage/Tiles")) == {SILICON: 99, INGOT: 6})
	enabled.button_pressed = false
	_check("Enabled off: slot disabled, progress reset", not _refinery.slots[0].enabled and _refinery.slots[0].progress == 0.0)
	_click(ground)
	await process_frame
	_check("click on open ground: station deselected, panel hidden", layer.station == null and not panel.visible)
	_click(on_station, true)
	_check("Shift-click on the station: not selected", layer.station == null)
	_drag(on_station, on_station + Vector2(60, 40))
	_check("a drag starting on the station: not selected", layer.station == null)
	_click(on_station)
	await process_frame
	_check("selected again: the panel shows the saved slots (Silicon, off / Silicon, off)", layer.station == _station and mineral.selected == 3
		and not enabled.button_pressed and mineral2.selected == 3)
	selection.set_selection([_main.get_node("Ships/Transporter")])
	await process_frame
	_check("selecting a ship clears the station and hides its panel", layer.station == null and not panel.visible)
	var other: Station = _main.get_node("Stations/Station")
	layer.select(other)
	await process_frame
	_check("Station (no refinery): storage shown (no tiles: nothing stored), no refinery rows", panel.visible and panel.get_node("Layout/Header/StationName").text == "Station"
		and not rows.get_node("Refinery").visible and _tiles(rows.get_node("Storage/Tiles")).is_empty())
	layer.select(null)
	selection.set_selection([])


func _click(position: Vector2, shift := false) -> void:
	_button(position, true, shift)
	_button(position, false, shift)


func _drag(from: Vector2, to: Vector2) -> void:
	_button(from, true, false)
	for k in range(1, 5):
		var motion := InputEventMouseMotion.new()
		motion.position = from.lerp(to, k / 4.0)
		motion.global_position = motion.position
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		root.push_input(motion, true)
	_button(to, false, false)


func _button(position: Vector2, pressed: bool, shift: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	event.global_position = position
	event.shift_pressed = shift
	root.push_input(event, true)


func _reset() -> void:
	_storage.amounts.clear()
	_storage.capacity = _station.storage_capacity
	for index in 2:
		_refinery.set_enabled(index, false)
		_refinery.set_mineral(index, &"")
		_refinery.slots[index].processed = 0
	_conserved = true


# Steps the refinery; tracks conservation per mineral (raw + ingot). Returns true.
func _steps(count: int) -> bool:
	for i in count:
		var before := _totals()
		_refinery._physics_process(DT)
		_conserved = _conserved and _totals() == before and _storage.quantity() <= _storage.capacity
	return true


func _totals() -> Dictionary:
	var totals := {}
	for mineral: StringName in RATES:
		totals[mineral] = _storage.quantity_of(mineral) + _storage.quantity_of(Inventory.ingot_of(mineral))
	return totals


# Resource -> units shown by the visible resource tiles of a panel's tile container
# (UX round P6: the storage tiles replaced the Raw / Ingots lines).
func _tiles(container: Node) -> Dictionary:
	var shown := {}
	for tile in container.get_children():
		if tile.visible:
			shown[tile.resource] = int((tile.get_node("Amount") as Label).text)
	return shown


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
