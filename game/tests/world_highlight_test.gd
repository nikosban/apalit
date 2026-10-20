extends SceneTree
## Headless UX round P8 (T20) checks on the playable main scene: WorldHighlight shows a
## selected style (cyan) on every selected ship and the selected station and a hover
## style (pale) on the ship or station under the cursor (not over the GUI), as the
## material_overlay of every mesh of the object; it never adds nodes, so Selection's
## pick boxes and rings and the station picks stay the same; the outline keeps its
## width on screen at any zoom; produced ships are included; the green rings stay.
## T21: an asteroid under the cursor gets the hover style in its surface override slot
## (its material copied with the highlight as next_pass), so the survey grid in its
## material_overlay and the asteroids' shared material are never touched.
## The cursor is given to WorldHighlight.update() directly (headless has no cursor).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/world_highlight_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const MINER := preload("res://game/ships/miner_unit.tscn")
const WorldHighlight := preload("res://game/presentation/world_highlight.gd")

var _failures := 0
var _checks := 0
var _main: Node
var _highlight: WorldHighlight
var _selection: Node
var _camera: Camera3D


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_main.get_node("Survey").set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		for child in ship.get_children():
			child.set_physics_process(false)
	_highlight = _main.get_node("WorldHighlight")
	_highlight.set_process(false) # Driven by update() with a chosen cursor position.
	_selection = _main.get_node("Selection")
	_camera = _main.get_node("CameraRig/Camera3D")
	var before := _measure()
	_frame(Vector2(0, 6), 34.0)
	await process_frame
	var away := Vector2(5, 5) # Screen corner: no ship or station there.

	_selection.set_selection([_ship("Miner1")])
	_highlight.update(away, true)
	_check("one ship selected: every mesh of Miner1 (nested hull) has the selected overlay, cyan fill 0.08; no other object highlighted",
		_styled("Ships/Miner1", WorldHighlight.Style.SELECTED, Color(0.30, 0.75, 0.90, 0.08)) and _count() == 1)

	_selection.set_selection([_ship("Frigate"), _ship("Gunship"), _ship("Destroyer")])
	_highlight.update(away, true)
	_check("three ships selected: each has the selected overlay, Miner1's is cleared",
		_styled("Ships/Frigate", WorldHighlight.Style.SELECTED) and _styled("Ships/Gunship", WorldHighlight.Style.SELECTED)
		and _styled("Ships/Destroyer", WorldHighlight.Style.SELECTED) and _cleared("Ships/Miner1") and _count() == 3)
	_selection._process(0.0)
	_check("the green selection rings stay on the selected ships", [_ship("Frigate"), _ship("Gunship"), _ship("Destroyer")].all(func(s: Node3D) -> bool: return _selection._rings[s].visible) and not _selection._rings[_ship("Miner1")].visible)

	_selection.set_selection([])
	var over_miner := _screen(_ship("Miner2").global_position)
	_highlight.update(over_miner, true)
	var hover_miner: bool = _highlight.hovered == _ship("Miner2") and _styled("Ships/Miner2", WorldHighlight.Style.HOVER, Color(0.75, 0.85, 0.95, 0.04))
	_highlight.update(over_miner, false)
	_check("hover: the ship under the cursor gets the pale hover overlay (fill 0.04); over the GUI nothing is hovered (%s)" % str(_highlight.hovered),
		hover_miner and _highlight.hovered == null and _cleared("Ships/Miner2"))

	_selection.set_selection([_ship("Miner2")])
	_highlight.update(over_miner, true)
	_check("a hovered selected ship keeps the selected style", _styled("Ships/Miner2", WorldHighlight.Style.SELECTED))
	_selection.set_selection([])

	var station: Node3D = _main.get_node("Stations/Station")
	_frame(Vector2(station.global_position.x, station.global_position.z), 30.0)
	await process_frame
	var over_station := _screen(station.global_position)
	_highlight.update(over_station, true)
	var hover_station: bool = _highlight.hovered == station and _styled("Stations/Station", WorldHighlight.Style.HOVER)
	_main.get_node("StationPanel").select(station)
	_highlight.update(away, true)
	_check("stations: hovered -> hover overlay on every station mesh; selected (station panel) -> selected overlay (%s)" % hover_station,
		hover_station and _styled("Stations/Station", WorldHighlight.Style.SELECTED))
	_main.get_node("StationPanel").select(null)
	_highlight.update(away, true)
	_check("deselected station: its overlay is removed, nothing highlighted", _cleared("Stations/Station") and _count() == 0)

	# Constant width on screen: the world thickness follows the camera distance.
	_selection.set_selection([_ship("Gunship")])
	var widths := []
	var pixels := []
	for zoom in [8.0, 20.0, 40.0]:
		_frame(Vector2(0, 0), zoom)
		await process_frame
		_highlight.update(away, true)
		widths.append(snappedf(_highlight._materials[_ship("Gunship")][1].get_shader_parameter("thickness"), 0.0001))
		pixels.append(snappedf(_highlight.outline_pixels(_ship("Gunship")), 0.001))
	_check("outline width constant on screen at zoom 8 / 20 / 40: %s px (world %s u)" % [str(pixels), str(widths)],
		pixels.all(func(p: float) -> bool: return absf(p - 2.0) < 0.01) and widths[0] < widths[1] and widths[1] < widths[2])

	# A ship added at run time (as the Shipyard does) is highlighted like the others.
	var produced: Node3D = MINER.instantiate()
	produced.name = "Miner9"
	produced.position = Vector3(20, 1.5, 20)
	_main.get_node("Ships").add_child(produced)
	_selection.register_ship(produced)
	_main.register_ship(produced)
	_selection.set_selection([produced])
	_highlight.update(away, true)
	_check("a ship added at run time and selected gets the selected overlay on all its meshes", _styled("Ships/Miner9", WorldHighlight.Style.SELECTED))
	_selection.set_selection([])
	_highlight.update(away, true)

	await _test_asteroids()

	# Overlays never change picking or the selection feedback: compare with the start.
	_selection.set_selection([_ship("Frigate"), _ship("Gunship"), _ship("Destroyer"), _ship("Miner1"), _ship("Transporter")])
	_main.get_node("StationPanel").select(station)
	_highlight.update(away, true)
	var during := _measure()
	_check("with overlays on five ships and the station: pick boxes, ring radii, mesh counts and station picks identical to the start (%d values)" % before.size(),
		during == before)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# T21: asteroid hover alone and together with a survey analysis grid.
func _test_asteroids() -> void:
	var field := _main.get_node("Asteroids")
	var asteroid: MeshInstance3D = field.node_of(5)
	var shared: Material = asteroid.mesh.surface_get_material(0)
	_frame(Vector2(asteroid.global_position.x, asteroid.global_position.z), 30.0)
	await process_frame
	var over := _screen(asteroid.global_position)
	var away := Vector2(5, 5)
	_highlight.update(over, true)
	var override := asteroid.get_surface_override_material(0)
	var fill := override.next_pass as ShaderMaterial if override != null else null
	_check("asteroid hover: the pale highlight is chained after a copy of the asteroid's own material in its surface override slot; overlay slot untouched (null)",
		_highlight.hovered == asteroid and _highlight.style_of(asteroid) == WorldHighlight.Style.HOVER and override != null and override != shared
		and fill != null and (fill.get_shader_parameter("fill_color") as Color).is_equal_approx(Color(0.75, 0.85, 0.95, 0.04)) and fill.next_pass != null
		and asteroid.material_overlay == null and shared.next_pass == null)
	_highlight.update(away, true)
	_check("cursor leaves the asteroid: surface override cleared, nothing highlighted", asteroid.get_surface_override_material(0) == null and _count() == 0)
	# The survey's analysis grid is the asteroid's material_overlay (as SurveyView sets it).
	var grid := ShaderMaterial.new()
	grid.shader = preload("res://game/survey/scan_grid.gdshader")
	asteroid.material_overlay = grid
	_highlight.update(over, true)
	var both: bool = asteroid.material_overlay == grid and asteroid.get_surface_override_material(0) != null
	_highlight.update(away, true)
	_check("with an analysis grid on the asteroid: grid and hover highlight shown together (%s); leaving clears only the highlight, the grid stays" % both,
		both and asteroid.material_overlay == grid and asteroid.get_surface_override_material(0) == null and shared.next_pass == null)
	_highlight.update(over, true)
	asteroid.material_overlay = null # The analysis ends while hovered (SurveyView clears its grid).
	_highlight.update(over, true)
	_check("the grid ending while hovered leaves the hover highlight in place",
		asteroid.get_surface_override_material(0) != null and _highlight.style_of(asteroid) == WorldHighlight.Style.HOVER)
	_highlight.update(away, true)
	var station: Node3D = _main.get_node("Stations/Station")
	_frame(Vector2(station.global_position.x, station.global_position.z), 30.0)
	await process_frame
	_highlight.update(_screen(station.global_position), true)
	_check("a station in front of the cursor is hovered, not an asteroid behind it", _highlight.hovered == station)
	_highlight.update(away, true)


# Every mesh of the object has the overlay of the style (and fill colour if given).
func _styled(path: String, style: int, fill := Color(0, 0, 0, 0)) -> bool:
	var target: Node3D = _main.get_node(path)
	if _highlight.style_of(target) != style:
		return false
	for mesh: MeshInstance3D in target.find_children("*", "MeshInstance3D", true, false):
		var overlay := mesh.material_overlay as ShaderMaterial
		if overlay == null or overlay.next_pass == null:
			return false
		if fill.a > 0.0 and not (overlay.get_shader_parameter("fill_color") as Color).is_equal_approx(fill):
			return false
	return true


func _cleared(path: String) -> bool:
	var target: Node3D = _main.get_node(path)
	return _highlight.style_of(target) == WorldHighlight.Style.NONE \
		and target.find_children("*", "MeshInstance3D", true, false).all(func(mesh: MeshInstance3D) -> bool: return mesh.material_overlay == null)


func _count() -> int:
	return _highlight._styles.size()


func _measure() -> Dictionary:
	var result := {}
	for ship in _main.get_node("Ships").get_children():
		if ship.name == "Miner9":
			continue # Added by the test after the first measurement.
		result["boxes " + ship.name] = str(_selection._parts[ship])
		result["ring " + ship.name] = (_selection._rings[ship].mesh as TorusMesh).outer_radius
		result["meshes " + ship.name] = ship.find_children("*", "MeshInstance3D", true, false).size()
	var station: Node3D = _main.get_node("Stations/Station")
	result["meshes Station"] = station.find_children("*", "MeshInstance3D", true, false).size()
	for x in range(-12, 13, 4):
		for z in range(-6, 7, 3):
			var origin := station.global_position + Vector3(x, 40, z + 20)
			result["pick %d,%d" % [x, z]] = snappedf(station.pick(origin, (station.global_position + Vector3(x, 0, z) - origin).normalized()), 0.0001)
	return result


func _screen(point: Vector3) -> Vector2:
	return _camera.unproject_position(point)


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
