extends SceneTree
## FF-01 composition (two Bastions, four Kestrels, one Barrage, one Wayfarer) and real selection / command input
## on the production movement loop in the Combat Test scene, from a test-owned starting position.
## Run: <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/ff01_test.gd

const UNIT := preload("res://game/ships/ff01_unit.tscn")
const WARSHIP := preload("res://game/ships/archetypes/warship.tscn")
const ARENA := preload("res://game/scenes/combat_test.tscn")
const Hardpoint := preload("res://game/weapons/hardpoint.gd")
const BASTION := "res://game/weapons/nc90_bastion.tscn"
const KESTREL := "res://game/weapons/pdc20_kestrel.tscn"
const BARRAGE := "res://game/weapons/rl8_barrage.tscn"
const WAYFARER := "res://game/weapons/gcm4_wayfarer.tscn"
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const EPS := 0.00001
## Test-owned starting position (facing +X); independent of the authored Combat Test spawns.
const SPAWN := Vector3(-45, 1.5, 0)
## The large-hull handling the FF-01 sets over the warship archetype.
const HANDLING := {
	"Locomotion": {"max_speed": 3.0, "max_reverse_speed": 1.5, "max_lateral_speed": 1.0, "forward_accel": 1.2, "reverse_accel": 0.5,
		"lateral_accel": 0.3, "max_turn_rate_deg": 25.0, "turn_accel_deg": 20.0},
	"RouteFollower": {"ship_radius": 6.2, "clearance_margin": 1.0},
	"Avoidance": {"size_class": 3, "separation_margin": 1.0},
	"Fuel": {"capacity": 400.0, "consumption": 1.0},
}
const MOUNTS := {
	"ForwardBastionHardpoint": [Vector3(0, 0.55, -3), 0.0, 120.0, 1, ["cannon"]],
	"AftBastionHardpoint": [Vector3(0, 0.55, 3), 180.0, 120.0, 1, ["cannon"]],
	"ForwardPortPDCHardpoint": [Vector3(-1.3, 0.55, -4), 45.0, 90.0, 0, ["gatling"]],
	"ForwardStarboardPDCHardpoint": [Vector3(1.3, 0.55, -4), -45.0, 90.0, 0, ["gatling"]],
	"AftPortPDCHardpoint": [Vector3(-1.3, 0.55, 4), 135.0, 90.0, 0, ["gatling"]],
	"AftStarboardPDCHardpoint": [Vector3(1.3, 0.55, 4), -135.0, 90.0, 0, ["gatling"]],
	"BarrageHardpoint": [Vector3(0, 0, -5.85), 0.0, 0.0, 1, ["rocket"]],
	"WayfarerHardpoint": [Vector3(0, 0.55, 0), 0.0, 160.0, 1, ["missile"]],
}


var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	_authored()
	await _load()
	await _selection_and_movement()
	await _commands()
	scene.free()
	await process_frame
	_check("no orphan nodes after FF-01 verification", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(message: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-116s %s" % [message, "PASS" if ok else "FAIL"])


func _authored() -> void:
	var unit := UNIT.instantiate()
	var reference := WARSHIP.instantiate()
	var defaults := Behavior.new()
	_check("FF-01 inherits the shared warship archetype and instances ff01.tscn at identity",
		UNIT.get_state().get_node_instance(0).resource_path == "res://game/ships/archetypes/warship.tscn"
		and unit.get_node("Model").scene_file_path == "res://game/ships/ff01.tscn"
		and unit.get_node("Model").transform.is_equal_approx(Transform3D.IDENTITY))
	var order := unit.get_children().map(func(node: Node) -> String: return str(node.name))
	_check("shared component and initialization order is preserved, with Behavior before Model",
		order == ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Docking", "Fuel", "Weapons", "Combat", "Behavior", "Model"])
	for name: String in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Docking", "Fuel", "Combat", "Behavior"]:
		var a := unit.get_node(name)
		var b: Node = reference.get_node(name) if reference.has_node(name) else defaults
		var handling: Dictionary = HANDLING.get(name, {})
		var same: bool = a.get_script() == b.get_script()
		for prop in b.get_property_list():
			# Combat.durability is FF-01's own configuration (checked below); the handling
			# is the large hull's (checked against its values).
			if prop.usage & PROPERTY_USAGE_STORAGE and not (name == "Combat" and prop.name == "durability") \
					and not (name == "Behavior" and String(prop.name).begins_with("combat_")) and not handling.has(prop.name):
				same = same and a.get(prop.name) == b.get(prop.name)
		for prop: String in handling:
			same = same and a.get(prop) == handling[prop]
		_check("%s uses the existing script, the shared defaults and the large-hull handling" % name, same)
	var behavior := unit.get_node("Behavior")
	_check("FF-01 cannon positioning with the approved editable prototype parameters",
		behavior.combat_weapon_family == &"cannon"
		and behavior.combat_min_distance == 27.0 and behavior.combat_max_distance == 45.0 and behavior.combat_nominal_distance == 38.25
		and behavior.combat_tangential_speed == 1.5 and behavior.combat_decision_interval == 0.5 and behavior.combat_order_interval == 1.0)
	_check("FF-01 exposes a continuous transition region and limits cannon-facing adjustment to its flight course",
		behavior.combat_transition_width > 0.0 and behavior.combat_course_slack_deg <= 10.0
		and behavior.combat_course_response_time > 0.0 and behavior.combat_course_replan_deg > 0.0)
	_check("Combat durability is ff01_durability.tres (160 / 100 / 30); the archetype has none",
		unit.get_node("Combat").durability == preload("res://game/ships/ff01_durability.tres") and reference.get_node("Combat").durability == null
		and unit.get_node("Combat").durability.max_hull == 160.0 and unit.get_node("Combat").durability.max_armor == 100.0
		and unit.get_node("Combat").durability.armor_resistance == 30.0)
	_check("footprint 6.2, clearance 1.0, size class 3, separation 1.0, fuel 400 / consumption 1.0",
		unit.get_node("RouteFollower").ship_radius == 6.2 and unit.get_node("RouteFollower").clearance_margin == 1.0
		and unit.get_node("Avoidance").size_class == 3 and unit.get_node("Avoidance").separation_margin == 1.0
		and unit.get_node("Fuel").capacity == 400.0 and unit.get_node("Fuel").consumption == 1.0)
	var weapons := unit.get_node("Weapons")
	_check("Weapons has exactly the eight named reservations at identity", weapons.transform.is_equal_approx(Transform3D.IDENTITY)
		and weapons.get_children().map(func(node: Node) -> String: return str(node.name)) == MOUNTS.keys())
	for name: String in MOUNTS:
		var mount := weapons.get_node(name)
		var row: Array = MOUNTS[name]
		var bastion: bool = name in ["ForwardBastionHardpoint", "AftBastionHardpoint"]
		var pdc: bool = name.ends_with("PDCHardpoint")
		var barrage: bool = name == "BarrageHardpoint"
		var wayfarer: bool = name == "WayfarerHardpoint"
		var installed: bool = mount.get_child_count() == 0 and mount.weapon() == null
		if bastion or pdc or barrage or wayfarer:
			installed = mount.get_child_count() == 1 and mount.weapon() != null and mount.weapon().scene_file_path == (BASTION if bastion else (KESTREL if pdc else (BARRAGE if barrage else WAYFARER)))
		_check("%s: exact position, neutral yaw, limit, size, family; %s" % [name, "one NC-90 Bastion installed" if bastion else ("one PDC-20 Kestrel installed" if pdc
			else ("one RL-8 Barrage installed" if barrage else "one GCM-4 Wayfarer installed"))],
			mount.get_script() == Hardpoint and mount.position.is_equal_approx(row[0])
			and mount.basis.is_equal_approx(Basis(Vector3.UP, deg_to_rad(row[1])))
			and mount.yaw_limit_deg == row[2] and mount.size == row[3] and Array(mount.families) == row[4]
			and installed)
	_check("Barrage is fixed and accepts the rocket family; shared cone default remains unused",
		weapons.get_node("BarrageHardpoint").pitch_min_deg == 0.0 and weapons.get_node("BarrageHardpoint").pitch_max_deg == 0.0
		and weapons.get_node("BarrageHardpoint").cone_deg == 15.0)
	var model := unit.get_node("Model")
	var bounds := AABB()
	var first := true
	var fits := true
	var primitives := true
	var neutral := true
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var transform := mesh.transform
		var ancestor := mesh.get_parent()
		while ancestor != model:
			transform = ancestor.transform * transform
			ancestor = ancestor.get_parent()
		var box: AABB = transform * mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
		for i in 8:
			var corner := box.get_endpoint(i)
			fits = fits and Vector2(corner.x, corner.z).length() <= 6.2 + EPS
		primitives = primitives and mesh.mesh is PrimitiveMesh and mesh.get_script() == null
		var color: Color = mesh.mesh.material.albedo_color
		neutral = neutral and is_equal_approx(color.r, color.g) and is_equal_approx(color.g, color.b)
	_check("complete Model bounds: length 12, width 3, height 1.1, centered at origin",
		bounds.position.is_equal_approx(Vector3(-1.5, -0.55, -6)) and bounds.size.is_equal_approx(Vector3(3, 1.1, 12)))
	_check("every hull/thruster box corner fits the planar radius; only native meshes and neutral gray materials", fits and primitives and neutral)
	var bow := model.get_node("Bow") as MeshInstance3D
	var tip_width := 0.0
	var shoulder_width := 0.0
	for vertex: Vector3 in bow.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		var point: Vector3 = bow.transform * vertex
		if absf(point.z + 6.0) < EPS:
			tip_width = maxf(tip_width, absf(point.x))
		if absf(point.z + 4.0) < EPS:
			shoulder_width = maxf(shoulder_width, absf(point.x))
	_check("actual bow vertices taper to -Z, with full-width shoulders aft", tip_width < EPS and absf(shoulder_width - 1.5) < EPS)
	var jets := ["Retro_L", "Retro_R", "Bow_L", "Bow_R", "Lateral_L", "Lateral_R", "Stern_L", "Stern_R"]
	_check("native thruster convention: engine cylinders and all eight named jet boxes",
		model.get_node("Thrusters/MainEngine").mesh is CylinderMesh
		and jets.all(func(name: String) -> bool: return model.get_node("Thrusters/" + name).mesh is BoxMesh))
	unit.free()
	reference.free()
	defaults.free()


func _load() -> void:
	scene = ARENA.instantiate()
	# A second friendly FF-01 (test-added) to receive the Guard command.
	var friend: Node3D = UNIT.instantiate()
	friend.name = "FriendFF01"
	friend.position = Vector3(0, 1.5, 20)
	scene.get_node("Ships").add_child(friend)
	root.add_child(scene)
	scene.get_node("Ships/FF01/Locomotion").place(Vector2(SPAWN.x, SPAWN.z), -PI / 2.0)
	scene.get_node("Ships/FF01/Avoidance").reset()
	for ship in scene.get_node("Ships").get_children():
		ship.get_node("Combat").stance = CombatShip.Stance.HOLD_FIRE
		ship.get_node("Combat").set_physics_process(false)
		if ship.name != &"FF01":
			ship.get_node("Behavior").set_physics_process(false)
	var follower := scene.get_node("Ships/FF01/RouteFollower")
	var navigation := scene.get_node("StaticNavigation")
	var ready := false
	for i in 120:
		ready = navigation.is_ready(follower.planning_radius())
		if ready:
			break
		await physics_frame
	_check("FF-01 navigation map is ready at planning radius 7.2", ready and follower.planning_radius() == 7.2)
	var subject := scene.get_node("Ships/FF01")
	_check("two Bastions, four Kestrels, one Barrage and one Wayfarer, no incompatible weapons, no shots; full initial fuel",
		CombatShip.of(subject).weapons.size() == 8 and CombatShip.of(subject).incompatible.is_empty()
		and scene.projectiles.spawned == 0 and scene.projectiles.launched == 0
		and subject.get_node("Fuel").fuel == 400.0)
	_check("FF-01 resolves the arena's existing navigation, collision, contacts and projectile services",
		follower._navigation == navigation and subject.get_node("Locomotion")._collision == scene.get_node("PlanarCollision")
		and CombatShip.of(subject).contacts == scene.contacts and CombatShip.of(subject).projectiles == scene.projectiles)
	var rect := Rect2(-380, -380, 760, 760)
	_check("camera and Strategic View follow +/-380; FF-01 positioning also follows the new sector",
		scene.get_node("CameraRig").bounds == rect and scene.strategic.sector_rect() == rect
		and subject.get_node("Behavior")._position_ok(Vector2(200, -200))
		and not subject.get_node("Behavior")._position_ok(Vector2(381, -200)))


func _look_at(point: Vector3) -> void:
	scene.get_node("CameraRig").global_position = Vector3(point.x, 0, point.z)
	await process_frame
	await process_frame


func _click(button: MouseButton, point: Vector3, control := false) -> void:
	var screen := root.get_camera_3d().unproject_position(point)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.position = screen
		event.global_position = screen
		event.ctrl_pressed = control
		event.pressed = pressed
		root.push_input(event, true)
	await process_frame


func _selection_and_movement() -> void:
	var subject := scene.get_node("Ships/FF01")
	await _look_at(subject.global_position)
	await _click(MOUSE_BUTTON_LEFT, subject.global_position)
	_check("a real left-click selects FF-01 through existing hull picking and registration", scene.selection().selected == [subject]
		and scene.selection()._parts.has(subject) and scene._markers.has(subject))
	var panel := scene.get_node("ShipPanel")
	await process_frame
	_check("FF-01 panel: hull 160, command controls, two NC-90 and four PDC-20 weapon rows",
		panel.ship == subject and panel._hull.visible and panel._hull_amount.text == "Hull: 160 / 160" and panel._combat.visible
		and panel._weapons.text.count("NC-90 Bastion") == 2 and panel._weapons.text.count("PDC-20 Kestrel") == 4)
	var destination := Vector3(-18, 0, -40)
	await _look_at(destination)
	await _click(MOUSE_BUTTON_RIGHT, destination)
	var follower := subject.get_node("RouteFollower")
	var locomotion := subject.get_node("Locomotion")
	_check("a real right-click gives FF-01 a MOVE to (-18, -40)", subject.get_node("Behavior").command == Behavior.Command.MOVE
		and follower.requested.distance_to(Vector2(-18, -40)) < 0.05 and locomotion.has_destination)
	var fuel_before: float = subject.get_node("Fuel").fuel
	var traveled := 0.0
	var stays_planar := true
	for i in 3600:
		var before: Vector2 = locomotion.planar_position
		await physics_frame
		traveled += before.distance_to(locomotion.planar_position)
		stays_planar = stays_planar and is_equal_approx(subject.global_position.y, SPAWN.y)
		if not locomotion.has_destination:
			break
	_check("FF-01 actually travels and arrives using normal navigation/avoidance/collision at fixed height",
		traveled > 27.0 and locomotion.planar_position.distance_to(Vector2(-18, -40)) < 0.5
		and not locomotion.has_destination and locomotion.collision_count == 0 and stays_planar)
	_check("existing fuel accounting charges actual movement at the unchanged consumption rate",
		absf(fuel_before - subject.get_node("Fuel").fuel - traveled) < 0.01)
	_check("movement emits the existing thruster effects; the two Bastions, four Kestrels, Barrage and Wayfarer stay installed",
		scene.get_node("ThrusterView").plumes_of(subject).size() == 2 and CombatShip.of(subject).weapons.size() == 8
		and scene.projectiles.spawned == 0 and scene.projectiles.launched == 0)


func _commands() -> void:
	var subject := scene.get_node("Ships/FF01")
	var behavior := subject.get_node("Behavior")
	var hostile := scene.get_node("Ships/HostileFF01")
	hostile.get_node("Locomotion").place(Vector2(35, -40), 0.0)
	hostile.get_node("Avoidance").reset()
	scene.sensors.evaluate()
	await _look_at(hostile.global_position)
	await _click(MOUSE_BUTTON_RIGHT, hostile.global_position)
	_check("right-click on a visible hostile assigns FF-01's target", CombatShip.of(subject).manual_target == hostile)
	await _click(MOUSE_BUTTON_RIGHT, hostile.global_position, true)
	_check("Ctrl-right-click gives the existing Attack command to FF-01", behavior.command == Behavior.Command.ATTACK
		and behavior.attack_target == hostile)
	scene.orders.cancel([subject])
	var friend := scene.get_node("Ships/FriendFF01")
	await _look_at(friend.global_position)
	await _click(MOUSE_BUTTON_RIGHT, friend.global_position, true)
	_check("Ctrl-right-click on a friendly ship gives the existing Guard command", behavior.command == Behavior.Command.GUARD
		and behavior.guard_target == friend)
	scene.orders.cancel([subject])
	var destination := Vector3(-18, 0, -50)
	await _look_at(destination)
	await _click(MOUSE_BUTTON_RIGHT, destination, true)
	_check("Ctrl-right-click on ground gives the existing Attack-Move command", behavior.command == Behavior.Command.ATTACK_MOVE
		and behavior.destination.distance_to(Vector2(-18, -50)) < 0.1)
	scene.orders.cancel([subject])
	_check("waypoints use the same command interface", scene.orders.waypoint([subject], Vector2(-18, -55), false) == 1
		and behavior.command == Behavior.Command.WAYPOINTS)
	scene.orders.cancel([subject])
	_check("combat-related orders keep the two Bastions, four Kestrels, Barrage and Wayfarer and produce no projectiles (Combat not stepped here)", CombatShip.of(subject).weapons.size() == 8
		and scene.projectiles.spawned == 0 and scene.projectiles.launched == 0)
