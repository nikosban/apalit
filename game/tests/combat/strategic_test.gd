extends SceneTree
## Combat prototype v0.4 (A4): strategic zoom, tactical markers and the tactical grid on
## E05, through real wheel, click and key input. Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/strategic_test.gd

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const TacticalGrid := preload("res://game/presentation/tactical_grid.gd")

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _load()
	await _case_zoom()
	await _case_thrusters()
	await _case_markers()
	await _case_grid()
	if scene != null:
		root.remove_child(scene)
		scene.free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _load() -> void:
	scene = E05.instantiate()
	scene.scenario_index = 4
	var sensors := scene.get_node("Sensors") # A3 / A4 checks without the fog of war (fog_test covers it)
	scene.remove_child(sensors)
	sensors.free()
	root.add_child(scene)
	scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
	scene.enemy_controller._steps.clear()
	for ship: Node in scene.get_node("Ships").get_children():
		CombatShip.of(ship).stance = CombatShip.Stance.HOLD_FIRE
	await physics_frame
	while not scene.enemy_controller.started:
		await physics_frame


func _rig() -> Node3D:
	return scene.get_node("CameraRig")


func _camera() -> Camera3D:
	return scene.get_viewport().get_camera_3d()


func _wheel(up: bool, times: int) -> void:
	for i in times:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
		event.pressed = true
		event.position = scene.get_viewport().get_visible_rect().size * 0.5
		root.push_input(event, true)
		await process_frame


func _click(position: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT, shift: bool = false) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = position
		event.global_position = position
		event.shift_pressed = shift
		root.push_input(event, true)
	await process_frame


func _screen(point: Vector3) -> Vector2:
	return _camera().unproject_position(point)


func _set_zoom(zoom: float) -> void:
	_rig().zoom_distance = zoom
	_rig()._apply_zoom()
	await process_frame


## The ground area seen on screen: [corner ground points (null where a ray misses), area].
func _footprint() -> Array:
	var size := scene.get_viewport().get_visible_rect().size
	var points := []
	for f in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
		var screen: Vector2 = size * f
		points.append(Plane(Vector3.UP, 0.0).intersects_ray(_camera().project_ray_origin(screen), _camera().project_ray_normal(screen)))
	if points.has(null):
		return [points, 0.0]
	var area := 0.0
	for i in 4:
		var a: Vector3 = points[i]
		var b: Vector3 = points[(i + 1) % 4]
		area += a.x * b.z - b.x * a.z
	return [points, absf(area) * 0.5]


## Zoom range and the model / marker switch with hysteresis. Phase A (continuous zoom):
## the wheel sets the target at once and the rendered zoom follows it smoothly; at the
## maximum the camera is at its Tactical pitch. Tactical view inspects a region of the
## battlefield; seeing the whole battlefield is the later Global view's requirement (the
## former check that all four E05 corners are on screen at zoom 150 no longer applies).
func _case_zoom() -> void:
	print("\n=== S1 zoom range, Tactical camera and representation switch")
	root.size = Vector2i(1920, 1080) # the headless window is square; judge at 16:9
	await process_frame
	_rig().global_position = Vector3.ZERO
	_rig().rotation = Vector3.ZERO
	await _set_zoom(40.0)
	var close_area: float = _footprint()[1]
	await _wheel(false, 30)
	var target: float = _rig().zoom_target
	var frames := 0
	while absf(_rig().zoom_distance - target) > 0.01 and frames < 120:
		await process_frame
		frames += 1
	var reached: float = _rig().zoom_distance
	_check("the wheel takes the requested zoom to the strategic maximum and no further (target %.1f); the rendered zoom converges on it %d frames later (%.3f)" % [target, frames, reached],
		is_equal_approx(target, 150.0) and absf(reached - 150.0) <= 0.01 and frames < 120)
	var pitch := -rad_to_deg(_camera().rotation.x)
	var pivot := _rig().global_position
	var bounds: Rect2 = _rig().bounds
	var view := _footprint()
	var centre: Variant = Plane(Vector3.UP, 0.0).intersects_ray(_camera().project_ray_origin(scene.get_viewport().get_visible_rect().size * 0.5), _camera().project_ray_normal(scene.get_viewport().get_visible_rect().size * 0.5))
	var finite: bool = _camera().global_position.is_finite() and centre != null and not view[0].has(null) and view[0].all(func(p: Vector3) -> bool: return p.is_finite())
	_check("at the maximum: Tactical pitch %.2f° (configured %.1f°), pivot %s inside the bounds, camera and the ground under the screen centre and corners finite" % [pitch, _rig().tactical_pitch_degrees, pivot],
		absf(pitch - _rig().tactical_pitch_degrees) < 0.01 and bounds.has_point(Vector2(pivot.x, pivot.z)) and finite and (centre as Vector3).distance_to(pivot) < 0.01)
	_check("Tactical view inspects a wider region than zoom 40 (ground on screen %.0f u² vs %.0f u²)" % [view[1], close_area], view[1] > close_area * 2.0)
	var gunship: Node3D = scene.ship("Gunship")
	var picked: Node3D = scene.selection().pick_any(_screen(gunship.global_position))
	scene.selection().set_selection([gunship])
	var at: Vector2 = scene.get_viewport().get_visible_rect().size * Vector2(0.3, 0.6)
	var ground: Vector3 = Plane(Vector3.UP, 0.0).intersects_ray(_camera().project_ray_origin(at), _camera().project_ray_normal(at))
	var command: Dictionary = scene.resolve_command(at)
	scene.selection().set_selection([])
	_check("interaction at the maximum: the Gunship's marker is picked under it; a right-click resolves to a MOVE at the ground point under the cursor (%s)" % str(command.get("point")),
		scene.markers.strategic and picked == gunship and command.get("kind") == scene.CommandKind.MOVE and (command.point as Vector2).distance_to(Vector2(ground.x, ground.z)) < 0.01)
	var markers = scene.markers
	var ship: Node3D = scene.ship("Destroyer")
	var states := []
	for zoom in [40.0, 60.0, 66.0, 60.0, 56.0, 54.0, 40.0]:
		await _set_zoom(zoom)
		await process_frame
		states.append([zoom, markers.strategic, ship.visible])
	print("  [zoom, markers, model visible]: " + str(states))
	var expected := [false, false, true, true, true, false, false]
	var ok := true
	for i in states.size():
		ok = ok and states[i][1] == expected[i] and states[i][2] == not expected[i]
	_check("markers above zoom 65, models again only below 55 (hysteresis); never both: a model is hidden exactly while markers show", ok)


## Propulsion effects follow the model: none at strategic zoom, back at tactical zoom.
func _case_thrusters() -> void:
	print("\n=== S1b propulsion effects and the representation switch")
	var view: Node = scene.get_node("ThrusterView")
	var ships: Array = scene.get_node("Ships").get_children()
	scene.orders.move([scene.ship("Destroyer")], Vector2(-20, 30))
	scene.orders.move([scene.ship("Gunship")], Vector2(-30, -30))
	_rig().global_position = Vector3.ZERO
	await _set_zoom(150.0)
	for i in 30:
		await physics_frame
	await process_frame
	await process_frame
	var lit_far := ships.filter(func(s: Node3D) -> bool: return view.plume_of(s) != null and view.plume_of(s).visible).size()
	var jets_far: int = view._jets_mesh.get_surface_count()
	await _set_zoom(40.0)
	await process_frame
	var lit_close := ships.filter(func(s: Node3D) -> bool: return view.plume_of(s) != null and view.plume_of(s).visible).size()
	_check("zoom 150 (markers) with ships under thrust: %d plumes shown, %d jet surfaces; zoom 40: %d plumes shown again" % [lit_far, jets_far, lit_close],
		lit_far == 0 and jets_far == 0 and lit_close > 0)


## Selection, orders and targeting through the markers; markers follow the real ships.
func _case_markers() -> void:
	print("\n=== S2 marker interaction")
	var ships := scene.get_node("Ships")
	var count := ships.get_child_count()
	var destroyer: Node3D = scene.ship("Destroyer")
	var gunship: Node3D = scene.ship("Gunship")
	var hostile: Node3D = scene.ship("HostileDestroyer")
	_rig().global_position = Vector3.ZERO
	await _set_zoom(40.0)
	_rig().global_position = Vector3(destroyer.global_position.x, 0, destroyer.global_position.z)
	await process_frame
	await _click(_screen(destroyer.global_position))
	var before: Array = scene.selection().selected.duplicate()
	_rig().global_position = Vector3.ZERO
	await _set_zoom(150.0)
	await process_frame
	_check("a ship selected with models stays selected after switching to markers", scene.markers.strategic and scene.selection().selected == before and before == [destroyer])
	await _click(_screen(gunship.global_position))
	var one: bool = scene.selection().selected == [gunship]
	await _click(_screen(destroyer.global_position), MOUSE_BUTTON_LEFT, true)
	var two: bool = scene.selection().selected.size() == 2
	_check("markers: a click selects the Gunship, Shift-click adds the Destroyer", one and two)
	var plans := [gunship.get_node("RouteFollower").plans, destroyer.get_node("RouteFollower").plans]
	var history: int = scene.orders.history.size()
	var goal := Vector3(-40, 0, 40)
	await _click(_screen(goal), MOUSE_BUTTON_RIGHT)
	var planned := [gunship.get_node("RouteFollower").plans - plans[0], destroyer.get_node("RouteFollower").plans - plans[1]]
	_check("markers: a right-click on the ground gives the group MOVE once (route plans per ship %s)" % str(planned),
		planned == [1, 1] and gunship.get_node("Locomotion").has_destination and destroyer.get_node("Locomotion").has_destination)
	await _click(_screen(hostile.global_position), MOUSE_BUTTON_RIGHT)
	_check("markers: a right-click on the hostile Destroyer's marker assigns it to both selected ships",
		CombatShip.of(gunship).manual_target == hostile and CombatShip.of(destroyer).manual_target == hostile)
	await _click(_screen(gunship.global_position))
	scene.begin_target_selection()
	await _click(_screen(scene.ship("HostileGunship").global_position))
	_check("markers: target selection and a click on a hostile marker assign it", CombatShip.of(gunship).manual_target == scene.ship("HostileGunship") and not scene.target_selection)
	for i in 240:
		await physics_frame
	await process_frame
	var follows := true
	for ship: Node3D in ships.get_children():
		if scene.markers.marker_at(_screen(ship.global_position)) != ship:
			follows = false
	_check("after 4 s of movement every marker is at its ship (marker_at(ship's screen position) is the ship); %d ships, none added" % ships.get_child_count(),
		follows and ships.get_child_count() == count)
	await _click(_screen(Vector3(-140, 0, 140)))
	_check("markers: a click on empty space clears the selection", scene.selection().selected.is_empty())


func _case_grid() -> void:
	print("\n=== S3 tactical grid")
	var grid: MeshInstance3D = scene.grid
	var aligned := grid.global_transform.basis.is_equal_approx(Basis.IDENTITY) and is_equal_approx(grid.global_position.x, 0.0) and is_equal_approx(grid.global_position.z, 0.0)
	var close := TacticalGrid.strengths(8.0)
	var tactical := TacticalGrid.strengths(40.0)
	var far := TacticalGrid.strengths(150.0)
	print("  [minor, major] alpha at zoom 8 / 40 / 150: %s / %s / %s" % [close, tactical, far])
	_check("the grid is on by default, world-aligned (identity basis at the origin, lines at world multiples of 10 / 50 u)", grid.visible and aligned)
	_check("strength follows zoom: suppressed close in, faint at tactical zoom, major lines strongest at strategic zoom (all below 0.2 alpha)",
		close == Vector2.ZERO and tactical.x > 0.0 and far.y > tactical.y and far.y <= 0.2 and far.x <= 0.1)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_G
	key.keycode = KEY_G
	key.pressed = true
	root.push_input(key, true)
	await process_frame
	var off := not grid.visible
	root.push_input(key, true)
	await process_frame
	_check("G toggles the grid off and on", off and grid.visible)
	await _set_zoom(40.0)
	var gunship: Node3D = scene.ship("Gunship")
	_rig().global_position = Vector3(gunship.global_position.x, 0, gunship.global_position.z)
	await process_frame
	await _click(_screen(gunship.global_position))
	var goal := Vector3(gunship.global_position.x + 8, 0, gunship.global_position.z - 6)
	await _click(_screen(goal), MOUSE_BUTTON_RIGHT)
	var destination: Vector2 = gunship.get_node("Locomotion").destination
	_check("with the grid on, a click selects and a right-click moves to the clicked ground point (%.2f u off)" % destination.distance_to(Vector2(goal.x, goal.z)),
		scene.selection().selected == [gunship] and destination.distance_to(Vector2(goal.x, goal.z)) < 0.5)
