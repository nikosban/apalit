extends SceneTree
## Combat prototype v0.4: simulation clock and tactical time checks. Uninterrupted game
## loop on E05 (three FF-01s per side); run with a fixed physics step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/time_test.gd

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const SimClock := preload("res://game/time/sim_clock.gd")
const DT := 1.0 / 60.0
const EPS := 0.000001

class Ticker extends Node:
	var steps := 0
	func _physics_process(_d: float) -> void:
		steps += 1

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _case_clock()
	await _case_process_modes()
	await _case_pause_orders()
	await _case_targeting()
	await _case_reset()
	await _case_paused_route()
	await _case_fast_forward()
	_free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _free() -> void:
	Engine.time_scale = 1.0
	paused = false
	if scene != null and is_instance_valid(scene):
		root.remove_child(scene)
		scene.free()
	scene = null


func _load(hold_fire: bool = true) -> Node3D:
	_free()
	scene = E05.instantiate()
	root.add_child(scene)
	var controller = scene.enemy_controller
	controller._steps.clear()
	controller._triggers.clear()
	controller._patrols.clear()
	if hold_fire:
		for ship: Node in scene.get_node("Ships").get_children():
			CombatShip.of(ship).stance = CombatShip.Stance.HOLD_FIRE # no fire refreshes threats
	await physics_frame
	while not controller.started:
		await physics_frame
	return scene


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


## Simulation clock: one clock per scene, advancing by the scaled physics delta and frozen
## under SceneTree.paused; scenario time and threat expiry follow it.
func _case_clock() -> void:
	print("\n=== C1 simulation clock")
	await _load()
	var clock := SimClock.current()
	_check("one simulation clock in the scene, and it is the current one", clock != null and clock.get_parent() == scene and scene.find_children("*", "", true, false).filter(func(n: Node) -> bool: return n.get_script() == SimClock).size() == 1)
	var controller = scene.enemy_controller
	var always := Ticker.new()
	always.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(always)

	var rates := {}
	for scale: float in [1.0, 0.25, 2.0]:
		Engine.time_scale = scale
		await physics_frame # the new scale applies from this step
		var t0 := CombatShip.now()
		var s0: float = controller.time
		await _ticks(60)
		rates[scale] = [CombatShip.now() - t0, controller.time - s0]
	Engine.time_scale = 1.0
	_check("60 ticks at 1x advance simulation time 1.000 s (%.6f), scenario time likewise (%.6f)" % [rates[1.0][0], rates[1.0][1]], absf(rates[1.0][0] - 1.0) < EPS and absf(rates[1.0][1] - 1.0) < EPS)
	_check("60 ticks at 0.25x advance 0.250 s (%.6f), scenario time likewise (%.6f)" % [rates[0.25][0], rates[0.25][1]], absf(rates[0.25][0] - 0.25) < EPS and absf(rates[0.25][1] - 0.25) < EPS)
	_check("60 ticks at 2x advance 2.000 s (%.6f), scenario time likewise (%.6f)" % [rates[2.0][0], rates[2.0][1]], absf(rates[2.0][0] - 2.0) < EPS and absf(rates[2.0][1] - 2.0) < EPS)

	# A threat registered just before a pause outlasts the pause, then expires on simulation time.
	var ff01b = CombatShip.of(scene.ship("FF01B"))
	var hostile: Node3D = scene.ship("HostileFF01B")
	ff01b.add_threat(hostile)
	var expiry: float = ff01b.threats[hostile]
	var persistence: float = ff01b.rules.threat_persistence
	paused = true
	var t_pause := CombatShip.now()
	var s_pause: float = controller.time
	var a0 := always.steps
	var frames := 0
	while always.steps - a0 < int(ceil(persistence / DT)) + 30:
		await process_frame
		frames += 1
	var real_ticks := always.steps - a0
	_check("paused for %d physics ticks (%.1f s, longer than the %.1f s threat persistence): simulation and scenario time frozen" % [real_ticks, real_ticks * DT, persistence],
		CombatShip.now() == t_pause and controller.time == s_pause and real_ticks > persistence / DT)
	_check("the threat registered before the pause is still current after it, its expiry unchanged", ff01b.is_threat(hostile) and ff01b.threats.get(hostile, -1.0) == expiry)
	paused = false
	Engine.time_scale = 2.0
	var expired_after := -1.0
	var start := CombatShip.now()
	for i in int(ceil(persistence / (2.0 * DT))) + 5:
		await physics_frame
		if expired_after < 0.0 and not ff01b.is_threat(hostile):
			expired_after = CombatShip.now() - t_pause
	Engine.time_scale = 1.0
	_check("at 2x the threat expires after %.3f s of simulation time (persistence %.1f s, %d real ticks)" % [expired_after, persistence, roundi((CombatShip.now() - start) / (2.0 * DT))],
		expired_after >= persistence - EPS and expired_after <= persistence + 2.0 * DT + EPS)
	always.queue_free()


# --- Input helpers (real input events, as the player gives them) ------------------------

func _camera() -> Camera3D:
	return scene.get_viewport().get_camera_3d()


func _screen(point: Vector3) -> Vector2:
	return _camera().unproject_position(point)


func _on_screen(point: Vector3) -> bool:
	return not _camera().is_position_behind(point) and scene.get_viewport().get_visible_rect().has_point(_screen(point))


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


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		root.push_input(event, true)
	await process_frame


# Simulation state that must not change while paused.
func _snapshot() -> Dictionary:
	var state := {"clock": CombatShip.now(), "scenario": scene.enemy_controller.time, "ships": {}, "ordnance": [], "rounds": []}
	for ship: Node3D in scene.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		var weapons := []
		for weapon in combat.weapons:
			weapons.append([weapon.cooldown_left, weapon.reload_left, weapon.ammo, weapon.magazine, weapon.shots, weapon.get("yaw"), weapon.get("pitch")])
		state.ships[ship.name] = [ship.global_transform, combat.health, weapons]
	var projectiles = scene.get_node("Projectiles")
	for node in projectiles.ordnance:
		state.ordnance.append([node.id, node.global_transform, node.velocity, node.age])
	for record in projectiles.active:
		state.rounds.append(record.duplicate())
	return state


## Process modes: input, camera and UI keep processing under pause; every simulation
## node (ships and their components, projectiles, effects, AI, clock) stops.
func _case_process_modes() -> void:
	print("\n=== C2 process modes under pause")
	await _load()
	scene.time_control.set_paused(true)
	await process_frame
	var always := ["CameraRig", "Selection", "CombatHUD", "CombatOverlay", "TimeControl"]
	var running := always.filter(func(name: String) -> bool: return scene.get_node(name).can_process())
	var stopped := []
	var leaking := []
	for node: Node in scene.find_children("*", "", true, false):
		if node.get_script() == null:
			continue
		var simulation := scene.get_node("Ships").is_ancestor_of(node) or node.name in ["SimClock", "Projectiles", "Effects", "OrdnanceTrails", "EnemyController", "CombatOrders", "Contacts", "ThrusterView", "StaticNavigation", "PlanarCollision", "Survey", "Asteroids"]
		if simulation:
			stopped.append(node)
			if node.can_process():
				leaking.append(String(scene.get_path_to(node)))
	_check("paused: camera, selection, HUD, overlay and time control process (%d / %d)" % [running.size(), always.size()], running.size() == always.size())
	_check("paused: none of the %d simulation scripts processes%s" % [stopped.size(), "" if leaking.is_empty() else " (still processing: %s)" % ", ".join(leaking)], leaking.is_empty() and stopped.size() > 20)
	scene.time_control.set_paused(false)


## Tactical pause (brief A1): orders given by real input while paused are accepted and
## executed on resume; nothing in the simulation advances during the pause; the camera
## pans and zooms in real time.
func _case_pause_orders() -> void:
	print("\n=== C3 tactical pause with orders")
	await _load(false)
	var ff01b: Node3D = scene.ship("FF01B")
	var ff01a: Node3D = scene.ship("FF01A")
	var hostile: Node3D = scene.ship("HostileFF01B")
	# A close engagement north-west of the central rock: FF01A and FF01B facing east, the
	# hostile 40 u ahead of FF01A (cannon range).
	for placed: Array in [[ff01a, Vector2(-60, 25), -PI * 0.5], [ff01b, Vector2(-45, 35), -PI * 0.5], [hostile, Vector2(-20, 25), PI * 0.5]]:
		placed[0].get_node("Locomotion").place(placed[1], placed[2])
		placed[0].get_node("Avoidance").reset()
	var rig: Node3D = scene.get_node("CameraRig")
	rig.global_position = Vector3(-45, 0, 22)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = 50.0 # frames both FF-01s, the hostile and both goals
	rig._apply_zoom()
	await _ticks(30) # weapons engage: ordnance, rounds and cooldowns are under way
	var goal_g := Vector2(-35, 35) # 10 u ahead of FF01B
	var goal_d := Vector2(-70, 5)
	for point in [ff01b.global_position, ff01a.global_position, hostile.global_position, Vector3(goal_g.x, 0, goal_g.y), Vector3(goal_d.x, 0, goal_d.y)]:
		if not _on_screen(point):
			_check("test layout: %s on screen (viewport %s)" % [point, scene.get_viewport().get_visible_rect().size], false)
			return
	await _key(KEY_SPACE)
	_check("Space pauses (tree paused, time control paused, HUD reads PAUSED)", paused and scene.time_control.paused and scene.time_control.label().begins_with("PAUSED"))
	var before := _snapshot()
	var pf0 := Engine.get_physics_frames()

	# Select both ships (click, Shift-click), then give each its own MOVE and both a target.
	await _click(_screen(ff01b.global_position))
	await _click(_screen(ff01a.global_position), MOUSE_BUTTON_LEFT, true)
	var both: bool = scene.selection().selected.size() == 2
	await _click(_screen(ff01b.global_position))
	await _click(_screen(Vector3(goal_g.x, 0, goal_g.y)), MOUSE_BUTTON_RIGHT)
	await _click(_screen(ff01a.global_position))
	await _click(_screen(Vector3(goal_d.x, 0, goal_d.y)), MOUSE_BUTTON_RIGHT)
	await _click(_screen(ff01b.global_position))
	await _click(_screen(ff01a.global_position), MOUSE_BUTTON_LEFT, true)
	await _key(KEY_T)
	var held_targeting: bool = scene.target_selection and paused
	await _click(_screen(hostile.global_position))
	await _key(KEY_F2) # stance change while paused
	var fg = ff01b.get_node("RouteFollower")
	var fd = ff01a.get_node("RouteFollower")
	var routed := func(f: Node, goal: Vector2) -> bool:
		return f.status in [RouteFollower.RouteStatus.ROUTE, RouteFollower.RouteStatus.DIRECT] and f.route.size() >= 2 and f.route[f.route.size() - 1].distance_to(goal) < 0.5
	_check("paused: click and Shift-click select both ships", both)
	_check("paused: each ship's MOVE is planned at once (status %s / %s, %d / %d route points)" % [RouteFollower.RouteStatus.keys()[fg.status], RouteFollower.RouteStatus.keys()[fd.status], fg.route.size(), fd.route.size()],
		routed.call(fg, goal_g) and routed.call(fd, goal_d))
	_check("paused: T opens target selection and stays paused; a click on the hostile assigns it to both ships",
		held_targeting and paused and not scene.target_selection and CombatShip.of(ff01b).manual_target == hostile and CombatShip.of(ff01a).manual_target == hostile)
	_check("paused: F2 sets Defensive on both selected ships", CombatShip.of(ff01b).stance == CombatShip.Stance.DEFENSIVE and CombatShip.of(ff01a).stance == CombatShip.Stance.DEFENSIVE)

	# Camera in real time while paused: wheel zoom and a W pan. The wheel sets the requested
	# zoom at once; the rendered zoom starts toward it in the next frame and gets there
	# while the game stays paused.
	var zoom0: float = rig.zoom_distance
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = scene.get_viewport().get_visible_rect().size * 0.5
	root.push_input(wheel, true)
	var requested: bool = rig.zoom_target < zoom0
	await process_frame
	var zoomed: bool = requested and rig.zoom_distance < zoom0 and rig.zoom_distance > rig.zoom_target
	for i in 60:
		await process_frame
	zoomed = zoomed and paused and rig.zoom_distance == rig.zoom_target
	var pan0 := rig.global_position
	var w := InputEventKey.new()
	w.physical_keycode = KEY_W
	w.keycode = KEY_W
	w.pressed = true
	Input.parse_input_event(w)
	for i in 20:
		await process_frame
	w = w.duplicate()
	w.pressed = false
	Input.parse_input_event(w)
	await process_frame
	_check("paused: the wheel sets the requested zoom at once, the rendered zoom follows and settles while paused (%.1f -> %.1f), and W pans (%.2f u)" % [zoom0, rig.zoom_distance, rig.global_position.distance_to(pan0)], zoomed and rig.global_position.distance_to(pan0) > 0.5)

	for i in 120:
		await process_frame
	var after := _snapshot()
	var changed := []
	for key in ["clock", "scenario", "ordnance", "rounds"]:
		if str(before[key]) != str(after[key]):
			changed.append(key)
	for ship_name in before.ships:
		if str(before.ships[ship_name]) != str(after.ships[ship_name]):
			changed.append(ship_name)
	_check("paused for %d engine physics ticks: no ship, weapon, reload, ordnance, round, damage or clock change%s (%d ordnance, %d rounds in flight)" % [Engine.get_physics_frames() - pf0, "" if changed.is_empty() else " (changed: %s)" % ", ".join(changed), before.ordnance.size(), before.rounds.size()],
		changed.is_empty())

	await _key(KEY_SPACE)
	var start_g := Vector2(ff01b.global_position.x, ff01b.global_position.z)
	var start_d := Vector2(ff01a.global_position.x, ff01a.global_position.z)
	await _ticks(600)
	var end_g := Vector2(ff01b.global_position.x, ff01b.global_position.z)
	var end_d := Vector2(ff01a.global_position.x, ff01a.global_position.z)
	_check("resumed: both ships fly their own orders (FF01B %.1f -> %.1f u from its goal, FF01A %.1f -> %.1f u)" % [start_g.distance_to(goal_g), end_g.distance_to(goal_g), start_d.distance_to(goal_d), end_d.distance_to(goal_d)],
		end_g.distance_to(goal_g) < 2.0 and end_d.distance_to(goal_d) < start_d.distance_to(goal_d) - 5.0)
	_check("resumed: the manual target stays assigned", CombatShip.of(ff01b).manual_target == hostile or not CombatShip.of(hostile).alive)


## Automatic target-selection slowdown (brief A2) through real keys and clicks.
func _case_targeting() -> void:
	print("\n=== C4 target selection slowdown")
	await _load()
	var tc = scene.time_control
	var ff01b: Node3D = scene.ship("FF01B")
	var hostile: Node3D = scene.ship("HostileFF01B")
	# E05's fleets start out of sensor contact (an unseen hostile cannot be picked): FF01B and
	# HostileFF01B 40 u apart north-west of the central rock, framed on screen.
	for placed: Array in [[ff01b, Vector2(-60, 25), -PI * 0.5], [hostile, Vector2(-20, 25), PI * 0.5]]:
		placed[0].get_node("Locomotion").place(placed[1], placed[2])
		placed[0].get_node("Avoidance").reset()
	var rig: Node3D = scene.get_node("CameraRig")
	rig.global_position = Vector3(-40, 0, 22)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = 50.0
	rig._apply_zoom()
	await _ticks(30) # sensors update
	await _click(_screen(ff01b.global_position))
	await _key(KEY_EQUAL)
	var fast: bool = Engine.time_scale == 2.0 and tc.scale() == 2.0
	await _key(KEY_T)
	var slowed: bool = Engine.time_scale == 0.25 and tc.scale() == 0.25
	await _key(KEY_T) # repeated: no stacking
	var once: bool = Engine.time_scale == 0.25 and scene.target_selection
	await _click(_screen(hostile.global_position))
	_check("from 2x: T slows to 0.25x, T again changes nothing, the click assigns the target and 2x returns",
		fast and slowed and once and Engine.time_scale == 2.0 and not scene.target_selection and CombatShip.of(ff01b).manual_target == hostile)
	await _key(KEY_T)
	await _key(KEY_ESCAPE)
	_check("from 2x: Esc cancels target selection and 2x returns", Engine.time_scale == 2.0 and not scene.target_selection)
	await _key(KEY_T)
	await _click(_screen(Vector3(-40, 0, 40)), MOUSE_BUTTON_RIGHT)
	var moved: bool = ff01b.get_node("Locomotion").has_destination
	_check("a right-click on empty space cancels target selection without a MOVE; 2x returns", Engine.time_scale == 2.0 and not scene.target_selection and not moved)
	await _key(KEY_T)
	await _key(KEY_MINUS)
	var during := Engine.time_scale == 0.25
	await _key(KEY_ESCAPE)
	_check("speed changed during target selection (2x -> 1x): still 0.25x while open, the new 1x after", during and Engine.time_scale == 1.0 and tc.speed == 1.0)
	await _key(KEY_SPACE)
	await _key(KEY_T)
	var held: bool = paused and scene.target_selection
	await _click(_screen(hostile.global_position))
	var after_assign := paused
	await _key(KEY_T)
	await _key(KEY_ESCAPE)
	_check("paused: target selection stays paused, assigning or canceling leaves it paused", held and after_assign and paused and not scene.target_selection and Engine.time_scale == 1.0)
	await _key(KEY_SPACE)
	await _key(KEY_MINUS)
	await _key(KEY_MINUS)
	var floor_speed := Engine.time_scale == 0.25
	await _key(KEY_KP_ADD)
	await _key(KEY_KP_ADD)
	await _key(KEY_KP_ADD)
	_check("- / = and keypad step 0.25x / 1x / 2x and stop at the ends", floor_speed and Engine.time_scale == 2.0 and tc.label() == "2x")
	await _click(_screen(Vector3(60, 0, 60))) # clears the selection
	await _key(KEY_T)
	_check("T without a selection does not open target selection (no slowdown)", not scene.target_selection and Engine.time_scale == 2.0)


## Replacing the scene (a reset) clears temporary time state (brief 3.3).
func _case_reset() -> void:
	print("\n=== C5 reset clears time state")
	await _load()
	scene.selection().set_selection([scene.ship("FF01B")])
	scene.time_control.step_speed(1)
	scene.begin_target_selection()
	scene.time_control.set_paused(true)
	var set_up: bool = paused and scene.target_selection
	await _replace_scene()
	var normal: bool = not paused and Engine.time_scale == 1.0 and scene.time_control.scale() == 1.0 and not scene.target_selection
	scene.selection().set_selection([scene.ship("FF01B")])
	scene.time_control.step_speed(1)
	var slowed: bool = scene.begin_target_selection() and Engine.time_scale == 0.25
	await _replace_scene()
	_check("paused 2x target selection, then a fresh scene: 1x, unpaused, no selection; a reset from 0.25x likewise",
		set_up and normal and slowed and not paused and Engine.time_scale == 1.0 and not scene.target_selection)


## Frees the scene and adds a fresh E05 in its place, as a reset does (no time state
## restored by the test).
func _replace_scene() -> void:
	var old := scene
	root.remove_child(old)
	old.queue_free()
	scene = E05.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame


## E05 while paused: a MOVE behind an asteroid is planned around it at once (navigation
## queries answer under pause), and the camera pans at the same real-time speed paused,
## at 0.25x and at 1x.
func _case_paused_route() -> void:
	print("\n=== C6 paused routing and camera speed (E05)")
	await _load()
	var ff01a: Node3D = scene.ship("FF01A")
	var from := Vector2(ff01a.global_position.x, ff01a.global_position.z)
	var best: MeshInstance3D = null
	for asteroid: MeshInstance3D in scene.get_node("Asteroids").get_children():
		var c := Vector2(asteroid.global_position.x, asteroid.global_position.z)
		if asteroid.scale.x > 4.0 and (best == null or c.distance_to(from) < Vector2(best.global_position.x, best.global_position.z).distance_to(from)):
			best = asteroid
	var center := Vector2(best.global_position.x, best.global_position.z)
	var goal := center + (center - from).normalized() * (best.scale.x * 0.5 + 12.0)
	scene.time_control.set_paused(true)
	await process_frame
	var given: bool = scene.orders.move([ff01a], goal)
	var follower = ff01a.get_node("RouteFollower")
	_check("paused: a MOVE behind the asteroid at (%.0f, %.0f) is routed around it at once (%s, %d points)" % [center.x, center.y, RouteFollower.RouteStatus.keys()[follower.status], follower.route.size()],
		given and follower.status == RouteFollower.RouteStatus.ROUTE and follower.route.size() > 2)
	var pans := []
	var settle := []
	for mode in ["paused", "0.25x", "1x"]:
		if mode == "0.25x":
			scene.time_control.set_paused(false)
			scene.time_control.step_speed(-1)
		elif mode == "1x":
			scene.time_control.step_speed(1)
		var rig: Node3D = scene.get_node("CameraRig")
		if mode == "paused":
			rig.zoom_distance = 40.0 # every mode pans and zooms from the same distance
			rig._apply_zoom()
		var pan0 := rig.global_position
		var w := InputEventKey.new()
		w.physical_keycode = KEY_D
		w.keycode = KEY_D
		w.pressed = true
		Input.parse_input_event(w)
		for i in 30:
			await process_frame
		var up: InputEventKey = w.duplicate()
		up.pressed = false
		Input.parse_input_event(up)
		await process_frame
		pans.append(rig.global_position.distance_to(pan0))
		# Zoom smoothing in real time: one wheel notch out from 40 and the frames until the
		# rendered zoom settles, then back to 40 for the next mode.
		rig.zoom_distance = 40.0
		rig._apply_zoom()
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
		wheel.pressed = true
		wheel.position = scene.get_viewport().get_visible_rect().size * 0.5
		root.push_input(wheel, true)
		var frames := 0
		while rig.zoom_distance != rig.zoom_target and frames < 240:
			await process_frame
			frames += 1
		settle.append(frames)
		rig.zoom_distance = 40.0
		rig._apply_zoom()
	_check("the camera pans the same distance in 30 frames paused, at 0.25x and at 1x (%.2f / %.2f / %.2f u)" % pans,
		absf(pans[0] - pans[2]) < 0.05 and absf(pans[1] - pans[2]) < 0.05 and pans[2] > 1.0)
	_check("one wheel notch settles in the same number of frames paused, at 0.25x and at 1x (%d / %d / %d)" % settle,
		settle[0] == settle[1] and settle[1] == settle[2] and settle[0] > 5 and settle[0] < 240)


## Fast-forward safety: the E05 battle without player orders at 1x and at 2x (60 Hz ticks,
## twice the step). Physical limits per tick, weapon cooldowns and magazine reloads in
## simulation time and hull separation are checked; the outcome is reported only.
func _case_fast_forward() -> void:
	print("\n=== C7 fast-forward safety (E05, passive)")
	var runs := {}
	for scale: float in [1.0, 2.0]:
		runs[scale] = await _battle_run(scale)
		var r: Dictionary = runs[scale]
		print("  %sx: %s at %.1f s; shots %d (%s); rounds %s; ordnance %s; missile ticks %d; min hull gap %.2f u; reloads %d" % [
			scale, r.winner, r.elapsed, r.shots, str(r.families), str(r.rounds), str(r.ordnance), r.missile_ticks, r.min_gap, r.reloads])
		_check("%sx: every powered missile tick within acceleration, turn rate and speed for its step (%d violations)" % [scale, r.missile_bad.size()], r.missile_bad.is_empty() and r.missile_ticks > 0)
		_check("%sx: every weapon's shots at least its cooldown apart in simulation time (%d violations)" % [scale, r.cooldown_bad.size()], r.cooldown_bad.is_empty() and r.shots > 0)
		_check("%sx: every magazine reload lasts its reload time in simulation time (%d of %d off by more than one step)" % [scale, r.reload_bad.size(), r.reloads], r.reload_bad.is_empty())
		_check("%sx: hulls never overlap (closest %.2f u)" % [scale, r.min_gap], r.min_gap > -0.05)
		for line in (r.missile_bad + r.cooldown_bad + r.reload_bad).slice(0, 8):
			print("    " + line)


func _battle_run(scale: float) -> Dictionary:
	await _load(false)
	var r := {"winner": "unfinished", "elapsed": 0.0, "shots": 0, "families": {}, "rounds": {}, "ordnance": {}, "missile_ticks": 0,
		"missile_bad": [], "cooldown_bad": [], "reload_bad": [], "reloads": 0, "min_gap": INF}
	var step := DT * scale
	var last_shot := {}
	var reload_from := {}
	for ship: Node3D in scene.get_node("Ships").get_children():
		for weapon in CombatShip.of(ship).weapons:
			weapon.shot.connect(func(w: Node, _id: int, _t: Node3D, _o: Transform3D) -> void:
				var now := CombatShip.now()
				r.shots += 1
				r.families[String(w.config.family)] = r.families.get(String(w.config.family), 0) + 1
				var key := w.get_instance_id()
				# A salvo (v0.4) is one firing cycle: its launches follow each other at the salvo
				# interval; the cooldown applies between the first launches of salvos.
				var salvo: int = w.get("salvo_size") if w.get("salvo_size") != null else 1
				var entry: Dictionary = last_shot.get(key, {})
				# Launches fall on physics steps: an interval that is not a whole number of steps
				# (the Barrage's 0.12 s) is met within one step.
				if not entry.is_empty() and salvo > 1 and entry.count < salvo and absf(now - entry.last - w.salvo_interval) <= step + 0.0001:
					entry.count += 1
					entry.last = now
					return
				if not entry.is_empty() and now - entry.start < w.config.cooldown - step * 0.5:
					r.cooldown_bad.append("%.3f %s %s: %.3f s after the previous firing cycle (cooldown %.2f)" % [now, w.ship.name, w.name, now - entry.start, w.config.cooldown])
				last_shot[key] = {"start": now, "last": now, "count": 1})
			weapon.reload_started.connect(func(w: Node, _cause: String) -> void: reload_from[w.get_instance_id()] = CombatShip.now())
			weapon.reload_finished.connect(func(w: Node, _moved: int) -> void:
				var key := w.get_instance_id()
				if reload_from.has(key):
					r.reloads += 1
					var took: float = CombatShip.now() - reload_from[key]
					if absf(took - w.config.reload_time) > step + EPS:
						r.reload_bad.append("%s %s: reload %.3f s (configured %.2f)" % [w.ship.name, w.name, took, w.config.reload_time])
					reload_from.erase(key))
	scene.time_control.speed = scale
	scene.time_control._apply()
	var battle := scene.get_node("FleetBattle")
	var missiles := {}
	var ships := scene.get_node("Ships")
	for i in roundi(300.0 / step):
		await physics_frame
		for node in scene.get_node("Projectiles").ordnance:
			if node.kind != &"missile":
				continue
			var c: Resource = node.config
			if missiles.has(node.id) and missiles[node.id].phase == "powered":
				var s: Dictionary = missiles[node.id]
				r.missile_ticks += 1
				if node.velocity.distance_to(s.v) > c.acceleration * step + 0.0001:
					r.missile_bad.append("missile %d: velocity change %.3f in one step" % [node.id, node.velocity.distance_to(s.v)])
				if (s.nose as Vector3).angle_to(node.forward()) > deg_to_rad(c.turn_rate_deg) * step + 0.000001:
					r.missile_bad.append("missile %d: turn %.3f deg in one step" % [node.id, rad_to_deg((s.nose as Vector3).angle_to(node.forward()))])
				if node.velocity.length() > c.max_speed + 0.0001:
					r.missile_bad.append("missile %d: above maximum speed" % node.id)
			missiles[node.id] = {"v": node.velocity, "nose": node.forward(), "phase": node.phase}
		var list := ships.get_children()
		for a in list.size():
			for b in range(a + 1, list.size()):
				var pa: Node3D = list[a]
				var pb: Node3D = list[b]
				var gap: float = Vector2(pa.global_position.x - pb.global_position.x, pa.global_position.z - pb.global_position.z).length() \
					- pa.get_node("RouteFollower").ship_radius - pb.get_node("RouteFollower").ship_radius
				r.min_gap = minf(r.min_gap, gap)
		if battle.finished:
			r.winner = ["VICTORY", "DEFEAT", "DRAW"][battle.winner]
			break
	r.elapsed = battle.elapsed if battle.finished else scene.enemy_controller.time
	var projectiles = scene.get_node("Projectiles")
	for record in projectiles.records:
		r.rounds[record.outcome] = r.rounds.get(record.outcome, 0) + 1
	for record in projectiles.ordnance_records:
		r.ordnance[record.outcome] = r.ordnance.get(record.outcome, 0) + 1
	return r
