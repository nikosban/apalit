extends SceneTree
## Phase C prototype: Strategic View on the playable main scene (plus a tight cluster of
## extra asteroids, fixed field seed) and, for the fog of war, on E05. Real wheel, click,
## key and motion input; the cursor is given to the hover systems explicitly.
## Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/strategic_view_test.gd

const MAIN := preload("res://main.tscn")
const E05 := preload("res://game/tests/combat/fixtures/e05_fleet.tscn")
const StrategicView := preload("res://game/presentation/strategic_view.gd")
const Survey := preload("res://game/survey/survey.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const EXTRA := 20 # Tight cluster added at (110, 110): a resource group larger than six.

var scene: Node3D
var view
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _load_main()
	await _case_entry()
	await _case_framing()
	await _case_fixed_camera()
	await _case_presentation()
	await _case_clusters()
	await _case_expansion()
	await _case_commands()
	await _case_boundary_and_orders()
	await _case_exit_and_reversal()
	await _case_handoff_input()
	await _case_paused_and_ui()
	_unload()
	await _case_fog()
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


func _load_main() -> void:
	scene = MAIN.instantiate()
	# Two player ships beside the scene's own, where the retired warships started.
	for added: Array in [["Transporter2", "res://game/ships/transporter_unit.tscn", Vector3(0, 1.5, 0)], ["FF01", "res://game/ships/ff01_unit.tscn", Vector3(14, 1.5, 0)]]:
		var ship: Node3D = load(added[1]).instantiate()
		ship.name = added[0]
		ship.position = added[2]
		scene.get_node("Ships").add_child(ship)
	var field := scene.get_node("Asteroids")
	field.session_seed = 4242
	var template: MeshInstance3D = field.get_child(0)
	for i in EXTRA:
		var rock := MeshInstance3D.new()
		rock.mesh = template.mesh
		rock.name = "Extra%d" % i
		rock.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 1.6), Vector3(104.0 + (i % 5) * 3.2, 1.5, 104.0 + (i / 5) * 3.2))
		rock.set_meta("asteroid_id", 900 + i)
		field.add_child(rock)
	root.add_child(scene)
	scene.get_node("Survey").set_physics_process(false)
	scene.get_node("WorldHighlight").set_process(false)
	await process_frame
	await process_frame
	view = scene.strategic
	view.auto_hover = false


func _rig() -> Node3D:
	return scene.get_node("CameraRig")


func _camera() -> Camera3D:
	return scene.get_viewport().get_camera_3d()


func _screen(point: Vector3) -> Vector2:
	return _camera().unproject_position(point)


func _rect() -> Rect2:
	return scene.get_viewport().get_visible_rect()


func _set_zoom(zoom: float) -> void:
	_rig().zoom_distance = zoom
	_rig()._apply_zoom()
	await process_frame
	await process_frame


# One wheel notch: inward (toward Tactical / closer) or outward.
func _wheel(inward: bool, at: Vector2 = Vector2.INF) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_WHEEL_UP if inward else MOUSE_BUTTON_WHEEL_DOWN
	event.pressed = true
	event.position = _rect().size * 0.5 if at == Vector2.INF else at
	root.push_input(event, true)


func _button(position: Vector2, button: MouseButton, pressed: bool, shift: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = position
	event.global_position = position
	event.shift_pressed = shift
	root.push_input(event, true)


func _click(position: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT, shift: bool = false) -> void:
	_button(position, button, true, shift)
	_button(position, button, false, shift)
	await process_frame


func _motion(position: Vector2, mask: int = 0, relative: Vector2 = Vector2.ZERO) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.button_mask = mask
	event.relative = relative
	root.push_input(event, true)


# Strategic-only nodes the rig's camera would render now (must be none in Tactical).
func _leaks() -> int:
	var rig_camera: Camera3D = _rig().get_node("Camera3D")
	var count := 0
	for node in [view._spheres, view._overlay, view._fog]:
		if node != null and node.is_visible_in_tree() and (node.layers & rig_camera.cull_mask) != 0:
			count += 1
	return count


func _settle(limit: int = 120) -> int:
	var frames := 0
	while view.transitioning() and frames < limit:
		await process_frame
		frames += 1
	await process_frame
	return frames


func _to_strategic() -> void:
	if view.is_active():
		return
	if not view.in_strategic():
		await _set_zoom(_rig().max_zoom)
		_wheel(false)
	await process_frame
	await _settle()


func _to_tactical() -> void:
	if view.state == StrategicView.State.TACTICAL:
		return
	_wheel(true)
	await process_frame
	await _settle()


func _survey(level: int) -> void:
	var survey := scene.get_node("Survey")
	survey.start_scan(Vector2.ZERO, 400.0, level)
	for i in 200:
		survey.advance(0.25)


## C1: the rig's limit gates the handoff; the markers move continuously.
func _case_entry() -> void:
	print("\n=== C1 entry after the Tactical limit, continuous handoff")
	_rig().global_position = Vector3(20, 0, -10)
	_rig().rotation = Vector3(0, deg_to_rad(30.0), 0)
	await _set_zoom(100.0)
	_wheel(false)
	await process_frame
	await process_frame
	var below: bool = view.state == StrategicView.State.TACTICAL and _rig().zoom_target > 100.0 and _leaks() == 0
	await _set_zoom(150.0)
	var pose: Transform3D = _rig().global_transform
	var ship: Node3D = scene.ship("Transporter2")
	var last := _screen(ship.global_position)
	_wheel(false)
	await process_frame
	var entering: bool = view.state == StrategicView.State.ENTERING and _camera() == view.camera()
	var worst := 0.0
	var frames := 0
	while view.transitioning() and frames < 120:
		await process_frame
		frames += 1
		var now := _screen(ship.global_position)
		worst = maxf(worst, now.distance_to(last))
		last = now
	await process_frame
	var top_down: bool = (-_camera().global_basis.z).dot(Vector3.DOWN) > 0.9999
	var yaw_kept: bool = _camera().global_basis.x.is_equal_approx(pose.basis.x)
	_check("Tactical shows no Strategic geometry; an outward notch below the limit only zooms the rig; at the limit it starts the handoff (Strategic camera current)", below and entering)
	_check("handoff %d frames; the Transporter2's marker moves at most %.1f px per frame (no jump); Strategic is top-down at the rig's yaw; rig untouched" % [frames, worst],
		view.is_active() and worst < 40.0 and top_down and yaw_kept and _rig().global_transform == pose)


## C2: the whole sector fits at any aspect ratio (analytic) and on this viewport.
func _case_framing() -> void:
	print("\n=== C2 sector framing")
	var fits := true
	var report := []
	for aspect in [16.0 / 9.0, 4.0 / 3.0, 21.0 / 9.0, 1.0, 9.0 / 16.0]:
		var frame: Transform3D = view.frame_transform(aspect)
		var tan_v := tan(deg_to_rad(view.camera().fov) * 0.5)
		var rect: Rect2 = view.sector_rect()
		var worst := 0.0
		for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
			var local: Vector3 = frame.affine_inverse() * Vector3(corner.x, 0.0, corner.y)
			worst = maxf(worst, maxf(absf(local.x) / (-local.z * tan_v * aspect), absf(local.y) / (-local.z * tan_v)))
		report.append(snappedf(worst, 0.001))
		fits = fits and worst <= 1.0
	var on_screen := true
	var rect: Rect2 = view.sector_rect()
	for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		on_screen = on_screen and _rect().has_point(_screen(Vector3(corner.x, 0.0, corner.y)))
	_check("all four sector corners inside the frustum at 16:9 / 4:3 / 21:9 / 1:1 / 9:16 (largest share of the half-view %s) and on this viewport" % str(report), fits and on_screen)


## C3: no pan, no rotation in Strategic.
func _case_fixed_camera() -> void:
	print("\n=== C3 fixed Strategic camera")
	var before: Transform3D = view.camera().global_transform
	var rig_before: Transform3D = _rig().global_transform
	for code in [KEY_W, KEY_Q]:
		var key := InputEventKey.new()
		key.physical_keycode = code
		key.keycode = code
		key.pressed = true
		root.push_input(key, true)
	for i in 20:
		await process_frame
	for code in [KEY_W, KEY_Q]:
		var key := InputEventKey.new()
		key.physical_keycode = code
		key.keycode = code
		key.pressed = false
		root.push_input(key, true)
	_motion(_rect().size * 0.5, MOUSE_BUTTON_MASK_MIDDLE, Vector2(80, 0))
	await process_frame
	await process_frame
	_check("W, Q held 20 frames and a middle drag move neither the Strategic camera nor the rig",
		view.camera().global_transform.is_equal_approx(before) and _rig().global_transform == rig_before)


## C4: Strategic shows only its own layer: simplified spheres, overlay, fog; no ground.
func _case_presentation() -> void:
	print("\n=== C4 Strategic presentation")
	var field := scene.get_node("Asteroids")
	var ground: MeshInstance3D = scene.get_node("Ground")
	var models_hidden: bool = field.ids().all(func(id: int) -> bool: return (field.node_of(id).layers & view.camera().cull_mask) == 0)
	var ships_hidden: bool = scene.get_node("Ships").get_children().all(func(s: Node3D) -> bool:
		return s.find_children("*", "MeshInstance3D", true, false).all(func(m: MeshInstance3D) -> bool: return (m.layers & view.camera().cull_mask) == 0))
	_check("Strategic camera renders only layer 20: no ground plane, no detailed asteroid or ship models (%d simplified spheres for %d asteroids, %d bake)" % [view.sphere_count(), field.ids().size(), view.builds],
		view.camera().cull_mask == StrategicView.LAYER and (ground.layers & view.camera().cull_mask) == 0 and models_hidden and ships_hidden
		and view.sphere_count() == field.ids().size() and view.builds == 1)
	var light: DirectionalLight3D = scene.get_node("DirectionalLight3D")
	var travel := -light.global_basis.z
	var expected := Vector2(travel.x, travel.z).normalized()
	_check("shadow direction from the scene light: %s (the light travels %s)" % [view.light_direction, expected], view.light_direction.is_equal_approx(expected))
	var c: Vector3 = field.center(field.ids()[0])
	var inside: Vector2 = view.field_at(Vector2(c.x, c.z))
	var empty: Vector2 = view.field_at(Vector2(140, -140))
	var formations: Array = view.formations_of(field, field.ids())
	var rule := true
	var casting := 0
	var scale: float = view._strategic_scale()
	for formation: Array in formations:
		var area := 0.0
		for id: int in formation:
			area += field.radius(id) * field.radius(id)
		var eligible: bool = sqrt(area) >= view.shadow_min_radius and sqrt(area) * scale >= view.shadow_min_pixels
		casting += 1 if eligible else 0
		for id: int in formation:
			rule = rule and view.casts_shadow(id) == eligible
	_check("contour field baked around asteroids (%.2f at one, %.2f in empty space); %d of %d formations cast shadows, exactly those meeting the size and screen thresholds" % [inside.x, empty.x, casting, formations.size()],
		inside.x > 0.5 and empty == Vector2.ZERO and rule and casting > 0 and casting < formations.size())
	_check("no permanent boundary shown", view.boundary_alpha() == 0.0)


## C5: clusters by screen proximity; resource markers only from survey knowledge.
func _case_clusters() -> void:
	print("\n=== C5 asteroid clusters and resource markers")
	var field := scene.get_node("Asteroids")
	var clusters: Array = view.clusters()
	var seen := {}
	var once := true
	for cluster: Dictionary in clusters:
		for id: int in cluster.members:
			once = once and not seen.has(id)
			seen[id] = clusters.find(cluster)
	var separated := true
	for a: int in seen:
		for b: int in seen:
			if a < b and seen[a] != seen[b] and _screen(field.center(a)).distance_to(_screen(field.center(b))) < view.cluster_distance:
				separated = false
	var extra_cluster: int = seen[900]
	var extra_together := range(EXTRA).all(func(i: int) -> bool: return seen[900 + i] == extra_cluster)
	_check("%d clusters: every asteroid in exactly one; asteroids closer than %.0f canvas units always share one; the added tight cluster is one" % [clusters.size(), view.cluster_distance],
		once and seen.size() == field.ids().size() and separated and extra_together)
	var unknown_markers := 0
	for entry: Dictionary in view.layout():
		unknown_markers += entry.resources.size()
	_check("nothing surveyed: no resource markers (unknown resources are not revealed); one environmental marker per cluster (%d)" % view.layout().size(),
		unknown_markers == 0 and view.layout().size() == clusters.size())
	await _survey(Survey.Level.ANALYZED)
	var depleted: int = clusters[extra_cluster].members[0]
	field.extract(depleted, 1000000)
	await process_frame
	var correct := true
	var max_per_cluster := 0
	for c in clusters.size():
		var families := {}
		for id: int in clusters[c].members:
			if field.deposit(id).reserves > 0:
				families[field.deposit(id).family] = true
		var shown: Array = view.layout()[c].resources.map(func(r: Dictionary) -> int: return r.family)
		correct = correct and shown.size() == families.size() and families.keys().all(func(f: int) -> bool: return shown.has(f))
		max_per_cluster = maxi(max_per_cluster, shown.size())
		for resource: Dictionary in view.layout()[c].resources:
			correct = correct and not resource.ids.has(depleted)
	_check("analyzed: one resource marker per family present in each cluster (at most %d per cluster); the depleted asteroid is in none" % max_per_cluster, correct and max_per_cluster <= 2)


func _extra_resource(min_count: int, max_count: int) -> Dictionary:
	for entry: Dictionary in view.layout():
		for resource: Dictionary in entry.resources:
			if resource.ids.size() >= min_count and resource.ids.size() <= max_count:
				return resource
	return {}


## C6: hover expansion, subgroups above six, members keep their asteroid identity.
func _case_expansion() -> void:
	print("\n=== C6 radial expansion")
	var big := _extra_resource(view.subgroup_size + 1, 999)
	var hover = scene.get_node("AsteroidHover")
	if big.is_empty():
		_check("a resource group larger than six exists in the added cluster", false)
		return
	view.update_hover(big.at)
	var first: Array = view.expansion()
	var subs := first.filter(func(e: Dictionary) -> bool: return e.kind == "subgroup")
	var expected := ceili(big.ids.size() / float(view.subgroup_size))
	_check("hovering a %d-asteroid resource marker shows %d subgroup markers (at most %d each), no member ring yet" % [big.ids.size(), subs.size(), view.subgroup_size],
		subs.size() == expected and subs.all(func(e: Dictionary) -> bool: return e.count <= view.subgroup_size) and subs.size() == first.size())
	view.update_hover(subs[0].at)
	var members: Array = view.expansion().filter(func(e: Dictionary) -> bool: return e.kind == "member")
	var ids: Array = members.map(func(e: Dictionary) -> int: return e.id)
	var identity := true
	for e: Dictionary in members:
		view.update_hover(e.at)
		identity = identity and view.asteroid_at(e.at) == e.id and hover.asteroid_at(e.at) == e.id and hover.describe(e.id) != ""
	var still_open: bool = view.expansion().size() == first.size() + members.size()
	_check("hovering subgroup 1 opens its ring of %d members (ids %s); moving across them keeps it open; each resolves to its own asteroid and tooltip" % [members.size(), str(ids)],
		members.size() == mini(view.subgroup_size, big.ids.size()) and big.ids.slice(0, members.size()) == ids and identity and still_open)
	view.update_hover(big.at + Vector2(200, 0))
	_check("leaving the group's area closes the expansion", view.expansion().is_empty())
	var small := _extra_resource(1, view.subgroup_size)
	if not small.is_empty():
		view.update_hover(small.at)
		var direct: Array = view.expansion()
		_check("a group of %d expands directly into %d member markers" % [small.ids.size(), direct.size()],
			direct.size() == small.ids.size() and direct.all(func(e: Dictionary) -> bool: return e.kind == "member"))
		view.update_hover(Vector2(-500, -500))


## C7: commands and picking without visible geometry.
func _case_commands() -> void:
	print("\n=== C7 selection and commands in Strategic")
	var field := scene.get_node("Asteroids")
	var miner: Node3D = scene.ship("Miner1")
	scene.selection().set_selection([miner])
	var resource := _extra_resource(1, 999)
	view.update_hover(resource.at)
	var entries: Array = view.expansion()
	if entries[0].kind == "subgroup":
		view.update_hover(entries[0].at)
	var member: Dictionary = view.expansion().filter(func(e: Dictionary) -> bool: return e.kind == "member")[0]
	var mine: Dictionary = scene.resolve_command(member.at)
	var real_point := _screen(field.center(member.id))
	view.update_hover(Vector2(-500, -500))
	var hidden: Dictionary = scene.resolve_command(real_point)
	_check("with a miner selected: a right-click on an expanded member resolves to MINE that asteroid; on the asteroid's own (hidden) position, collapsed, it does not (%s)" % str(hidden.get("kind")),
		mine.get("kind") == scene.CommandKind.MINE and mine.get("asteroid") == member.id and hidden.get("kind") != scene.CommandKind.MINE)
	var station: Node3D = scene.get_node("Stations").get_child(0)
	var dock: Dictionary = scene.resolve_command(_screen(station.global_position))
	scene.selection().set_selection([])
	await _click(_screen(station.global_position))
	_check("station marker: DOCK for the miner; a click selects that station (panel: %s)" % str(scene.get_node("StationPanel").station),
		dock.get("kind") == scene.CommandKind.DOCK and dock.get("station") == station and scene.get_node("StationPanel").station == station)
	var transporter: Node3D = scene.ship("Transporter2")
	var ff01: Node3D = scene.ship("FF01")
	await _click(_screen(transporter.global_position))
	var one: bool = scene.selection().selected == [transporter]
	await _click(_screen(ff01.global_position), MOUSE_BUTTON_LEFT, true)
	var two: bool = scene.selection().selected.size() == 2
	scene.selection().set_selection([])
	var a := _screen(transporter.global_position)
	var b := _screen(ff01.global_position)
	var box := Rect2(a, Vector2.ZERO).expand(b).grow(14.0)
	_button(box.position, MOUSE_BUTTON_LEFT, true)
	_motion(box.end)
	_button(box.end, MOUSE_BUTTON_LEFT, false)
	await process_frame
	var boxed: Array = scene.selection().selected
	_check("ship markers: click selects, Shift-click adds, a drag box selects both (%d)" % boxed.size(), one and two and boxed.has(transporter) and boxed.has(ff01))
	scene.selection().set_selection([transporter])
	var goal := Vector3(60, 0, -60)
	await _click(_screen(goal), MOUSE_BUTTON_RIGHT)
	var destination: Vector2 = transporter.get_node("Locomotion").destination
	_check("a right-click on open space moves to the ground point under it through the Strategic camera (%.2f u off)" % destination.distance_to(Vector2(goal.x, goal.z)),
		transporter.get_node("Locomotion").has_destination and destination.distance_to(Vector2(goal.x, goal.z)) < 0.5)
	var markers = scene.markers
	var keep: float = markers.interactive_emphasis
	markers.interactive_emphasis = 2.0 # Markers not interactive: only a hull pick could find a ship.
	var by_hull: Node3D = scene.selection().pick_any(_screen(transporter.global_position))
	markers.interactive_emphasis = keep
	_check("hidden hulls never pick in Strategic (markers made non-interactive: nothing found at the Transporter2)", by_hull == null)
	var env: Vector2 = view.layout()[0].env
	if scene.selection().pick_any(env) == null and view.station_at(env) == null:
		scene.selection().set_selection([transporter])
		await _click(env)
		_check("a left-click on an environmental cluster marker keeps the selection (not a click on empty space)", scene.selection().selected == [transporter])


## C8: boundary only for a refused order outside the sector; selected ships' orders.
func _case_boundary_and_orders() -> void:
	print("\n=== C8 boundary feedback and order lines")
	var transporter: Node3D = scene.ship("Transporter2")
	scene.selection().set_selection([transporter])
	var before: Vector2 = transporter.get_node("Locomotion").destination
	var outside := Vector2.INF # Outside the square, on screen, away from the ship panel (right).
	for point in [Vector3(-156, 0, 0), Vector3(0, 0, -156), Vector3(0, 0, 156), Vector3(156, 0, 0)]:
		var at := _screen(point)
		if _rect().has_point(at) and at.y > _rect().size.y * 0.25 and (outside == Vector2.INF or at.x < outside.x):
			outside = at
	var shown_before: float = view.boundary_alpha()
	await _click(outside, MOUSE_BUTTON_RIGHT)
	var shown: float = view.boundary_alpha()
	_check("a right-click outside the command square (on screen: %s) shows the boundary (alpha %.2f, none before) and gives no order" % [_rect().has_point(outside), shown],
		_rect().has_point(outside) and shown_before == 0.0 and shown > 0.0 and transporter.get_node("Locomotion").destination == before)
	for i in 120:
		await process_frame
	_check("the boundary fades away again (alpha %.2f after 2 s)" % view.boundary_alpha(), view.boundary_alpha() == 0.0)
	var lines: Array = view.order_lines(transporter)
	var route: Dictionary = lines[0] if not lines.is_empty() else {}
	var ends: bool = not route.is_empty() and (route.points[route.points.size() - 1] as Vector2).distance_to(transporter.get_node("Locomotion").destination) < 0.01
	_check("the selected Transporter2's order line is its simulated route, ending at its destination (%d points)" % (route.points.size() if not route.is_empty() else 0), route.get("kind") == "route" and ends)


## C9: exit restores the Tactical pose exactly; reversal both ways.
func _case_exit_and_reversal() -> void:
	print("\n=== C9 exit, restore, reversal")
	var saved: Dictionary = view._saved.duplicate()
	var selected: Array = scene.selection().selected.duplicate()
	_wheel(true)
	await process_frame
	var exiting: bool = view.state == StrategicView.State.EXITING
	await _settle()
	var restored: bool = _rig().global_transform == saved.transform and _rig().zoom_distance == saved.zoom and _rig().zoom_target == saved.target and _leaks() == 0
	_check("an inward notch returns: rig pose (transform, zoom %.1f, target %.1f) restored exactly, no Strategic geometry left in Tactical, rig camera current, rig live again, selection kept" % [_rig().zoom_distance, _rig().zoom_target],
		exiting and restored and _camera() == _rig().get_node("Camera3D") and _rig().is_processing() and scene.selection().selected == selected)
	_wheel(false)
	for i in 8:
		await process_frame
	var mid: float = view.progress
	_wheel(true)
	await process_frame
	var reversing: bool = view.state == StrategicView.State.EXITING
	await _settle()
	var back: bool = view.state == StrategicView.State.TACTICAL and _rig().global_transform == saved.transform
	_wheel(false)
	await _settle()
	_wheel(true)
	for i in 8:
		await process_frame
	_wheel(false)
	await process_frame
	var re_entering: bool = view.state == StrategicView.State.ENTERING
	await _settle()
	_check("reversal: entering at progress %.2f, an inward notch turns back to Tactical (pose restored); exiting, an outward notch turns back to Strategic" % mid,
		mid > 0.0 and mid < 1.0 and reversing and back and re_entering and view.is_active())


## C10: no click or command completes across a handoff.
func _case_handoff_input() -> void:
	print("\n=== C10 input during the handoff")
	await _to_tactical()
	var transporter: Node3D = scene.ship("Transporter2")
	scene.selection().set_selection([transporter])
	var empty := _rect().size * Vector2(0.12, 0.55) # Left: away from the ship panel.
	_button(empty, MOUSE_BUTTON_LEFT, true) # Pressed in Tactical on empty space...
	await process_frame
	_wheel(false)
	await process_frame
	_button(empty, MOUSE_BUTTON_LEFT, false) # ...released during the handoff.
	await process_frame
	var kept: bool = scene.selection().selected == [transporter]
	var before: Vector2 = transporter.get_node("Locomotion").destination
	var planned: int = transporter.get_node("RouteFollower").plans
	await _click(_rect().size * 0.3, MOUSE_BUTTON_RIGHT)
	var no_order: bool = transporter.get_node("RouteFollower").plans == planned and transporter.get_node("Locomotion").destination == before
	var during: bool = view.transitioning()
	await _settle()
	await _click(empty) # A full click after the handoff behaves normally (nothing there: clears).
	_check("a press begun in Tactical and released in the handoff does not clear the selection; a right-click in the handoff gives no order; afterwards clicks work",
		during and kept and no_order and scene.selection().selected.is_empty())


## C11: paused simulation; UI panels keep the wheel.
func _case_paused_and_ui() -> void:
	print("\n=== C11 paused, UI panels")
	await _to_tactical()
	scene.time_control.set_paused(true)
	await _to_strategic()
	var entered: bool = view.is_active()
	await _to_tactical()
	scene.time_control.set_paused(false)
	_check("paused: Strategic is entered and left (real time)", entered and view.state == StrategicView.State.TACTICAL)
	await _set_zoom(150.0)
	var layer := CanvasLayer.new()
	layer.layer = 5
	var panel := Panel.new()
	panel.size = _rect().size
	layer.add_child(panel)
	scene.add_child(layer)
	await process_frame
	_motion(_rect().size * 0.5)
	await process_frame
	_wheel(false)
	await process_frame
	await process_frame
	var blocked: bool = view.state == StrategicView.State.TACTICAL
	layer.free()
	await process_frame
	_check("over a UI panel an outward notch at the limit does not enter Strategic", blocked)


## C12: the fog: undetected hostiles stay hidden; the Strategic fog is FogView's own.
func _case_fog() -> void:
	print("\n=== C12 fog of war (E05)")
	scene = E05.instantiate()
	scene.scenario_index = 0
	root.add_child(scene)
	await process_frame
	await process_frame
	view = scene.strategic
	view.auto_hover = false
	var hidden: Node3D = scene.ship("HostileFF01A")
	hidden.get_node("Locomotion").place(Vector2(140, 140), 0.0)
	scene.get_node("HostileFleet").process_mode = Node.PROCESS_MODE_DISABLED
	for i in 20:
		await physics_frame
	scene.sensors.evaluate()
	await _to_strategic()
	var screen := _screen(hidden.global_position)
	var fog: MeshInstance3D = view._fog
	_check("Strategic: a never-detected hostile has no marker and no pick (%s); the Strategic fog uses FogView's material and shows with it" % str(scene.player_sees(hidden)),
		not scene.player_sees(hidden) and scene.markers.marker_at(screen) == null and scene.selection().pick_any(screen) == null
		and fog != null and fog.material_override == scene.fog_view.material_override and fog.visible == scene.fog_view.visible and (fog.layers & view.camera().cull_mask) != 0)
