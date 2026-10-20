extends CanvasLayer
## Strategic zoom representation (node `TacticalMarkers`, added by the scene's combat
## layer, always processing; migrated from the combat prototype v0.4). Above `enter_zoom`
## (camera rig zoom distance) the ships' 3D models are hidden and every ship is drawn as a
## screen-space tactical marker; below `exit_zoom` the models return (hysteresis: no
## flicker around one threshold). Markers are the ships themselves (no second entity):
## picking (Selection) and commands use the same ship nodes, and selection is a set of
## ships, so it persists across the switch.
##
## Symbols (constant screen size), in the production marker language (ObjectMarkers):
##   category shape: combat ship triangle, logistics ship octagon;
##   faction: the faction tint, and a second outer outline on hostile markers;
##   combat ships: one bar inside, two for the Destroyer class (larger marker);
##   a tick from the centre along the ship's heading;
##   selected: corner brackets;  manual target of a selected ship: four crosshair ticks;
##   movement order of a selected ship: dashed line to its destination and a small ring;
##   destroyed (hulk): a small grey cross.
## Visibility (A5): the arena decides which hostile ships the player may see
## (`player_sees()`), and where lost contacts were last seen (`last_known()`); nothing else
## is drawn for hostile ships.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const ObjectMarkers := preload("res://game/presentation/object_markers.gd")
const SELECT_COLOR := Color(0.35, 0.9, 0.45)
const ORDER_COLOR := Color(0.85, 0.6, 0.25)
const TARGET_COLOR := Color(1.0, 0.85, 0.55)
const HULK_COLOR := Color(0.55, 0.55, 0.58)
const BASE_SIZE := 11.0 # px half-extent of a Gunship frame at 1080 lines

@export var enter_zoom := 65.0 # zoom distance above which markers replace the models
@export var exit_zoom := 55.0 # zoom distance below which the models return

var strategic := false
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


## Applies the zoom thresholds to the current camera zoom (idempotent; called by readers
## that process before this node, so model and effects switch in the same frame).
func refresh() -> void:
	var zoom: float = _arena.get_node("CameraRig").zoom_distance
	if not strategic and zoom > enter_zoom:
		strategic = true
	elif strategic and zoom < exit_zoom:
		strategic = false


func _process(_delta: float) -> void:
	refresh()
	for ship: Node3D in _arena.get_node("Ships").get_children():
		ship.visible = _arena.model_shown(ship)
	_canvas.queue_redraw()


## Screen scale of the markers (constant apparent size at any resolution).
func scale_factor() -> float:
	return maxf(0.75, _canvas.get_viewport_rect().size.y / 1080.0)


func half_size(ship: Node3D) -> float:
	var follower := ship.get_node_or_null("RouteFollower")
	var big: bool = follower != null and follower.ship_radius >= 5.0 # Destroyer class (Gunship ~3 u)
	return BASE_SIZE * scale_factor() * (1.35 if big else 1.0)


## The ship whose marker contains a screen point (strategic zoom only), or null. Only
## ships the player may see have a marker.
func marker_at(screen: Vector2) -> Node3D:
	if not strategic:
		return null
	var camera := get_viewport().get_camera_3d()
	var best: Node3D = null
	var best_distance := INF
	for ship: Node3D in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat == null or combat.removed_from_play or not _arena.player_sees(ship) or camera.is_position_behind(ship.global_position):
			continue
		var distance := camera.unproject_position(ship.global_position).distance_to(screen)
		if distance <= half_size(ship) * 1.6 and distance < best_distance:
			best = ship
			best_distance = distance
	return best


func _draw_markers() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	_arena.draw_contact_memory(_canvas, camera, 1.6 * scale_factor())
	if not strategic:
		return
	var selected: Array = _arena.selection().selected
	var targets := {}
	for ship: Node3D in selected:
		var combat = CombatShip.of(ship)
		if combat != null and combat.manual_target != null and is_instance_valid(combat.manual_target):
			targets[combat.manual_target] = true
	var width := 1.6 * scale_factor()
	# Movement orders of the selected ships first (under the markers).
	for ship: Node3D in selected:
		var locomotion = ship.get_node_or_null("Locomotion")
		if locomotion == null or not locomotion.has_destination or camera.is_position_behind(ship.global_position):
			continue
		var from := camera.unproject_position(ship.global_position)
		var to := camera.unproject_position(Vector3(locomotion.destination.x, 0.0, locomotion.destination.y))
		_canvas.draw_dashed_line(from, to, Color(ORDER_COLOR, 0.8), width, 6.0 * scale_factor())
		_canvas.draw_arc(to, 4.0 * scale_factor(), 0.0, TAU, 16, Color(ORDER_COLOR, 0.9), width)
	for ship: Node3D in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat == null or combat.removed_from_play or camera.is_position_behind(ship.global_position):
			continue
		if not _arena.player_sees(ship):
			continue
		var center := camera.unproject_position(ship.global_position)
		var h := half_size(ship)
		if not combat.alive:
			var c := Color(HULK_COLOR, 0.8)
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
		var line := Color(tint.lerp(Color.WHITE, 0.55), 0.95)
		_canvas.draw_colored_polygon(frame, Color(tint.darkened(0.45), 0.55))
		_canvas.draw_polyline(frame + PackedVector2Array([frame[0]]), line, width + 0.6)
		if combat.faction != _arena.PLAYER_FACTION:
			var outer := ObjectMarkers.shape_points(shape, center, size + 4.0 * scale_factor())
			_canvas.draw_polyline(outer + PackedVector2Array([outer[0]]), line, width)
		if shape == ObjectMarkers.Shape.TRIANGLE:
			var bars := 2 if h > BASE_SIZE * scale_factor() * 1.1 else 1
			for i in bars:
				var y := h * 0.18 + (float(i) - (bars - 1) * 0.5) * h * 0.3
				_canvas.draw_line(center + Vector2(-h * 0.38, y), center + Vector2(h * 0.38, y), Color(0.95, 0.95, 0.95, 0.9), width)
		var bow: Vector3 = ship.global_position - ship.global_basis.z * 4.0
		var direction := (camera.unproject_position(bow) - center).normalized()
		_canvas.draw_line(center + direction * h * 1.05, center + direction * h * 1.75, Color(0.95, 0.95, 0.95, 0.9), width)
		if selected.has(ship):
			_brackets(center, h * 1.45, Color(SELECT_COLOR, 0.95), width)
		if targets.has(ship):
			_crosshair(center, h, Color(TARGET_COLOR, 0.95), width)


func _brackets(center: Vector2, h: float, color: Color, width: float) -> void:
	var l := h * 0.45
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := center + Vector2(sx * h, sy * h)
			_canvas.draw_line(corner, corner - Vector2(sx * l, 0), color, width)
			_canvas.draw_line(corner, corner - Vector2(0, sy * l), color, width)


func _crosshair(center: Vector2, h: float, color: Color, width: float) -> void:
	for direction in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		_canvas.draw_line(center + direction * h * 1.55, center + direction * h * 2.2, color, width)
