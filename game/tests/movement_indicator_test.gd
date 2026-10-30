extends SceneTree
## Movement indicator (issue #3) on the startup scene, Combat Test: one selected FF-01 with
## a MOVE shows one indicator (one symbol) at zoom 5, 40 and 150, through the Strategic
## handoff and in Strategic View; it lies on the ground (circle foreshortened under the
## pitch, round top-down) with its width across the screen and its strokes at the style's
## physical px; the circle is anchored on the ordered destination; the line stops the
## world gap beyond the whole symbol (circle and arc); the shared style resource drives the
## production and preview renderers (a change is seen at once); a line too short for the
## symbol and gap is omitted with the symbol kept; a destination behind the camera is not
## drawn and a ship behind it has its line cut at the near plane; TacticalMarkers no
## longer draws a movement order. The scene runs in a 1920 x 1080 SubViewport (one canvas
## unit is one screen px; the headless window is 64 x 64). Rendering itself is not checked.
## Run from the project folder:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/movement_indicator_test.gd
## Every check is PASS/FAIL.

const COMBAT_TEST := preload("res://game/scenes/combat_test.tscn")
const INDICATOR := preload("res://game/presentation/movement_indicator/movement_indicator.tscn")
const PREVIEW := preload("res://game/presentation/movement_indicator/movement_indicator_preview.tscn")
const StrategicView := preload("res://game/presentation/strategic_view.gd")

var _failures := 0
var _checks := 0
var _scene: Node
var _indicator: Node
var _ship: Node3D
var _destination := Vector2(-120, 12)
var _view: SubViewport # The scene's screen.


func _initialize() -> void:
	_view = SubViewport.new()
	_view.size = Vector2i(1920, 1080)
	root.add_child(_view)
	await process_frame
	_scene = COMBAT_TEST.instantiate()
	_view.add_child(_scene)
	_scene.get_node("Ships/HostileFF01").process_mode = Node.PROCESS_MODE_DISABLED
	await physics_frame
	_indicator = _scene.get_node("MovementIndicator")
	_ship = _scene.ship("FF01")
	_scene.selection().set_selection([_ship])
	_check("the FF01's MOVE is given", _scene.issue_move([_ship], _destination))
	for i in 120: # The route is planned once the navigation map is ready.
		if _ship.get_node("Locomotion").has_destination:
			break
		await physics_frame
	_destination = _ship.get_node("Locomotion").destination
	_rig().global_position = Vector3(_destination.x, 0.0, _destination.y)
	for zoom in [5.0, 40.0, 150.0]:
		_rig().zoom_distance = zoom
		_rig()._apply_zoom()
		await process_frame
		_check_symbol("zoom %.0f" % zoom, false)
	_check("TacticalMarkers draws no movement order (no ORDER_COLOR)", not (load("res://game/presentation/tactical_markers.gd") as Script).get_script_constant_map().has("ORDER_COLOR"))
	_scene.strategic.enter()
	var one := true
	while _scene.strategic.progress < 1.0:
		await process_frame
		one = one and _indicator.layout().size() == 1
	await process_frame
	_check("Strategic handoff: one indicator in every frame", one)
	_check_symbol("Strategic View", true)
	_scene.strategic.exit()
	while _scene.strategic.state != StrategicView.State.TACTICAL:
		await process_frame
	await process_frame
	_check_style()
	_check_edges()
	_view.free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _rig() -> Node3D:
	return _scene.get_node("CameraRig")


# One symbol at the destination, style px sizes, the line beyond the symbol plus the gap.
func _check_symbol(view: String, strategic: bool) -> void:
	var camera := _view.get_camera_3d()
	var items: Array = _indicator.layout()
	_check("%s: one indicator for the one selected ship" % view, items.size() == 1 and items[0].entry.ship == _ship)
	if items.size() != 1:
		return
	var item: Dictionary = items[0]
	var style: Resource = _indicator.style
	var pixels: float = _indicator.pixel_scale()
	var width := _width(camera, item)
	var height := _height(item.circle)
	_check("%s: circle %.2f px across the screen, strokes %.2f / line %.2f px (style %.0f / %.0f / %.0f px, %.2f screen px per canvas unit)" % [view, width, item.stroke * pixels, item.width * pixels, style.marker_diameter_px, style.marker_stroke_px, style.line_width_px, pixels],
		pixels == 1.0 and absf(width - style.marker_diameter_px) < 0.02 * style.marker_diameter_px
		and is_equal_approx(item.stroke * pixels, style.marker_stroke_px) and is_equal_approx(item.width * pixels, style.line_width_px))
	var flat := absf(height / width - 1.0) < 0.03 if strategic else height / width < 0.95
	_check("%s: the circle lies on the ground (screen height / width %.2f: %s)" % [view, height / width, "round top-down" if strategic else "foreshortened"], flat)
	var anchor := camera.unproject_position(Vector3(_destination.x, 0.0, _destination.y))
	_check("%s: anchored on the ordered destination (%.3f px off)" % [view, item.anchor.distance_to(anchor)], item.anchor.distance_to(anchor) < 0.01)
	var line: Dictionary = item.lines[item.lines.size() - 1]
	var shown: bool = line.points.size() > 1
	var end: Vector2 = line.points[line.points.size() - 1] if shown else item.anchor
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(camera.project_ray_origin(end), camera.project_ray_normal(end))
	var world: Vector2 = Vector2(hit.x, hit.z) if hit != null else _destination
	var expected: float = item.silhouette + _scene.destination_gap_world
	var arc_gap := INF
	for point: Vector2 in item.arc:
		arc_gap = minf(arc_gap, point.distance_to(end))
	_check("%s: the line stops outside circle and arc (%.1f px from the arc stroke centre) and the world gap beyond them (%.3f u from the destination, expected %.3f)" % [view, arc_gap, world.distance_to(_destination), expected],
		shown and arc_gap > item.stroke * 0.5 and absf(world.distance_to(_destination) - expected) < 0.005 * expected)
	_check("%s: the arc faces the incoming line" % view, shown and item.direction.dot(_destination.direction_to(world)) > 0.99)
	if strategic:
		_check("Strategic View: only the route is drawn (full opacity)", item.lines.size() == 1 and is_equal_approx(line.alpha, 1.0))


# The circle's width across the screen (px) at the destination.
func _width(camera: Camera3D, item: Dictionary) -> float:
	var across: Vector2 = Vector2(camera.global_basis.x.x, camera.global_basis.x.z).normalized() * item.radius
	var d: Vector2 = item.destination
	return camera.unproject_position(Vector3(d.x + across.x, 0.0, d.y + across.y)).distance_to(camera.unproject_position(Vector3(d.x - across.x, 0.0, d.y - across.y))) * _indicator.pixel_scale()


# The circle's extent (px) perpendicular to its width: the screen axis along the camera's up.
func _height(points: PackedVector2Array) -> float:
	var low := INF
	var high := -INF
	for point in points:
		low = minf(low, point.y)
		high = maxf(high, point.y)
	return (high - low) * _indicator.pixel_scale()


# The shared style: one resource for the scenes and the preview; a change is seen at once.
func _check_style() -> void:
	var preview := PREVIEW.instantiate()
	var shared: bool = preview.get_node("View/Viewport/MovementIndicator").style == _indicator.style
	preview.free()
	_check("the preview and the gameplay scene use the same style resource", shared)
	var style: Resource = _indicator.style
	var saved := [style.marker_diameter_px, style.line_width_px, style.color]
	style.marker_diameter_px = 40.0
	style.line_width_px = 3.0
	var width := _width(_view.get_camera_3d(), _indicator.layout()[0])
	_check("a style change (marker 28 -> 40 px) is drawn at once (circle %.2f px across)" % width, absf(width - 40.0) < 0.8)
	style.marker_diameter_px = saved[0]
	style.line_width_px = saved[1]
	style.color = saved[2]


# A second renderer on the same camera: too-short lines, destinations and ships behind the camera.
func _check_edges() -> void:
	var extra := INDICATOR.instantiate()
	_scene.add_child(extra)
	var camera := _view.get_camera_3d()
	var centre := Vector2(_rig().global_position.x, _rig().global_position.z)
	extra.set_entries([{"from": centre + Vector2(0.3, 0.0), "destination": centre}])
	var item: Dictionary = extra.layout()[0] if extra.layout().size() == 1 else {}
	_check("a line shorter than the symbol and gap is omitted, the symbol stays", not item.is_empty() and item.lines[0].points.is_empty())
	var back := -camera.global_basis.z
	var behind := Vector2(camera.global_position.x, camera.global_position.z) - Vector2(back.x, back.z).normalized() * (camera.global_position.y * 5.0 + 50.0)
	extra.set_entries([{"from": centre, "destination": behind}])
	_check("a destination behind the camera is not drawn", extra.layout().is_empty())
	extra.set_entries([{"from": behind, "destination": centre}])
	var cut: Array = extra.layout()[0].lines[0].points if extra.layout().size() == 1 else []
	_check("a ship behind the camera: its line is cut at the near plane (%d points)" % cut.size(), cut.size() == 2)
	extra.free()


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-150s %s" % [label, "PASS" if ok else "FAIL"])
