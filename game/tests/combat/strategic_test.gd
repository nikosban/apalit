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


## Zoom range and the model / marker switch with hysteresis.
func _case_zoom() -> void:
	print("\n=== S1 zoom range and representation switch")
	root.size = Vector2i(1920, 1080) # the headless window is square; judge coverage at 16:9
	await process_frame
	_rig().global_position = Vector3.ZERO
	_rig().rotation = Vector3.ZERO
	await _set_zoom(40.0)
	await _wheel(false, 30)
	var reached: float = _rig().zoom_distance
	var rect := scene.get_viewport().get_visible_rect()
	var corners := [Vector3(-100, 0, -80), Vector3(100, 0, -80), Vector3(-100, 0, 80), Vector3(100, 0, 80)]
	var inside := corners.filter(func(c: Vector3) -> bool: return rect.has_point(_screen(c))).size()
	_check("the wheel zooms out to the strategic maximum %.0f and no further; centred, all four corners of the E05 battlefield (±100 × ±80) on screen (%d / 4, viewport %s)" % [reached, inside, rect.size],
		is_equal_approx(reached, 150.0) and inside == 4)
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
