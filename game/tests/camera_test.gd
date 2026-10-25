extends SceneTree
## Camera rig (continuous zoom, Phase A): smoothed wheel zoom, pitch from the rendered
## distance, cursor anchoring, snaps and camera input, on the rig alone (max zoom 150 as
## in main.tscn); screen points are fractions of the visible rect. Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/camera_test.gd

const RIG := preload("res://game/camera/camera_rig.tscn")
var CENTER := Vector2.ZERO # set from the visible rect (1152 × 648 with the project stretch)
var OFF_CENTER := Vector2.ZERO
const MAX_DRIFT := 5.0 # px

var _world: Node3D
var _rig: Node3D
var _camera: Camera3D
var _panel: Control
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	root.size = Vector2i(1920, 1080)
	_world = Node3D.new()
	_rig = RIG.instantiate()
	_rig.max_zoom = 150.0
	_rig.zoom_distance = 20.0
	_rig.process_mode = Node.PROCESS_MODE_ALWAYS # as in the scenes (ALWAYS_NODES)
	_world.add_child(_rig)
	# UI as in the game: a full-screen overlay that ignores the mouse (as the marker and HUD
	# canvases) and a panel with a button. Neither consumes wheel events (Godot 4.7 passes
	# them on); the rig itself ignores the wheel while a control is hovered.
	var layer := CanvasLayer.new()
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(overlay)
	_panel = Panel.new()
	_panel.position = Vector2(400, 500)
	_panel.size = Vector2(150, 100)
	var button := Button.new()
	button.position = Vector2(10, 10)
	button.size = Vector2(60, 40)
	_panel.add_child(button)
	layer.add_child(_panel)
	_world.add_child(layer)
	root.add_child(_world)
	_camera = _rig.get_node("Camera3D")
	await process_frame
	CENTER = _at(0.5, 0.5)
	OFF_CENTER = _at(0.8, 0.25)
	print("visible rect %s" % root.get_visible_rect().size)
	await _case_interpolation()
	await _case_wheel_factor()
	await _case_pitch()
	await _case_anchor()
	await _case_anchor_limits()
	await _case_input()
	await _case_snap()
	await _case_time()
	root.remove_child(_world)
	_world.free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _reset(zoom: float, yaw_degrees: float = 0.0, pivot: Vector3 = Vector3.ZERO) -> void:
	_rig.rotation = Vector3(0, deg_to_rad(yaw_degrees), 0)
	_rig.global_position = pivot
	_rig.zoom_distance = zoom
	_rig._apply_zoom()
	await process_frame


## A screen point as fractions of the visible rect.
func _at(x: float, y: float) -> Vector2:
	return root.get_visible_rect().size * Vector2(x, y)


func _wheel(screen: Vector2, out: bool, factor: float = 1.0) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_WHEEL_DOWN if out else MOUSE_BUTTON_WHEEL_UP
	event.pressed = true
	event.factor = factor
	event.position = screen
	event.global_position = screen
	root.push_input(event, true)


func _hover(screen: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = screen
	event.global_position = screen
	root.push_input(event, true)


func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)


func _ground(screen: Vector2) -> Variant:
	return Plane(Vector3.UP, 0.0).intersects_ray(_camera.project_ray_origin(screen), _camera.project_ray_normal(screen))


func _pitch() -> float:
	return -rad_to_deg(_camera.rotation.x)


func _settled() -> bool:
	return _rig.zoom_distance == _rig.zoom_target


## Frames until the rendered zoom settles (at most `limit`), recording each frame.
func _run(limit: int = 240, anchor: Variant = null, screen: Vector2 = Vector2.ZERO) -> Dictionary:
	var r := {"frames": 0, "drift": 0.0, "jump": 0.0, "finite": true, "inside": true, "distances": [], "pitch_ok": true, "pitch_step": 0.0}
	var last: Vector3 = _rig.global_position
	var last_pitch := _pitch()
	var bounds: Rect2 = _rig.bounds
	while not _settled() and r.frames < limit:
		await process_frame
		r.frames += 1
		r.distances.append(_rig.zoom_distance)
		var p: Vector3 = _rig.global_position
		r.finite = r.finite and p.is_finite() and _camera.global_position.is_finite() and is_finite(_rig.zoom_distance)
		r.inside = r.inside and p.x >= bounds.position.x - 0.001 and p.x <= bounds.end.x + 0.001 and p.z >= bounds.position.y - 0.001 and p.z <= bounds.end.y + 0.001
		r.jump = maxf(r.jump, p.distance_to(last))
		last = p
		r.pitch_ok = r.pitch_ok and absf(_pitch() - _rig.pitch_for(_rig.zoom_distance)) < 0.001
		r.pitch_step = maxf(r.pitch_step, absf(_pitch() - last_pitch))
		last_pitch = _pitch()
		if anchor != null:
			r.drift = maxf(r.drift, _camera.unproject_position(anchor).distance_to(screen))
	return r


func _monotonic(values: Array, rising: bool) -> bool:
	for i in range(1, values.size()):
		if (values[i] < values[i - 1]) if rising else (values[i] > values[i - 1]):
			return false
	return true


# --- Interpolation -----------------------------------------------------------------------

func _case_interpolation() -> void:
	print("\n=== K1 smoothed zoom")
	await _reset(20.0)
	_wheel(CENTER, true)
	var target: float = _rig.zoom_target
	await process_frame
	var first: float = _rig.zoom_distance
	var r := await _run()
	var d: Array = [20.0, first] + r.distances
	var to_95 := 0
	for i in d.size():
		if log(d[i] / 20.0) >= 0.95 * log(target / 20.0):
			to_95 = i
			break
	_check("one notch out: the target moves at once to 22.0 (%.3f); the rendered zoom only starts toward it (%.3f after one frame)" % [target, first],
		is_equal_approx(target, 22.0) and first > 20.0 and first < 21.0)
	_check("it rises every frame without overshoot and settles exactly on the target (%d frames; 95%% after %d frames = %.0f ms)" % [r.frames + 1, to_95, to_95 * 1000.0 / 60.0],
		_monotonic(d, true) and d.max() <= target + 0.000001 and _rig.zoom_distance == target and to_95 >= 12 and to_95 <= 18)

	await _reset(20.0)
	for i in 3:
		_wheel(CENTER, true)
		await process_frame
	_check("three notches in consecutive frames accumulate on the target (%.4f = 20 × 1.1³)" % _rig.zoom_target, is_equal_approx(_rig.zoom_target, 20.0 * pow(1.1, 3)))
	for i in 3:
		_wheel(CENTER, false)
	var back := await _run()
	_check("reversing mid-way: the target returns to 20 (%.9f) and the rendered zoom follows back to it (peak %.3f, settles %.6f)" % [_rig.zoom_target, ([20.0] + back.distances).max(), _rig.zoom_distance],
		absf(_rig.zoom_target - 20.0) < 0.000001 and absf(_rig.zoom_distance - 20.0) < 0.000001 and _monotonic(back.distances, false))

	await _reset(37.0)
	for i in 7:
		_wheel(CENTER, true)
	for i in 7:
		_wheel(CENTER, false)
	_check("seven notches out and seven in restore the target (37 -> %.9f)" % _rig.zoom_target, absf(_rig.zoom_target - 37.0) < 0.000001)

	await _reset(20.0)
	for i in 60:
		_wheel(CENTER, true)
	var out_target: float = _rig.zoom_target
	var far := await _run()
	for i in 80:
		_wheel(CENTER, false)
	var in_target: float = _rig.zoom_target
	var near := await _run()
	var all: Array = far.distances + near.distances
	_check("limits: 60 notches out stop the target at 150 (%.1f), 80 in at 5 (%.1f); the rendered zoom stays within [%.2f, %.2f] and settles at each" % [out_target, in_target, all.min(), all.max()],
		out_target == 150.0 and in_target == 5.0 and all.min() >= 5.0 and all.max() <= 150.0 and far.frames < 240 and near.frames < 240 and _rig.zoom_distance == 5.0)


func _case_wheel_factor() -> void:
	print("\n=== K2 wheel factor")
	var results := []
	for factor in [0.5, 2.0, 0.0, NAN, -1.0, 100.0]:
		await _reset(20.0)
		_wheel(CENTER, true, factor)
		results.append(_rig.zoom_target)
	print("  targets for factors 0.5 / 2 / 0 / NaN / -1 / 100: %s" % str(results))
	_check("a fractional factor counts as a fraction of a notch (0.5 -> %.4f), 2 as two notches (%.4f)" % [results[0], results[1]],
		is_equal_approx(results[0], 20.0 * pow(1.1, 0.5)) and is_equal_approx(results[1], 20.0 * 1.21))
	_check("factor 0, NaN or negative counts as one notch; a huge factor is capped at 10 notches (%.3f)" % results[5],
		is_equal_approx(results[2], 22.0) and is_equal_approx(results[3], 22.0) and is_equal_approx(results[4], 22.0) and is_equal_approx(results[5], 20.0 * pow(1.1, 10)))
	await _reset(20.0)


# --- Pitch -------------------------------------------------------------------------------

func _case_pitch() -> void:
	print("\n=== K3 pitch from the rendered distance")
	var samples := []
	var d := 5.0
	while d <= 150.0:
		samples.append(_rig.pitch_for(d))
		d *= 1.02
	var close := _rig.pitch_degrees as float
	var far := _rig.tactical_pitch_degrees as float
	_check("default pitches: close %.1f° (expected 40°), tactical %.1f° (expected 60°)" % [close, far], is_equal_approx(close, 40.0) and is_equal_approx(far, 60.0))
	_check("pitch_for: %.0f° up to distance 20 (%.2f at 5, %.2f at 20), %.0f° from 100 (%.2f at 100, %.2f at 150), never falling between" % [close, _rig.pitch_for(5.0), _rig.pitch_for(20.0), far, _rig.pitch_for(100.0), _rig.pitch_for(150.0)],
		is_equal_approx(_rig.pitch_for(5.0), close) and is_equal_approx(_rig.pitch_for(20.0), close) and is_equal_approx(_rig.pitch_for(100.0), far)
		and is_equal_approx(_rig.pitch_for(150.0), far) and _monotonic(samples, true))
	# Log-space midpoint of 20 and 100: the smoothstep is at 0.5, so the pitch is halfway.
	var middle := sqrt(20.0 * 100.0)
	_check("pitch_for at the log midpoint (%.2f u): %.2f° (halfway, %.2f°)" % [middle, _rig.pitch_for(middle), (close + far) * 0.5],
		is_equal_approx(_rig.pitch_for(middle), (close + far) * 0.5))
	await _reset(10.0)
	for i in 40:
		_wheel(CENTER, true)
	var r := await _run()
	_check("zooming 10 -> 150 in one burst: the camera pitch equals pitch_for(rendered distance) every frame (largest step %.2f° per frame); ends at %.2f°" % [r.pitch_step, _pitch()],
		r.pitch_ok and is_equal_approx(_pitch(), far))
	await _reset(45.0)
	_wheel(CENTER, true)
	var one := await _run()
	_check("one notch in the middle of the pitch band (45 -> 49.5): pitch %.2f° -> %.2f° over %d frames, largest step %.3f° per frame" % [_rig.pitch_for(45.0), _pitch(), one.frames, one.pitch_step],
		one.pitch_ok and one.pitch_step < 1.0 and _pitch() > _rig.pitch_for(45.0))
	var centred := true
	for zoom in [5.0, 20.0, 45.0, 100.0, 150.0]:
		await _reset(zoom, 30.0, Vector3(12, 0, -7))
		var hit: Variant = _ground(CENTER)
		centred = centred and hit != null and (hit as Vector3).distance_to(Vector3(12, 0, -7)) < 0.01
	_check("the screen centre stays on the pivot at every pitch (zoom 5 / 20 / 45 / 100 / 150)", centred)


# --- Cursor anchoring --------------------------------------------------------------------

func _anchored_zoom(screen: Vector2, from: float, notches: int, out: bool, yaw: float = 0.0, pivot: Vector3 = Vector3.ZERO) -> Dictionary:
	await _reset(from, yaw, pivot)
	var anchor: Variant = _ground(screen)
	for i in notches:
		_wheel(screen, out)
	var r := await _run(240, anchor, screen)
	r["pitch_from"] = _rig.pitch_for(from)
	r["pitch_to"] = _pitch()
	return r


func _case_anchor() -> void:
	print("\n=== K4 cursor anchoring")
	var cases := [
		["centre, 20 -> 111 (pitch close -> tactical)", CENTER, 20.0, 18, true, 0.0],
		["off-centre, 20 -> 111", OFF_CENTER, 20.0, 18, true, 0.0],
		["off-centre, 100 -> 19 (pitch tactical -> close)", OFF_CENTER, 100.0, 17, false, 0.0],
		["near the bottom-right edge, 30 -> 94", _at(0.99, 0.98), 30.0, 12, true, 0.0],
		["near the top-left edge, 30 -> 94", _at(0.02, 0.03), 30.0, 12, true, 0.0],
		["near the top-left edge, 90 -> 29", _at(0.02, 0.03), 90.0, 12, false, 0.0],
		["off-centre, yaw 45, 20 -> 111", OFF_CENTER, 20.0, 18, true, 45.0],
		["off-centre, yaw 200, 100 -> 19", OFF_CENTER, 100.0, 17, false, 200.0],
		["bottom-left, yaw 300, 15 -> 58", _at(0.12, 0.85), 15.0, 14, true, 300.0],
	]
	for c in cases:
		var r: Dictionary = await _anchored_zoom(c[1], c[2], c[3], c[4], c[5])
		_check("anchor %s: drift %.3f px (pitch %.1f° -> %.1f°, %d frames, pivot inside bounds, finite)" % [c[0], r.drift, r.pitch_from, r.pitch_to, r.frames],
			r.drift <= MAX_DRIFT and r.inside and r.finite and r.frames < 240)


func _case_anchor_limits() -> void:
	print("\n=== K5 anchoring at the bounds and without a ground hit")
	# Pivot near the +X / +Z corner; the cursor's ground point lies beyond the bounds, so
	# keeping it under the cursor would need the pivot outside them: the bounds win.
	var r: Dictionary = await _anchored_zoom(_at(0.95, 0.93), 60.0, 15, false, 0.0, Vector3(145, 0, 145))
	_check("bounds: zoom in toward a point beyond the map from (145, 145): pivot stays inside, finite, largest step %.2f u per frame; anchor point %.0f px from the cursor (pinned by the bounds, not asserted)" % [r.jump, r.drift],
		r.inside and r.finite and r.jump < 10.0 and _rig.zoom_distance == _rig.zoom_target)
	r = await _anchored_zoom(_at(0.95, 0.93), 30.0, 15, true, 0.0, Vector3(148, 0, 148))
	# Zooming out there moves the pivot into the map: the anchor holds (a 15-notch burst
	# moves the pivot fast in the first frames; the step is reported, not limited).
	_check("bounds: zoom out at the corner (148, 148): the pivot moves inward, inside and finite (largest step %.2f u per frame); drift %.3f px" % [r.jump, r.drift],
		r.inside and r.finite and r.drift <= MAX_DRIFT)

	# A ray above the horizon (pitch lowered for the test): no anchor, the pivot holds.
	var saved: Array = [_rig.pitch_degrees, _rig.tactical_pitch_degrees]
	_rig.pitch_degrees = 10.0
	_rig.tactical_pitch_degrees = 10.0
	await _reset(30.0, 0.0, Vector3(5, 0, 5))
	var sky := _at(0.5, 0.005)
	var no_hit: bool = _ground(sky) == null or (_ground(sky) as Vector3).distance_to(_camera.global_position) > 1000.0
	for i in 5:
		_wheel(sky, true)
	var s := await _run()
	_check("a cursor above the horizon (no usable ground hit): no anchor, the pivot holds (%s), zoom settles (%.2f), finite" % [_rig.global_position, _rig.zoom_distance],
		no_hit and s.finite and _rig.global_position.distance_to(Vector3(5, 0, 5)) < 0.000001 and _rig.zoom_distance == _rig.zoom_target)
	_rig.pitch_degrees = saved[0]
	_rig.tactical_pitch_degrees = saved[1]
	await _reset(30.0)
	_wheel(Vector2(-100000, -100000), true)
	_wheel(Vector2(1e9, 1e9), false)
	s = await _run()
	_check("wheel events far outside the viewport: no jump (largest step %.2f u), finite, pivot inside" % s.jump, s.finite and s.inside and s.jump < 10.0)


# --- Camera input --------------------------------------------------------------------------

func _case_input() -> void:
	print("\n=== K6 pan, rotation and GUI")
	# W pan during an anchored zoom: the pan wins, the zoom carries on, the anchor is gone.
	await _reset(30.0)
	for i in 12:
		_wheel(OFF_CENTER, true)
	await process_frame
	await process_frame
	var p0: Vector3 = _rig.global_position
	_key(KEY_W, true)
	for i in 10:
		await process_frame
	_key(KEY_W, false)
	await process_frame
	await process_frame
	var cancelled: bool = not _rig._anchored
	var p1: Vector3 = _rig.global_position
	var r := await _run()
	_check("W during an anchored zoom: the pivot pans forward (%.2f u), the anchor is dropped, the zoom still settles (%.2f = target), the pivot then holds" % [p0.distance_to(p1), _rig.zoom_distance],
		p1.z < p0.z - 1.0 and cancelled and _rig.zoom_distance == _rig.zoom_target and _rig.global_position.distance_to(p1) < 0.000001)

	await _reset(30.0)
	for i in 12:
		_wheel(OFF_CENTER, true)
	await process_frame
	var yaw0: float = _rig.rotation.y
	_key(KEY_Q, true)
	for i in 5:
		await process_frame
	_key(KEY_Q, false)
	await process_frame
	await process_frame
	cancelled = not _rig._anchored
	p1 = _rig.global_position
	r = await _run()
	_check("Q during an anchored zoom: the rig yaws (%.1f°), the anchor is dropped, the zoom settles, the pivot then holds" % rad_to_deg(_rig.rotation.y - yaw0),
		_rig.rotation.y > yaw0 + 0.05 and cancelled and _rig.zoom_distance == _rig.zoom_target and _rig.global_position.distance_to(p1) < 0.000001)

	await _reset(30.0)
	for i in 12:
		_wheel(OFF_CENTER, true)
	await process_frame
	yaw0 = _rig.rotation.y
	var drag := InputEventMouseMotion.new()
	drag.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	drag.relative = Vector2(40, 0)
	drag.position = CENTER
	root.push_input(drag, true)
	cancelled = not _rig._anchored
	p1 = _rig.global_position
	r = await _run()
	_check("middle drag during an anchored zoom: the rig yaws (%.1f°), the anchor is dropped, the zoom settles, the pivot holds" % rad_to_deg(_rig.rotation.y - yaw0),
		absf(_rig.rotation.y - yaw0) > 0.1 and cancelled and _rig.zoom_distance == _rig.zoom_target and _rig.global_position.distance_to(p1) < 0.000001)

	# The cursor moves before each wheel event, as in play (hover follows mouse motion).
	await _reset(30.0)
	var blocked := []
	for at in [Vector2(520, 580), Vector2(440, 530)]: # the panel's body, its button
		_hover(at)
		_wheel(at, true)
		_wheel(at, false)
		await process_frame
		blocked.append(_rig.zoom_target == 30.0 and _rig.zoom_distance == 30.0)
	_check("over a UI panel (body %s, button %s) the wheel does not zoom the camera" % blocked, blocked == [true, true])
	_hover(Vector2(800, 550)) # beside the panel, under the full-screen overlay (mouse ignored)
	_wheel(Vector2(800, 550), true)
	_check("beside the panel, under an overlay that ignores the mouse, the wheel zooms (target %.1f)" % _rig.zoom_target, is_equal_approx(_rig.zoom_target, 33.0))
	await _run()


# --- Snaps -----------------------------------------------------------------------------------

func _case_snap() -> void:
	print("\n=== K7 immediate snaps")
	await _reset(20.0)
	for i in 10:
		_wheel(OFF_CENTER, true)
	await process_frame
	await process_frame
	_rig.zoom_distance = 60.0
	_rig._apply_zoom()
	var at_once: bool = _rig.zoom_distance == 60.0 and _rig.zoom_target == 60.0 and is_equal_approx(_pitch(), _rig.pitch_for(60.0)) and not _rig._anchored
	var p0: Vector3 = _rig.global_position
	var held := true
	for i in 10:
		await process_frame
		held = held and _rig.zoom_distance == 60.0 and _rig.global_position == p0
	_check("zoom_distance + _apply_zoom() during a wheel zoom: distance, target and pitch (%.2f°) at once, anchor dropped; nothing moves afterwards" % _pitch(), at_once and held)

	for i in 10:
		_wheel(CENTER, true)
	await process_frame
	_rig.zoom_distance = 12.0 # written without a snap call
	await process_frame
	var raw: bool = _rig.zoom_distance == 12.0 and _rig.zoom_target == 12.0
	await process_frame
	_check("zoom_distance written alone mid-zoom snaps on the next frame and is not pulled back (%.2f, target %.2f)" % [_rig.zoom_distance, _rig.zoom_target],
		raw and _rig.zoom_distance == 12.0)

	var levels := []
	for zoom in [5.0, 27.386, 150.0]:
		await _reset(zoom)
		levels.append(_rig.zoom_level())
	_rig.max_zoom = 40.0
	await _reset(40.0)
	var level_40: float = _rig.zoom_level()
	_rig.max_zoom = 150.0
	_check("zoom_level(): 5 -> %.3f, 27.4 -> %.3f, 150 -> %.3f; with max_zoom 40, distance 40 -> %.3f (the reference scale, not 1)" % [levels[0], levels[1], levels[2], level_40],
		is_equal_approx(levels[0], 0.0) and absf(levels[1] - 0.5) < 0.001 and is_equal_approx(levels[2], 1.0) and absf(level_40 - log(8.0) / log(30.0)) < 0.0001)


# --- Time ------------------------------------------------------------------------------------

func _case_time() -> void:
	print("\n=== K8 real time")
	var frames := []
	for mode in ["1x", "0.25x", "2x", "paused"]:
		Engine.time_scale = {"1x": 1.0, "0.25x": 0.25, "2x": 2.0, "paused": 1.0}[mode]
		paused = mode == "paused"
		await _reset(20.0)
		for i in 4:
			_wheel(CENTER, true)
		var r := await _run()
		frames.append(r.frames)
	Engine.time_scale = 1.0
	paused = false
	_check("the zoom settles in the same number of frames at 1x, 0.25x, 2x and paused (%s)" % str(frames), frames.max() == frames.min() and frames[0] > 5)
