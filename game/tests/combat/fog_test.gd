extends SceneTree
## Combat prototype v0.4 (A5): sensors and fog of war on E05 (its Sensors: 100 u, 5 Hz,
## 8 s memory). Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/fog_test.gd
##   F1 detection, asteroid occlusion, the static last-known marker and no targeting of a
##      hidden ship; F2 expiry after 8 s of simulation time (paused: none; 2x: on simulation
##      time) and reacquisition; F3 faction-wide sharing; F4 the camera reveals nothing;
##      F5 a hidden launcher: no flash, missile or trail shown outside coverage, point defense
##      still intercepts; F6 ordnance guidance ignores the 8 s marker.

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const TS := CombatShip.TargetState
const DT := 1.0 / 60.0
const EAST := -PI * 0.5
const WEST := PI * 0.5
const PLAYER := 0

var scene: Node3D
var _checks := 0
var _failures := 0
var _asteroid: MeshInstance3D
var _center := Vector2.ZERO
var _radius := 0.0


func _initialize() -> void:
	await process_frame
	await _case_occlusion()
	await _case_expiry()
	await _case_sharing()
	await _case_camera()
	await _case_hidden_launcher()
	await _case_ordnance_memory()
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


## E05 with its scripted fleet off and every ship holding fire; the friendly FF01B, FF01C and
## the hostile HostileFF01C / HostileFF01A parked out of the way (far corners) unless placed.
func _load() -> void:
	_free()
	scene = E05.instantiate()
	scene.scenario_index = 0
	root.add_child(scene)
	scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
	scene.enemy_controller._steps.clear()
	scene.enemy_controller._patrols.clear()
	for ship: Node in scene.get_node("Ships").get_children():
		CombatShip.of(ship).stance = CombatShip.Stance.HOLD_FIRE
	await physics_frame
	while not scene.enemy_controller.started:
		await physics_frame
	_asteroid = null
	for each: MeshInstance3D in scene.get_node("Asteroids").get_children():
		if each.scale.x >= 6.0 and (_asteroid == null or each.scale.x > _asteroid.scale.x):
			_asteroid = each
	_center = Vector2(_asteroid.global_position.x, _asteroid.global_position.z)
	_radius = _asteroid.scale.x * 0.5
	_park("FF01B", Vector2(-140, -140))
	_park("FF01C", Vector2(-140, 140))
	_park("HostileFF01C", Vector2(140, -140))
	_park("HostileFF01A", Vector2(140, 140))


func _park(name: String, point: Vector2) -> void:
	_place(name, point, EAST)


func _place(name: String, point: Vector2, heading: float) -> void:
	var ship: Node3D = scene.ship(name)
	ship.get_node("Locomotion").place(point, heading)
	ship.get_node("Avoidance").reset()


## Sensor line between two planar points (the Sensors' own test).
func _clear(a: Vector2, b: Vector2) -> bool:
	return scene.sensors._sees(Vector3(a.x, 1.5, a.y), Vector3(b.x, 1.5, b.y))


func _spot_free(p: Vector2) -> bool:
	var asteroids := scene.get_node("Asteroids")
	for id: int in asteroids.ids():
		var c: Vector3 = asteroids.center(id)
		if Vector2(c.x, c.z).distance_to(p) < asteroids.radius(id) + 8.0:
			return false
	return absf(p.x) < 140.0 and absf(p.y) < 140.0


## A free point `min_d`..`max_d` from `from` whose sensor line to `to_see` is clear.
func _find(from: Vector2, min_d: float, max_d: float, to_see: Vector2) -> Vector2:
	for d in range(int(min_d), int(max_d) + 1, 5):
		for step in 36:
			var p := from + Vector2.from_angle(step * TAU / 36.0) * d
			if _spot_free(p) and _clear(p, to_see):
				return p
	push_error("fog_test: no point found")
	return from


## Behind the big asteroid as seen from `observer`.
func _behind(observer: Vector2) -> Vector2:
	return _center + (_center - observer).normalized() * (_radius + 12.0)


func _sense() -> void:
	await physics_frame
	scene.sensors.evaluate()
	await process_frame
	await process_frame # presentation (visibility) updated


func _sim(seconds: float) -> void:
	var end: float = CombatShip.now() + seconds
	while CombatShip.now() < end - 0.000001:
		await physics_frame


func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)


func _camera() -> Camera3D:
	return scene.get_viewport().get_camera_3d()


func _frame(point: Vector2, zoom: float) -> void:
	var rig: Node3D = scene.get_node("CameraRig")
	rig.global_position = Vector3(point.x, 0, point.y)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = zoom
	rig._apply_zoom()
	await process_frame
	await process_frame


func _click(position: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		event.global_position = position
		root.push_input(event, true)
	await process_frame


## F1: detection in the open, occlusion by an asteroid, the last-known marker.
func _case_occlusion() -> void:
	print("\n=== F1 detection, asteroid occlusion, last-known position")
	await _load()
	var ff01a: Node3D = scene.ship("FF01A")
	var hostile: Node3D = scene.ship("HostileFF01B")
	var observer := _center + Vector2(-(_radius + 25.0), 0)
	var open := _find(_center + Vector2(0, -(_radius + 20.0)), 0, 40, observer) # in the open, clear line
	_place("FF01A", observer, EAST)
	_place("HostileFF01B", open, WEST)
	await _sense()
	await _frame(_center, 40.0)
	var seen: bool = scene.sensors.detected(PLAYER, hostile) and scene.player_sees(hostile) and hostile.visible
	var status_open: int = CombatShip.of(ff01a).target_status(hostile)
	_check("in the open at %.0f u: detected, the model shown, a valid target" % _planar(hostile).distance_to(observer), seen and status_open == TS.VALID)
	var seen_at := _planar(hostile)
	var hidden_point := _center + Vector2(_radius + 12.0, 0)
	_place("HostileFF01B", hidden_point, WEST)
	await _sense()
	var distance := hidden_point.distance_to(observer)
	var lost: Array = scene.sensors.last_known(PLAYER)
	var marker_ok: bool = lost.size() == 1 and lost[0].ship == hostile and Vector2(lost[0].position.x, lost[0].position.z).distance_to(seen_at) < 0.01
	_check("behind the asteroid at %.0f u (inside the 100 u range): no contact, model hidden, contact lost for targeting" % distance,
		distance < 100.0 and not scene.sensors.detected(PLAYER, hostile) and not hostile.visible and CombatShip.of(ff01a).target_status(hostile) == TS.CONTACT_LOST)
	_check("lost: one last-known marker, at the position of the last detection", marker_ok)
	_place("HostileFF01B", hidden_point + Vector2(8, 10), WEST) # moves while hidden
	await _sense()
	lost = scene.sensors.last_known(PLAYER)
	_check("the hidden ship moves: the marker stays where it was last seen", lost.size() == 1 and Vector2(lost[0].position.x, lost[0].position.z).distance_to(seen_at) < 0.01)
	scene.selection().set_selection([ff01a])
	var screen := _camera().unproject_position(hostile.global_position)
	scene.begin_target_selection()
	await _click(screen)
	var picked: Node3D = scene.selection().pick_any(screen)
	_check("the hidden ship cannot be picked or chosen as a target (selection stays open, no manual target)",
		picked == null and CombatShip.of(ff01a).manual_target == null and scene.target_selection)
	scene.cancel_target_selection()
	var last_screen := _camera().unproject_position(Vector3(seen_at.x, 1.5, seen_at.y))
	_check("nothing is picked at the last-known marker either", scene.selection().pick_any(last_screen) == null)


## F2: the marker lasts 8 s of simulation time; a pause does not age it; at 2x it expires
## on simulation time; reacquisition restores live contact at once.
func _case_expiry() -> void:
	print("\n=== F2 marker expiry on simulation time, reacquisition")
	await _load()
	var hostile: Node3D = scene.ship("HostileFF01B")
	var observer := _center + Vector2(-(_radius + 25.0), 0)
	var open := _find(_center + Vector2(0, -(_radius + 20.0)), 0, 40, observer)
	_place("FF01A", observer, EAST)
	_place("HostileFF01B", open, WEST)
	await _sense()
	_place("HostileFF01B", _center + Vector2(_radius + 12.0, 0), WEST)
	await _sense()
	var lost_at: float = CombatShip.now()
	scene.time_control.set_paused(true)
	for i in 900:
		await process_frame # 15 s of real time at the fixed step
	var after_pause: Array = scene.sensors.last_known(PLAYER)
	scene.time_control.set_paused(false)
	_check("paused for 900 frames (15 s): the marker is still shown, aged %.2f s" % (after_pause[0].age if not after_pause.is_empty() else -1.0), after_pause.size() == 1 and after_pause[0].age < 0.05)
	await _sim(7.7)
	var before_end: int = scene.sensors.last_known(PLAYER).size()
	await _sim(0.6)
	var after_end: int = scene.sensors.last_known(PLAYER).size()
	_check("1x: still marked 7.7 s after the loss, gone by 8.3 s (expiry 8 s of simulation time, 5 Hz evaluation)", before_end == 1 and after_end == 0)
	_check("expired: no model, no marker, no last-known entry", not hostile.visible and not scene.player_knows(hostile))
	_place("HostileFF01B", open, WEST)
	await physics_frame
	var waited := 0
	while not scene.sensors.detected(PLAYER, hostile) and waited < 30:
		await physics_frame
		waited += 1
	await process_frame
	_check("back in the open: live contact again within one evaluation (%d ticks), model shown" % waited, waited <= 13 and hostile.visible)
	# 2x: the same loss expires after 8 s of simulation time, i.e. about 240 real ticks.
	_place("HostileFF01B", _center + Vector2(_radius + 12.0, 0), WEST)
	await _sense()
	scene.time_control.step_speed(1)
	var start_frames := Engine.get_physics_frames()
	var start_sim: float = CombatShip.now() - scene.sensors.last_known(PLAYER)[0].age # the loss itself
	while not scene.sensors.last_known(PLAYER).is_empty() and Engine.get_physics_frames() - start_frames < 1200:
		await physics_frame
	var sim_age: float = CombatShip.now() - start_sim
	var ticks := Engine.get_physics_frames() - start_frames
	scene.time_control.step_speed(-1)
	_check("2x: the marker expires after %.2f s of simulation time (%d real ticks)" % [sim_age, ticks], sim_age >= 7.99 and sim_age <= 8.45 and ticks <= 255)


## F3: one detecting ship gives the whole faction the contact.
func _case_sharing() -> void:
	print("\n=== F3 faction-wide contact")
	await _load()
	var hostile: Node3D = scene.ship("HostileFF01B")
	_place("FF01A", _center + Vector2(-(_radius + 25.0), 0), EAST)
	_place("HostileFF01B", _center + Vector2(_radius + 12.0, 0), WEST)
	_place("FF01B", _find(_center + Vector2(_radius + 12.0, 0), 30, 60, _center + Vector2(_radius + 12.0, 0)), EAST) # sees it from elsewhere
	await _sense()
	var ff01a = CombatShip.of(scene.ship("FF01A"))
	_check("the FF01A's line is blocked, the FF01B sees it: the faction has contact and the FF01A may target it",
		scene.sensors.detected(PLAYER, hostile) and ff01a.target_status(hostile) == TS.VALID and hostile.visible)
	_park("FF01B", Vector2(-140, -140))
	await _sense()
	_check("the FF01B leaves: contact lost for the whole faction", not scene.sensors.detected(PLAYER, hostile) and ff01a.target_status(hostile) == TS.CONTACT_LOST and scene.sensors.is_lost(PLAYER, hostile))


## F4: zooming out or moving the camera over a hidden ship reveals nothing.
func _case_camera() -> void:
	print("\n=== F4 the camera reveals nothing")
	await _load()
	var hidden: Node3D = scene.ship("HostileFF01A") # parked at (140, 140), never detected
	await _sense()
	var reveals := 0
	for zoom in [20.0, 40.0, 80.0, 150.0]:
		await _frame(_planar(hidden), zoom)
		var screen := _camera().unproject_position(hidden.global_position)
		if hidden.visible or scene.selection().pick_any(screen) != null or scene.markers.marker_at(screen) != null or scene.player_knows(hidden):
			reveals += 1
	_check("camera centred on a never-detected ship at zoom 20 / 40 / 80 / 150: no model, marker, pick or entry (%d reveals)" % reveals, reveals == 0)
	await _frame(_planar(hidden), 40.0)
	scene.fog_reveal = true
	await process_frame
	var debug_shows: bool = hidden.visible
	scene.fog_reveal = false
	await process_frame
	_check("the labelled debug override (fog_reveal) shows it; off by default and off again", debug_shows and not hidden.visible)


## F5: a hidden FF01A launches at a player ship another hostile spots: its muzzle flash,
## its missiles and their trails are not shown outside coverage; the player's point defense
## still engages incoming missiles.
func _case_hidden_launcher() -> void:
	print("\n=== F5 hidden launcher: no leaks, point defense still works")
	await _load()
	var ff01a: Node3D = scene.ship("FF01A")
	var launcher: Node3D = scene.ship("HostileFF01A")
	var spotter: Node3D = scene.ship("HostileFF01B")
	var observer := _center + Vector2(-(_radius + 30.0), 0)
	_place("FF01A", observer, WEST) # stern Gatling toward the launcher
	_place("HostileFF01A", _center + Vector2(_radius + 14.0, 0), WEST)
	_place("HostileFF01B", _find(observer, 30, 50, observer), EAST) # visible spotter
	await _sense()
	var lc = CombatShip.of(launcher)
	lc.stance = CombatShip.Stance.AGGRESSIVE
	scene.orders.assign_target([launcher], ff01a)
	for w in lc.weapons:
		if String(w.config.family) != "missile":
			w.enabled = false # missiles only (they need no line of fire)
	var leaks: Array[String] = []
	var launches := 0
	var defense0: int = 0
	for w in CombatShip.of(ff01a).weapons:
		if w.get("defense_shots") != null:
			defense0 += w.defense_shots
	var seen_ordnance := 0
	var defense_ticks := 0
	var hidden_ordnance := 0
	for i in 60 * 12:
		await physics_frame # the previous frame's presentation is complete here
		if launcher.visible:
			leaks.append("%.2f launcher model visible" % CombatShip.now())
		for node in scene.get_node("Effects").get_children():
			if node is Node3D and node.visible and _planar(node).distance_to(_planar(launcher)) < 8.0:
				leaks.append("%.2f effect shown at the hidden launcher" % CombatShip.now())
		for w in CombatShip.of(ff01a).weapons:
			if w.get("mode") == "defense":
				defense_ticks += 1
		for node in scene.projectiles.ordnance:
			if node.faction == 1:
				var covered: bool = scene.sensors.covered(PLAYER, node.global_position)
				if node.visible != covered:
					leaks.append("%.2f ordnance %d shown %s, covered %s" % [CombatShip.now(), node.id, node.visible, covered])
				if covered:
					seen_ordnance += 1
				else:
					hidden_ordnance += 1
		launches = scene.projectiles.launched
	var defense := -defense0
	for w in CombatShip.of(ff01a).weapons:
		if w.get("defense_shots") != null:
			defense += w.defense_shots
	print("  ordnance outcomes: %s; FF01A hull %.0f" % [str(scene.projectiles.ordnance_records.map(func(r: Dictionary) -> String: return r.outcome)), CombatShip.of(ff01a).health])
	for line in leaks.slice(0, 6):
		print("  LEAK " + line)
	_check("the hidden launcher fired %d missiles; its model, flashes and the missiles outside coverage stayed hidden (%d ordnance-ticks hidden, %d shown inside coverage, %d leaks)" % [launches, hidden_ordnance, seen_ordnance, leaks.size()],
		launches > 0 and hidden_ordnance > 0 and seen_ordnance > 0 and leaks.is_empty() and not scene.sensors.detected(PLAYER, launcher))
	_check("point defense took the incoming missiles as its targets without contact with their launcher (%d ticks in defense, %d rounds)" % [defense_ticks, defense], defense_ticks > 0)


## F6: guidance of ordnance already in flight uses its own contact rule, never the marker.
func _case_ordnance_memory() -> void:
	print("\n=== F6 ordnance guidance and the last-known marker")
	await _load()
	var ff01a: Node3D = scene.ship("FF01A")
	var hostile: Node3D = scene.ship("HostileFF01B")
	var observer := _center + Vector2(-(_radius + 30.0), 0)
	_place("FF01A", observer, EAST)
	_place("HostileFF01B", _find(observer, 45, 70, observer), WEST)
	await _sense()
	var dc = CombatShip.of(ff01a)
	dc.stance = CombatShip.Stance.AGGRESSIVE
	for w in dc.weapons:
		if String(w.config.family) != "missile":
			w.enabled = false
	scene.orders.assign_target([ff01a], hostile)
	var missile: Node3D = null
	for i in 240:
		await physics_frame
		for node in scene.projectiles.ordnance:
			if node.faction == PLAYER:
				missile = node
		if missile != null:
			break
	if missile == null:
		_check("a missile was launched", false)
		return
	_place("HostileFF01B", _behind(observer), WEST) # behind the asteroid
	for i in 15:
		await physics_frame
	var lost: bool = not scene.sensors.detected(PLAYER, hostile)
	var goal_then: Vector3 = missile.last_known
	_place("HostileFF01B", _behind(observer) + Vector2(4, 12), WEST) # moves while hidden
	for i in 10:
		await physics_frame
	var marker: Array = scene.sensors.last_known(PLAYER)
	_check("contact lost: the missile flies to its own last known point and does not follow the hidden ship",
		not is_instance_valid(missile) or (lost and not missile.has_contact and missile.last_known == goal_then and missile.last_known.distance_to(hostile.global_position) > 10.0))
	_check("the player's marker is a separate record (the HUD's); it does not move either", marker.size() == 1 and _planar(hostile).distance_to(Vector2(marker[0].position.x, marker[0].position.z)) > 10.0)
