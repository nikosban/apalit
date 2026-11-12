extends SceneTree
## Headless UX round P8 (T23) checks on the playable main scene: the command cursor
## shows what a right-click would do, from the same resolution and checks as the click.
## For every case the cursor is read, then the click is given to the scene's own
## right-click handler (Player._command) and its outcome compared: Move where an
## order is taken, Mine / Dock where those are accepted, Unavailable where the click is
## refused (no route, no working position, Dock at its own station, a group without
## room), the arrow with nothing selected or over the GUI. Navigation is a
## StaticNavigation subclass that can refuse routes into a zone. Results are cached per
## target; a frame's cost is measured. Ship physics is stepped manually when needed.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/command_cursor_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const CommandCursor := preload("res://game/player/ui/command_cursor.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const DT := 1.0 / 60.0
const NAVIGATION_SOURCE := """extends "res://game/navigation/static_navigation.gd"
var blocked_to := Vector2.INF # Plans ending within blocked_radius of this point are refused.
var blocked_radius := 3.0
func plan(radius: float, from: Vector2, to: Vector2) -> PackedVector2Array:
	if to.distance_to(blocked_to) < blocked_radius:
		return PackedVector2Array()
	return super.plan(radius, from, to)
"""

var _failures := 0
var _checks := 0
var _main: Node
var _cursor: CommandCursor
var _selection: Node
var _camera: Camera3D
var _nav: Node
var _ships: Array[String] = []


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	var ff01: Node3D = load("res://game/ships/ff01_unit.tscn").instantiate() # A ship without mining.
	ff01.name = "FF01"
	ff01.position = Vector3(14, 1.5, 0)
	_main.get_node("Ships").add_child(ff01)
	var navigation := _main.get_node("StaticNavigation")
	var obstacles: NodePath = navigation.obstacles_path
	var script := GDScript.new()
	script.source_code = NAVIGATION_SOURCE
	script.reload()
	navigation.set_script(script)
	navigation.obstacles_path = obstacles
	root.add_child(_main)
	_nav = _main.get_node("StaticNavigation")
	_main.get_node("Survey").set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		_ships.append(String(ship.name))
		for child in ship.get_children():
			child.set_physics_process(false)
	_cursor = _main.get_node("Player/CommandCursor")
	_cursor.set_process(false) # Driven by update() with a chosen point.
	_selection = _main.get_node("Player/Selection")
	_camera = _main.get_node("Player/CameraRig/Camera3D")
	for s in _ships:
		while not _nav.is_ready(_n(s, "RouteFollower").planning_radius()):
			await physics_frame
	await _test_basic()
	await _test_asteroids()
	await _test_station()
	await _test_group()
	await _test_cost()
	await _test_input_precedence()
	_test_camera_overrides()
	_test_notice_timing()
	_test_resolved_intent_without_player()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _test_basic() -> void:
	_frame(Vector2(0, 0), 34.0)
	await process_frame
	var ground := _screen(Vector3(10, 0, -12))
	_selection.set_selection([])
	_check("nothing selected: the arrow, and a right-click gives no order", _cursor.update(ground, true, DT) == CommandCursor.Cursor.NONE)
	_selection.set_selection([_ship("FF01")])
	var shown := _cursor.update(ground, true, DT)
	_main.get_node("Player")._command(ground)
	_check("FF01, open ground: Move, and the click gives the order (%s)" % str(_n("FF01", "RouteFollower").requested),
		shown == CommandCursor.Cursor.MOVE and _lo("FF01").has_destination and _n("FF01", "RouteFollower").requested.distance_to(Vector2(10, -12)) < 0.6)
	_reset()
	_selection.set_selection([_ship("FF01")])
	_nav.blocked_to = Vector2(14, 12)
	var refused := _screen(Vector3(14, 0, 12))
	shown = _cursor.update(refused, true, DT)
	var notice := _notice()
	_main.get_node("Player")._command(refused)
	_check("FF01, a point with no route: Unavailable (%s), and the click is refused ('%s'), no order (%s)" % [shown, _notice(), _lo("FF01").has_destination],
		shown == CommandCursor.Cursor.UNAVAILABLE and _notice() == "No route found" and not _lo("FF01").has_destination)
	_nav.blocked_to = Vector2.INF
	_check("over the GUI: the arrow", _cursor.update(ground, false, DT) == CommandCursor.Cursor.NONE)
	_reset()


func _test_asteroids() -> void:
	var field := _main.get_node("Asteroids")
	var id := _nearest_asteroid(_lo("Miner1").planar_position)
	var center: Vector3 = field.center(id)
	_frame(Vector2(center.x, center.z), 30.0)
	await process_frame
	var over := _screen(center)
	_selection.set_selection([_ship("Miner1")])
	var shown := _cursor.update(over, true, DT)
	_main.get_node("Player")._command(over)
	_check("Miner1 over an asteroid with a working position: Mine, and the click assigns it (asteroid %d, %s)" % [id, _mining("Miner1").status_name()],
		shown == CommandCursor.Cursor.MINE and _mining("Miner1").target == id and _mining("Miner1").is_active())
	_reset()
	_nav.blocked_to = Vector2(center.x, center.z)
	_nav.blocked_radius = field.radius(id) + 10.0 # Every working point refused.
	_selection.set_selection([_ship("Miner1")])
	shown = _cursor.update(over, true, DT)
	_main.get_node("Player")._command(over)
	_check("Miner1 over an asteroid without a reachable working position: Unavailable, and the click is refused ('%s')" % _notice(),
		shown == CommandCursor.Cursor.UNAVAILABLE and _notice().ends_with("no reachable working position at the asteroid") and _mining("Miner1").target == -1)
	_nav.blocked_to = Vector2.INF
	_nav.blocked_radius = 3.0
	_reset()
	_selection.set_selection([_ship("FF01")])
	shown = _cursor.update(over, true, DT)
	_main.get_node("Player")._command(over)
	var destination: Vector2 = _lo("FF01").destination
	var gap: float = destination.distance_to(Vector2(center.x, center.z)) - field.radius(id) - _n("FF01", "RouteFollower").ship_radius
	_check("FF01 over an asteroid: Move, and the click moves it to a point outside the asteroid's footprint (%.2f u clear)" % gap,
		shown == CommandCursor.Cursor.MOVE and _lo("FF01").has_destination and gap >= 0.0)
	_reset()


func _test_station() -> void:
	var station: Node3D = _main.get_node("Stations/Station")
	_frame(Vector2(station.global_position.x, station.global_position.z), 30.0)
	await process_frame
	var over := _screen(station.global_position)
	_selection.set_selection([_ship("Miner1")])
	_lo("Miner1").place(_nav.closest_point(2.6, Vector2(station.global_position.x, station.global_position.z) + Vector2(55, 0)), 0.0)
	var shown := _cursor.update(over, true, DT)
	_main.get_node("Player")._command(over)
	_check("Miner1 over the Station: Dock, and the click requests the dock (%s)" % _dk("Miner1").state_name(),
		shown == CommandCursor.Cursor.DOCK and _dk("Miner1").station == station)
	_main.get_node("Stations/Station").slots[1].ship = _ship("Miner2") # Any other ship holds berth 1.
	_until(func() -> bool: return _dk("Miner1").state == Docking.State.DOCKED, 60 * 150)
	_main.get_node("Stations/Station").slots[1].ship = null
	shown = _cursor.update(over, true, DT * 40) # Same target, re-checked after REFRESH.
	_main.get_node("Player")._command(over)
	_check("docked at the Station, over the Station: Unavailable (Dock there changes nothing), and the click changes nothing (%s)" % _dk("Miner1").state_name(),
		shown == CommandCursor.Cursor.UNAVAILABLE and _dk("Miner1").state == Docking.State.DOCKED and not _dk("Miner1").has_held_command())
	_reset()


func _test_group() -> void:
	_frame(Vector2(0, 0), 34.0)
	await process_frame
	var point := Vector3(20, 0, -20)
	var screen := _screen(point)
	_selection.set_selection([_ship("FF01"), _ship("Transporter"), _ship("Miner2")])
	var moving := _cursor.update(screen, true, DT)
	var rested := _cursor.update(screen, true, CommandCursor.GROUP_REST)
	_main.get_node("Player")._command(screen)
	_check("group over open ground: Move while moving (%s) and after resting (%s); the click gives every ship an order" % [moving, rested],
		moving == CommandCursor.Cursor.MOVE and rested == CommandCursor.Cursor.MOVE
		and ["FF01", "Transporter", "Miner2"].all(func(s: String) -> bool: return _lo(s).has_destination))
	_reset()
	_nav.blocked_to = Vector2(point.x, point.z)
	_nav.blocked_radius = 400.0 # No destination for anyone anywhere.
	_selection.set_selection([_ship("FF01"), _ship("Transporter"), _ship("Miner2")])
	_cursor.update(screen, true, DT)
	rested = _cursor.update(screen, true, CommandCursor.GROUP_REST)
	_main.get_node("Player")._command(screen)
	_check("group with no room: Unavailable once the cursor rests (%s), and the click gives no order ('%s'; %s)" % [rested, _notice(), str(["FF01", "Transporter", "Miner2"].map(func(s: String) -> bool: return _lo(s).has_destination))],
		rested == CommandCursor.Cursor.UNAVAILABLE and _notice() == "Not enough space for the group - no orders given"
		and ["FF01", "Transporter", "Miner2"].all(func(s: String) -> bool: return not _lo(s).has_destination))
	_nav.blocked_to = Vector2.INF
	_nav.blocked_radius = 3.0
	_reset()


func _test_cost() -> void:
	_frame(Vector2(0, 0), 34.0)
	await process_frame
	_selection.set_selection([_ship("Miner1")])
	var before: int = _cursor.checks
	for i in 30:
		_cursor.update(_screen(Vector3(10.2 + i * 0.01, 0, -12.2)), true, DT) # Within one 2 u cell.
	var same_cell: int = _cursor.checks - before
	var start := Time.get_ticks_usec()
	var frames := 120
	for i in frames:
		_cursor.update(_screen(Vector3(-30 + i * 0.5, 0, -10 + i * 0.25)), true, DT) # Sweeping across cells.
	var mean := (Time.get_ticks_usec() - start) / 1000.0 / frames
	_check("caching: 30 updates within one cell run %d check(s); sweeping across %d cells costs %.3f ms per update on average" % [same_cell, frames, mean],
		same_cell == 1 and mean < 4.0)
	_selection.set_selection([])


func _test_input_precedence() -> void:
	_reset()
	var player := _main.get_node("Player")
	var rig := player.get_node("CameraRig")
	var ship := _ship("FF01")
	_selection.set_selection([ship])
	_frame(Vector2(0, 0), 34.0)
	await process_frame
	var ground := _screen(Vector3(10, 0, -12))
	var overlay := CanvasLayer.new()
	overlay.layer = 10
	var control := Control.new()
	control.position = ground - Vector2(5, 5)
	control.size = Vector2(10, 10)
	control.mouse_filter = Control.MOUSE_FILTER_STOP
	var received := [0]
	control.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			received[0] += 1
			control.accept_event())
	_main.add_child(overlay)
	overlay.add_child(control)
	_point_at(ground)
	await process_frame

	var dispatches: Array[Node3D] = []
	_main.command_given.connect(func(recipient: Node3D, _kind: int) -> void: dispatches.append(recipient))
	_press_at(ground, MOUSE_BUTTON_LEFT)
	_press_at(ground, MOUSE_BUTTON_RIGHT)
	_press_at(ground, MOUSE_BUTTON_WHEEL_DOWN)
	_check("Player input: GUI takes click and wheel before ordinary selection, commands, and zoom",
		received[0] == 3 and _selection.selected == [ship] and dispatches.is_empty() and rig.zoom_target == 34.0)

	player.begin_target_selection()
	_press_at(ground, MOUSE_BUTTON_RIGHT)
	_check("Player input: targeting intercepts right-click before the GUI and cancels without a MOVE",
		received[0] == 3 and not player.target_selection and dispatches.is_empty() and Engine.time_scale == 1.0)

	_frame(Vector2(0, 0), rig.max_zoom)
	_press_at(ground, MOUSE_BUTTON_WHEEL_DOWN)
	_check("Player input: a GUI wheel at maximum zoom leaves the camera in Tactical",
		received[0] == 4 and not _main.strategic.in_strategic())

	overlay.free()
	_frame(Vector2(0, 0), 34.0)
	_point_at(ground)
	await process_frame
	_press_at(ground, MOUSE_BUTTON_RIGHT)
	_check("Player input: a free right-click dispatches exactly one accepted world order",
		dispatches == [ship] and _lo("FF01").has_destination)

	_frame(Vector2(0, 0), rig.max_zoom)
	_press_at(ground, MOUSE_BUTTON_WHEEL_DOWN)
	_press_at(ground, MOUSE_BUTTON_LEFT)
	_press_at(ground, MOUSE_BUTTON_RIGHT)
	_check("Player input: Strategic handoff takes the wheel and blocks world clicks",
		_main.strategic.transitioning() and _selection.selected == [ship] and dispatches == [ship])


func _test_camera_overrides() -> void:
	var e05 := (load("res://game/tests/combat/fixtures/e05_fleet.tscn") as PackedScene).instantiate()
	var tri := (load("res://game/tests/docking/tri_dock_demo.tscn") as PackedScene).instantiate()
	var e05_rig := e05.get_node("Player/CameraRig") as Node3D
	var tri_rig := tri.get_node("Player/CameraRig") as Node3D
	_check("Player camera: E05 and Tri Dock retain their inherited camera transforms",
		e05_rig != null and e05_rig.position == Vector3(-55, 0, 10)
		and tri_rig != null and tri_rig.position == Vector3(50, 0, 40))
	e05.free()
	tri.free()


func _test_notice_timing() -> void:
	var control = _main.time_control
	var player := _main.get_node("Player")
	var notice := player.get_node("NoticeUI/Notice") as Label
	control.step_speed(1)
	_main._show_notice("Fast")
	player._process(1.9 * Engine.time_scale)
	var fast_visible := notice.visible
	player._process(0.2 * Engine.time_scale)
	var fast_expired := not notice.visible

	control.step_speed(-1)
	control.step_speed(-1)
	_main._show_notice("Slow")
	player._process(1.9 * Engine.time_scale)
	var slow_visible := notice.visible
	player._process(0.2 * Engine.time_scale)
	var slow_expired := not notice.visible

	control.set_paused(true)
	_main._show_notice("Paused")
	player._process(1.9)
	var paused_visible := notice.visible
	player._process(0.2)
	_check("Player notice: two seconds of real time at 2x, 0.25x, and while paused",
		fast_visible and fast_expired and slow_visible and slow_expired and paused_visible and not notice.visible)
	control.set_paused(false)
	control.step_speed(1)


func _test_resolved_intent_without_player() -> void:
	_reset()
	var ship := _ship("FF01")
	var intent := {"kind": _main.CommandKind.MOVE, "point": Vector2(10, -12)}
	_main.get_node("Player").free()
	_main.strategic.free()
	var available: bool = _main.can_submit_intent([ship], intent)
	var accepted: bool = _main.submit_intent([ship], intent)
	_check("Resolved order API: a supplied recipient can take a MOVE without Player or a camera",
		not _main.has_node("Player") and root.get_camera_3d() == null and available and accepted
		and _n("FF01", "RouteFollower").requested.is_equal_approx(intent.point))
	_main.free()


func _point_at(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)


func _press_at(point: Vector2, button: MouseButton) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = button
		event.pressed = pressed
		event.factor = 1.0
		root.push_input(event, true)


# ------------------------------------------------------------------ helpers
func _reset() -> void:
	_cursor.update(Vector2.ZERO, false, 0.0) # Forget the last target (each case starts fresh).
	_selection.set_selection([])
	_main._show_notice("")
	for s in _ships:
		var dk := _dk(s)
		dk.phase = Docking.Phase.NONE
		dk.hold_command(Callable())
		dk.cancel()
		dk.state = Docking.State.NONE
		_n(s, "RouteFollower").clear()
		_lo(s).place(_lo(s).planar_position, _lo(s).heading)
		var mining := _main.get_node_or_null("Ships/%s/Mining" % s) as MiningOperation
		if mining != null:
			mining.cancel()
			mining.target = -1
			mining.status = MiningOperation.Status.NONE
			mining._route_pending = false
	for station in _main.get_node("Stations").get_children():
		for slot in station.slots:
			slot.ship = null
			slot.leaving = false
		for h in station.holds:
			h.ship = null
		station.queue.clear()
		station._exiting.clear()


func _step() -> void:
	for s in _ships:
		_n(s, "RouteFollower")._physics_process(DT)
		_n(s, "Avoidance")._physics_process(DT)
	for s in _ships:
		_lo(s)._step(DT)
	for s in _ships:
		_dk(s)._physics_process(DT)
	for station in _main.get_node("Stations").get_children():
		station._physics_process(DT)


func _until(condition: Callable, limit: int) -> void:
	for i in limit:
		if condition.call():
			return
		_step()


func _nearest_asteroid(from: Vector2) -> int:
	var field := _main.get_node("Asteroids")
	var best := -1
	var best_distance := INF
	for id: int in field.ids():
		var c: Vector3 = field.center(id)
		var d := Vector2(c.x, c.z).distance_to(from)
		if d < best_distance:
			best_distance = d
			best = id
	return best


func _notice() -> String:
	return (_main.get_node("Player/NoticeUI/Notice") as Label).text


func _screen(point: Vector3) -> Vector2:
	return _camera.unproject_position(point)


func _frame(center: Vector2, zoom: float) -> void:
	var rig := _main.get_node("Player/CameraRig")
	rig.global_position = Vector3(center.x, 0, center.y)
	rig.zoom_distance = zoom
	rig._apply_zoom()


func _ship(s: String) -> Node3D:
	return _main.get_node("Ships/" + s)


func _n(s: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [s, child])


func _lo(s: String) -> Node:
	return _n(s, "Locomotion")


func _dk(s: String) -> Docking:
	return _n(s, "Docking") as Docking


func _mining(s: String) -> MiningOperation:
	return _n(s, "Mining") as MiningOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
