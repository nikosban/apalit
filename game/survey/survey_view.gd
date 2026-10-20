extends Node3D
## Phase 2 Stage 1 survey presentation; reads the Survey and the AsteroidField, never
## writes them. Draws each scan's pulse (a ring on the ground growing from the
## activation point at the survey's pulse speed, with the scan boundary), the
## surface-analysis grid on asteroids being analyzed (their material_overlay; mesh
## and material untouched), and a screen overlay with a progress ring and percentage
## while an asteroid is analyzed and DATA UPLOADED while uploading. UX round (P8): the
## persistent marker per asteroid is gone; what the survey knows (marker_of(): Asteroid,
## Asteroid Minerals, Asteroid Ice) now tints the object marker shown on an asteroid
## only while it is hovered (game/presentation/object_markers.gd).

enum Marker { ASTEROID, MINERALS, ICE }

const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const Survey := preload("res://game/survey/survey.gd")
const GRID_SHADER := preload("res://game/survey/scan_grid.gdshader")
const PULSE_HEIGHT := 0.05
const PULSE_WIDTH := 0.5 # u
const BOUNDARY_WIDTH := 0.25 # u
const PULSE_FADE := 0.8 # s after the pulse reaches its radius
const RING_SEGMENTS := 96
const SCAN_COLOR := Color(0.35, 0.85, 1.0)
const UPLOAD_COLOR := Color(0.55, 1.0, 0.7)
const UNKNOWN_COLOR := Color(0.7, 0.72, 0.75, 0.85) # Survey-knowledge colours, used by the object markers.
const MINERALS_COLOR := Color(0.95, 0.65, 0.25)
const ICE_COLOR := Color(0.55, 0.85, 1.0)
const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.7)
const MARKER_LIFT := 1.5 # u above the asteroid's top (the analysis feedback, clear of the centred object marker)
const PROGRESS_RADIUS := 11.0 # px
const FONT_SIZE := 12

@export var survey_path := NodePath("../Survey")
@export var field_path := NodePath("../Asteroids")

var _pulses: Array[Dictionary] = [] # {origin, radius, age}
var _grids := {} # asteroid id -> ShaderMaterial
var _pulse_mesh := ImmediateMesh.new()
var _overlay: Control

@onready var _survey := get_node(survey_path) as Survey
@onready var _field := get_node(field_path) as AsteroidField


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pulses := MeshInstance3D.new()
	pulses.mesh = _pulse_mesh
	pulses.material_override = material
	pulses.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pulses)
	var layer := CanvasLayer.new()
	layer.layer = 0 # Below the panels (layer 1).
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	layer.add_child(_overlay)
	add_child(layer)
	_survey.scan_started.connect(_on_scan_started)


## What the survey knows of an asteroid, as a marker kind, for a level and family.
static func marker_for(level: int, family: int) -> Marker:
	if level == Survey.Level.UNKNOWN:
		return Marker.ASTEROID
	return Marker.MINERALS if family == AsteroidField.Family.MINERALS else Marker.ICE


func marker_of(id: int) -> Marker:
	return marker_for(_survey.level_of(id), _field.deposit(id).family)


func _on_scan_started(origin: Vector2, radius: float) -> void:
	_pulses.append({"origin": origin, "radius": radius, "age": 0.0})


func _process(delta: float) -> void:
	_update_pulses(delta)
	_update_grids()
	_overlay.queue_redraw()


func _update_pulses(delta: float) -> void:
	_pulse_mesh.clear_surfaces()
	for pulse: Dictionary in _pulses.duplicate():
		pulse.age += delta
		var grow_time: float = pulse.radius / _survey.pulse_speed
		if pulse.age > grow_time + PULSE_FADE:
			_pulses.erase(pulse)
	if _pulses.is_empty():
		return
	_pulse_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for pulse: Dictionary in _pulses:
		var grow_time: float = pulse.radius / _survey.pulse_speed
		var front := minf(pulse.age * _survey.pulse_speed, pulse.radius)
		var fade: float = 1.0 if pulse.age <= grow_time else 1.0 - (pulse.age - grow_time) / PULSE_FADE
		_ring(pulse.origin, maxf(front - PULSE_WIDTH, 0.0), front, Color(SCAN_COLOR, 0.9 * fade))
		_ring(pulse.origin, pulse.radius - BOUNDARY_WIDTH, pulse.radius, Color(SCAN_COLOR, 0.3 * fade))
	_pulse_mesh.surface_end()


func _ring(center: Vector2, inner: float, outer: float, color: Color) -> void:
	for i in RING_SEGMENTS:
		var a := Vector2.from_angle(TAU * i / RING_SEGMENTS)
		var b := Vector2.from_angle(TAU * (i + 1) / RING_SEGMENTS)
		var points := [center + a * inner, center + a * outer, center + b * outer, center + b * inner]
		for k: int in [0, 1, 2, 0, 2, 3]:
			_pulse_mesh.surface_set_color(color)
			_pulse_mesh.surface_add_vertex(Vector3(points[k].x, PULSE_HEIGHT, points[k].y))


func _update_grids() -> void:
	var active := _survey.analyzing_ids()
	for id: int in _grids.keys():
		if not active.has(id):
			_field.node_of(id).material_overlay = null
			_grids.erase(id)
	for id: int in active:
		if not _grids.has(id):
			var material := ShaderMaterial.new()
			material.shader = GRID_SHADER
			_grids[id] = material
			_field.node_of(id).material_overlay = material
		var entry := _survey.analysis(id)
		var fade := 1.0
		if entry.phase == Survey.Phase.UPLOADING:
			fade = clampf(entry.upload_left / (0.5 * _survey.upload_time), 0.0, 1.0)
		_grids[id].set_shader_parameter("progress", entry.progress)
		_grids[id].set_shader_parameter("fade", fade)


func _draw_overlay() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var view := _overlay.get_rect().grow(40.0)
	var font := ThemeDB.fallback_font
	for id: int in _field.ids():
		var entry := _survey.analysis(id)
		if entry.is_empty():
			continue # Only asteroids being analyzed or uploading show anything here.
		var top: Vector3 = _field.center(id) + Vector3.UP * (_field.radius(id) + MARKER_LIFT)
		if camera.is_position_behind(top):
			continue
		var at := camera.unproject_position(top)
		if not view.has_point(at):
			continue
		if entry.phase == Survey.Phase.ANALYZING:
			_overlay.draw_arc(at, PROGRESS_RADIUS, -PI / 2.0, -PI / 2.0 + TAU * entry.progress, 48, SCAN_COLOR, 2.0, true)
			_text(font, at + Vector2(PROGRESS_RADIUS + 4.0, 4.0), "%d%%" % floori(entry.progress * 100.0), SCAN_COLOR)
		else:
			_overlay.draw_arc(at, PROGRESS_RADIUS, 0.0, TAU, 48, UPLOAD_COLOR, 2.0, true)
			var label := "DATA UPLOADED"
			var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
			_text(font, at + Vector2(-width * 0.5, -PROGRESS_RADIUS - 6.0), label, UPLOAD_COLOR)



func _text(font: Font, at: Vector2, text: String, color: Color) -> void:
	_overlay.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, 3, OUTLINE_COLOR)
	_overlay.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, color)
