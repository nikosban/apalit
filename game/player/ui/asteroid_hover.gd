extends CanvasLayer
## Phase 2 Stage 1 asteroid hover: one small panel next to the cursor for the
## asteroid under it (not over the GUI or a ship), showing what the fleet survey
## knows at its current level. Reserves are read live once analyzed. Phase 2
## Stage 3: over a station (it comes first), the station's storage and docks.
## Never consumes input.

const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const Survey := preload("res://game/survey/survey.gd")
const ShipSelection := preload("res://game/player/selection/ship_selection.gd")
const Tooltip := preload("res://game/player/ui/overlays/hover_tooltip/hover_tooltip.tscn")

var hovered := -1 # Asteroid id under the cursor, or -1.
var hovered_station: Variant = null # Station under the cursor, or null.

var _panel: PanelContainer
var _label: Label

var _field: AsteroidField
var _survey: Survey
var _selection: ShipSelection
var _stations: Node
var _strategic: Node


func configure(field: AsteroidField, survey: Survey, selection: ShipSelection, stations: Node, strategic: Node) -> void:
	_field = field
	_survey = survey
	_selection = selection
	_stations = stations
	_strategic = strategic


func _ready() -> void:
	layer = 2 # Above the panels (layer 1).
	_panel = Tooltip.instantiate()
	_label = _panel.get_node("Label")
	add_child(_panel)


func _process(_delta: float) -> void:
	var viewport := get_viewport()
	var mouse := viewport.get_mouse_position()
	var free := viewport.gui_get_hovered_control() == null
	hovered_station = station_at(mouse) if free else null
	hovered = asteroid_at(mouse) if free and hovered_station == null else -1
	_panel.visible = hovered >= 0 or hovered_station != null
	if not _panel.visible:
		return
	_label.text = hovered_station.describe() if hovered_station != null else describe(hovered)
	_panel.reset_size()
	var limit := viewport.get_visible_rect().size - _panel.size
	_panel.position = (mouse + (_panel.get_meta("cursor_offset") as Vector2)).clamp(Vector2.ZERO, limit.max(Vector2.ZERO))


## Asteroid under a screen point, or -1 (also when a ship is under it). Phase C: in
## Strategic View, an expanded resource marker's asteroid (it comes first there).
func asteroid_at(screen_position: Vector2) -> int:
	if _strategic != null and _strategic.in_strategic():
		return _strategic.asteroid_at(screen_position)
	var camera := get_viewport().get_camera_3d()
	if camera == null or _selection.pick(screen_position) != null:
		return -1
	return _field.pick(camera.project_ray_origin(screen_position), camera.project_ray_normal(screen_position))


## Station under a screen point, or null (also when a ship is under it). Phase C: in
## Strategic View, the station whose marker contains the point.
func station_at(screen_position: Vector2) -> Node3D:
	var camera := get_viewport().get_camera_3d()
	if camera == null or _stations == null or _selection.pick(screen_position) != null:
		return null
	if _strategic != null and _strategic.in_strategic():
		return _strategic.station_at(screen_position)
	var best: Node3D = null
	var best_distance := INF
	for station in _stations.get_children():
		var distance: float = station.pick(camera.project_ray_origin(screen_position), camera.project_ray_normal(screen_position))
		if distance < best_distance:
			best_distance = distance
			best = station
	return best


## Hover text for an asteroid at its current survey level.
func describe(id: int) -> String:
	var level := _survey.level_of(id)
	if level == Survey.Level.UNKNOWN:
		return "Asteroid\nNot scanned"
	var deposit := _field.deposit(id)
	var lines: Array[String] = []
	if deposit.family == AsteroidField.Family.MINERALS:
		lines.append("Asteroid Minerals")
		if level == Survey.Level.ANALYZED:
			for mineral: StringName in AsteroidField.MINERALS:
				lines.append("%s %d%%" % [String(mineral).capitalize(), deposit.composition[mineral]])
		else:
			lines.append("Composition unknown")
	else:
		lines.append("Asteroid Ice")
	lines.append("Remaining reserves: %d units" % deposit.reserves if level == Survey.Level.ANALYZED else "Reserves unknown")
	return "\n".join(lines)
