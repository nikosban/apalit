extends SceneTree
## Headless UX / QoL refinement round checks on the playable main scene.
## Part A (T01, transport configuration defects A1-A4): reproduced on the old ship panel
## (UI commit timing and layout, not configuration acceptance); A4 is fixed since P6
## (fixed width, wrapping text), A1-A3 since P7 (the transport editor: typed values
## enter the draft at once, one Apply; Clear on every row; one row per requirement).
## The checks state the fixed behaviour. Originally the defect checks became the pass
## criteria of T13 (panel width) and T18 (transport editor), which update them to the
## new controls. Part B (T02 / T03, refinery slot display): the value under each slot
## is the units that slot refined since its current mineral was chosen; production,
## shared storage and 1-for-1 conversion are unchanged. Ship and station physics is
## off; the refinery is stepped manually at 60 Hz.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/ui_qol_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const Inventory := preload("res://game/cargo/inventory.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const Refinery := preload("res://game/refining/refinery.gd")
const Station := preload("res://game/stations/station.gd")
const DT := 1.0 / 60.0
const IRON := &"iron"
const NICKEL := &"nickel"

var _failures := 0
var _checks := 0
var _main: Node
var _selection: Node
var _panel: CanvasLayer # ShipPanel
var _rows: Control # ShipPanel's Transport group (Actions section)
var _transport: TransportOperation


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_main.get_node("Survey").set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		for child in ship.get_children():
			child.set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	_main.get_node("Stations/Station2/Refinery").set_physics_process(false)
	_selection = _main.get_node("Selection")
	_panel = _main.get_node("ShipPanel")
	_rows = _panel.get_node("Panel/Layout/Scroll/Body/Actions/Transport")
	_transport = _main.get_node("Ships/Transporter/Transport")

	await _test_commit_timing()
	await _test_clear_action()
	await _test_review()
	await _test_panel_width()
	await _test_refinery_display()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# A1 (fixed in T18): before, a quantity typed into the requirement row was applied only
# when the SpinBox committed it (Enter or focus loss, e.g. the click that deselected
# the ship). Now the editor's amount box takes typed text at once into the draft, and
# one Apply saves it, with no reselection.
func _test_commit_timing() -> void:
	_clear()
	var editor := _open_editor()
	var amount := editor.row(0, IRON).get_node("Amount") as SpinBox
	var line := amount.get_line_edit()
	line.text = "250"
	line.text_changed.emit("250") # Typed, no Enter, focus kept.
	for frame in 5:
		await process_frame
	var drafted: int = editor.draft[IRON]
	var saved_before: int = _transport.required[IRON]
	editor.apply()
	_check("A1 fixed: a typed requirement enters the draft without Enter, focus loss or reselection (Iron typed 250, draft %d, saved before Apply %d), one Apply saves it (%d)"
		% [drafted, saved_before, _transport.required[IRON]], drafted == 250 and saved_before == 0 and _transport.required[IRON] == 250 and _selection.selected.size() == 1)
	_check("A1 cause addressed: the editor's amount box takes typed text (update_on_text_changed %s)" % str(amount.update_on_text_changed), amount.update_on_text_changed)
	_clear()


# A2 (fixed in T18): every row of the editor has Clear, which removes the requirement
# from the draft; Apply saves it.
func _test_clear_action() -> void:
	_clear()
	_transport.set_requirement(IRON, 100)
	var editor := _open_editor()
	var clear_buttons := editor.find_children("Clear", "Button", true, false)
	_check("A2 fixed: every editor row has a Clear action (%d rows, %d Clear buttons)" % [editor._rows.size(), clear_buttons.size()],
		clear_buttons.size() == editor._rows.size() and editor._rows.size() == 14)
	(editor.row(0, IRON).get_node("Clear") as Button).pressed.emit()
	editor.apply()
	_check("A2 fixed: Clear on Iron, then Apply: the requirement is removed (Iron %d)" % _transport.required[IRON], _transport.required[IRON] == 0)
	_clear()


# A3 (fixed in T18): every requirement has its own row with its amount (Ore and Ingots
# tabs); the summary line in the ship panel still lists them all.
func _test_review() -> void:
	_clear()
	_transport.set_requirement(IRON, 100)
	_transport.set_requirement(&"titanium_ingot", 300)
	var editor := _open_editor()
	var iron := int((editor.row(0, IRON).get_node("Amount") as SpinBox).value)
	var titanium := int((editor.row(1, &"titanium_ingot").get_node("Amount") as SpinBox).value)
	_check("A3 fixed: every configured requirement has its own row with its amount (Iron %d in Ore, Titanium Ingots %d in Ingots)" % [iron, titanium],
		iron == 100 and titanium == 300)
	_check("A3 summary: the ship panel still lists them all (%s)" % (_rows.get_node("Required") as Label).text,
		(_rows.get_node("Required") as Label).text == "Required: Iron 100, Titanium Ingots 300")
	_clear()


# A4: before P6 the panel was resized to its contents every frame and labels without
# autowrap (Required, Cargo, Status) widened it with long resource lists; since P6 the
# panel shell has a fixed width and long text wraps.
func _test_panel_width() -> void:
	_clear()
	_select_row(IRON)
	await process_frame
	await process_frame
	var panel: Control = _panel.get_node("Panel")
	var before := panel.size.x
	for ingot: StringName in [&"titanium_ingot", &"cobalt_ingot", &"silicon_ingot", &"nickel_ingot"]:
		_transport.set_requirement(ingot, 100)
	await process_frame
	await process_frame
	var after := panel.size.x
	var required := _rows.get_node("Required") as Label
	_check("A4 defect: the panel keeps its width when requirements are added (%.0f px -> %.0f px)" % [before, after], is_equal_approx(before, after))
	_check("A4 fixed: the panel stays 340 px wide (%.0f px); long text wraps (Required label autowrap on, %d lines)" % [after, required.get_line_count()],
		is_equal_approx(after, 340.0) and required.autowrap_mode != TextServer.AUTOWRAP_OFF)
	_clear()


# B (T02 / T03): slot 1 Iron, slot 2 Nickel, both enabled; slot 2 changed to Iron.
func _test_refinery_display() -> void:
	_selection.set_selection([])
	var station: Station = _main.get_node("Stations/Station2")
	var refinery: Refinery = station.get_node("Refinery")
	var storage: Inventory = station.storage
	var layer := _main.get_node("StationPanel")
	storage.amounts.clear()
	storage.add(IRON, 200)
	storage.add(NICKEL, 100)
	refinery.set_mineral(0, IRON)
	refinery.set_mineral(1, NICKEL)
	refinery.set_enabled(0, true)
	refinery.set_enabled(1, true)
	var conserved := _step(refinery, storage, 60 * 5) # Iron 4 / s: 20, Nickel 3 / s: 15.
	refinery.set_mineral(1, IRON)
	conserved = _step(refinery, storage, 60 * 1) and conserved # Both on Iron: 4 more each.
	layer.select(station)
	await process_frame
	var status1 := (layer.get_node("Panel/Layout/Scroll/Body/Refinery/Slot1/Status") as Label).text
	var status2 := (layer.get_node("Panel/Layout/Scroll/Body/Refinery/Slot2/Status") as Label).text
	_check("B: after Nickel -> Iron, slot 2 shows the units refined since Iron was chosen (%s | %s)" % [status1, status2],
		status1 == "Processing - 4.0 units/s, 24 refined" and status2 == "Processing - 4.0 units/s, 4 refined")
	_check("B: production unchanged: Iron Ingots 28, Nickel Ingots 15, raw + ingots conserved every tick (%s)" % storage.describe(),
		storage.quantity_of(&"iron_ingot") == 28 and storage.quantity_of(&"nickel_ingot") == 15 and storage.quantity_of(IRON) == 172
		and storage.quantity_of(NICKEL) == 85 and conserved)
	_check("B: lifetime counts per slot kept (slot 1 %d, slot 2 %d)" % [refinery.slots[0].processed, refinery.slots[1].processed],
		refinery.slots[0].processed == 24 and refinery.slots[1].processed == 19)
	refinery.set_mineral(1, IRON) # The same mineral again: not a change.
	refinery.set_enabled(1, false)
	refinery.set_enabled(1, true) # Disable / enable without a mineral change.
	await process_frame
	status2 = (layer.get_node("Panel/Layout/Scroll/Body/Refinery/Slot2/Status") as Label).text
	_check("B: choosing the same mineral, or disabling and enabling, keeps the count (%s)" % status2, status2 == "Processing - 4.0 units/s, 4 refined")
	refinery.set_mineral(0, &"")
	await process_frame
	status1 = (layer.get_node("Panel/Layout/Scroll/Body/Refinery/Slot1/Status") as Label).text
	refinery.set_mineral(0, NICKEL)
	await process_frame
	var status1_nickel := (layer.get_node("Panel/Layout/Scroll/Body/Refinery/Slot1/Status") as Label).text
	_check("B: slot 1 to no mineral, then Nickel: count starts again from 0; slot 2 untouched (%s | %s | %s)" % [status1, status1_nickel, status2],
		status1 == "No mineral selected" and status1_nickel == "Processing - 3.0 units/s, 0 refined"
		and (layer.get_node("Panel/Layout/Scroll/Body/Refinery/Slot2/Status") as Label).text == "Processing - 4.0 units/s, 4 refined")
	layer.select(null)
	for index in 2:
		refinery.set_enabled(index, false)
		refinery.set_mineral(index, &"")
	storage.amounts.clear()


func _step(refinery: Refinery, storage: Inventory, count: int) -> bool:
	var conserved := true
	for i in count:
		var before := [storage.quantity_of(IRON) + storage.quantity_of(&"iron_ingot"), storage.quantity_of(NICKEL) + storage.quantity_of(&"nickel_ingot")]
		refinery._physics_process(DT)
		conserved = conserved and before == [storage.quantity_of(IRON) + storage.quantity_of(&"iron_ingot"), storage.quantity_of(NICKEL) + storage.quantity_of(&"nickel_ingot")]
	return conserved


# Selects the Transporter (its ship panel shows the Transport section).
func _select_row(_resource: StringName) -> void:
	_selection.set_selection([_main.get_node("Ships/Transporter")])


# Selects the Transporter and opens the transport editor (Configure Cargo).
func _open_editor() -> Node:
	_select_row(IRON)
	(_rows.get_node("Configure") as Button).pressed.emit()
	return _main.get_node("ShipPanel/TransportEditor")


func _clear() -> void:
	_main.get_node("ShipPanel/TransportEditor").close()
	_selection.set_selection([])
	_transport.cancel()
	_transport.status = TransportOperation.Status.NONE
	for resource in Inventory.RESOURCES:
		_transport.required[resource] = 0
		_transport.percent[resource] = false


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
