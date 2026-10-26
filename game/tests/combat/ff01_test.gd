extends SceneTree
## FF-01 composition, mount reservations (two NC-90 Bastions, four PDC-20 Kestrels, two empty), preserved Combat Test content, and
## real selection / command input on the production movement loop.
## Run: <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/ff01_test.gd

const UNIT := preload("res://game/ships/ff01_unit.tscn")
const DESTROYER := preload("res://game/ships/destroyer_unit.tscn")
const ARENA := preload("res://game/scenes/combat_test.tscn")
const MAIN := preload("res://main.tscn")
const Hardpoint := preload("res://game/weapons/hardpoint.gd")
const BASTION := "res://game/weapons/nc90_bastion.tscn"
const KESTREL := "res://game/weapons/pdc20_kestrel.tscn"
const BARRAGE := "res://game/weapons/rl8_barrage.tscn"
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const Profiles := preload("res://game/behavior/weapon_profiles.gd")
const EPS := 0.00001
const SPAWN := Vector3(-18, 1.5, -12)
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
const ORIGINAL := {
	"Gunship": ["res://game/ships/gunship_unit.tscn", Vector3(0, 1.5, 0), 0.0, 0],
	"Destroyer": ["res://game/ships/destroyer_unit.tscn", Vector3(14, 1.5, 0), 0.0, 0],
	"Gunship2": ["res://game/ships/gunship_unit.tscn", Vector3(2, 1.5, -12), 0.0, 0],
	"HostileDestroyer": ["res://game/ships/destroyer_unit.tscn", Vector3(126, 1.5, 2), PI / 2.0, 1],
	"HostileGunship": ["res://game/ships/gunship_unit.tscn", Vector3(117, 1.5, -6), PI / 2.0, 1],
	"HostileGunship2": ["res://game/ships/gunship_unit.tscn", Vector3(117, 1.5, 11), PI / 2.0, 1],
}

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	_authored()
	_preserved_arena()
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
	var reference := DESTROYER.instantiate()
	_check("FF-01 inherits the shared warship archetype and instances ff01.tscn at identity",
		UNIT.get_state().get_node_instance(0).resource_path == "res://game/ships/archetypes/warship.tscn"
		and unit.get_node("Model").scene_file_path == "res://game/ships/ff01.tscn"
		and unit.get_node("Model").transform.is_equal_approx(Transform3D.IDENTITY))
	var order := unit.get_children().map(func(node: Node) -> String: return str(node.name))
	_check("shared component and initialization order is preserved, with Behavior before Model",
		order == ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Docking", "Fuel", "Weapons", "Combat", "Behavior", "Model"])
	for name: String in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Docking", "Fuel", "Combat", "Behavior"]:
		var a := unit.get_node(name)
		var b := reference.get_node(name)
		var same: bool = a.get_script() == b.get_script()
		for prop in b.get_property_list():
			# Combat.durability is FF-01's own configuration (checked below).
			if prop.usage & PROPERTY_USAGE_STORAGE and not (name == "Combat" and prop.name == "durability"):
				same = same and a.get(prop.name) == b.get(prop.name)
		_check("%s uses the existing script and Destroyer baseline settings" % name, same)
	_check("Combat durability is ff01_durability.tres (160 / 100 / 30); the Destroyer has none",
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
		var installed: bool = mount.get_child_count() == 0 and mount.weapon() == null
		if bastion or pdc or barrage:
			installed = mount.get_child_count() == 1 and mount.weapon() != null and mount.weapon().scene_file_path == (BASTION if bastion else (KESTREL if pdc else BARRAGE))
		_check("%s: exact position, neutral yaw, limit, size, family; %s" % [name, "one NC-90 Bastion installed" if bastion else ("one PDC-20 Kestrel installed" if pdc
			else ("one RL-8 Barrage installed" if barrage else "no installed child"))],
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


# Built-in mesh/material values are compared, rather than scene-local resource IDs.
func _same_resource(a: Resource, b: Resource) -> bool:
	if a == null or b == null:
		return a == b
	if a.get_class() != b.get_class():
		return false
	for prop in a.get_property_list():
		if not prop.usage & PROPERTY_USAGE_STORAGE or prop.name in ["resource_path", "resource_scene_unique_id"]:
			continue
		var left: Variant = a.get(prop.name)
		var right: Variant = b.get(prop.name)
		if left is Resource or right is Resource:
			if not _same_resource(left, right):
				return false
		elif left != right:
			return false
	return true


func _preserved_arena() -> void:
	var arena := ARENA.instantiate()
	var reference := MAIN.instantiate()
	var expected := ORIGINAL.keys() + ["FF01"]
	_check("Combat Test contains the original six ships plus FF-01 and an empty Stations container",
		arena.get_node("Ships").get_children().map(func(node: Node) -> String: return str(node.name)) == expected
		and arena.get_node("Stations").get_child_count() == 0)
	for name: String in ORIGINAL:
		var row: Array = ORIGINAL[name]
		var ship := arena.get_node("Ships/" + name)
		var stance := CombatShip.Stance.AGGRESSIVE if row[3] == 1 else CombatShip.Stance.DEFENSIVE
		_check("original %s: unchanged variant, transform, faction and stance" % name,
			ship.scene_file_path == row[0] and ship.transform.is_equal_approx(Transform3D(Basis(Vector3.UP, row[2]), row[1]))
			and ship.get_node("Combat").faction == row[3] and ship.get_node("Combat").stance == stance)
	var overrides_ok := true
	var state := ARENA.get_state()
	for i in state.get_node_count():
		var path := str(state.get_node_path(i)).trim_prefix("./")
		if not path.begins_with("Ships/") or not ORIGINAL.has(path.get_slice("/", 1)):
			continue
		var child_override := path.count("/") > 1
		if child_override and not (path.ends_with("/Combat") and path.get_slice("/", 1).begins_with("Hostile")):
			overrides_ok = false
		for p in state.get_node_property_count(i):
			var property := str(state.get_node_property_name(i, p))
			overrides_ok = overrides_ok and property in (["faction", "stance"] if child_override else ["transform"])
	_check("no added overrides/components on original ships; their loadouts and shared configuration remain inherited", overrides_ok)
	var field := arena.get_node("Asteroids")
	var original := reference.get_node("Asteroids")
	var rocks_match: bool = field.get_child_count() == 36 and original.get_child_count() == 36 and field.get_script() == original.get_script()
	for property: String in ["session_seed", "mineral_share", "min_reserves", "max_reserves"]:
		rocks_match = rocks_match and field.get(property) == original.get(property)
	for rock: MeshInstance3D in field.get_children():
		var other := original.get_node_or_null(NodePath(rock.name)) as MeshInstance3D
		rocks_match = rocks_match and other != null and rock.transform == other.transform
		rocks_match = rocks_match and rock.get_meta("asteroid_id") == other.get_meta("asteroid_id") and _same_resource(rock.mesh, other.mesh)
	_check("all 36 asteroid transforms, IDs, primitive/material settings and deposit configuration match the original field", rocks_match)
	_check("Combat Test remains a 760 by 760 arena, navigation half-size 380",
		arena.get_node("StaticNavigation").map_half_size == 380.0 and arena.get_node("Ground").mesh.size == Vector2(760, 760))
	var subject := arena.get_node("Ships/FF01")
	_check("FF-01 is an unmodified friendly unit instance at (-18, 1.5, -12)", subject.scene_file_path == UNIT.resource_path
		and subject.position == SPAWN and subject.basis.is_equal_approx(Basis.IDENTITY) and subject.get_node("Combat").faction == 0)
	arena.free()
	reference.free()


func _load() -> void:
	scene = ARENA.instantiate()
	root.add_child(scene)
	scene.get_node("HostileCommander").set_physics_process(false)
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
	var point := Vector2(SPAWN.x, SPAWN.z)
	var clear: bool = navigation.segment_clear(point, point, follower.planning_radius())
	for ship in scene.get_node("Ships").get_children():
		if ship != subject:
			clear = clear and subject.get_node("Locomotion").planar_position.distance_to(ship.get_node("Locomotion").planar_position) > follower.ship_radius + ship.get_node("RouteFollower").ship_radius
	_check("authored spawn clears every ship footprint and every asteroid with planning clearance", clear)
	_check("two installed Bastions, four Kestrels and one Barrage, no incompatible weapons, Mid-range and Close Quarters profiles, no shots; full initial fuel",
		CombatShip.of(subject).weapons.size() == 7 and CombatShip.of(subject).incompatible.is_empty()
		and Profiles.available(CombatShip.of(subject)) == [Profiles.Profile.MID, Profiles.Profile.CLOSE] and scene.projectiles.spawned == 0 and scene.projectiles.launched == 0
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
	_check("FF-01 panel: hull 160, command controls, the Mid-range and Close Quarters profiles, two NC-90 and four PDC-20 weapon rows",
		panel.ship == subject and panel._hull.text == "Hull: 160 / 160" and panel._combat.visible
		and panel._profile.item_count == 2 and panel._weapons.text.count("NC-90 Bastion") == 2 and panel._weapons.text.count("PDC-20 Kestrel") == 4)
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
	_check("movement emits the existing thruster effects; the two Bastions, four Kestrels and the Barrage stay installed",
		scene.get_node("ThrusterView").plumes_of(subject).size() == 2 and CombatShip.of(subject).weapons.size() == 7
		and scene.projectiles.spawned == 0 and scene.projectiles.launched == 0)


func _commands() -> void:
	var subject := scene.get_node("Ships/FF01")
	var behavior := subject.get_node("Behavior")
	var hostile := scene.get_node("Ships/HostileGunship")
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
	var friend := scene.get_node("Ships/Gunship")
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
	_check("combat-related orders keep the two Bastions, four Kestrels and the Barrage and produce no projectiles (Combat not stepped here)", CombatShip.of(subject).weapons.size() == 7
		and scene.projectiles.spawned == 0 and scene.projectiles.launched == 0)
