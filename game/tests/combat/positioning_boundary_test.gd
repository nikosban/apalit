extends SceneTree
## I01: configured combat boundaries, unchanged footprint/obstacle margins and the
## production Guard, engagement, Defensive and group-waypoint callers.
## Run: <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/positioning_boundary_test.gd

const MAIN := preload("res://main.tscn")
const SHOWCASE := preload("res://game/scenes/sector_showcase.tscn")
const REUSE := preload("res://game/tests/reuse_arena.tscn")
const ENCOUNTER := preload("res://game/tests/combat/fixtures/encounter_arena.tscn")
const COMBAT_TEST := preload("res://game/scenes/combat_test.tscn")
const STATION := preload("res://game/stations/station.tscn")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Navigation := preload("res://game/navigation/static_navigation.gd")
const Profiles := preload("res://game/behavior/weapon_profiles.gd")
const EPS := 0.01

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _case_dimensions()
	await _case_combat_arena()
	await _case_reference()
	await _case_exact_edges()
	await _case_clearance()
	await _case_guard()
	for mode: String in ["Aggressive", "Attack", "Attack-Move"]:
		await _case_engagement(mode)
	await _case_attack_move_leash()
	await _case_defensive()
	await _case_waypoints()
	_free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _free() -> void:
	if is_instance_valid(scene):
		root.remove_child(scene)
		scene.free()
	scene = null


# Isolate positions from authored obstacles, sensors and scenario orders. Only the
# in-memory instance changes; geometry is configured before navigation reads it.
# Subjects run the actual RouteFollower/Avoidance/Locomotion loop. Combat processing
# is disabled so shots cannot destroy subjects; eligibility queries remain real.
func _load(packed: PackedScene, rock_point: Variant = null, with_station := false, alternate := false) -> void:
	_free()
	scene = packed.instantiate()
	if scene.get("scenario_index") != null:
		scene.scenario_index = -1
	for name: String in ["Sensors", "HostileCommander"]:
		var node := scene.get_node_or_null(name)
		if node != null:
			node.free()
	var field := scene.get_node("Asteroids")
	for child in field.get_children():
		child.free()
	field.session_seed = 20261025
	var stations := scene.get_node_or_null("Stations")
	if stations != null:
		for child in stations.get_children():
			child.free()
	if rock_point != null:
		var rock := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 2.0
		mesh.height = 4.0
		rock.mesh = mesh
		rock.position = Vector3(rock_point.x, 1.5, rock_point.y)
		rock.set_meta("asteroid_id", 1)
		field.add_child(rock)
	if with_station:
		var station := STATION.instantiate()
		station.position = Vector3(200, 1.5, -80)
		stations.add_child(station)
	if alternate:
		var navigation := Navigation.new()
		navigation.name = "AlternateNavigation"
		navigation.obstacles_path = NodePath("../Asteroids")
		navigation.map_half_size = 64.0
		scene.add_child(navigation)
		scene.move_child(navigation, scene.get_node("Ships").get_index())
		scene.get_node("Ships/Gunship/RouteFollower").navigation_path = NodePath("../../../AlternateNavigation")
	root.add_child(scene)
	var controller := scene.get_node_or_null("EnemyController")
	if controller != null:
		controller.set_physics_process(false)
	var half: float = scene.get_node("StaticNavigation").map_half_size
	var i := 0
	for ship in scene.get_node("Ships").get_children():
		ship.process_mode = Node.PROCESS_MODE_DISABLED
		ship.get_node("Combat").stance = CombatShip.Stance.HOLD_FIRE
		ship.get_node("Combat").set_physics_process(false)
		ship.get_node("Fuel").set_physics_process(false)
		ship.get_node("Locomotion").place(Vector2(-half + 20, -half + 20 + 14 * i), 0.0)
		i += 1
		if ship.name in ["Gunship", "Destroyer"] and not ship.has_node("Behavior"):
			var behavior := Behavior.new()
			behavior.name = "Behavior"
			ship.add_child(behavior)
		if ship.has_node("Behavior"):
			ship.get_node("Behavior").set_physics_process(false)
	for frame in 120:
		var ready := true
		for ship in scene.get_node("Ships").get_children():
			var follower = ship.get_node("RouteFollower")
			ready = ready and follower.get_node(follower.navigation_path).is_ready(follower.planning_radius())
		if ready:
			return
		await physics_frame
	_check("navigation maps became ready", false)


func _ship(name: String) -> Node3D:
	return scene.get_node("Ships/" + name)


func _b(name: String = "Gunship") -> Node:
	return _ship(name).get_node("Behavior")


func _put(name: String, point: Vector2, heading := 0.0) -> void:
	var ship := _ship(name)
	ship.process_mode = Node.PROCESS_MODE_INHERIT
	ship.get_node("RouteFollower").clear()
	ship.get_node("Locomotion").place(point, heading)
	ship.get_node("Avoidance").reset()
	if ship.has_node("Behavior"):
		var b = ship.get_node("Behavior")
		b._set_anchor()
		b.has_station = false
		b._last_order = -INF


func _run(seconds: float) -> void:
	var end := CombatShip.now() + seconds
	while CombatShip.now() < end:
		await physics_frame


func _route_ends_at(ship: Node3D, point: Vector2) -> bool:
	var route: PackedVector2Array = ship.get_node("RouteFollower").route
	return route.size() >= 2 and route[route.size() - 1].distance_to(point) < 0.25


func _case_dimensions() -> void:
	for entry: Array in [[MAIN, 150.0], [SHOWCASE, 380.0], [REUSE, 150.0], [ENCOUNTER, 150.0], [COMBAT_TEST, 380.0]]:
		await _load(entry[0])
		var half: float = scene.get_node("StaticNavigation").map_half_size
		_check("%s keeps its configured half-size %.0f" % [scene.name, entry[1]], is_equal_approx(half, entry[1]))
		for name: String in ["Gunship", "Destroyer"]:
			var b = _b(name)
			_check("%s %s: old interior still valid; 138 valid; 200 follows this scene's size" % [scene.name, name],
				b._position_ok(Vector2(100, 100)) and b._position_ok(Vector2(138, 0))
				and b._position_ok(Vector2(200, 0)) == (half > 200.0))
			for margin: float in [0.0, Behavior.GUARD_CHOICE_MARGIN]:
				var edge: float = half - b.follower.ship_radius - margin
				var fits := true
				var rejects := true
				for direction: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
					fits = fits and b._position_ok(direction * (edge - EPS), margin)
					rejects = rejects and not b._position_ok(direction * (edge + EPS), margin)
					rejects = rejects and not b._position_ok(direction * (half + 1.0), margin)
				_check("%s %s margin %.0f: all four edges keep footprint and margin" % [scene.name, name, margin], fits and rejects)
			_check("%s %s: edge diagnostics follow the configured size" % [scene.name, name],
				b._unusable_reason(Vector2(half + 1.0, 0)) == "map edge"
				and b._unusable_reason(Vector2(138, 0)) == "another guard")
	_free()


# Keep the authored field, six armed ships and FF-01 (two NC-90 Bastions) for this case. Only the test's live
# instance is controlled: stop weapons and the commander, then exercise actual
# commands, navigation, avoidance, locomotion and Behavior beyond the old boundary.
func _case_combat_arena() -> void:
	_free()
	scene = COMBAT_TEST.instantiate()
	root.add_child(scene)
	scene.get_node("HostileCommander").set_physics_process(false)
	for ship in scene.get_node("Ships").get_children():
		ship.get_node("Combat").stance = CombatShip.Stance.HOLD_FIRE
		ship.get_node("Combat").set_physics_process(false)
		ship.get_node("Behavior").set_physics_process(false)
	var navigation = scene.get_node("StaticNavigation")
	var ready := false
	for frame in 120:
		ready = scene.get_node("Ships").get_children().all(func(ship: Node) -> bool:
			return navigation.is_ready(ship.get_node("RouteFollower").planning_radius()))
		if ready:
			break
		await physics_frame
	_check("Combat Test: navigation maps are ready for every authored ship", ready)
	var names: Array = scene.get_node("Ships").get_children().map(func(ship: Node) -> String: return str(ship.name))
	var original := ["Gunship", "Destroyer", "Gunship2", "HostileDestroyer", "HostileGunship", "HostileGunship2"]
	_check("Combat Test: the six original armed ships plus FF-01 with its two NC-90 Bastions and four PDC-20 Kestrels, and no stations",
		names == original + ["FF01"]
		and original.all(func(name: String) -> bool: return not CombatShip.of(_ship(name)).weapons.is_empty())
		and CombatShip.of(_ship("FF01")).weapons.size() == 6
		and scene.get_node("Stations").get_child_count() == 0)
	var rect := Rect2(-380, -380, 760, 760)
	_check("Combat Test: 36 authored asteroids; navigation, command bounds, camera, Strategic View and ground cover 760 by 760",
		scene.get_node("Asteroids").ids().size() == 36 and navigation.map_half_size == 380.0
		and scene.sector_half_size() == 380.0 and scene.get_node("CameraRig").bounds == rect
		and scene.strategic.sector_rect() == rect and scene.get_node("Ground").mesh.size == Vector2(760, 760))
	var gunship := _ship("Gunship")
	var b = _b()
	_put("Gunship", Vector2(140, 0), -PI / 2.0)
	var destination := Vector2(200, 0)
	var moved: bool = scene.orders.move([gunship], destination)
	_check("Combat Test: a production MOVE across x = 150 is accepted with a route to x = 200",
		moved and b.command == Behavior.Command.MOVE and _route_ends_at(gunship, destination))
	await _run(25.0)
	_check("Combat Test: the ship actually crosses x = 150 and arrives at x = 200 without collision",
		b._here().x > 150.0 and b._here().distance_to(destination) < 0.5
		and not b.locomotion.has_destination and b.locomotion.collision_count == 0)
	var requested: Vector2 = b.follower.requested
	scene.selection().set_selection([gunship])
	scene.get_node("CameraRig").global_position = Vector3(360, 0, 0)
	var screen := root.get_camera_3d().unproject_position(Vector3(381, 0, 0))
	var outside: Dictionary = scene.resolve_command(screen)
	_check("Combat Test: the player command resolver refuses a point outside the new sector without changing the destination",
		outside.is_empty() and not scene.command_available(outside) and b.follower.requested == requested)
	_put("Destroyer", Vector2(200, 0))
	_put("Gunship", Vector2(200, 28))
	var guarded: int = scene.orders.guard([gunship], _ship("Destroyer"))
	b.set_physics_process(true)
	await _run(0.6)
	_check("Combat Test: Guard requests a usable combat position beyond x = 150 through the production route path",
		guarded == 1 and b.guard_slot >= 0 and b.has_station and b.station.x > 150.0
		and b._slot_usable(b.guard_slot) and _route_ends_at(gunship, b.station))
	await _run(14.0)
	_check("Combat Test: Guard actually reaches its slot beyond x = 150 without collision or command replacement",
		b.command == Behavior.Command.GUARD and b._here().x > 150.0
		and b._here().distance_to(b.slot_point(b.guard_slot)) < 1.5 and b.locomotion.collision_count == 0)
	scene.orders.cancel([gunship])
	_put("Destroyer", Vector2(240, 40))
	_put("Gunship", Vector2(200, 0))
	_put("HostileGunship", Vector2(200, -90))
	scene.sensors.evaluate()
	b.combat.target = _ship("HostileGunship")
	scene.orders.set_stance([gunship], CombatShip.Stance.AGGRESSIVE)
	await _run(2.0)
	var band := Profiles.band(b.combat, b.requested_profile)
	_check("Combat Test: Aggressive engagement requests a routable firing position beyond x = 150",
		b.has_station and b.station.x > 150.0 and b._station_ok(b.station, Vector2(200, -90), band)
		and _route_ends_at(gunship, b.station))
	await _run(20.0)
	_check("Combat Test: engagement actually reaches its firing position beyond x = 150 without collision",
		b.has_station and b._here().x > 150.0 and b._here().distance_to(b.station) < 1.5
		and b._station_ok(b.station, Vector2(200, -90), band) and b.locomotion.collision_count == 0)
	_free()


func _case_reference() -> void:
	await _load(REUSE, null, false, true)
	_check("reuse root has no sector API; a follower's alternate navigation (64) overrides the root navigation (150)",
		not scene.has_method("sector_half_size") and _b()._position_ok(Vector2(60, 0))
		and not _b()._position_ok(Vector2(80, 0))
		and _b()._unusable_reason(Vector2(80, 0)) == "map edge"
		and _b("Destroyer")._position_ok(Vector2(80, 0)))


func _case_exact_edges() -> void:
	await _load(MAIN)
	var b = _b()
	var original: float = b.follower.ship_radius
	# An exactly representable radius makes equality exact in Vector2's float storage.
	# The real 3.4/6.2 radii are covered just inside/outside every edge above.
	b.follower.ship_radius = 4.0
	_check("edge equality remains inclusive, including corners and the Guard margin",
		b._position_ok(Vector2(146, 146)) and b._position_ok(Vector2(-146, -146))
		and b._position_ok(Vector2(142, -142), 4.0)
		and not b._position_ok(Vector2(146 + EPS, 146))
		and not b._position_ok(Vector2(142 + EPS, -142), 4.0))
	b.follower.ship_radius = original


func _case_clearance() -> void:
	await _load(SHOWCASE, Vector2(200, 0), true)
	for name: String in ["Gunship", "Destroyer"]:
		var b = _b(name)
		for margin: float in [0.0, Behavior.GUARD_CHOICE_MARGIN]:
			var clearance: float = b.follower.ship_radius + margin + Behavior.ROCK_CLEARANCE
			_check("%s margin %.0f: asteroid clearance unchanged beyond 135" % [name, margin],
				not b._position_ok(Vector2(200 + 2 + clearance - EPS, 0), margin)
				and b._position_ok(Vector2(200 + 2 + clearance + EPS, 0), margin))
			_check("%s margin %.0f: production station clearance unchanged beyond 135" % [name, margin],
				not b._position_ok(Vector2(200, -80 + 3 + clearance - EPS), margin)
				and b._position_ok(Vector2(200, -80 + 3 + clearance + EPS), margin))
		_check("%s: in-bounds obstacle diagnostics and line-of-fire obstruction remain intact" % name,
			b._unusable_reason(Vector2(200, 0)) == "asteroid"
			and b._unusable_reason(Vector2(200, -80)) == "asteroid"
			and not b.line_clear(Vector2(180, 0), Vector2(220, 0))
			and not b.line_clear(Vector2(180, -80), Vector2(220, -80)))
	var gunship := _ship("Gunship")
	_put("Gunship", Vector2(300, 100))
	var follower = gunship.get_node("RouteFollower")
	var near_edge := Vector2(380.0 - follower.ship_radius - 0.5, 100)
	var nav = scene.get_node("StaticNavigation")
	_check("combat footprint check does not acquire the route planner's additional clearance margin",
		_b()._position_ok(near_edge) and not nav.segment_clear(near_edge, near_edge, follower.planning_radius()))
	var taken: bool = scene.autonomous_move(gunship, near_edge)
	_check("the existing route planner still resolves a near-edge request inward",
		taken and follower.requested == near_edge and follower.route.size() >= 2
		and follower.route[follower.route.size() - 1].distance_to(near_edge) > 0.1
		and _b()._position_ok(follower.route[follower.route.size() - 1]))


func _case_guard() -> void:
	await _load(SHOWCASE)
	_put("Destroyer", Vector2(200, 0))
	_put("Gunship", Vector2(200, 28))
	var g := _ship("Gunship")
	var b = _b()
	var given: int = scene.orders.guard([g], _ship("Destroyer"))
	b.set_physics_process(true)
	await _run(0.6)
	_check("Guard selects and requests a usable slot beyond 135 through the production route path",
		given == 1 and b.guard_slot >= 0 and b.has_station and b.station.x > 135
		and b._slot_usable(b.guard_slot) and _route_ends_at(g, b.station))
	await _run(12.0)
	_check("Guard reaches its slot beyond 135 without a collision or command replacement",
		b.command == Behavior.Command.GUARD and b.guard_slot >= 0
		and b._here().distance_to(b.slot_point(b.guard_slot)) < 1.5
		and g.get_node("Locomotion").collision_count == 0)
	b.set_physics_process(false)
	_put("Destroyer", Vector2(370, 0))
	_put("Gunship", Vector2(370, 28))
	b.guard_slot = 6 # Astern, x = 370.
	_ship("Destroyer").get_node("Locomotion").velocity = Vector2(10, 0)
	b._guard()
	_check("Guard rejects an out-of-sector lead point and requests its valid unled slot",
		b.has_station and b.station.distance_to(b.slot_point(6)) < EPS
		and b._unusable_reason(b.slot_point(6) + Vector2(20, 0)) == "map edge")
	_put("Destroyer", Vector2(375, 0))
	_check("Guard edge slots preserve footprint and choice-margin rejection",
		not b._slot_usable(1) and b._slot_usable(0)
		and not b._slot_usable(6, Behavior.GUARD_CHOICE_MARGIN))


func _case_engagement(mode: String) -> void:
	await _load(SHOWCASE)
	_put("Gunship", Vector2(200, 0))
	_put("HostileGunship", Vector2(200, -90))
	var g := _ship("Gunship")
	var enemy := _ship("HostileGunship")
	var b = _b()
	b.combat.target = enemy
	match mode:
		"Aggressive":
			scene.orders.set_stance([g], CombatShip.Stance.AGGRESSIVE)
		"Attack":
			scene.orders.attack([g], enemy) # Passive + explicit Attack remains authorized.
		"Attack-Move":
			scene.orders.set_stance([g], CombatShip.Stance.AGGRESSIVE)
			scene.orders.attack_move([g], Vector2(200, -130))
	b.set_physics_process(true)
	await _run(2.0)
	var band := Profiles.band(b.combat, b.requested_profile)
	var positioned: bool = b.has_station and b.station.x > 135 and b._station_ok(b.station, Vector2(200, -90), band)
	_check("%s: engagement station beyond 135 is requested, routable and retained as valid" % mode,
		positioned and _route_ends_at(g, b.station) and b.fallbacks.size() <= 1)
	if mode == "Attack-Move":
		_check("Attack-Move engagement still respects its route leash",
			b.encounter == enemy and b._route_offset(b.station) <= Behavior.ATTACK_MOVE_LEASH)
	var requests: int = b.move_requests
	await _run(0.6)
	_check("%s: an existing valid engagement station causes no redundant movement request" % mode,
		b.move_requests == requests)


func _case_attack_move_leash() -> void:
	await _load(SHOWCASE)
	_put("Gunship", Vector2(200, 0))
	_put("HostileGunship", Vector2(310, -40))
	var b = _b()
	b.combat.target = _ship("HostileGunship")
	scene.orders.set_stance([_ship("Gunship")], CombatShip.Stance.AGGRESSIVE)
	scene.orders.attack_move([_ship("Gunship")], Vector2(200, -130))
	b.set_physics_process(true)
	await _run(2.0)
	_check("newly valid stations outside the Attack-Move leash do not replace destination travel",
		b.encounter == null and b.command == Behavior.Command.ATTACK_MOVE
		and b.station == b.destination and b.move_requests == 1)


func _case_defensive() -> void:
	await _load(SHOWCASE, Vector2(200, -20))
	_put("Gunship", Vector2(200, 0))
	_put("HostileGunship", Vector2(200, -60))
	var g := _ship("Gunship")
	var enemy := _ship("HostileGunship")
	var b = _b()
	scene.orders.set_stance([g], CombatShip.Stance.DEFENSIVE)
	b.combat.target = enemy
	b.combat.threats[enemy] = CombatShip.now() + 100.0
	var obscured: bool = b.combat.weapons.any(func(w: Node) -> bool: return w.assess(enemy).state == CombatShip.TargetState.OBSCURED)
	b.set_physics_process(true)
	await _run(2.0)
	_check("Defensive restores obstructed fire with a local firing-position request beyond 135",
		obscured and b.reposition_requests == 1 and b.has_station and b.station.x > 135
		and b.station.distance_to(b.anchor) <= Behavior.DEFENSE_RADIUS
		and b._firing_position_ok(b.station, enemy, b.combat.weapons)
		and _route_ends_at(g, b.station))
	await _run(5.0)
	var requests: int = b.move_requests
	_put("HostileGunship", Vector2(200, -140))
	await _run(2.0)
	_check("Defensive does not pursue an out-of-range threat after its local reposition",
		b.move_requests == requests and b._here().distance_to(b.anchor) <= Behavior.DEFENSE_RADIUS + EPS)
	b.combat.target = null
	await _run(7.0)
	_check("Defensive still returns to its anchor after the threat ends",
		b._here().distance_to(b.anchor) <= Behavior.ANCHOR_TOLERANCE
		and g.get_node("Locomotion").collision_count == 0)


func _case_waypoints() -> void:
	await _load(SHOWCASE)
	_put("Gunship", Vector2(200, 0))
	_put("Destroyer", Vector2(200, 20))
	var group := [_ship("Gunship"), _ship("Destroyer")]
	var first: int = scene.orders.waypoint(group, Vector2(220, -30), false)
	var offsets: Array[Vector2] = [_b().waypoint_offset, _b("Destroyer").waypoint_offset]
	# Drift after dispatch makes recomputing from the current spread observably different.
	_ship("Gunship").get_node("Locomotion").place(Vector2(210, 0), 0.0)
	var next := Vector2(260, -60)
	var appended: int = scene.orders.waypoint(group, next, true)
	_check("appended group waypoints beyond 135 preserve their original offsets after a ship drifts",
		first == 2 and appended == 2
		and _b().waypoints.back() == next + offsets[0]
		and _b("Destroyer").waypoints.back() == next + offsets[1])
	var edge: int = scene.orders.waypoint(group, Vector2(400, -60), true)
	_check("group waypoints still reassign offsets that would put footprints beyond the real sector",
		edge == 2 and _b()._position_ok(_b().waypoints.back())
		and _b("Destroyer")._position_ok(_b("Destroyer").waypoints.back())
		and (_b().waypoint_offset != offsets[0] or _b("Destroyer").waypoint_offset != offsets[1]))
