extends SceneTree
## Headless Stage 5.1/5.2 checks on the real lab scene: mouse selection and
## single-ship MOVE orders, driven by input events pushed into the viewport (the
## GUI sees them first, as in the game). Ship physics is stepped manually at 60 Hz
## in the game's order (per ship RouteFollower then Avoidance, then Locomotion).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/selection_test.gd
## Every check is PASS/FAIL; expectations come from the scene layout, not from the
## selection code.

const LAB := preload("res://game/scenes/movement_test.tscn")
const DT := 1.0 / 60.0
const SHIPS := ["Miner", "Transporter", "FF01"]

var _failures := 0
var _checks := 0
var _lab: Node
var _selection: Node
var _camera: Camera3D
var _rig: Node3D


func _initialize() -> void:
	await process_frame
	_lab = LAB.instantiate()
	root.add_child(_lab)
	_selection = _lab.get_node("Selection")
	_camera = _lab.get_node("CameraRig/Camera3D")
	_rig = _lab.get_node("CameraRig")
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance"]:
			_node(ship_name, child).set_physics_process(false)
	for ship_name in SHIPS:
		while not _lab.get_node("StaticNavigation").is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame
	print("viewport %s" % str(root.get_visible_rect().size))
	_layout()

	_test_single_and_empty()
	_test_shift_click()
	_test_box()
	_test_overlap()
	_test_indicators()
	_test_camera()
	_test_debug_ui()
	_test_keys()
	_test_moving_selection()
	_test_orders()
	_test_group_and_ship_click()
	_test_style_snapshot()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# Ships at rest in open space east of the obstacles, camera above them.
func _layout() -> void:
	_place("Miner", Vector2(105, 0), 0.0)
	_place("Transporter", Vector2(118, 0), 0.0)
	_place("FF01", Vector2(135, 0), 0.0)
	_rig.global_position = Vector3(120, 0, 0)
	_rig.rotation = Vector3(0.0, deg_to_rad(45.0), 0.0)
	_rig.zoom_distance = 40.0
	_rig._apply_zoom()
	_selection.set_selection([])


func _test_single_and_empty() -> void:
	for ship_name in SHIPS:
		_click(_screen(ship_name))
		_check("click selects %s" % ship_name, _names() == [ship_name])
	_click(_ground_screen(Vector2(120, 25)))
	_check("click on empty ground clears", _names().is_empty())
	_click(_screen("Transporter"))
	_click(_ground_screen(Vector2(120, 25)), true)
	_check("shift-click on empty ground keeps the selection", _names() == ["Transporter"])


func _test_shift_click() -> void:
	_click(_screen("Miner"))
	_click(_screen("FF01"), true)
	_check("shift-click adds", _names() == ["Miner", "FF01"])
	_click(_screen("Miner"), true)
	_check("shift-click removes", _names() == ["FF01"])


func _test_box() -> void:
	var f := _screen("Miner")
	var g := _screen("Transporter")
	var d := _screen("FF01")
	var rect := Rect2(f, Vector2.ZERO).expand(g).grow(20.0)
	_check("layout: FF01 outside the Miner-Transporter box", not rect.has_point(d))
	_drag(rect.position, rect.end)
	_check("box selects the ships inside", _names() == ["Miner", "Transporter"])
	_drag(d - Vector2(20, 20), d + Vector2(20, 20), true)
	_check("shift-box adds", _names() == ["Miner", "Transporter", "FF01"])
	_drag(d - Vector2(20, 20), d + Vector2(20, 20))
	_check("box without shift replaces", _names() == ["FF01"])
	# A drag starting over the Miner is a box, not a click on it.
	_drag(f + Vector2(-8, -8), g + Vector2(8, 8))
	_check("drag starting over a ship selects by box", _names() == ["Miner", "Transporter"])
	_drag(_ground_screen(Vector2(120, 30)), _ground_screen(Vector2(122, 32)))
	_check("empty box clears", _names().is_empty())
	_drag(f, f + Vector2(4, 0))
	_check("movement within the threshold is a click", _names() == ["Miner"])


# Miner parked on the camera side of the Transporter so their images overlap; the
# ship nearer the camera is picked where both are under the cursor.
func _test_overlap() -> void:
	# The Transporter's long axis points at the camera and the Miner sits on its near
	# end (footprints overlapping), so the ray through the Miner also hits the Transporter.
	var toward_camera := Vector2(_camera.global_position.x, _camera.global_position.z) - Vector2(118, 0)
	toward_camera = toward_camera.normalized()
	_place("Transporter", Vector2(118, 0), atan2(-toward_camera.x, -toward_camera.y))
	_place("Miner", Vector2(118, 0) + toward_camera * 2.0, 0.0)
	var f := _screen("Miner")
	var transporter := _ship("Transporter")
	var to_ship := transporter.global_transform.affine_inverse()
	var both := false
	for part: AABB in _selection._parts[transporter]:
		if part.intersects_ray(to_ship * _camera.project_ray_origin(f), to_ship.basis * _camera.project_ray_normal(f)) != null:
			both = true
	_check("layout: the ray through the Miner also hits the Transporter hull", both)
	var picks := []
	for i in 3:
		_click(f)
		picks.append(_names())
	_check("overlap: the nearer ship (Miner) is picked, every time", picks == [["Miner"], ["Miner"], ["Miner"]])
	var far_end := _camera.unproject_position(Vector3(118, 1.5, 0) - Vector3(toward_camera.x, 0, toward_camera.y) * 2.0)
	_click(far_end)
	_check("overlap: the far part of the Transporter picks the Transporter", _names() == ["Transporter"])
	_layout()


func _test_indicators() -> void:
	_selection.set_selection([_ship("Miner"), _ship("FF01")])
	_selection._process(0.0)
	var visible := []
	for ship_name in SHIPS:
		if (_selection._rings[_ship(ship_name)] as Node3D).visible:
			visible.append(ship_name)
	_check("selection rings shown for every selected ship only", visible == ["Miner", "FF01"])


func _test_camera() -> void:
	_click(_screen("Transporter"))
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_WHEEL_UP # Zoom in (40 is the maximum zoom-out).
	event.pressed = true
	event.position = _screen("Transporter")
	root.push_input(event, true)
	var zoom: float = _rig.zoom_target # requested at once; the rendered zoom follows over frames
	var yaw: float = _rig.rotation.y
	var motion := InputEventMouseMotion.new()
	motion.position = _screen("Transporter")
	motion.relative = Vector2(60, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	root.push_input(motion, true)
	_check("wheel and middle-drag move the camera (zoom %.1f, yaw %.1f)" % [zoom, rad_to_deg(_rig.rotation.y)], zoom != 40.0 and absf(_rig.rotation.y - deg_to_rad(45.0)) > 0.01)
	_check("camera input leaves the selection alone", _names() == ["Transporter"])
	_click(_screen("FF01"))
	_check("picking after a camera rotation", _names() == ["FF01"])
	_rig.rotation = Vector3(0.0, yaw, 0.0)
	_layout()


func _test_debug_ui() -> void:
	_click(_screen("Transporter"))
	var toggle := _lab.get_node("DebugUI/Panel/DebugToggle") as CheckBox
	var was := toggle.button_pressed
	_click(toggle.get_global_rect().get_center())
	_check("a click on the debug panel toggles it", toggle.button_pressed != was)
	_check("a click on the debug panel does not change the selection", _names() == ["Transporter"])
	_click(toggle.get_global_rect().get_center())
	var g := _screen("Transporter")
	var panel := toggle.get_global_rect().get_center()
	var expected := []
	var start := g + Vector2(40.0 * signf(g.x - panel.x), 40) # UX round P6: the debug panel may be on either side (now top left).
	var rect := Rect2(start, Vector2.ZERO).expand(panel)
	for ship_name in SHIPS:
		if rect.has_point(_screen(ship_name)):
			expected.append(ship_name)
	_drag(start, panel)
	_check("a box released over the debug panel completes (%s)" % ", ".join(expected), _names() == expected and expected.has("Transporter"))


func _test_keys() -> void:
	_click(_screen("Transporter"))
	for key in [KEY_1, KEY_2, KEY_3]:
		_key(key)
	_check("keys 1/2/3 no longer select", _names() == ["Transporter"])
	_key(KEY_4)
	_check("scenario 4 selects its moving ships", _names() == ["Miner", "Transporter"])
	_key(KEY_8)
	_check("scenario 8 selects its moving ship", _names() == ["Transporter"])
	_reset_orders()
	_layout()


# Selection activity while a ship moves must not change its movement at all.
func _test_moving_selection() -> void:
	var target := Vector2(105, -60)
	var reference := _fly("Miner", target, 300, false)
	var touched := _fly("Miner", target, 300, true)
	_check("selection during movement leaves the trajectory identical", reference == touched)


func _test_orders() -> void:
	var miner := _node("Miner", "Locomotion")
	var follower := _node("Miner", "RouteFollower")
	_click(_screen("Miner"))
	var first := Vector2(105, -50)
	var plans: int = follower.plans
	_right_click(_ground_screen(first))
	_check("right-click orders the selected ship", follower.plans == plans + 1 and miner.has_destination and miner.destination.distance_to(first) < 0.05)
	_steps(120)
	_click(_screen("Transporter"))
	_check("selecting another ship", _names() == ["Transporter"])
	var before: Vector2 = miner.planar_position
	_steps(60)
	_check("deselected ship keeps its order and moves", miner.has_destination and miner.planar_position.distance_to(before) > 1.0)
	_lab._process(0.0)
	_check("no marker for an unselected ship", _marker("Miner") == null)
	_click(_screen("Miner"))
	_lab._process(0.0)
	var marker: Variant = _marker("Miner")
	_check("reselecting shows its current order (marker at the destination)", marker != null
		and (marker as Vector2).distance_to(first) < 0.05)
	var drawn: Array = _lab.get_node("MovementIndicator").layout().filter(func(item: Dictionary) -> bool: return item.entry.ship == _ship("Miner"))
	# Headless the window is 64 x 64, so the px-sized symbol is large in the world: the line
	# is drawn exactly when the ship is beyond the symbol and gap (movement_indicator_test
	# checks it on a 1080p screen).
	var beyond: bool = not drawn.is_empty() and Vector2(_ship("Miner").global_position.x, _ship("Miner").global_position.z).distance_to(first) > drawn[0].clearance
	_check("destination line drawn when the ship is beyond the symbol and gap (beyond: %s)" % beyond,
		drawn.size() == 1 and drawn[0].lines.size() == 1 and (drawn[0].lines[0].points.size() > 1) == beyond)
	# Redirect while moving: momentum kept, order replaced at once.
	var second := Vector2(80, -30)
	var velocity: Vector2 = miner.velocity
	var angular: float = miner.angular_velocity
	plans = follower.plans
	_right_click(_ground_screen(second))
	_check("redirect replaces the order immediately", follower.plans == plans + 1 and miner.destination.distance_to(second) < 0.05)
	_check("redirect keeps velocity and turn rate", miner.velocity == velocity and miner.angular_velocity == angular)
	_click(_ground_screen(Vector2(130, 30)))
	var t := 0
	while miner.has_destination and t < 60 * 60:
		_steps(1)
		t += 1
	_check("deselected ship completes its order (arrived)", miner.arrived and miner.planar_position.distance_to(second) < 0.05)
	_click(_screen("Miner"))
	_lab._process(0.0)
	_check("no marker after completion", _marker("Miner") == null)
	_layout()


func _test_group_and_ship_click() -> void:
	var miner := _node("Miner", "Locomotion")
	var follower := _node("Miner", "RouteFollower")
	_click(_screen("Miner"))
	_click(_screen("Transporter"), true)
	# Stage 5.3: a group right-click orders every selected ship, to separate destinations.
	var transporter := _node("Transporter", "Locomotion")
	_right_click(_ground_screen(Vector2(110, -40)))
	var gap: float = miner.destination.distance_to(transporter.destination) - 1.6 - 3.4
	_check("group right-click orders every selected ship (destination gap %.2f u)" % gap,
		miner.has_destination and transporter.has_destination and gap >= 1.0 - 0.001)
	_reset_orders()
	_layout()
	# Right-click on another (stationary) ship: a MOVE to the nearest reachable point
	# beside it, outside its clearance, on the ordered ship's side (movement_lab.gd
	# _move_single, GroupOrders.resolve_occupied).
	_click(_screen("Miner"))
	_right_click(_screen("Transporter"))
	var group := _lab.get_node("GroupOrders")
	var transporter_at: Vector2 = _node("Transporter", "Locomotion").planar_position
	var clearance: float = 1.6 + 3.4 + group.separation_margin + group.destination_buffer
	var beside: float = miner.destination.distance_to(transporter_at)
	_check("right-click over a stationary ship is a MOVE beside it (%.2f u from it, clearance %.2f u)" % [beside, clearance],
		miner.has_destination and (follower.status == follower.RouteStatus.ROUTE or follower.status == follower.RouteStatus.DIRECT)
		and beside >= clearance - 0.01 and beside <= clearance + group.resolve_margin + 0.01
		and (miner.destination - transporter_at).dot(miner.planar_position - transporter_at) >= 0.0)
	_check("the ship under the cursor is not ordered", not _node("Transporter", "Locomotion").has_destination)
	_reset_orders()
	_layout()


# Flies one ship for `ticks` from a fixed start; with `touch`, the selection is
# exercised every 10 ticks (clicks on the moving ship, empty ground, shift, boxes).
# Returns the final position, velocity, heading and angular velocity.
func _fly(ship_name: String, target: Vector2, ticks: int, touch: bool) -> Array:
	_layout()
	_selection.set_selection([])
	_node(ship_name, "RouteFollower").order(target)
	for i in ticks:
		if touch and i % 10 == 0:
			match (i / 10) % 4:
				0:
					_click(_screen(ship_name))
				1:
					_click(_ground_screen(Vector2(130, 30)))
				2:
					_click(_screen(ship_name), true)
				3:
					var s := _screen(ship_name)
					_drag(s - Vector2(30, 30), s + Vector2(30, 30), true)
		_steps(1)
	var loco := _node(ship_name, "Locomotion")
	var result := [loco.planar_position, loco.velocity, loco.heading, loco.angular_velocity]
	_reset_orders()
	return result


func _steps(count: int) -> void:
	for i in count:
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_node(ship_name, "Locomotion")._step(DT)


func _reset_orders() -> void:
	for ship_name in SHIPS:
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()


func _place(ship_name: String, point: Vector2, heading: float) -> void:
	_node(ship_name, "Locomotion").place(point, heading)


func _click(position: Vector2, shift := false) -> void:
	_button(MOUSE_BUTTON_LEFT, position, true, shift)
	_button(MOUSE_BUTTON_LEFT, position, false, shift)


func _right_click(position: Vector2) -> void:
	_button(MOUSE_BUTTON_RIGHT, position, true, false)
	_button(MOUSE_BUTTON_RIGHT, position, false, false)


func _drag(from: Vector2, to: Vector2, shift := false) -> void:
	_button(MOUSE_BUTTON_LEFT, from, true, shift)
	for k in range(1, 5):
		var motion := InputEventMouseMotion.new()
		motion.position = from.lerp(to, k / 4.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.shift_pressed = shift
		root.push_input(motion, true)
	_button(MOUSE_BUTTON_LEFT, to, false, shift)


func _button(index: MouseButton, position: Vector2, pressed: bool, shift: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	event.position = position
	event.global_position = position
	event.shift_pressed = shift
	event.button_mask = (MOUSE_BUTTON_MASK_LEFT if index == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if pressed else 0
	root.push_input(event, true)


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		root.push_input(event, true)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-75s %s" % [label, "PASS" if ok else "FAIL (selection: %s)" % ", ".join(_names())])


func _names() -> Array:
	var names := []
	for ship: Node in _selection.selected:
		names.append(String(ship.name))
	return names


func _ship(ship_name: String) -> Node3D:
	return _lab.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _lab.get_node("Ships/%s/%s" % [ship_name, child])


func _screen(ship_name: String) -> Vector2:
	return _camera.unproject_position(_ship(ship_name).global_position)


func _ground_screen(point: Vector2) -> Vector2:
	return _camera.unproject_position(Vector3(point.x, 0.0, point.y))


# The destination the movement indicator shows for a ship, or null.
func _marker(ship_name: String) -> Variant:
	for entry: Dictionary in _lab.get_node("MovementIndicator").entries():
		if entry.ship == _ship(ship_name):
			return entry.destination
	return null


func _test_style_snapshot() -> void:
	var source = _selection.interaction_style
	var padding: float = source.ring_padding
	var color: Color = source.selection_indicator_color
	var box_color: Color = source.drag_box.bg_color
	var radius: float = _selection._rings[_ship("Miner")].mesh.outer_radius
	source.ring_padding = padding + 0.4
	source.selection_indicator_color = Color(0.8, 0.2, 0.4)
	source.drag_box.bg_color = Color(0.2, 0.3, 0.4, 0.2)
	_selection._process(0.0)
	_check("style: active ring and nested drag style retain ready-time snapshot",
		is_equal_approx(_selection._rings[_ship("Miner")].mesh.outer_radius, radius)
		and _selection._ring_material.albedo_color.is_equal_approx(color)
		and _selection._box.get_theme_stylebox("panel").bg_color == box_color)
	var late := Node3D.new()
	late.name = "LateStyleProbe"
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	late.add_child(mesh)
	_lab.get_node("Ships").add_child(late)
	_selection.register_ship(late)
	_check("style: late registration keeps existing run dimensions",
		is_equal_approx(_selection._rings[late].mesh.outer_radius, sqrt(0.5) + padding))
	_selection.unregister_ship(late)
	late.queue_free()
	var selection = load("res://game/selection/ship_selection.gd").new()
	_lab.add_child(selection)
	selection._process(0.0)
	_check("style: restart consumes new ring and nested drag settings",
		is_equal_approx(selection._rings[_ship("Miner")].mesh.outer_radius, radius + 0.4)
		and selection._ring_material.albedo_color.is_equal_approx(source.selection_indicator_color)
		and selection._box.get_theme_stylebox("panel").bg_color == source.drag_box.bg_color)
	selection._ring_material.albedo_color = Color(1, 1, 1, 0.1)
	_check("style: runtime material change does not mutate source or another run",
		source.selection_indicator_color == Color(0.8, 0.2, 0.4) and _selection._ring_material.albedo_color.is_equal_approx(color))
	source.ring_padding = padding
	source.selection_indicator_color = color
	source.drag_box.bg_color = box_color
	_lab.remove_child(selection)
	selection.free()
