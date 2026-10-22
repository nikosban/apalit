extends CanvasLayer
## Tactical presentation of the Local / Tactical camera (node `TacticalMarkers`, added by
## the scene's combat layer, always processing; migrated from the combat prototype v0.4).
## Phase B: one continuous value, `emphasis()` (0 Local, 1 Tactical), derived from the
## camera rig's zoom_level() with a smoothstep between `emphasis_start_distance` and
## `emphasis_end_distance` (camera zoom distances). The 3D models stay visible at every
## zoom; the screen-space tactical markers fade in over them with the emphasis, and the
## other presentation systems (selection ring, hull bars, object markers, grid) read the
## same value. Markers are the ships themselves (no second entity): picking (Selection)
## and commands use the same ship nodes, and selection is a set of ships, so zooming
## never changes it. A ship's marker takes clicks only while its opacity (the emphasis)
## is at least `interactive_emphasis`; below it the hull pick is the only ship pick.
##
## Symbols (constant screen size), in the production marker language (ObjectMarkers):
##   category shape: combat ship triangle, logistics ship octagon;
##   faction: the faction tint, and a second outer outline on hostile markers;
##   combat ships: one bar inside, two for the Destroyer class (larger marker);
##   selected: corner brackets;  manual target of a selected ship: four crosshair ticks;
##   movement order of a selected ship: dashed line to its destination and a small ring;
##   destroyed (hulk): a small grey cross;
##   station (B2): a pale square with a centre dot, never in a faction tint (stations
##   have no faction yet);
##   asteroid (B2): one small, quiet diamond per individual asteroid, in the survey's
##   colour (SurveyView.marker_of(): grey not scanned, amber minerals, blue ice).
## Stations and asteroids keep their own picking (ray against their models; the station
## marker lies inside the station's projected body at every zoom), so their markers are
## presentation only. An object that is hovered or selected (WorldHighlight) is marked by
## ObjectMarkers instead, so it is never drawn twice. Off-screen objects are not drawn.
## Phase C: in Strategic View (the scene's `strategic`), whose asteroid clusters and order
## lines replace them, the asteroid diamonds and the straight order lines fade out with
## its handoff progress.
## Visibility (A5): the arena decides which hostile ships the player may see
## (`player_sees()`), and where lost contacts were last seen (`last_known()`); nothing else
## is drawn for hostile ships. Lost-contact memory is drawn at every zoom.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const CameraRig := preload("res://game/camera/camera_rig.gd")
const ObjectMarkers := preload("res://game/presentation/object_markers.gd")
const SurveyView := preload("res://game/survey/survey_view.gd")
const SELECT_COLOR := Color(0.35, 0.9, 0.45)
const ORDER_COLOR := Color(0.85, 0.6, 0.25)
const TARGET_COLOR := Color(1.0, 0.85, 0.55)
const HULK_COLOR := Color(0.55, 0.55, 0.58)
# Sector Showcase round: the canvas is 1080 lines tall (project base size), so these are
# real px at 1080p; smaller, finer and less filled than before, so hulls show through.
const BASE_SIZE := 6.5 # px half-extent of a Gunship frame at 1080 lines
const STATION_SIZE := 6.0 # px centre to corner of a station square at 1080 lines
const STATION_COLOR := Color(0.78, 0.8, 0.84)
const ASTEROID_SIZE := 2.5 # px centre to corner of an asteroid diamond at 1080 lines
const LINE_WIDTH := 1.0 # px stroke at 1080 lines
const FILL_ALPHA := 0.15 # marker fills stay light: the model under them stays visible
const ASTEROID_ALPHA := 0.6 # asteroid markers stay quieter than ships and stations

@export var emphasis_start_distance := 30.0 # zoom distance where the Tactical emphasis starts (0)
@export var emphasis_end_distance := 100.0 # zoom distance where it is complete (1)
@export var interactive_emphasis := 0.5 # marker opacity from which a marker takes clicks
## Independent scales (Sector Showcase round): `marker_scale` sizes the drawn markers only;
## `hit_radius` is the click radius around a ship marker's centre (px at 1080 lines), never
## smaller than the drawn marker, so smaller artwork keeps a comfortable target.
@export var marker_scale := 1.0
@export var hit_radius := 14.0

var _canvas: Control

@onready var _arena := get_parent()


func _ready() -> void:
	layer = 0
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_markers)
	add_child(_canvas)


## Tactical emphasis now, 0 (Local) to 1 (Tactical): continuous in the rendered zoom, so
## it follows the camera while the zoom is still interpolating.
func emphasis() -> float:
	return emphasis_at(_arena.get_node("CameraRig").zoom_level(), level_of(emphasis_start_distance), level_of(emphasis_end_distance))


## Smoothstep of a zoom level (CameraRig.zoom_level()) between two levels.
static func emphasis_at(level: float, start_level: float, end_level: float) -> float:
	return smoothstep(start_level, end_level, level)


## CameraRig.zoom_level() for a zoom distance (its log scale on its reference range).
static func level_of(distance: float) -> float:
	var low := CameraRig.REFERENCE_MIN_ZOOM
	var high := CameraRig.REFERENCE_MAX_ZOOM
	return log(clampf(distance, low, high) / low) / log(high / low)


func _process(_delta: float) -> void:
	for ship: Node3D in _arena.get_node("Ships").get_children():
		ship.visible = _arena.model_shown(ship)
	_canvas.queue_redraw()


## Screen scale of the markers (constant apparent size at any resolution), times
## `marker_scale`.
func scale_factor() -> float:
	return maxf(0.75, _canvas.get_viewport_rect().size.y / 1080.0) * marker_scale


## Click radius around a ship marker's centre (canvas units): `hit_radius`, or the drawn
## marker when that is larger.
func hit_size(ship: Node3D) -> float:
	return maxf(hit_radius * maxf(0.75, _canvas.get_viewport_rect().size.y / 1080.0), half_size(ship) * 1.6)


func half_size(ship: Node3D) -> float:
	var follower := ship.get_node_or_null("RouteFollower")
	var big: bool = follower != null and follower.ship_radius >= 5.0 # Destroyer class (Gunship ~3 u)
	return BASE_SIZE * scale_factor() * (1.35 if big else 1.0)


## The ship whose marker contains a screen point, or null: only while the markers are
## interactive (emphasis at least `interactive_emphasis`), and only ships the player may
## see have a marker. Overlapping markers: the marker centre nearest the point wins; at
## equal distance the earlier ship under Ships.
func marker_at(screen: Vector2) -> Node3D:
	if emphasis() < interactive_emphasis:
		return null
	var camera := get_viewport().get_camera_3d()
	var best: Node3D = null
	var best_distance := INF
	for ship: Node3D in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat == null or combat.removed_from_play or not _arena.player_sees(ship) or camera.is_position_behind(ship.global_position):
			continue
		var distance := camera.unproject_position(ship.global_position).distance_to(screen)
		if distance <= hit_size(ship) and distance < best_distance:
			best = ship
			best_distance = distance
	return best


func _draw_markers() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	_arena.draw_contact_memory(_canvas, camera, LINE_WIDTH * scale_factor())
	var alpha := emphasis() # Markers fade in with the Tactical emphasis.
	if alpha <= 0.0:
		return
	var strategic = _arena.get("strategic")
	var handoff: float = strategic.progress if strategic != null else 0.0
	_draw_objects(alpha, alpha * (1.0 - handoff)) # Under the ship markers.
	var view := _canvas.get_viewport_rect().grow(BASE_SIZE * 4.0 * scale_factor())
	var selected: Array = _arena.selection().selected
	var targets := {}
	for ship: Node3D in selected:
		var combat = CombatShip.of(ship)
		if combat != null and combat.manual_target != null and is_instance_valid(combat.manual_target):
			targets[combat.manual_target] = true
	var width := LINE_WIDTH * scale_factor()
	# Movement orders of the selected ships first (under the markers).
	for ship: Node3D in selected:
		var locomotion = ship.get_node_or_null("Locomotion")
		if locomotion == null or not locomotion.has_destination or camera.is_position_behind(ship.global_position):
			continue
		var from := camera.unproject_position(ship.global_position)
		var to := camera.unproject_position(Vector3(locomotion.destination.x, 0.0, locomotion.destination.y))
		_canvas.draw_dashed_line(from, to, Color(ORDER_COLOR, 0.8 * alpha * (1.0 - handoff)), width, 6.0 * scale_factor())
		_canvas.draw_arc(to, 4.0 * scale_factor(), 0.0, TAU, 16, Color(ORDER_COLOR, 0.9 * alpha * (1.0 - handoff)), width)
	for ship: Node3D in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat == null or combat.removed_from_play or camera.is_position_behind(ship.global_position):
			continue
		if not _arena.player_sees(ship):
			continue
		var center := camera.unproject_position(ship.global_position)
		if not view.has_point(center):
			continue # Off screen: nothing to draw.
		var h := half_size(ship)
		if not combat.alive:
			var c := Color(HULK_COLOR, 0.8 * alpha)
			_canvas.draw_line(center + Vector2(-h, -h) * 0.6, center + Vector2(h, h) * 0.6, c, width)
			_canvas.draw_line(center + Vector2(-h, h) * 0.6, center + Vector2(h, -h) * 0.6, c, width)
			continue
		# The production category shape (ObjectMarkers: triangle combat ship, octagon
		# logistics ship) in the faction's tint; a hostile marker also has an outer outline,
		# so faction does not rest on colour alone. Armed and unarmed combat ships carry
		# their class bars (one, two for the Destroyer class).
		var tint: Color = CombatShip.FACTION_COLORS[combat.faction]
		var shape: int = ObjectMarkers.ship_shape(ship)
		var size := h * (1.45 if shape == ObjectMarkers.Shape.TRIANGLE else 1.2)
		var frame := ObjectMarkers.shape_points(shape, center, size)
		var line := Color(tint.lerp(Color.WHITE, 0.55), 0.95 * alpha)
		_canvas.draw_colored_polygon(frame, Color(tint.darkened(0.45), FILL_ALPHA * alpha))
		_canvas.draw_polyline(frame + PackedVector2Array([frame[0]]), line, width + 0.3 * scale_factor(), true)
		if combat.faction != _arena.PLAYER_FACTION:
			var outer := ObjectMarkers.shape_points(shape, center, size + 2.5 * scale_factor())
			_canvas.draw_polyline(outer + PackedVector2Array([outer[0]]), line, width)
		if shape == ObjectMarkers.Shape.TRIANGLE:
			var bars := 2 if h > BASE_SIZE * scale_factor() * 1.1 else 1
			for i in bars:
				var y := h * 0.18 + (float(i) - (bars - 1) * 0.5) * h * 0.3
				_canvas.draw_line(center + Vector2(-h * 0.38, y), center + Vector2(h * 0.38, y), Color(0.95, 0.95, 0.95, 0.9 * alpha), width)
		if selected.has(ship):
			_brackets(center, h * 1.75, Color(SELECT_COLOR, 0.95 * alpha), width)
		if targets.has(ship):
			_crosshair(center, h, Color(TARGET_COLOR, 0.95 * alpha), width)


## The station and asteroid markers to draw now: {target, asteroid (id, or -1 for a
## station), position (screen), color}: the asteroids in ascending id order, then the
## stations (drawn in this order, stations over asteroids); only objects shown, in front
## of the camera and on screen, and none for an object ObjectMarkers marks (hovered or
## selected: WorldHighlight). Built from the live nodes every call, so a removed object
## has no entry.
func object_entries() -> Array:
	var result := []
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return result
	var view := _canvas.get_viewport_rect().grow(BASE_SIZE * 4.0 * scale_factor())
	var highlight := _arena.get_node_or_null("WorldHighlight")
	var marked: Dictionary = highlight.highlighted() if highlight != null else {}
	var field := _arena.get_node_or_null("Asteroids")
	if field != null and field.has_method("ids") and field.is_visible_in_tree():
		var survey_view := _arena.get_node_or_null("SurveyView")
		for id: int in field.ids():
			var asteroid: Node3D = field.node_of(id) # Asteroids are direct children of the field.
			if not asteroid.visible or marked.has(asteroid) or camera.is_position_behind(asteroid.global_position):
				continue
			var center := camera.unproject_position(asteroid.global_position)
			if view.has_point(center):
				var color: Color = ObjectMarkers.SURVEY_COLORS[survey_view.marker_of(id)] if survey_view != null else SurveyView.UNKNOWN_COLOR
				result.append({"target": asteroid, "asteroid": id, "position": center, "color": color})
	var stations := _arena.get_node_or_null("Stations")
	if stations != null:
		for station: Node3D in stations.get_children():
			if station.is_visible_in_tree() and not marked.has(station) and not camera.is_position_behind(station.global_position):
				var center := camera.unproject_position(station.global_position)
				if view.has_point(center):
					result.append({"target": station, "asteroid": -1, "position": center, "color": STATION_COLOR})
	return result


# Asteroids: one small quiet diamond each, all in one batched triangle array (one canvas
# command however many asteroids); stations: a square with a centre dot.
func _draw_objects(alpha: float, asteroid_alpha: float) -> void:
	var width := LINE_WIDTH * scale_factor()
	var size := ASTEROID_SIZE * scale_factor()
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var faded := {} # survey colour -> its four vertex colours at the asteroid alpha
	for entry: Dictionary in object_entries():
		var color: Color = entry.color
		var at: Vector2 = entry.position
		if entry.asteroid >= 0:
			if asteroid_alpha <= 0.0:
				continue
			var first := points.size()
			points.append_array([at + Vector2(size, 0), at + Vector2(0, size), at + Vector2(-size, 0), at + Vector2(0, -size)])
			if not faded.has(color):
				var c := Color(color, ASTEROID_ALPHA * asteroid_alpha)
				faded[color] = PackedColorArray([c, c, c, c])
			colors.append_array(faded[color])
			indices.append_array([first, first + 1, first + 2, first, first + 2, first + 3])
			continue
		if not indices.is_empty(): # Asteroids first (they come first): under the stations.
			RenderingServer.canvas_item_add_triangle_array(_canvas.get_canvas_item(), indices, points, colors)
			indices.clear()
		var frame := ObjectMarkers.shape_points(ObjectMarkers.Shape.SQUARE, at, STATION_SIZE * scale_factor())
		_canvas.draw_colored_polygon(frame, Color(color.darkened(0.6), FILL_ALPHA * alpha))
		_canvas.draw_polyline(frame + PackedVector2Array([frame[0]]), Color(color, 0.95 * alpha), width + 0.3 * scale_factor(), true)
		_canvas.draw_circle(at, width, Color(color, 0.95 * alpha))
	if not indices.is_empty():
		RenderingServer.canvas_item_add_triangle_array(_canvas.get_canvas_item(), indices, points, colors)


func _brackets(center: Vector2, h: float, color: Color, width: float) -> void:
	var l := h * 0.3
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := center + Vector2(sx * h, sy * h)
			_canvas.draw_line(corner, corner - Vector2(sx * l, 0), color, width)
			_canvas.draw_line(corner, corner - Vector2(0, sy * l), color, width)


func _crosshair(center: Vector2, h: float, color: Color, width: float) -> void:
	for direction in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		_canvas.draw_line(center + direction * h * 1.55, center + direction * h * 2.2, color, width)
