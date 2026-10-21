extends Node
## UX round (P8) world highlight: hover and selection feedback for ships and stations, a
## low-opacity fill and an outline around each object's silhouette (two shader passes as
## the `material_overlay` of every mesh of the object; no nodes added, so ship and
## station picking are unchanged, and the hull scenes' shared materials are untouched).
## Selected (every selected ship, the selected station): cyan; hovered (the ship or
## station under the cursor, not over the GUI): pale; selected wins. The outline width is
## kept constant on screen from the camera distance. Reads Selection, the station panel
## and the camera; changes nothing they own. The green selection rings stay. T21: an
## asteroid under the cursor (neither a ship nor a station there, as the hover text) is
## hovered too; because the survey's analysis grid uses the asteroids'
## `material_overlay`, an asteroid's highlight goes into its surface override slot
## instead: a copy of its own material with the highlight passes as `next_pass`, so the
## grid and the highlight show together and the asteroid's shared material is untouched.

enum Style { NONE, HOVER, SELECTED }

const FILL := preload("res://game/presentation/highlight_fill.gdshader")
const OUTLINE := preload("res://game/presentation/highlight_outline.gdshader")
const SELECTED_COLOR := Color(0.30, 0.75, 0.90)
const HOVER_COLOR := Color(0.75, 0.85, 0.95)
const FILL_ALPHA := {Style.HOVER: 0.04, Style.SELECTED: 0.08}
const OUTLINE_ALPHA := {Style.HOVER: 0.6, Style.SELECTED: 0.9}
const OUTLINE_PIXELS := {Style.HOVER: 1.5, Style.SELECTED: 2.0} # Width on screen.

@export var selection_path := NodePath("../Selection")
@export var stations_path := NodePath("../Stations")
@export var station_panel_path := NodePath("../StationPanel")
@export var field_path := NodePath("../Asteroids")

var hovered: Node3D = null # The ship or station under the cursor, or null.

var _styles := {} # object -> Style currently applied
var _materials := {} # object -> [fill, outline] (one pair per object; asteroids: + their composed material)

@onready var _selection := get_node(selection_path)
@onready var _stations := get_node_or_null(stations_path)
@onready var _station_panel := get_node_or_null(station_panel_path)
@onready var _field := get_node_or_null(field_path)


func _process(_delta: float) -> void:
	var viewport := get_viewport()
	update(viewport.get_mouse_position(), viewport.gui_get_hovered_control() == null)


## Applies the styles for a cursor position (free: not over the GUI).
func update(mouse: Vector2, free: bool) -> void:
	hovered = _object_at(mouse) if free else null
	var wanted := {}
	if hovered != null:
		wanted[hovered] = Style.HOVER
	for ship: Node3D in _selection.selected:
		wanted[ship] = Style.SELECTED
	if _station_panel != null and _station_panel.station != null:
		wanted[_station_panel.station] = Style.SELECTED
	for target: Node3D in _styles.keys():
		if not wanted.has(target) or not is_instance_valid(target):
			_set_style(target, Style.NONE)
	for target: Node3D in wanted:
		if _styles.get(target, Style.NONE) != wanted[target]:
			_set_style(target, wanted[target])
	_update_widths()


## The style shown on an object (Style.NONE if none).
func style_of(target: Node3D) -> Style:
	return _styles.get(target, Style.NONE)


## Every highlighted object and its style (read by the object markers).
func highlighted() -> Dictionary:
	return _styles


# The ship under the cursor, else the station, else the asteroid (the hover text's order).
# Phase C, Strategic View: an expanded asteroid marker first, then ships and stations by
# their markers.
func _object_at(mouse: Vector2) -> Node3D:
	var strategic = get_parent().get("strategic")
	if strategic != null and strategic.in_strategic():
		var id: int = strategic.asteroid_at(mouse)
		if id >= 0 and _field != null:
			return _field.node_of(id)
		var marked: Node3D = _selection.pick(mouse)
		return marked if marked != null else strategic.station_at(mouse)
	var ship: Node3D = _selection.pick(mouse)
	if ship != null:
		return ship
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	var best: Node3D = null
	var best_distance := INF
	if _stations != null:
		for station: Node3D in _stations.get_children():
			var distance: float = station.pick(origin, direction)
			if distance < best_distance:
				best_distance = distance
				best = station
	if best == null and _field != null:
		var asteroid: int = _field.pick(origin, direction)
		if asteroid >= 0:
			best = _field.node_of(asteroid)
	return best


func _set_style(target: Node3D, style: Style) -> void:
	if not is_instance_valid(target):
		_styles.erase(target)
		_materials.erase(target)
		return
	var overlay: Material = null
	if style != Style.NONE:
		var pair: Array = _materials.get(target, [])
		if pair.is_empty():
			var fill := ShaderMaterial.new()
			fill.shader = FILL
			fill.render_priority = 0
			var outline := ShaderMaterial.new()
			outline.shader = OUTLINE
			outline.render_priority = 1 # After every fill: the stencil is complete.
			fill.next_pass = outline
			pair = [fill, outline]
			_materials[target] = pair
		var color := SELECTED_COLOR if style == Style.SELECTED else HOVER_COLOR
		pair[0].set_shader_parameter("fill_color", Color(color, FILL_ALPHA[style]))
		pair[1].set_shader_parameter("outline_color", Color(color, OUTLINE_ALPHA[style]))
		overlay = pair[0]
		_styles[target] = style
	else:
		_styles.erase(target)
	if _field != null and target.get_parent() == _field:
		_set_asteroid(target as MeshInstance3D, overlay)
		return
	for mesh: MeshInstance3D in target.find_children("*", "MeshInstance3D", true, false):
		if not mesh.mesh is ImmediateMesh: # Debug drawings (berths) are not part of the object.
			mesh.material_overlay = overlay


# An asteroid's highlight: its own material (from the shared mesh) copied once, with the
# highlight passes as next_pass, in the instance's surface override slot; removed by
# clearing that slot (the survey grid in material_overlay is never touched).
func _set_asteroid(mesh: MeshInstance3D, highlight: Material) -> void:
	if highlight == null:
		mesh.set_surface_override_material(0, null)
		return
	var pair: Array = _materials[mesh]
	if pair.size() < 3:
		var composed: Material = mesh.mesh.surface_get_material(0).duplicate()
		composed.next_pass = highlight
		pair.append(composed)
	mesh.set_surface_override_material(0, pair[2])


# Outline width in world units for a constant width on screen at each object's distance.
func _update_widths() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var height := get_viewport().get_visible_rect().size.y
	for target: Node3D in _styles:
		var distance := camera.global_position.distance_to(target.global_position)
		var per_pixel := 2.0 * distance * tan(deg_to_rad(camera.fov) * 0.5) / maxf(height, 1.0)
		_materials[target][1].set_shader_parameter("thickness", OUTLINE_PIXELS[_styles[target]] * per_pixel)


## Outline width in pixels currently shown for an object (for checks), or 0.
func outline_pixels(target: Node3D) -> float:
	if not _styles.has(target):
		return 0.0
	var camera := get_viewport().get_camera_3d()
	var distance := camera.global_position.distance_to(target.global_position)
	var per_pixel := 2.0 * distance * tan(deg_to_rad(camera.fov) * 0.5) / maxf(get_viewport().get_visible_rect().size.y, 1.0)
	return float(_materials[target][1].get_shader_parameter("thickness")) / per_pixel
