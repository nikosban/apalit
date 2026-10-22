extends SceneTree
## Phase B (Local / Tactical semantic zoom): the 3D models stay visible at every zoom, the
## tactical markers fade in over them with one continuous emphasis, and picking,
## selection and commands resolve to the same ship whether a marker or a hull is clicked.
## B1 on E05 (ships; the fog of war is fog_test's), through real wheel, click and key input;
## B2 on the playable main scene (stations, individual asteroids, ships). Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/tactical_view_test.gd

const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const MAIN := preload("res://main.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _load_e05()
	await _case_continuity()
	await _case_picking()
	await _case_overlap()
	await _case_selection_blend()
	await _case_box_and_commands()
	await _case_ui_blocking()
	_unload()
	await _load_main()
	await _case_objects_shown()
	await _case_object_alignment()
	await _case_station_interaction()
	await _case_asteroid_interaction()
	await _case_paused()
	await _case_removal()
	_unload()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _unload() -> void:
	if scene != null:
		root.remove_child(scene)
		scene.free()
		scene = null


func _load_e05() -> void:
	scene = E05.instantiate()
	scene.scenario_index = 4
	var sensors := scene.get_node("Sensors") # Every ship visible; fog_test covers detection.
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


func _screen(point: Vector3) -> Vector2:
	return _camera().unproject_position(point)


func _centre() -> Vector2:
	return scene.get_viewport().get_visible_rect().size * 0.5


func _set_zoom(zoom: float) -> void:
	_rig().zoom_distance = zoom
	_rig()._apply_zoom()
	await process_frame
	await process_frame


func _look_at(point: Vector3, zoom: float) -> void:
	_rig().rotation = Vector3.ZERO
	_rig().global_position = Vector3(point.x, 0.0, point.z)
	await _set_zoom(zoom)


func _wheel(up: bool, notches: int) -> void:
	for i in notches:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
		event.pressed = true
		event.position = _centre()
		root.push_input(event, true)


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


func _drag(from: Vector2, to: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	root.push_input(press, true)
	var motion := InputEventMouseMotion.new()
	motion.position = to
	root.push_input(motion, true)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = to
	root.push_input(release, true)
	await process_frame


func _own_ships() -> Array:
	return scene.get_node("Ships").get_children().filter(func(s: Node3D) -> bool: return CombatShip.of(s).faction == scene.PLAYER_FACTION)


func _all_visible() -> bool:
	return scene.get_node("Ships").get_children().all(func(s: Node3D) -> bool: return s.visible)


# Frames of the rendered zoom settling on its target: [emphasis per frame, models always shown].
func _follow(limit: int) -> Array:
	var values := []
	var shown := true
	var frames := 0
	while frames < limit:
		await process_frame
		frames += 1
		values.append(scene.markers.emphasis())
		shown = shown and _all_visible()
		if _rig().zoom_distance == _rig().zoom_target:
			break
	return [values, shown]


static func _monotonic(values: Array, rising: bool) -> bool:
	for i in range(1, values.size()):
		if (values[i] < values[i - 1] - 1e-9) if rising else (values[i] > values[i - 1] + 1e-9):
			return false
	return true


static func _max_step(values: Array) -> float:
	var step := 0.0
	for i in range(1, values.size()):
		step = maxf(step, absf(values[i] - values[i - 1]))
	return step


## B1-1: models stay rendered and the emphasis changes continuously in both directions,
## while the camera interpolates, also when the zoom reverses mid-transition.
func _case_continuity() -> void:
	print("\n=== B1-1 continuous emphasis, models kept")
	await _look_at(Vector3.ZERO, 20.0)
	var start: float = scene.markers.emphasis()
	_wheel(false, 25)
	var out: Array = await _follow(240)
	var values: Array = out[0]
	var between := values.filter(func(e: float) -> bool: return e > 0.02 and e < 0.98).size()
	_check("zoom out 20 -> 150 (one burst): emphasis %.3f -> %.3f rising only, %d frames in between, models shown every frame" % [start, values[-1], between],
		start == 0.0 and values[-1] == 1.0 and _monotonic(values, true) and between >= 5 and out[1])
	_wheel(true, 25)
	var back: Array = await _follow(240)
	_check("zoom in 150 -> 20: emphasis falls only, back to %.3f, models shown every frame" % back[0][-1],
		back[0][-1] == 0.0 and _monotonic(back[0], false) and back[1])
	await _set_zoom(50.0)
	var steps := []
	for notch in 8:
		var before: float = scene.markers.emphasis()
		_wheel(false, 1)
		var one: Array = await _follow(240)
		steps.append(_max_step([before] + one[0]))
	print("  largest per-frame emphasis step, single notches from zoom 50: %s" % str(steps.map(func(x: float) -> float: return snappedf(x, 0.0001))))
	_check("single wheel notches through the transition: largest per-frame emphasis change %.4f (< 0.05, no pop)" % steps.max(), steps.max() < 0.05)
	await _set_zoom(30.0)
	var reversal := []
	var shown := true
	_wheel(false, 12)
	for i in 6:
		await process_frame
		reversal.append(scene.markers.emphasis())
		shown = shown and _all_visible()
	var peak: float = reversal[-1]
	_wheel(true, 12)
	_rig().global_position += Vector3(4.0, 0.0, -3.0) # The camera moves during the transition.
	var after: Array = await _follow(240)
	reversal.append_array(after[0])
	print("  emphasis per frame: %s" % str(reversal.map(func(x: float) -> float: return snappedf(x, 0.001))))
	var finite := reversal.all(func(e: float) -> bool: return is_finite(e) and e >= 0.0 and e <= 1.0)
	_check("rapid reversal (12 notches out, 6 frames, 12 back, camera moved): emphasis peaks at %.3f, falls back to %.6f, stays in [0, 1], models shown" % [peak, reversal[-1]],
		peak > 0.0 and reversal[-1] < 1e-6 and finite and _monotonic(after[0], false) and shown and after[1])


## B1-2: a marker picks only while interactive; a hull click outside the marker still
## picks; both select the same ship node.
func _case_picking() -> void:
	print("\n=== B1-2 marker and hull picking")
	var destroyer: Node3D = scene.ship("Destroyer")
	var markers = scene.markers
	await _look_at(destroyer.global_position, 45.0)
	var centre := _screen(destroyer.global_position)
	_check("zoom 45 (emphasis %.2f < %.2f): the marker takes no clicks; the hull pick finds the Destroyer" % [markers.emphasis(), markers.interactive_emphasis],
		markers.emphasis() < markers.interactive_emphasis and markers.marker_at(centre) == null and scene.selection().pick(centre) == destroyer)
	await _look_at(destroyer.global_position, 70.0)
	centre = _screen(destroyer.global_position)
	scene.selection().set_selection([])
	await _click(centre)
	var by_marker: Array = scene.selection().selected.duplicate()
	var hull_point := Vector2.INF
	var axis := destroyer.global_basis.z.normalized()
	for side in [1.0, -1.0]:
		for i in 40:
			var candidate := _screen(destroyer.global_position + axis * side * (1.0 + i * 0.25))
			if markers.marker_at(candidate) == null and scene.selection().pick(candidate) == destroyer:
				hull_point = candidate
				break
		if hull_point != Vector2.INF:
			break
	scene.selection().set_selection([])
	if hull_point != Vector2.INF:
		await _click(hull_point)
	var by_hull: Array = scene.selection().selected.duplicate()
	_check("zoom 70 (emphasis %.2f): a click on the marker and a click on the hull %.0f px from it (outside the marker) select the same ship %s" % [markers.emphasis(), hull_point.distance_to(centre), str(by_hull)],
		markers.marker_at(centre) == destroyer and by_marker == [destroyer] and by_hull == [destroyer])
	var hostile: Node3D = scene.ship("HostileDestroyer")
	await _look_at(hostile.global_position, 150.0)
	scene.selection().set_selection([])
	await _click(_screen(hostile.global_position))
	_check("a hostile's marker picks it for targeting (pick_any) but never selects it", scene.selection().pick_any(_screen(hostile.global_position)) == hostile and scene.selection().selected.is_empty())


## B1-3: overlapping markers resolve by the nearest marker centre, then by Ships order.
func _case_overlap() -> void:
	print("\n=== B1-3 overlapping markers")
	var own := _own_ships()
	var first: Node3D = own[0]
	var second: Node3D = own[1]
	first.get_node("Locomotion").place(Vector2(-60, -60), 0.0)
	second.get_node("Locomotion").place(Vector2(-58, -60), 0.0)
	await physics_frame
	await _look_at(Vector3(-59, 0, -60), 150.0)
	var a := _screen(first.global_position)
	var b := _screen(second.global_position)
	var markers = scene.markers
	var near_a: Node3D = markers.marker_at(a.lerp(b, 0.3))
	var near_b: Node3D = markers.marker_at(a.lerp(b, 0.7))
	var middle := []
	for i in 5:
		middle.append(markers.marker_at(a.lerp(b, 0.5)))
	var order_first: bool = first.get_index() < second.get_index()
	_check("markers %.1f px apart (overlapping): nearer A -> A, nearer B -> B, the midpoint -> the earlier ship under Ships, the same 5 times" % a.distance_to(b),
		a.distance_to(b) < 2.0 * markers.hit_size(first) and near_a == first and near_b == second
		and middle.all(func(s: Node3D) -> bool: return s == (first if order_first else second)))


## B1-4: selection survives the transition; the ring fades out as the brackets fade in.
func _case_selection_blend() -> void:
	print("\n=== B1-4 selection across the transition")
	var gunship: Node3D = scene.ship("Gunship")
	await _look_at(gunship.global_position, 20.0)
	await _click(_screen(gunship.global_position))
	var selection = scene.selection()
	var ring: MeshInstance3D = selection._rings[gunship]
	var ring_close: bool = ring.visible and is_equal_approx(selection._ring_material.albedo_color.a, 1.0)
	_wheel(false, 25)
	var kept := true
	var blended := true
	for i in 120:
		await process_frame
		kept = kept and selection.selected == [gunship]
		blended = blended and is_equal_approx(selection._ring_material.albedo_color.a + scene.markers.emphasis(), 1.0)
		if _rig().zoom_distance == _rig().zoom_target:
			break
	await process_frame
	var ring_far: bool = not ring.visible
	_wheel(true, 25)
	for i in 120:
		await process_frame
		kept = kept and selection.selected == [gunship]
		if _rig().zoom_distance == _rig().zoom_target:
			break
	await process_frame
	_check("selected at zoom 20 (ring opaque), zoomed to 150 and back: still [Gunship] every frame; ring alpha + marker emphasis = 1 every frame; ring hidden at 150, back at 20",
		ring_close and kept and blended and ring_far and ring.visible)


## B1-5: box selection and commands at full Tactical emphasis.
func _case_box_and_commands() -> void:
	print("\n=== B1-5 box selection and commands at Tactical zoom")
	var own := _own_ships()
	await _look_at(Vector3(-59, 0, -60), 150.0)
	var a := _screen(own[0].global_position)
	var b := _screen(own[1].global_position)
	var box := Rect2(a, Vector2.ZERO).expand(b).grow(20.0)
	scene.selection().set_selection([])
	await _drag(box.position, box.end)
	var boxed: Array = scene.selection().selected
	_check("a drag box around two markers selects both ships (%d)" % boxed.size(), boxed.size() == 2 and boxed.has(own[0]) and boxed.has(own[1]))
	var hostile: Node3D = scene.ship("HostileGunship")
	await _look_at(hostile.global_position, 150.0)
	await _click(_screen(hostile.global_position), MOUSE_BUTTON_RIGHT)
	_check("a right-click on a hostile marker targets it for both selected ships",
		CombatShip.of(own[0]).manual_target == hostile and CombatShip.of(own[1]).manual_target == hostile)
	var goal := Vector3(hostile.global_position.x + 30.0, 0.0, hostile.global_position.z)
	await _click(_screen(goal), MOUSE_BUTTON_RIGHT)
	_check("a right-click on open ground gives both a destination near the clicked point",
		own[0].get_node("Locomotion").has_destination and own[1].get_node("Locomotion").has_destination)


## B1-6: a GUI panel over a marker keeps input priority.
func _case_ui_blocking() -> void:
	print("\n=== B1-6 UI panels keep input priority")
	var gunship: Node3D = scene.ship("Gunship")
	await _look_at(gunship.global_position, 150.0)
	var centre := _screen(gunship.global_position)
	var layer := CanvasLayer.new()
	layer.layer = 5
	var panel := Panel.new()
	panel.position = centre - Vector2(40, 40)
	panel.size = Vector2(80, 80)
	layer.add_child(panel)
	scene.add_child(layer)
	await process_frame
	scene.selection().set_selection([])
	var motion := InputEventMouseMotion.new()
	motion.position = centre
	root.push_input(motion, true)
	await process_frame
	await _click(centre)
	var blocked: bool = scene.selection().selected.is_empty()
	layer.queue_free()
	await process_frame
	await process_frame
	await _click(centre)
	_check("a click on a GUI panel over the Gunship's marker selects nothing; with the panel gone the same click selects it",
		blocked and scene.selection().selected == [gunship])


func _load_main() -> void:
	scene = MAIN.instantiate()
	root.add_child(scene)
	scene.get_node("Survey").set_physics_process(false)
	scene.get_node("WorldHighlight").set_process(false) # Headless has no cursor: hover is given explicitly.
	await process_frame
	await process_frame


func _entries_by_target() -> Dictionary:
	var result := {}
	for entry: Dictionary in scene.markers.object_entries():
		result[entry.target] = result.get(entry.target, 0) + 1
	return result


# Asteroid ids whose centre projects inside the visible rect.
func _asteroids_on_screen() -> Array:
	var field = scene.get_node("Asteroids")
	var view := scene.get_viewport().get_visible_rect()
	return field.ids().filter(func(id: int) -> bool:
		var point: Vector3 = field.node_of(id).global_position
		return not _camera().is_position_behind(point) and view.has_point(_screen(point)))


# Largest distance between a station / asteroid marker and its object's projected centre.
func _worst_offset() -> float:
	var worst := 0.0
	for entry: Dictionary in scene.markers.object_entries():
		worst = maxf(worst, (entry.position as Vector2).distance_to(_screen((entry.target as Node3D).global_position)))
	return worst


## B2-1: every object class keeps its model and gets its own marker, one per object.
func _case_objects_shown() -> void:
	print("\n=== B2-1 stations and individual asteroids: models kept, one marker each")
	var field = scene.get_node("Asteroids")
	var markers = scene.markers
	var stations: Array = scene.get_node("Stations").get_children()
	await _look_at(Vector3(-50, 0, -20), 150.0)
	var counts := _entries_by_target()
	var on_screen := _asteroids_on_screen()
	var asteroid_ids: Array = markers.object_entries().filter(func(e: Dictionary) -> bool: return e.asteroid >= 0).map(func(e: Dictionary) -> int: return e.asteroid)
	var all_once: bool = counts.values().all(func(n: int) -> bool: return n == 1)
	var every_asteroid: bool = on_screen.all(func(id: int) -> bool: return asteroid_ids.has(id))
	var stations_marked := stations.filter(func(st: Node3D) -> bool: return counts.has(st)).size()
	var models: bool = field.ids().all(func(id: int) -> bool: return field.node_of(id).is_visible_in_tree()) and stations.all(func(st: Node3D) -> bool: return st.is_visible_in_tree()) and _all_visible()
	print("  zoom 150: %d asteroid markers (%d asteroids on screen of %d), %d of %d stations marked" % [asteroid_ids.size(), on_screen.size(), field.ids().size(), stations_marked, stations.size()])
	_check("zoom 150 (emphasis %.2f): every on-screen asteroid has exactly one marker by its own id, every station one, no duplicates; all models shown" % markers.emphasis(),
		markers.emphasis() == 1.0 and every_asteroid and all_once and stations_marked == stations.size() and models)
	var colours := {}
	for entry: Dictionary in markers.object_entries():
		if entry.asteroid >= 0:
			colours[entry.color] = true
	var survey: Array = [markers.SurveyView.UNKNOWN_COLOR, markers.SurveyView.MINERALS_COLOR, markers.SurveyView.ICE_COLOR]
	var quiet: bool = markers.ASTEROID_SIZE < markers.STATION_SIZE and markers.ASTEROID_SIZE < markers.BASE_SIZE and markers.ASTEROID_ALPHA < 1.0
	_check("asteroid markers are smaller and fainter than station and ship markers (%.0f / %.0f / %.0f px, alpha %.1f) in the survey colours (%d colour(s) now)" % [markers.ASTEROID_SIZE, markers.STATION_SIZE, markers.BASE_SIZE, markers.ASTEROID_ALPHA, colours.size()],
		quiet and colours.keys().all(func(c: Color) -> bool: return survey.has(c)))
	await _look_at(Vector3(-50, 0, -20), 20.0)
	_check("zoom 20: emphasis 0, so the object markers draw nothing (their alpha is the emphasis); models shown",
		markers.emphasis() == 0.0 and stations.all(func(st: Node3D) -> bool: return st.is_visible_in_tree()))
	var highlight = scene.get_node("WorldHighlight")
	await _look_at(Vector3(-50, 0, -20), 150.0)
	var asteroid: Node3D = field.node_of(on_screen[0])
	highlight.update(_screen(asteroid.global_position), true)
	var marked_once: bool = not _entries_by_target().has(asteroid) and scene.get_node("ObjectMarkers").entries().any(func(e: Dictionary) -> bool: return e.target == asteroid)
	highlight.update(Vector2(-100, -100), true)
	_check("a hovered asteroid is marked once, by ObjectMarkers, not twice; unhovered, its tactical marker is back",
		marked_once and _entries_by_target().has(asteroid))


## B2-2: markers stay on their objects when the camera yaws, pitches (zoom) and pans.
func _case_object_alignment() -> void:
	print("\n=== B2-2 alignment under camera yaw, pitch and pan")
	var worst := 0.0
	for pose in [[Vector3(-50, 0, -20), 0.0, 150.0], [Vector3(-30, 0, 10), 37.0, 90.0], [Vector3(-60, 0, -40), -120.0, 120.0]]:
		_rig().global_position = pose[0]
		_rig().rotation = Vector3(0, deg_to_rad(pose[1]), 0)
		await _set_zoom(pose[2])
		worst = maxf(worst, _worst_offset())
	_rig().rotation = Vector3.ZERO
	_check("three camera poses (yaw 0 / 37 / -120°, zoom 150 / 90 / 120): every marker at its object's projected centre (worst %.4f px)" % worst, worst < 0.01)


## B2-3: a station's marker lies inside its model's pick, so clicking it selects the
## station (existing station selection) and a right-click docks there (existing command).
func _case_station_interaction() -> void:
	print("\n=== B2-3 station markers and the existing station interactions")
	var hover = scene.get_node("AsteroidHover")
	var panel = scene.get_node("StationPanel")
	var markers = scene.markers
	var report := []
	for station: Node3D in scene.get_node("Stations").get_children():
		for zoom in [70.0, 100.0, 150.0]:
			await _look_at(station.global_position, zoom)
			var centre := _screen(station.global_position)
			var half: float = markers.STATION_SIZE * markers.scale_factor() * 0.92 * 0.7072 # The square's half side.
			var misses := 0
			for gx in 5:
				for gy in 5:
					if hover.station_at(centre + Vector2(lerpf(-half, half, gx / 4.0), lerpf(-half, half, gy / 4.0))) != station:
						misses += 1
			report.append(misses)
	_check("every station at zoom 70 / 100 / 150: all 25 points of its marker square pick that station (misses %s)" % str(report), report.all(func(n: int) -> bool: return n == 0))
	var station: Node3D = scene.get_node("Stations").get_child(0)
	await _look_at(station.global_position, 150.0)
	scene.selection().set_selection([])
	await _click(_screen(station.global_position))
	_check("a click on the station's marker selects that station (station panel: %s)" % str(panel.station), panel.station == station)
	var miner: Node3D = scene.ship("Miner1")
	scene.selection().set_selection([miner])
	var command: Dictionary = scene.resolve_command(_screen(station.global_position))
	scene.selection().set_selection([])
	_check("a right-click on the station's marker with a miner selected resolves to DOCK at that station",
		command.get("kind") == scene.CommandKind.DOCK and command.get("station") == station)


## B2-4: an asteroid's marker lies inside its model's pick (hover, MINE unchanged), and
## asteroid markers never take a click from a ship.
func _case_asteroid_interaction() -> void:
	print("\n=== B2-4 asteroid markers, mining command and ship priority")
	var field = scene.get_node("Asteroids")
	var markers = scene.markers
	await _look_at(Vector3(-50, 0, -20), 150.0)
	var misses := 0
	var tested := 0
	var size: float = markers.ASTEROID_SIZE * markers.scale_factor()
	for entry: Dictionary in markers.object_entries():
		if entry.asteroid < 0:
			continue
		for offset in [Vector2.ZERO, Vector2(size, 0), Vector2(-size, 0), Vector2(0, size), Vector2(0, -size)]:
			var point: Vector2 = entry.position + offset
			tested += 1
			if field.pick(_camera().project_ray_origin(point), _camera().project_ray_normal(point)) != entry.asteroid:
				misses += 1
	_check("zoom 150: the centre and four corners of every asteroid marker pick that asteroid (%d of %d points miss)" % [misses, tested], misses == 0 and tested > 0)
	var id: int = _asteroids_on_screen()[0]
	var asteroid: Node3D = field.node_of(id)
	await _look_at(asteroid.global_position, 150.0)
	scene.selection().set_selection([scene.ship("Miner1")])
	var command: Dictionary = scene.resolve_command(_screen(asteroid.global_position))
	_check("a right-click on an asteroid's marker with a miner selected resolves to MINE that asteroid (id %d)" % id,
		command.get("kind") == scene.CommandKind.MINE and command.get("asteroid") == id)
	var gunship: Node3D = scene.ship("Gunship")
	gunship.get_node("Locomotion").place(Vector2(asteroid.global_position.x + field.radius(id) + 2.5, asteroid.global_position.z), 0.0)
	await physics_frame
	await _look_at(asteroid.global_position, 150.0)
	scene.selection().set_selection([])
	await _click(_screen(gunship.global_position))
	_check("a ship parked beside an asteroid (markers %.1f px apart): a click on the ship's marker selects the ship" % _screen(gunship.global_position).distance_to(_screen(asteroid.global_position)),
		scene.selection().selected == [gunship])


## B2-5: paused, the overlays still follow the camera (they are presentation, always processing).
func _case_paused() -> void:
	print("\n=== B2-5 paused")
	await _look_at(Vector3(-50, 0, -20), 60.0)
	scene.time_control.set_paused(true)
	await process_frame
	var before: float = scene.markers.emphasis()
	_wheel(false, 10)
	await _follow(240)
	_rig().global_position += Vector3(6, 0, 4)
	await process_frame
	await process_frame
	var worst := _worst_offset()
	var after: float = scene.markers.emphasis()
	var was_paused := paused
	scene.time_control.set_paused(false)
	await process_frame
	_check("paused: the wheel still raises the emphasis (%.2f -> %.2f) and markers stay on their objects after a pan (worst %.4f px)" % [before, after, worst],
		was_paused and after > before and worst < 0.01)


## B2-6: an object leaving the scene leaves no marker behind.
func _case_removal() -> void:
	print("\n=== B2-6 removed objects")
	var field = scene.get_node("Asteroids")
	await _look_at(Vector3(-50, 0, -20), 150.0)
	var id: int = _asteroids_on_screen()[0]
	var asteroid: Node3D = field.node_of(id)
	asteroid.visible = false
	await process_frame
	var hidden_gone: bool = not _entries_by_target().has(asteroid) # The field never frees an asteroid (fixed geometry).
	asteroid.visible = true
	await process_frame
	var back: bool = _entries_by_target().has(asteroid)
	var station: Node3D = scene.get_node("Stations").get_child(0)
	await _look_at(station.global_position, 150.0)
	scene.get_node("StationPanel").select(null)
	scene.get_node("Stations").remove_child(station)
	await process_frame
	var station_gone: bool = scene.markers.object_entries().all(func(e: Dictionary) -> bool: return e.target != station)
	station.free()
	_check("a hidden asteroid and a removed station have no marker (no stale entries); shown again, the asteroid's marker returns", hidden_gone and back and station_gone)
