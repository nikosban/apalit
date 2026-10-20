extends SceneTree
## Headless UX round P7 (T17 / T18) checks on the playable main scene: the transport
## main panel and the transport editor (epic section 6.2). The editor edits a draft of
## the loading requirements (Ore: six raw minerals + Ice, Ingots: six ingots + the same
## Ice, Components: disabled); typed values, tab switches, Clear and selection changes
## change only the draft; Apply hands the whole draft to
## TransportOperation.apply_requirements(), all or nothing (a late invalid row after
## several valid ones changes nothing saved, the draft stays for correction); Cancel
## closes without applying. Unloading is shown as information, not edited. A second
## Transporter (transporter_unit.tscn) is added at run time and registered as the
## Shipyard does. Ship physics is off.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/transport_editor_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const TRANSPORTER := preload("res://game/ships/transporter_unit.tscn")
const Inventory := preload("res://game/cargo/inventory.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const EDITOR := "ShipPanel/TransportEditor"
const TRANSPORT := "ShipPanel/Panel/Layout/Scroll/Body/Actions/Transport"
const ORE := 0
const INGOTS := 1

var _failures := 0
var _checks := 0
var _main: Node
var _editor: Node
var _transport: TransportOperation
var _notices: Array[String] = []


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	var other: Node3D = TRANSPORTER.instantiate()
	other.name = "TransporterB"
	other.position = Vector3(70, 1.5, 60)
	_main.get_node("Ships").add_child(other)
	_main.get_node("Selection").register_ship(other)
	_main.register_ship(other)
	_main.get_node("Survey").set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		for child in ship.get_children():
			child.set_physics_process(false)
		var transport := ship.get_node_or_null("Transport")
		if transport != null:
			transport.notice.connect(func(text: String) -> void: _notices.append(text))
	_editor = _main.get_node(EDITOR)
	_transport = _main.get_node("Ships/Transporter/Transport")
	await _test_main_panel()
	await _test_open()
	await _test_draft_only()
	await _test_tabs_and_ice()
	await _test_selection_changes()
	await _test_apply()
	await _test_late_invalid()
	await _test_capacity_edge()
	await _test_cancel()
	await _test_other_transporter()
	await _test_active_assignment()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# T17: route, saved requirements, unloading rule, Configure.
func _test_main_panel() -> void:
	_select("Transporter")
	await _frames(2)
	var rows := _main.get_node(TRANSPORT)
	var route_unset: String = rows.get_node("Route").text
	_transport.set_load_station(_main.get_node("Stations/Station"))
	_transport.set_unload_station(_main.get_node("Stations/Station2"))
	await _frames(2)
	_check("main panel: route '%s' then '%s'; requirements summary; unloading shown as all cargo; Configure Cargo; no requirement row" % [route_unset, rows.get_node("Route").text],
		route_unset == "Route: choose two different stations" and rows.get_node("Route").text == "Route: Station → Station2"
		and (rows.get_node("Required") as Label).text == "Required: none" and (rows.get_node("Unloading") as Label).text.contains("all cargo")
		and rows.get_node_or_null("Configure") != null and rows.get_node_or_null("RequirementRow") == null)


func _test_open() -> void:
	(_main.get_node(TRANSPORT + "/Configure") as Button).pressed.emit()
	await _frames(2)
	var panel: Control = _editor.get_node("Panel")
	var ship_panel: Control = _main.get_node("ShipPanel/Panel")
	var ore := _resources(ORE)
	var ingots := _resources(INGOTS)
	var tabs = _editor.get_node("Panel/Layout/Header/Tabs")
	_check("Configure opens the editor beside the ship panel (%.0f..%.0f px, panel from %.0f px) for the Transporter (%s)" % [panel.get_global_rect().position.x,
		panel.get_global_rect().end.x, ship_panel.get_global_rect().position.x, _editor.get_node("Panel/Layout/Header/Title").text],
		_editor.is_open() and _editor.ship == _ship("Transporter") and panel.get_global_rect().end.x <= ship_panel.get_global_rect().position.x)
	_check("tabs: Ore %s, Ingots %s (Ice in both), Components disabled; unloading is information only" % [str(ore), str(ingots)],
		ore == [&"iron", &"nickel", &"silicon", &"cobalt", &"gold", &"titanium", &"ice"]
		and ingots == [&"iron_ingot", &"nickel_ingot", &"silicon_ingot", &"cobalt_ingot", &"gold_ingot", &"titanium_ingot", &"ice"]
		and tabs.button(2).disabled and (_editor.get_node("Panel/Layout/Footer/Unloading") as Label).text.contains("whole cargo"))


# A typed amount enters the draft at once (no Enter, no focus loss); nothing is saved.
func _test_draft_only() -> void:
	await _type(ORE, &"iron", 200)
	await _frames(1)
	_check("typed Iron 200 (no Enter): in the draft (%d), not saved (%d), Apply enabled, unapplied changes shown" % [_editor.draft[&"iron"], _transport.required[&"iron"]],
		_editor.draft[&"iron"] == 200 and _transport.required[&"iron"] == 0 and not (_editor.get_node("Panel/Layout/Footer/Buttons/Apply") as Button).disabled
		and (_editor.get_node("Panel/Layout/Footer/Total") as Label).text.contains("unapplied"))


func _test_tabs_and_ice() -> void:
	_tab(INGOTS)
	await _type(INGOTS, &"titanium_ingot", 30, true)
	_tab(ORE)
	await _frames(1)
	var iron_shown := _shown(ORE, &"iron")
	_check("switching tabs keeps the draft: Iron still %d (shown %d), Titanium Ingots %d%% in the draft" % [_editor.draft[&"iron"], iron_shown, _editor.draft[&"titanium_ingot"]],
		_editor.draft[&"iron"] == 200 and iron_shown == 200 and _editor.draft[&"titanium_ingot"] == 30 and _editor.draft_percent[&"titanium_ingot"])
	await _type(ORE, &"ice", 50)
	var ingots_ice := _shown(INGOTS, &"ice")
	_editor.row(INGOTS, &"ice").get_node("Clear").pressed.emit()
	_check("Ice is one draft value in both tabs: 50 typed in Ore shows 50 in Ingots (%d); Clear in Ingots -> 0 in the draft and in Ore (%d)" % [ingots_ice, _shown(ORE, &"ice")],
		ingots_ice == 50 and _editor.draft[&"ice"] == 0 and _shown(ORE, &"ice") == 0 and _transport.required[&"ice"] == 0)


# Selection changes neither apply nor discard the draft.
func _test_selection_changes() -> void:
	_main.get_node("Selection").set_selection([])
	await _frames(2)
	var kept_deselected: bool = _editor.is_open() and _editor.draft[&"iron"] == 200
	_select("Frigate")
	await _frames(2)
	_check("deselecting, then selecting the Frigate: the editor stays open for the Transporter with its draft (Iron %d), nothing saved" % _editor.draft[&"iron"],
		kept_deselected and _editor.is_open() and _editor.ship == _ship("Transporter") and _editor.draft[&"iron"] == 200 and _transport.required[&"iron"] == 0)


func _test_apply() -> void:
	_notices.clear()
	var applied: bool = _editor.apply()
	_check("Apply: every draft value saved at once (Iron 200, Titanium Ingots 30%%), no reselection, no notice (%s)" % _transport.describe_requirements(),
		applied and _transport.required[&"iron"] == 200 and _transport.required[&"titanium_ingot"] == 30 and _transport.percent[&"titanium_ingot"]
		and _transport.total_required() == 500 and _notices.is_empty() and not _editor.is_dirty())


# Several valid rows, then one that makes the whole exceed the hold: nothing is saved.
func _test_late_invalid() -> void:
	var before := [_transport.required.duplicate(), _transport.percent.duplicate()]
	await _type(ORE, &"nickel", 100)
	await _type(ORE, &"cobalt", 100)
	_tab(INGOTS)
	await _type(INGOTS, &"silicon_ingot", 50, true) # 200 + 300 + 100 + 100 + 500 = 1200 > 1000.
	_notices.clear()
	var applied: bool = _editor.apply()
	await _frames(1)
	_check("late invalid row (Silicon Ingots 50%% after Nickel and Cobalt 100): rejected, nothing saved (%s), one notice, draft kept for correction, reason shown" % _transport.describe_requirements(),
		not applied and _transport.required == before[0] and _transport.percent == before[1] and _notices.size() == 1
		and _notices[0].contains("exceed the cargo capacity") and _editor.draft[&"nickel"] == 100 and _editor.draft[&"silicon_ingot"] == 50
		and (_editor.get_node("Panel/Layout/Footer/Message") as Label).text.begins_with("Not applied"))


func _test_capacity_edge() -> void:
	await _type(INGOTS, &"silicon_ingot", 30, true) # Exactly 1000.
	var exact: bool = _editor.apply()
	var saved_exact := _transport.total_required()
	await _type(INGOTS, &"silicon_ingot", 31, true) # 1010.
	var over: bool = _editor.apply()
	_check("percent near capacity: 30%% makes exactly 1000 and is saved (%d); 31%% (1010) is rejected and 30%% stays (%d%%)" % [saved_exact, _transport.required[&"silicon_ingot"]],
		exact and saved_exact == 1000 and not over and _transport.required[&"silicon_ingot"] == 30 and _transport.total_required() == 1000)
	await _type(INGOTS, &"silicon_ingot", 30, true)


func _test_cancel() -> void:
	_tab(ORE)
	await _type(ORE, &"iron", 10)
	(_editor.get_node("Panel/Layout/Footer/Buttons/Cancel") as Button).pressed.emit()
	_check("Cancel: the editor closes, the saved requirements unchanged (Iron %d)" % _transport.required[&"iron"],
		not _editor.is_open() and _transport.required[&"iron"] == 200 and _transport.total_required() == 1000)


# Configure for another transporter waits while the editor holds unapplied changes.
func _test_other_transporter() -> void:
	_select("Transporter")
	await _frames(1)
	(_main.get_node(TRANSPORT + "/Configure") as Button).pressed.emit()
	await _type(ORE, &"gold", 0)
	await _type(ORE, &"iron", 150) # Unapplied.
	_select("TransporterB")
	await _frames(2)
	var blocked: bool = (_main.get_node(TRANSPORT + "/Configure") as Button).disabled
	(_editor.get_node("Panel/Layout/Footer/Buttons/Cancel") as Button).pressed.emit()
	await _frames(2)
	var free_again: bool = not (_main.get_node(TRANSPORT + "/Configure") as Button).disabled
	(_main.get_node(TRANSPORT + "/Configure") as Button).pressed.emit()
	_check("another transporter: Configure waits while the Transporter's draft is unapplied (%s), then opens for TransporterB (%s)" % [blocked, _editor.ship.name],
		blocked and free_again and _editor.ship == _ship("TransporterB") and _transport.required[&"iron"] == 200)
	(_editor.get_node("Panel/Layout/Footer/Buttons/Cancel") as Button).pressed.emit()


# Applying during an active assignment keeps it running (live edit); all at zero pauses it.
func _test_active_assignment() -> void:
	_select("Transporter")
	await _frames(1)
	_transport.start()
	(_main.get_node(TRANSPORT + "/Configure") as Button).pressed.emit()
	_tab(ORE)
	await _type(ORE, &"iron", 100)
	_notices.clear()
	var raised: bool = _editor.apply()
	var still_active := _transport.status == TransportOperation.Status.LOADING and _notices.is_empty()
	for resource in [&"iron", &"nickel", &"cobalt"]:
		await _type(ORE, resource, 0)
	_tab(INGOTS)
	await _type(INGOTS, &"titanium_ingot", 0, true)
	await _type(INGOTS, &"silicon_ingot", 0, true)
	var cleared: bool = _editor.apply()
	_check("during an active assignment: a valid Apply keeps it Loading with the new values (%s); clearing everything and Apply pauses it with its notice (%s)" % [still_active, str(_notices)],
		raised and still_active and cleared and _transport.status == TransportOperation.Status.PAUSED
		and _notices == ["Transporter: transport paused - no cargo required"])


# ------------------------------------------------------------------ helpers
func _type(tab: int, resource: StringName, amount: int, as_percent := false) -> void:
	var row: Node = _editor.row(tab, resource)
	var mode = row.get_node("Mode")
	if mode.selected != (1 if as_percent else 0):
		mode.button(1 if as_percent else 0).button_pressed = true
	var line := (row.get_node("Amount") as SpinBox).get_line_edit()
	line.text = str(amount)
	line.text_changed.emit(line.text) # Typed, no Enter, focus kept.
	await process_frame # The SpinBox takes typed text in the next frame (as when typing).


func _shown(tab: int, resource: StringName) -> int:
	return int((_editor.row(tab, resource).get_node("Amount") as SpinBox).value)


func _tab(tab: int) -> void:
	_editor.get_node("Panel/Layout/Header/Tabs").button(tab).button_pressed = true


func _resources(tab: int) -> Array:
	var body := "Panel/Layout/Scroll/Body/" + ("Ore" if tab == ORE else "Ingots")
	return _editor.get_node(body).get_children().map(func(row: Node) -> StringName: return row.resource)


func _select(ship_name: String) -> void:
	_main.get_node("Selection").set_selection([_ship(ship_name)])


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
