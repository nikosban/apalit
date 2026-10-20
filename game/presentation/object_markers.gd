extends Node
## UX round (P8) object markers: one small icon at the centre of every object that is
## hovered or selected (the objects WorldHighlight highlights), drawn in screen space so
## it faces the camera and keeps its size at any zoom; nothing is marked otherwise. One
## shared system: the shape follows the object's category, not its type: combat ships
## (no cargo hold) a triangle, logistics ships (with a cargo hold: miners, transporters)
## an octagon, stations a square, asteroids a diamond. Ships and stations are drawn in
## the highlight's colour (selected cyan, hover pale); an asteroid's diamond shows what
## the survey knows (grey not scanned, amber minerals, blue ice; SurveyView.marker_of()).
## Placeholder graphics. Below the panels (canvas layer 0).

enum Shape { TRIANGLE, OCTAGON, SQUARE, DIAMOND }

const WorldHighlight := preload("res://game/presentation/world_highlight.gd")
const SurveyView := preload("res://game/survey/survey_view.gd")
const SIZE := 7.0 # px, centre to corner
const OUTLINE := Color(0.0, 0.0, 0.0, 0.75)
const SELECTED_COLOR := Color(0.30, 0.75, 0.90)
const HOVER_COLOR := Color(0.85, 0.90, 0.95)
const SURVEY_COLORS := {SurveyView.Marker.ASTEROID: SurveyView.UNKNOWN_COLOR, SurveyView.Marker.MINERALS: SurveyView.MINERALS_COLOR,
	SurveyView.Marker.ICE: SurveyView.ICE_COLOR} # The survey's own colours.

@export var highlight_path := NodePath("../WorldHighlight")
@export var survey_view_path := NodePath("../SurveyView")
@export var ships_path := NodePath("../Ships")
@export var stations_path := NodePath("../Stations")
@export var field_path := NodePath("../Asteroids")

var _overlay: Control

@onready var _highlight := get_node(highlight_path) as WorldHighlight
@onready var _survey_view := get_node_or_null(survey_view_path) as SurveyView
@onready var _ships := get_node_or_null(ships_path)
@onready var _stations := get_node_or_null(stations_path)
@onready var _field := get_node_or_null(field_path)


func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0 # Below the panels (layer 1), as the survey overlay.
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_markers)
	layer.add_child(_overlay)
	add_child(layer)


func _process(_delta: float) -> void:
	_overlay.queue_redraw()


## The markers to draw now: {target, shape, position (screen), color}, one per
## highlighted object in front of the camera and on screen (off-screen objects are not
## marked: their projected positions can be far outside the view).
func entries() -> Array:
	var result := []
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return result
	var view := get_viewport().get_visible_rect().grow(SIZE * 2.0)
	var styles := _highlight.highlighted()
	var tactical = get_parent().get("markers") # Combat: at strategic zoom ships have tactical markers.
	var strategic: bool = tactical != null and tactical.strategic
	for target: Node3D in styles:
		if not is_instance_valid(target) or camera.is_position_behind(target.global_position):
			continue
		if not view.has_point(camera.unproject_position(target.global_position)):
			continue
		var color := SELECTED_COLOR if styles[target] == WorldHighlight.Style.SELECTED else HOVER_COLOR
		var shape := Shape.SQUARE
		var parent := target.get_parent()
		if parent == _ships:
			if strategic:
				continue
			shape = ship_shape(target)
		elif parent == _field:
			shape = Shape.DIAMOND
			if _survey_view != null:
				color = SURVEY_COLORS[_survey_view.marker_of(int(target.get_meta("asteroid_id")))]
		elif parent != _stations:
			continue
		result.append({"target": target, "shape": shape, "position": camera.unproject_position(target.global_position), "color": color})
	return result


func _draw_markers() -> void:
	for entry: Dictionary in entries():
		var points := _points(entry.shape, entry.position)
		_overlay.draw_colored_polygon(points, entry.color)
		var outline := points.duplicate()
		outline.append(points[0])
		_overlay.draw_polyline(outline, OUTLINE, 1.5, true)


## Corner points of a marker shape around a screen point.
static func _points(shape: Shape, at: Vector2) -> PackedVector2Array:
	return shape_points(shape, at, SIZE)


## Corner points of a marker shape of any size (shared with the strategic-zoom markers).
static func shape_points(shape: Shape, at: Vector2, size: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	match shape:
		Shape.TRIANGLE:
			for i in 3:
				points.append(at + Vector2.from_angle(-PI / 2.0 + TAU * i / 3.0) * size)
		Shape.OCTAGON:
			for i in 8:
				points.append(at + Vector2.from_angle(TAU * (i + 0.5) / 8.0) * size * 0.92)
		Shape.SQUARE:
			for i in 4:
				points.append(at + Vector2.from_angle(PI / 4.0 + TAU * i / 4.0) * size * 0.92)
		Shape.DIAMOND:
			for i in 4:
				points.append(at + Vector2.from_angle(TAU * i / 4.0) * size)
	return points


## A ship's marker category: logistics (a cargo hold) an octagon, every other ship a triangle.
static func ship_shape(ship: Node) -> Shape:
	return Shape.OCTAGON if ship.get_node_or_null("Cargo") != null else Shape.TRIANGLE
