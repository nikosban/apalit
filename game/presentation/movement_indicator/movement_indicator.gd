@tool
extends CanvasLayer
## Movement indicator (movement_indicator.tscn, node `MovementIndicator`): the single
## renderer of the selected ships' movement orders, instanced once per gameplay scene and
## by the preview (movement_indicator_preview.tscn). Display only: the owner (the scene's
## movement_lab.gd, or the preview) supplies plain data every frame with set_entries();
## nothing here reads or changes gameplay.
##
## Per entry, drawn over the 3D view and under the UI panels (layer 0; the Control
## ignores the mouse): one line from the ship towards the destination, the destination
## circle and a detached arc beside it on the incoming line's side. Everything lies flat
## on the ground plane (Y 0) and is projected through the current camera, so the circle
## and arc show in perspective and turn with the camera like world geometry. Sizes come
## from the shared `style` in physical screen px, at every zoom and window size: each
## frame the symbol's world size is chosen so its width across the screen at the
## destination is the style's px (its height foreshortens with the pitch); strokes are
## constant px. Lines (and the connector to a requested point the destination was moved
## from) stop `destination_gap_world` world units beyond the whole symbol (circle and
## arc); a line that does not clear it is omitted and the symbol stays. With a route
## (Strategic View) the straight line cross-fades into the route polyline by
## `route_blend`, the arc turning with it, so there is only ever one symbol.

const CIRCLE_POINTS := 48
const ARC_POINTS := 24
const NEAR_MARGIN := 0.001 # A line point behind the camera is moved this far in front of its near plane.

## The shared look (movement_indicator_style.gd); edit movement_indicator_style.tres.
@export var style: Resource = preload("res://game/presentation/movement_indicator/movement_indicator_style.tres"):
	set(value):
		if style != null and style.changed.is_connected(redraw):
			style.changed.disconnect(redraw)
		style = value
		if style != null:
			style.changed.connect(redraw)
		redraw()

## World distance (u) between the symbol's outer edge and the end of the lines. Set by the
## owner (the scene's `destination_gap_world`); never a pixel minimum.
var destination_gap_world := 0.25

var _entries: Array = []
var _route_blend := 0.0

@onready var _canvas: Control = $Canvas


func _ready() -> void:
	_canvas.draw.connect(_draw_indicators)


## The orders to show: [{from, destination, requested (optional), route (optional)}], world
## X/Z points. `requested`: where the order asked for when the destination was moved from
## it (connector). `route`: the planned route from the ship to the destination.
## `route_blend`: 0 the straight line, 1 the route, cross-faded in between. Other keys
## (the scenes pass `ship`) are kept, unread.
func set_entries(entries: Array, route_blend := 0.0) -> void:
	_entries = entries
	_route_blend = clampf(route_blend, 0.0, 1.0)
	redraw()


## The entries last set (tests).
func entries() -> Array:
	return _entries


func redraw() -> void:
	if _canvas != null:
		_canvas.queue_redraw()


## Physical screen px per canvas unit (the window's stretch and, in the preview, its
## SubViewport): style px divided by this are canvas units.
func pixel_scale() -> float:
	return maxf(get_viewport().get_screen_transform().get_scale().x, 0.0001)


## What is drawn now, per entry whose destination is in front of the camera: {entry (as
## set), destination, direction (world unit vector towards the incoming line), radius,
## arc_center, arc_radius, silhouette (outer radius of circle and arc), clearance
## (silhouette + gap): world X/Z and u; anchor, circle and arc (points), stroke, width
## (line), lines [{points, alpha}], connector (points, empty when none): canvas units}.
func layout() -> Array:
	var result := []
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null or style == null:
		return result
	var pixels: float = pixel_scale()
	var stroke: float = style.marker_stroke_px / pixels
	var width: float = style.line_width_px / pixels
	var half_sweep: float = deg_to_rad(style.arc_sweep_degrees) * 0.5
	var across := Vector2(camera.global_basis.x.x, camera.global_basis.x.z).normalized() # Screen-across on the ground.
	for entry: Dictionary in _entries:
		var destination: Vector2 = entry.destination
		if camera.is_position_behind(_ground(destination)):
			continue
		var anchor := camera.unproject_position(_ground(destination))
		# World u per physical px at the destination, across the screen.
		var span := camera.unproject_position(_ground(destination + across)).distance_to(camera.unproject_position(_ground(destination - across)))
		var unit: float = 2.0 / maxf(span * pixels, 0.0001)
		var radius: float = style.marker_diameter_px * 0.5 * unit
		var arc_radius: float = style.arc_size_px * 0.5 * unit
		var apex: float = radius + (style.marker_stroke_px + style.arc_offset_px) * unit # Arc stroke centre on the incoming side.
		var arc_end: float = Vector2(apex - arc_radius + arc_radius * cos(half_sweep), arc_radius * sin(half_sweep)).length()
		var silhouette: float = maxf(radius, maxf(apex, arc_end)) + style.marker_stroke_px * 0.5 * unit
		var clearance: float = silhouette + destination_gap_world
		var straight := PackedVector2Array([entry.from, destination])
		var route: PackedVector2Array = entry.get("route", PackedVector2Array())
		var blend := _route_blend if route.size() > 2 else 0.0 # A direct route is the straight line.
		var direction := _direction(straight)
		var lines := []
		if blend < 1.0:
			lines.append({"points": _clip(camera, straight, clearance), "alpha": 1.0 - blend})
		if blend > 0.0:
			direction = direction.slerp(_direction(route), blend)
			lines.append({"points": _clip(camera, route, clearance), "alpha": blend})
		var connector := PackedVector2Array()
		if entry.has("requested"):
			connector = _clip(camera, PackedVector2Array([entry.requested, destination]), clearance)
		var arc_center := destination + direction * (apex - arc_radius)
		result.append({"entry": entry, "destination": destination, "direction": direction, "radius": radius,
			"arc_center": arc_center, "arc_radius": arc_radius, "silhouette": silhouette, "clearance": clearance,
			"anchor": anchor, "stroke": stroke, "width": width,
			"circle": _ring(camera, destination, radius, 0.0, TAU, CIRCLE_POINTS),
			"arc": _ring(camera, arc_center, arc_radius, direction.angle() - half_sweep, direction.angle() + half_sweep, ARC_POINTS),
			"lines": lines, "connector": connector})
	return result


func _draw_indicators() -> void:
	if style == null:
		return
	var items := layout()
	for item: Dictionary in items: # Lines under every symbol.
		for line: Dictionary in item.lines:
			if line.points.size() > 1:
				_canvas.draw_polyline(line.points, Color(style.color, style.color.a * line.alpha), item.width, true)
		if item.connector.size() > 1:
			_canvas.draw_polyline(item.connector, style.color, item.width, true)
	for item: Dictionary in items:
		_canvas.draw_polyline(item.circle, style.color, item.stroke, true)
		_canvas.draw_polyline(item.arc, style.color, item.stroke, true)


func _ground(point: Vector2) -> Vector3:
	return Vector3(point.x, 0.0, point.y)


# A circle or arc on the ground (world centre and radius, angles in the X/Z plane) on screen.
func _ring(camera: Camera3D, center: Vector2, radius: float, from: float, to: float, count: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in count + 1:
		var angle := lerpf(from, to, float(i) / count)
		points.append(camera.unproject_position(_ground(center + Vector2(cos(angle), sin(angle)) * radius)))
	return points


# World direction from the destination towards the line arriving at it (world points
# ending at the destination); -X when there is no segment.
func _direction(points: PackedVector2Array) -> Vector2:
	var end := points[points.size() - 1]
	for i in range(points.size() - 2, -1, -1):
		if end.distance_to(points[i]) > 0.0001:
			return end.direction_to(points[i])
	return Vector2.LEFT


# A polyline (world points ending at the destination) on screen without its part within
# `clearance` (u) of the destination. Empty when nothing clears it; a part behind the
# camera is cut at its near plane.
func _clip(camera: Camera3D, points: PackedVector2Array, clearance: float) -> PackedVector2Array:
	var count := points.size()
	var end := points[count - 1]
	var kept := PackedVector2Array()
	for i in range(count - 2, -1, -1):
		if points[i].distance_to(end) > clearance:
			# Where segment i -> i + 1 enters the clearance circle around the destination.
			var from := points[i]
			var direction := from.direction_to(points[i + 1])
			var offset := from - end
			var b := offset.dot(direction)
			var t := -b - sqrt(maxf(b * b - offset.length_squared() + clearance * clearance, 0.0))
			kept = points.slice(0, i + 1)
			kept.append(from + direction * t)
			break
	# On screen from the clipped end back towards the ship, cut where it goes behind the camera.
	var result := PackedVector2Array()
	var forward := -camera.global_transform.basis.z
	var origin := camera.global_transform.origin
	var near := camera.near + NEAR_MARGIN
	for i in range(kept.size() - 1, -1, -1):
		var point := _ground(kept[i])
		var depth := forward.dot(point - origin)
		if depth < near:
			if not result.is_empty():
				var previous := _ground(kept[i + 1])
				var previous_depth := forward.dot(previous - origin)
				result.append(camera.unproject_position(previous.lerp(point, (previous_depth - near) / (previous_depth - depth))))
			break
		result.append(camera.unproject_position(point))
	result.reverse()
	return result if result.size() > 1 else PackedVector2Array()
