extends SceneTree
## Headless UX round P8 (T22) checks on the playable main scene: ObjectMarkers draws one
## centred, screen-space marker per hovered or selected object (WorldHighlight's set) and
## none otherwise; shape by category (combat ship triangle, logistics ship octagon,
## station square, asteroid diamond); asteroids tinted by the survey's knowledge; the
## marker sits on the object's centre at the minimum and maximum zoom and keeps its size;
## a ship added at run time is marked by its category; SurveyView no longer draws a
## persistent marker per asteroid (its transient analysis feedback stays).
## The cursor is given to WorldHighlight.update() directly (headless has no cursor).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/object_markers_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const MINER := preload("res://game/ships/miner_unit.tscn")
const ObjectMarkers := preload("res://game/presentation/object_markers.gd")
const SurveyView := preload("res://game/survey/survey_view.gd")

var _failures := 0
var _checks := 0
var _main: Node
var _markers: ObjectMarkers
var _highlight: Node
var _selection: Node
var _camera: Camera3D
var _away := Vector2(5, 5)


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	var ff01: Node3D = load("res://game/ships/ff01_unit.tscn").instantiate() # The warship (combat) type.
	ff01.name = "FF01"
	ff01.position = Vector3(14, 1.5, 0)
	_main.get_node("Ships").add_child(ff01)
	root.add_child(_main)
	_main.get_node("Survey").set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		for child in ship.get_children():
			child.set_physics_process(false)
	_markers = _main.get_node("ObjectMarkers")
	_highlight = _main.get_node("WorldHighlight")
	_highlight.set_process(false)
	_selection = _main.get_node("Selection")
	_camera = _main.get_node("CameraRig/Camera3D")
	_main.get_node("Ships/Transporter/Locomotion").place(Vector2(-22, 6), 0.0) # In view with the others (it starts far west).
	_frame(Vector2(0, 6), 34.0)
	await process_frame

	_highlight.update(_away, true)
	_check("nothing hovered or selected: no markers (the map shows none)", _markers.entries().is_empty())

	_selection.set_selection([_ship("FF01"), _ship("Miner1"), _ship("Transporter")])
	_highlight.update(_away, true)
	var shapes := _shapes()
	_check("selected ships: FF01 triangle (combat), Miner1 and Transporter octagons (logistics), cyan (%s)" % str(shapes),
		shapes == {"FF01": ObjectMarkers.Shape.TRIANGLE, "Miner1": ObjectMarkers.Shape.OCTAGON,
			"Transporter": ObjectMarkers.Shape.OCTAGON}
		and _markers.entries().all(func(e: Dictionary) -> bool: return e.color == Color(0.30, 0.75, 0.90)))
	var centred := true
	for zoom in [5.0, 40.0]:
		_frame(Vector2(0, 6), zoom)
		await process_frame
		_highlight.update(_away, true)
		for entry: Dictionary in _markers.entries():
			centred = centred and (entry.position as Vector2).distance_to(_camera.unproject_position(entry.target.global_position)) < 0.01
	_check("markers centred on their objects at the minimum and maximum zoom (5 and 40); fixed size %.0f px (screen space)" % ObjectMarkers.SIZE, centred)
	_frame(Vector2(120, 120), 10.0) # The selected ships are now far off screen.
	await process_frame
	_highlight.update(_away, true)
	_check("selected ships off screen: not marked (no marker drawn far outside the view)", _markers.entries().is_empty())
	_selection.set_selection([])

	var station: Node3D = _main.get_node("Stations/Station")
	_frame(Vector2(station.global_position.x, station.global_position.z), 30.0)
	await process_frame
	_highlight.update(_camera.unproject_position(station.global_position), true)
	var hovered := _markers.entries()
	_check("hovered station: one square, hover colour", hovered.size() == 1 and hovered[0].target == station
		and hovered[0].shape == ObjectMarkers.Shape.SQUARE and hovered[0].color == Color(0.85, 0.90, 0.95))
	_main.get_node("StationPanel").select(station)
	_highlight.update(_away, true)
	_check("selected station: square in the selected colour", _markers.entries().size() == 1 and _markers.entries()[0].color == Color(0.30, 0.75, 0.90))
	_main.get_node("StationPanel").select(null)

	var field := _main.get_node("Asteroids")
	var asteroid: MeshInstance3D = field.node_of(5)
	var view: SurveyView = _main.get_node("SurveyView")
	_frame(Vector2(asteroid.global_position.x, asteroid.global_position.z), 30.0)
	await process_frame
	_highlight.update(_camera.unproject_position(asteroid.global_position), true)
	var entry: Dictionary = _markers.entries()[0] if _markers.entries().size() == 1 else {}
	_check("hovered asteroid: a diamond tinted by what the survey knows (%s)" % str(view.marker_of(5)),
		not entry.is_empty() and entry.target == asteroid and entry.shape == ObjectMarkers.Shape.DIAMOND
		and entry.color == ObjectMarkers.SURVEY_COLORS[view.marker_of(5)])
	var tints := [ObjectMarkers.SURVEY_COLORS[SurveyView.marker_for(0, 0)], ObjectMarkers.SURVEY_COLORS[SurveyView.marker_for(1, 0)],
		ObjectMarkers.SURVEY_COLORS[SurveyView.marker_for(1, 1)]]
	_check("survey tints: not scanned grey, minerals amber, ice blue (the survey's own colours)",
		tints == [SurveyView.UNKNOWN_COLOR, SurveyView.MINERALS_COLOR, SurveyView.ICE_COLOR])
	_highlight.update(_away, true)
	_check("cursor away: the asteroid's marker is gone", _markers.entries().is_empty())
	_check("SurveyView no longer draws a persistent marker per asteroid", not view.has_method("_draw_marker"))

	var produced: Node3D = MINER.instantiate()
	produced.name = "Miner9"
	produced.position = Vector3(20, 1.5, 20)
	_main.get_node("Ships").add_child(produced)
	_selection.register_ship(produced)
	_main.register_ship(produced)
	_selection.set_selection([produced])
	_frame(Vector2(20, 20), 30.0)
	await process_frame
	_highlight.update(_away, true)
	_check("a ship added at run time is marked by its category (octagon)", _shapes() == {"Miner9": ObjectMarkers.Shape.OCTAGON})
	_selection.set_selection([])
	_highlight.update(_away, true)
	_check("deselected: no markers", _markers.entries().is_empty())
	_test_style_snapshot()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _shapes() -> Dictionary:
	var shapes := {}
	for entry: Dictionary in _markers.entries():
		shapes[String(entry.target.name)] = entry.shape
	return shapes


func _frame(center: Vector2, zoom: float) -> void:
	var rig := _main.get_node("CameraRig")
	rig.global_position = Vector3(center.x, 0, center.y)
	rig.zoom_distance = zoom
	rig._apply_zoom()


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])


func _test_style_snapshot() -> void:
	var interaction = _markers.interaction_style
	var source = _markers.marker_style
	var selected: Color = interaction.selected_color
	var stroke: float = source.object_stroke
	interaction.selected_color = Color(0.4, 0.2, 0.8)
	source.object_stroke = 2.25
	_frame(Vector2(-8, 14), 30.0)
	_selection.set_selection([_ship("Miner1")])
	_highlight.update(_away, false)
	_check("style: existing Object markers keep color and stroke snapshot",
		_markers.entries().any(func(entry): return entry.target == _ship("Miner1") and entry.color == selected)
		and is_equal_approx(_markers._marker.object_stroke, stroke))
	var ship: Node3D = _ship("Miner1")
	var markers = ObjectMarkers.new()
	_main.add_child(markers)
	_check("style: restarted Object markers consume both updated resources",
		markers.entries().any(func(entry): return entry.target == ship and entry.color == interaction.selected_color)
		and is_equal_approx(markers._marker.object_stroke, 2.25))
	markers._marker.object_stroke = 3.0
	_check("style: marker runtime changes leave source and other run untouched",
		is_equal_approx(source.object_stroke, 2.25) and is_equal_approx(_markers._marker.object_stroke, stroke))
	interaction.selected_color = selected
	source.object_stroke = stroke
	_main.remove_child(markers)
	markers.free()
