extends SceneTree
## Headless UX round P9 (T25) checks on the playable main scene: every ship type has
## black thruster parts in its model (Model/Thrusters: MainEngine cylinders (MainEngine,
## MainEngine2, ...) and eight jet boxes) inside its collision radius, counted as hull (Selection pick boxes, a click on
## an engine that misses the original hull picks the ship, the selection outline); the
## ThrusterView finds them on every ship, produced ships included, and draws only under
## itself; the main plume sits on the nozzle pointing back and follows its states (BOOST
## accelerating, THRUST cruising, IDLE stopped / braking / turning / sideways, NONE
## without propulsion), one plume on each main engine's nozzle; the jets fire on the right sides, and together with the main
## engine when the motions combine (accelerating through a turn).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/thruster_view_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const ThrusterView := preload("res://game/presentation/thruster_view.gd")
const WorldHighlight := preload("res://game/presentation/world_highlight.gd")
const UNITS := {
	"Miner": "res://game/ships/miner_unit.tscn", "Transporter": "res://game/ships/transporter_unit.tscn",
	"FF01": "res://game/ships/ff01_unit.tscn",
}
const SHIPS := ["Miner1", "Transporter", "FF01"] # One of each type (the FF-01 is added to the scene).
# Hull family with black thruster parts and a main engine protruding past the hull; the
# FF-01 blockout has its own dark-grey parts and a flush engine.
const PROTRUDING_BLACK := ["Miner1", "Transporter"]
const JETS := ["Retro_L", "Retro_R", "Bow_L", "Bow_R", "Lateral_L", "Lateral_R", "Stern_L", "Stern_R"]
const OPEN := Vector2(118, 0) # Open ground (no ships, stations or obstacles).

var _failures := 0
var _checks := 0
var _main: Node
var _view: ThrusterView
var _selection: Node
var _camera: Camera3D


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	var ff01: Node3D = load(UNITS["FF01"]).instantiate()
	ff01.name = "FF01"
	ff01.position = Vector3(14, 1.5, 0)
	_main.get_node("Ships").add_child(ff01)
	root.add_child(_main)
	_view = _main.get_node("ThrusterView")
	_selection = _main.get_node("Selection")
	_camera = _main.get_node("CameraRig/Camera3D")
	for i in 10:
		await physics_frame
	_test_parts()
	await _test_engines()
	await _test_picking_and_outline()
	await _test_states()
	await _test_combined()
	await _test_produced()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# 1. Parts on every type: names, black material, inside the collision radius; the view
# knows the nine emitters; nothing drawn under a ship.
func _test_parts() -> void:
	var found: Array[String] = []
	var inside := true
	var black := true
	var emitters := true
	for ship_name: String in SHIPS:
		var ship := _ship(ship_name)
		var thrusters := ship.get_node_or_null("Model/Thrusters")
		var names: Array[String] = []
		if thrusters != null:
			for part: Node in thrusters.get_children():
				names.append(String(part.name))
		var engines := names.filter(func(n: String) -> bool: return n.begins_with("MainEngine"))
		var jets := names.filter(func(n: String) -> bool: return not n.begins_with("MainEngine"))
		if not engines.has("MainEngine") or jets != JETS:
			found.append("%s %s" % [ship_name, str(names)])
			continue
		var radius: float = ship.get_node("RouteFollower").ship_radius
		var to_ship := ship.global_transform.affine_inverse()
		for part: MeshInstance3D in thrusters.get_children():
			var material := part.mesh.surface_get_material(0) as StandardMaterial3D
			if ship_name in PROTRUDING_BLACK:
				black = black and material != null and material.albedo_color.v < 0.05
			var box: AABB = (to_ship * part.global_transform) * part.get_aabb()
			for i in 8:
				inside = inside and Vector2(box.get_endpoint(i).x, box.get_endpoint(i).z).length() <= radius + 0.0001
		emitters = emitters and _view.emitters_of(ship).size() == 9
	_check("every type has Model/Thrusters with MainEngine (+ MainEngine2...) + 8 jet boxes (%s)" % (", ".join(found) if not found.is_empty() else "all"), found.is_empty())
	_check("all thruster parts are inside the ship's collision radius", inside)
	_check("the Miner and Transporter thruster parts are black", black)
	_check("ThrusterView knows the nine emitters of each type", emitters)
	var under_ship := false
	var effects := true
	for ship_name: String in SHIPS:
		var ship := _ship(ship_name)
		var nodes: Array[Node3D] = [_view.plume_of(ship)]
		for jet: String in JETS:
			nodes.append(_view.jet_of(ship, jet))
		for node: Node3D in nodes:
			effects = effects and node != null and _view.is_ancestor_of(node)
			under_ship = under_ship or (node != null and ship.is_ancestor_of(node))
	_check("each plume and jet is a thruster effect under ThrusterView, never under a ship", effects and not under_ship)


# 1b. Every main engine has its own plume, on its nozzle (the cylinder's rear face).
func _test_engines() -> void:
	await process_frame
	var wrong: Array[String] = []
	for ship_name: String in SHIPS:
		var ship := _ship(ship_name)
		var cylinders := ship.get_node("Model/Thrusters").get_children().filter(func(n: Node) -> bool: return String(n.name).begins_with("MainEngine"))
		var plumes := _view.plumes_of(ship)
		if plumes.size() != cylinders.size():
			wrong.append("%s %d plumes for %d engines" % [ship_name, plumes.size(), cylinders.size()])
			continue
		for i in cylinders.size():
			var engine: MeshInstance3D = cylinders[i]
			var nozzle: Vector3 = engine.global_position + ship.global_basis.z.normalized() * (engine.mesh as CylinderMesh).height / 2.0
			if not plumes[i].visible or plumes[i].global_position.distance_to(nozzle) > 0.001:
				wrong.append("%s %s (visible %s, %.4f u off)" % [ship_name, engine.name, plumes[i].visible, plumes[i].global_position.distance_to(nozzle)])
	_check("each main engine has its own visible plume on its nozzle (%s)" % (", ".join(wrong) if not wrong.is_empty() else "all"), wrong.is_empty())


# 2. Thrusters are hull: pick boxes, a click on the protruding engine (the ray missing
# the original hull) picks the ship, the selection outline covers them.
func _test_picking_and_outline() -> void:
	var boxes := true
	var picked: Array[String] = []
	var engine_only := true
	var hull_hit: Array[String] = []
	for ship_name: String in SHIPS:
		var ship := _ship(ship_name)
		var thrusters := ship.get_node("Model/Thrusters")
		var parts: Array = _selection._parts[ship]
		var meshes := ship.find_children("*", "MeshInstance3D", true, false)
		boxes = boxes and parts.size() == meshes.size() and thrusters.get_child_count() >= 9
		# Broadside to the camera (right side facing it), alone on open ground.
		_frame(OPEN, 24.0)
		await process_frame
		var toward := Vector2(_camera.global_position.x, _camera.global_position.z) - OPEN
		toward = toward.normalized()
		var original := AABB()
		var engine_box := AABB()
		var to_ship := ship.global_transform.affine_inverse()
		for mesh: MeshInstance3D in meshes:
			var box: AABB = (to_ship * mesh.global_transform) * mesh.get_aabb()
			if mesh.name == &"MainEngine":
				engine_box = box
			elif not thrusters.is_ancestor_of(mesh):
				original = box if original.size == Vector3.ZERO else original.merge(box)
		var saved: Transform3D = ship.global_transform
		ship.get_node("Locomotion").place(OPEN, atan2(-toward.y, toward.x))
		_frame(OPEN, 24.0)
		await process_frame
		var nozzle: Vector3 = _view.emitters_of(ship).Main[0]
		var aim_local := Vector3(nozzle.x, nozzle.y, (original.end.z + nozzle.z) / 2.0) # The first engine behind the hull.
		var aim := ship.global_transform * aim_local
		_frame(Vector2(aim.x, aim.z), 24.0) # Centred on the aim: no perspective skew along the hull.
		await process_frame
		var screen := _camera.unproject_position(aim)
		var origin := ship.global_transform.affine_inverse() * _camera.project_ray_origin(screen)
		var direction := ship.global_transform.affine_inverse().basis * _camera.project_ray_normal(screen)
		var hits_hull := false
		for mesh: MeshInstance3D in meshes:
			if thrusters.is_ancestor_of(mesh):
				continue
			var box: AABB = (ship.global_transform.affine_inverse() * mesh.global_transform) * mesh.get_aabb()
			hits_hull = hits_hull or box.intersects_ray(origin, direction) != null
		var engine_hit := engine_box.intersects_ray(origin, direction) != null
		if ship_name in PROTRUDING_BLACK and (hits_hull or not engine_hit):
			engine_only = false
			hull_hit.append("%s (hull %s, engine %s, ray %s)" % [ship_name, hits_hull, engine_hit, str(direction.snapped(Vector3(0.01, 0.01, 0.01)))])
		if _selection.pick(screen) == ship:
			picked.append(ship_name)
		ship.get_node("Locomotion").place(Vector2(saved.origin.x, saved.origin.z), ship.get_node("Locomotion").heading)
	_check("Selection pick boxes include the thruster parts of each type", boxes)
	_check("the ray through the protruding main engine misses the original hull and hits the engine box (Miner, Transporter) %s" % ", ".join(hull_hit), engine_only)
	_check("a click on the main engine picks the ship: %s" % str(picked), picked.size() == SHIPS.size())
	var highlight: WorldHighlight = _main.get_node("WorldHighlight")
	var outlined := true
	_selection.set_selection(SHIPS.map(func(n: String) -> Node3D: return _ship(n)))
	highlight.update(Vector2(5, 5), true)
	for ship_name: String in SHIPS:
		for part: MeshInstance3D in _ship(ship_name).get_node("Model/Thrusters").get_children():
			outlined = outlined and part.material_overlay != null
	_check("the selection outline covers every thruster part", outlined)
	_selection.set_selection([])
	highlight.update(Vector2(5, 5), true)


# 3. Plume states and jets on Miner1 in the real loop: idle when stopped; boost while
# accelerating; thrust cruising; idle braking (retro jets); turning jets in a turn in
# place; lateral jets sideways; none without propulsion.
func _test_states() -> void:
	var ship := _ship("Miner1")
	var lo: Node = ship.get_node("Locomotion")
	lo.place(OPEN, 0.0)
	_frame(OPEN, 24.0)
	for i in 30:
		await physics_frame
	await process_frame
	var plume := _view.plume_of(ship)
	var nozzle: Vector3 = ship.global_transform * (_view.emitters_of(ship).Main[0] as Vector3)
	var back := ship.global_transform.basis.z.normalized()
	var exhaust := -plume.global_basis.z.normalized()
	_check("stopped with propulsion: IDLE, plume on the nozzle (%.4f u), exhaust pointing back (dot %.4f), idle glow without exhaust (thrust %.2f, powered %s, emitting %s)" % [plume.global_position.distance_to(nozzle), exhaust.dot(back), plume.thrust, plume.powered, plume.emitting()],
		_view.state_of(ship) == ThrusterView.State.IDLE and plume.visible and plume.global_position.distance_to(nozzle) < 0.001
		and exhaust.dot(back) > 0.999 and plume.thrust == 0.0 and plume.powered and not plume.emitting())
	var quiet := JETS.all(func(jet: String) -> bool: return _view.jet_of(ship, jet).thrust == 0.0 and not _view.jet_of(ship, jet).emitting())
	_check("stopped: every directional jet inactive (no thrust, no emission)", quiet)
	ship.get_node("RouteFollower").order(OPEN + Vector2(0, -30))
	var seen := {}
	var order: Array[String] = []
	var main_max := 0.0
	var retro_max := 0.0
	var boost_thrust := 0.0
	var cruise_thrust := 0.0
	var dimmed: Array[float] = []
	for i in 900:
		await physics_frame
		var state := _view.state_of(ship)
		var label: String = ThrusterView.State.keys()[state]
		if order.is_empty() or order[-1] != label:
			order.append(label)
		seen[label] = true
		if state == ThrusterView.State.BOOST:
			main_max = maxf(main_max, _view.intensity_of(ship, "Main"))
		if state == ThrusterView.State.IDLE and lo.velocity.length() > 0.2:
			retro_max = maxf(retro_max, minf(_view.intensity_of(ship, "Retro_L"), _view.intensity_of(ship, "Retro_R")))
		await process_frame # The effects follow in the frame after the tick.
		if state == ThrusterView.State.BOOST:
			boost_thrust = maxf(boost_thrust, plume.thrust)
		var retro: float = _view.intensity_of(ship, "Retro_L")
		if state == ThrusterView.State.THRUST and retro <= ThrusterView.THRESHOLD:
			cruise_thrust = plume.thrust # Cruising: no braking at all.
		if state == ThrusterView.State.THRUST and retro > ThrusterView.THRESHOLD:
			dimmed.append(plume.thrust) # Stage 6B.2: minor braking while cruising.
		if i > 30 and not lo.has_destination and lo.velocity.length() < 0.01:
			break
	_check("move ahead 30 u: states %s; main engine up to %.2f while boosting; retro jets up to %.2f while braking" % [" > ".join(order), main_max, retro_max],
		order == ["IDLE", "BOOST", "THRUST", "IDLE"] and main_max > 0.9 and retro_max > 0.9)
	_check("main thrust: boost up to %.2f, cruise %.2f (expected 0.5)" % [boost_thrust, cruise_thrust],
		boost_thrust > 0.9 and absf(cruise_thrust - 0.5) < 0.01)
	# Stage 6B.2: as braking starts, the plume dims (above zero, below the cruise 0.5)
	# instead of going out at the first retro impulse; full braking is IDLE (checked above).
	_check("minor braking while cruising dims the main plume instead of putting it out (%d ticks, thrust %s)" % [dimmed.size(), str(dimmed.map(func(t: float) -> String: return "%.2f" % t))],
		not dimmed.is_empty() and dimmed.all(func(t: float) -> bool: return t > 0.0 and t < 0.5))
	lo.face(lo.heading + deg_to_rad(120.0))
	var turn := {"Bow_R": 0.0, "Stern_L": 0.0, "Bow_L": 0.0, "Stern_R": 0.0, "Main": 0.0}
	var turn_states := {}
	var bow_r := _view.jet_of(ship, "Bow_R")
	var bow_r_thrust := 0.0
	var bow_r_pulses := 0
	var bow_r_off := false
	var was_emitting := false
	for i in 240:
		await physics_frame
		await process_frame
		for jet: String in turn:
			turn[jet] = maxf(turn[jet], _view.intensity_of(ship, jet))
		turn_states[ThrusterView.State.keys()[_view.state_of(ship)]] = true
		bow_r_thrust = maxf(bow_r_thrust, bow_r.thrust)
		if bow_r.emitting() and not was_emitting:
			bow_r_pulses += 1
		was_emitting = bow_r.emitting()
		bow_r_off = bow_r_thrust > 0.9 and bow_r.thrust == 0.0 and not bow_r.emitting()
	# A steady stream starts once per activation (the jet fires in one acceleration phase of
	# the turn); pulses start more than once.
	var continuous: bool = bow_r.settings.continuous
	_check("turn in place: the bow-right jet effect fires up to %.2f, %d emission starts (%s), then stops emitting (%s)" % [bow_r_thrust, bow_r_pulses, "stream" if continuous else "pulses", bow_r_off],
		bow_r_thrust > 0.9 and (bow_r_pulses == 1 if continuous else bow_r_pulses >= 2) and bow_r_off)
	_check("turn in place: bow-right + stern-left (%.2f, %.2f), then bow-left + stern-right (%.2f, %.2f); main %.2f; states %s" % [turn.Bow_R, turn.Stern_L, turn.Bow_L, turn.Stern_R, turn.Main, str(turn_states.keys())],
		turn.Bow_R > 0.9 and turn.Stern_L > 0.9 and turn.Bow_L > 0.9 and turn.Stern_R > 0.9 and turn.Main < ThrusterView.THRESHOLD and turn_states.keys() == ["IDLE"])
	var right := Vector2(cos(lo.heading), -sin(lo.heading))
	lo.move_to(lo.planar_position + right * 2.0, true)
	var lateral := {"Lateral_L": 0.0, "Lateral_R": 0.0}
	for i in 300:
		await physics_frame
		for jet: String in lateral:
			lateral[jet] = maxf(lateral[jet], _view.intensity_of(ship, jet))
	_check("sideways 2 u to the right: the left lateral jet pushes (%.2f), the right one stops it (%.2f); IDLE" % [lateral.Lateral_L, lateral.Lateral_R],
		lateral.Lateral_L > 0.9 and lateral.Lateral_R > 0.5 and _view.state_of(ship) == ThrusterView.State.IDLE)
	await process_frame
	var fuel: Node = ship.get_node("Fuel")
	var tank: float = fuel.fuel
	fuel._set_fuel(0.0)
	for i in 60:
		await physics_frame
	await process_frame
	var all_zero := true
	for jet: String in ["Main"] + JETS:
		all_zero = all_zero and _view.intensity_of(ship, jet) < 0.001
	_check("without propulsion (no fuel, propulsion %s): NONE (%s), no glow or exhaust (powered %s, thrust %.2f), every jet off (%s)" % [str(ship.get_node("Locomotion").propulsion), ThrusterView.State.keys()[_view.state_of(ship)], plume.powered, plume.thrust, all_zero],
		_view.state_of(ship) == ThrusterView.State.NONE and not plume.powered and plume.thrust == 0.0 and not plume.emitting() and all_zero)
	fuel._set_fuel(tank)
	for i in 5:
		await physics_frame


# 4. Combined effects: from a stop, a move 90 degrees to the left (far away) turns while
# accelerating: the main engine and the turning jets fire in the same ticks.
func _test_combined() -> void:
	var ship := _ship("Miner1")
	var lo: Node = ship.get_node("Locomotion")
	lo.place(OPEN, 0.0)
	for i in 30:
		await physics_frame
	ship.get_node("RouteFollower").order(OPEN + Vector2(-40, 0))
	var together := 0
	var best := [0.0, 0.0]
	for i in 240:
		await physics_frame
		var main := _view.intensity_of(ship, "Main")
		var turning := maxf(minf(_view.intensity_of(ship, "Bow_R"), _view.intensity_of(ship, "Stern_L")),
			minf(_view.intensity_of(ship, "Bow_L"), _view.intensity_of(ship, "Stern_R")))
		if main > 0.1 and turning > 0.1:
			together += 1
			if main + turning > best[0] + best[1]:
				best = [main, turning]
	_check("accelerating through a 90 deg turn: main engine and turning jets fire together for %d ticks (e.g. main %.2f, turning %.2f), the plume boosting" % [together, best[0], best[1]],
		together >= 5)
	lo.place(OPEN, 0.0)


# 5. Produced ships (added under Ships at run time) get the effects; a removed ship's
# plume goes with it.
func _test_produced() -> void:
	var added: Array[Node3D] = []
	var x := -20.0
	for type: String in UNITS:
		var ship: Node3D = (load(UNITS[type]) as PackedScene).instantiate()
		ship.name = "Produced" + type
		ship.position = Vector3(OPEN.x + x, 0, OPEN.y + 30)
		x += 12.0
		_main.get_node("Ships").add_child(ship)
		_selection.register_ship(ship) # Selection picks over every child of Ships.
		added.append(ship)
	for i in 3:
		await physics_frame
	await process_frame
	var ready := added.all(func(s: Node3D) -> bool: return _view.emitters_of(s).size() == 9 and _view.plume_of(s) != null and _view.state_of(s) == ThrusterView.State.IDLE)
	_check("three produced ships (one per type) have their nine emitters and an idle plume", ready)
	var plume := _view.plume_of(added[0])
	_remove(added[0])
	for i in 3:
		await physics_frame
	await process_frame
	_check("a removed ship's plume is removed with it", not is_instance_valid(plume) and _view._ships.size() == _main.get_node("Ships").get_child_count())
	for ship in added.slice(1):
		_remove(ship)
	await physics_frame


# Removes a test ship (the game never removes ships; Selection keeps its pick boxes and
# ring, so they are removed here too).
func _remove(ship: Node3D) -> void:
	_selection._parts.erase(ship)
	(_selection._rings[ship] as Node).queue_free()
	_selection._rings.erase(ship)
	_main.get_node("Ships").remove_child(ship)
	ship.queue_free()


func _frame(center: Vector2, zoom: float) -> void:
	var rig := _main.get_node("CameraRig")
	rig.global_position = Vector3(center.x, 0, center.y)
	rig.zoom_distance = zoom
	rig._apply_zoom()


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
