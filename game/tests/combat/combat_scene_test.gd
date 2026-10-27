extends SceneTree
## Combat migration M7: the integrated production scenes. Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/combat_scene_test.gd
## On game/scenes/combat_test.tscn (the standalone combat arena: a player FF-01 and an
## Aggressive hostile FF-01, no commander), with the two ships placed by the test at
## (-45, 0) and (45, 0) facing each other, within sensor range, independent of the
## authored spawns:
##   S1 the hostile ship acts on its own Behavior (Aggressive, no command); one authority
##      per world service
##   S2 the full battle with the player's FF-01 Aggressive: detection, fire, 4-missile
##      salvos, point-defense interceptions, a kill, a result; nothing in flight, no stale
##      reference and no orphan node afterwards
##   S5 controls: a right-click on a visible hostile targets it (no MOVE); at Tactical zoom
##      the markers pick own ships and never select a hostile; the ship panel shows the hull
##      and, for armed ships only, tactic and weapons
## On main.tscn (the economy running):
##   S3 pause (Space): simulation clock, mining, refining, ship construction, fuel and
##      movement stop; a right-click MOVE is taken at once without anything moving; the
##      camera still pans; resumed, everything goes on
##   S4 time dilation 2x and 0.25x: the simulation clock and the economy advance at that
##      rate per frame; 1x restores it
##   S6 a ship produced by the Shipyard: hull 150, player faction, no weapons, no
##      Behavior, selectable, damaged by hostile fire

const COMBAT_TEST := preload("res://game/scenes/combat_test.tscn")
const MAIN := preload("res://main.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const SimClock := preload("res://game/time/sim_clock.gd")
const DT := 1.0 / 60.0
const PLAYER_FLEET := ["FF01"]
const HOSTILES := ["HostileFF01"]

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _s1_s2()
	await _s5_controls()
	await _s5_unarmed_panel()
	await _s3_pause()
	await _s4_dilation()
	await _s6_produced()
	_free()
	await process_frame
	_check("no orphan nodes after the last scene (%d)" % Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _free() -> void:
	if scene != null and is_instance_valid(scene):
		root.remove_child(scene)
		scene.free()
	scene = null


func _load(packed: PackedScene) -> void:
	_free()
	scene = packed.instantiate()
	root.add_child(scene)
	for i in 10:
		await physics_frame


func _ship(name: String) -> Node3D:
	return scene.get_node("Ships").get_node_or_null(name)


# Test-owned encounter layout: overrides the authored Combat Test spawns.
func _stage() -> void:
	for entry in [["FF01", Vector2(-45, 0), -PI / 2.0], ["HostileFF01", Vector2(45, 0), PI / 2.0]]:
		_ship(entry[0]).get_node("Locomotion").place(entry[1], entry[2])
		_ship(entry[0]).get_node("Avoidance").reset()
	await physics_frame
	scene.sensors.evaluate()


func _run(seconds: float, until: Callable = Callable()) -> bool:
	for i in roundi(seconds / DT):
		await physics_frame
		if until.is_valid() and until.call():
			return true
	return false


func _screen(point: Vector3) -> Vector2:
	return root.get_camera_3d().unproject_position(point)


func _click(button: MouseButton, screen: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = screen
		event.global_position = screen
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


func _look_at(point: Vector3) -> void:
	scene.get_node("CameraRig").global_position = Vector3(point.x, 0.0, point.z)
	await process_frame
	await process_frame


func _s1_s2() -> void:
	print("\n=== S1 commander and fog")
	await _load(COMBAT_TEST)
	await _stage()
	await process_frame
	await _run(3.0)
	var commands := HOSTILES.map(func(n: String) -> String: return Behavior.COMMAND_NAMES[Behavior.of(_ship(n)).command])
	var tactics := HOSTILES.all(func(n: String) -> bool: return CombatShip.of(_ship(n)).stance == CombatShip.Stance.AGGRESSIVE)
	_check("no commander: the hostile FF-01 acts on its own Behavior (command %s), Aggressive" % str(commands),
		not scene.has_node("HostileCommander") and commands == ["None"] and tactics)
	# One authority each; one combat component per ship; one command handler per Behavior.
	var count := func(script_path: String) -> int:
		return scene.find_children("*", "", true, false).filter(func(n: Node) -> bool: return n.get_script() != null and n.get_script().resource_path == script_path).size()
	var ships: Array = scene.get_node("Ships").get_children()
	var behaviors := ships.filter(func(s: Node) -> bool: return s.has_node("Behavior")).size()
	var singles := [count.call("res://game/time/sim_clock.gd"), count.call("res://game/time/time_control.gd"), count.call("res://game/combat/combat_orders.gd"),
		count.call("res://game/sensors/sensors.gd"), count.call("res://game/combat/projectile_system.gd")]
	_check("one clock, time authority, command interface, sensor system and projectile system %s; one Combat per ship (%d / %d); %d command_given handlers for %d Behaviors" % [
		str(singles), count.call("res://game/combat/combat_ship.gd"), ships.size(), scene.command_given.get_connections().size(), behaviors],
		singles == [1, 1, 1, 1, 1] and count.call("res://game/combat/combat_ship.gd") == ships.size() and scene.command_given.get_connections().size() == behaviors)
	print("\n=== S2 battle")
	scene.orders.set_stance(PLAYER_FLEET.map(func(n: String) -> Node3D: return _ship(n)), CombatShip.Stance.AGGRESSIVE)
	var projectiles: Node = scene.get_node("Projectiles")
	var launches := []
	projectiles.ordnance_launched.connect(func(node: Node3D) -> void: launches.append({"time": SimClock.now(), "owner": node.owner_name, "kind": String(node.kind)}))
	var detected := {"time": -1.0}
	var kills := []
	for name in PLAYER_FLEET + HOSTILES:
		var ship := _ship(name)
		CombatShip.of(ship).destroyed.connect(func(s: Node3D) -> void: kills.append([SimClock.now(), String(s.name)]))
	var alive := func(names: Array) -> int:
		return names.filter(func(n: String) -> bool: return _ship(n) != null and CombatShip.of(_ship(n)).alive).size()
	var ended := await _run(400.0, func() -> bool:
		if detected.time < 0.0 and HOSTILES.any(func(n: String) -> bool: return _ship(n) != null and scene.player_sees(_ship(n))):
			detected.time = SimClock.now()
		return alive.call(PLAYER_FLEET) == 0 or alive.call(HOSTILES) == 0)
	var salvos := 0
	var missiles := launches.filter(func(l: Dictionary) -> bool: return l.kind == "missile")
	for i in missiles.size():
		var burst := missiles.filter(func(l: Dictionary) -> bool: return l.owner == missiles[i].owner and l.time >= missiles[i].time and l.time - missiles[i].time <= 0.7)
		if burst.size() >= 4 and (i == 0 or missiles[i - 1].owner != missiles[i].owner or missiles[i].time - missiles[i - 1].time > 0.7):
			salvos += 1
	var intercepts: int = projectiles.records.filter(func(r: Dictionary) -> bool: return r.outcome == "intercept").size()
	var damage: int = projectiles.damage_events.size()
	var winner := "player" if alive.call(HOSTILES) == 0 and alive.call(PLAYER_FLEET) > 0 else ("hostile" if alive.call(PLAYER_FLEET) == 0 else "none")
	print("  detected at %.1f s; %d launches (%d missiles, %d salvos), %d interceptions, %d damaging hits; kills %s; ended %s at %.1f s, winner %s" % [
		detected.time, launches.size(), missiles.size(), salvos, intercepts, damage, str(kills), ended, SimClock.now(), winner])
	_check("the fleets meet: detected (%.1f s), damaging hits (%d), kills (%d) and a result (%s)" % [detected.time, damage, kills.size(), winner],
		detected.time > 0.0 and damage > 0 and kills.size() > 0 and ended)
	_check("4-missile salvos (%d) and Gatling point-defense interceptions (%d) occur" % [salvos, intercepts], salvos >= 1 and intercepts >= 1)
	await _run(12.0)
	var stale := false
	for ship: Node in scene.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		for reference in [combat.target, combat.manual_target, combat.auto_target, combat.attack_target]:
			stale = stale or (reference != null and not is_instance_valid(reference))
		var behavior = Behavior.of(ship)
		if behavior != null:
			for reference in [behavior.guard_target, behavior.attack_target, behavior.encounter]:
				stale = stale or (reference != null and not is_instance_valid(reference))
	_check("afterwards: nothing in flight (%d rounds, %d ordnance), no stale combat or behavior reference" % [projectiles.active.size(), projectiles.ordnance.size()],
		projectiles.ordnance.is_empty() and not stale)


func _s5_controls() -> void:
	print("\n=== S5 controls")
	await _load(COMBAT_TEST)
	await _stage()
	var ff01_ship := _ship("FF01")
	var hostile := _ship("HostileFF01")
	hostile.get_node("Locomotion").place(Vector2(0, -45), 0.0)
	hostile.get_node("Avoidance").reset()
	scene.orders.set_stance([hostile], CombatShip.Stance.HOLD_FIRE)
	await physics_frame
	scene.sensors.evaluate()
	await physics_frame
	scene.selection().set_selection([ff01_ship])
	await _look_at(hostile.global_position)
	var destination_before: bool = ff01_ship.get_node("Locomotion").has_destination
	await _click(MOUSE_BUTTON_RIGHT, _screen(hostile.global_position))
	_check("right-click on a visible hostile: it becomes the selected ship's manual target; no MOVE given ('%s')" % scene._notice.text,
		CombatShip.of(ff01_ship).manual_target == hostile and ff01_ship.get_node("Locomotion").has_destination == destination_before and scene._notice.text.begins_with("Target: "))
	# Tactical zoom (Phase B): the markers are drawn over the visible models and pick them.
	var rig := scene.get_node("CameraRig")
	rig.zoom_distance = 120.0
	rig._apply_zoom()
	await _look_at(ff01_ship.global_position)
	var tactical: bool = scene.markers.emphasis() >= scene.markers.interactive_emphasis and ff01_ship.visible
	scene.selection().set_selection([])
	await _click(MOUSE_BUTTON_LEFT, _screen(ff01_ship.global_position))
	var picked_own: bool = scene.selection().selected == [ff01_ship]
	await _click(MOUSE_BUTTON_LEFT, _screen(hostile.global_position))
	var hostile_selected: bool = scene.selection().selected.has(hostile)
	_check("Tactical zoom: models kept, markers interactive; a click on the FF-01's marker selects it; a hostile marker is never selected",
		tactical and picked_own and not hostile_selected)
	rig.zoom_distance = 20.0
	rig._apply_zoom()
	await process_frame
	# Armed ship panels remain covered on the combat arena itself.
	var panel: Node = scene.get_node("ShipPanel")
	scene.selection().set_selection([ff01_ship])
	await process_frame
	var row := [panel._hull.text, panel._combat.visible]
	print("  panel: %s" % str(row))
	_check("armed ship panel: hull and Combat",
		row == ["Hull: 160 / 160", true])
	scene.selection().set_selection([ff01_ship])
	await process_frame
	panel._tactic.item_selected.emit(panel._tactic.get_item_index(CombatShip.Stance.AGGRESSIVE))
	_check("the panel's tactic selector sets the tactic through CombatOrders", CombatShip.of(ff01_ship).stance == CombatShip.Stance.AGGRESSIVE
		and scene.orders.history[-1].channel == "engagement")


func _s5_unarmed_panel() -> void:
	print("\n=== S5 unarmed panel on the Test Arena")
	await _load(MAIN)
	scene.selection().set_selection([_ship("Miner1")])
	await process_frame
	var panel: Node = scene.get_node("ShipPanel")
	_check("unarmed Miner1 panel: hull 150, no Combat section",
		panel._hull.text == "Hull: 150 / 150" and not panel._combat.visible)


# Sets up the economy on main.tscn: mining, a refinery slot, a ship under construction,
# a ship under way (fuel).
func _economy() -> Dictionary:
	await _load(MAIN)
	# An armed player ship (with Behavior) added for the order checks, as at run time.
	var ff01: Node3D = load("res://game/ships/ff01_unit.tscn").instantiate()
	ff01.name = "FF01"
	ff01.position = Vector3(0, 1.5, 0)
	scene.get_node("Ships").add_child(ff01)
	scene.register_ship(ff01)
	var miner := _ship("Miner1")
	var field: Node = scene.get_node("Asteroids")
	var nearest := -1
	var best := INF
	for id: int in field.ids():
		var c: Vector3 = field.center(id)
		var d := Vector2(c.x, c.z).distance_to(Vector2(-8, 14))
		if d < best:
			best = d
			nearest = id
	miner.get_node("Mining").assign(nearest)
	var refinery_station: Node3D = scene.get_node("Stations/Station2")
	refinery_station.storage.add(&"iron", 500)
	var refinery: Node = refinery_station.get_node("Refinery")
	refinery.set_mineral(0, &"iron")
	refinery.set_enabled(0, true)
	var yard_station: Node3D = scene.get_node("Stations/Shipyard")
	for entry in [[&"iron_ingot", 200], [&"nickel_ingot", 100], [&"silicon_ingot", 50]]:
		yard_station.storage.add(entry[0], entry[1])
	var shipyard: Node = yard_station.get_node("Shipyard")
	shipyard.order(&"mining_ship")
	_ship("Transporter").get_node("RouteFollower").order(Vector2(-30, -40))
	await _run(25.0, func() -> bool: return miner.get_node("Cargo").inventory.quantity() > 0)
	return {"miner": miner, "refinery": refinery, "shipyard": shipyard, "mover": _ship("Transporter")}


func _state(e: Dictionary) -> Array:
	return [SimClock.now(), e.miner.get_node("Cargo").inventory.quantity(), e.refinery.slots[0].processed + e.refinery.slots[0].progress,
		e.shipyard.elapsed, e.mover.get_node("Fuel").fuel, e.mover.get_node("Locomotion").planar_position]


func _s3_pause() -> void:
	print("\n=== S3 pause")
	var e := await _economy()
	var earlier := _state(e)
	await _run(1.0)
	await _key(KEY_SPACE)
	var paused: bool = scene.time_control.paused and root.get_tree().paused
	var during := _state(e)
	for i in 120:
		await physics_frame
	var after := _state(e)
	var running := range(5).all(func(i: int) -> bool: return during[i] != earlier[i] or i == 1) # Cargo may be full.
	print("  1 s before %s\n  paused     %s\n  2 s later  %s" % [str(earlier), str(during), str(after)])
	_check("running, then paused (Space): clock, mining, refining, construction, fuel and movement stand still for 2 s", paused and running and during == after)
	# Orders and camera while paused.
	var ff01_ship := _ship("FF01")
	scene.selection().set_selection([ff01_ship])
	await _look_at(Vector3(20, 0, 20))
	await _click(MOUSE_BUTTON_RIGHT, _screen(Vector3(20, 0, 20)))
	var position: Vector2 = ff01_ship.get_node("Locomotion").planar_position
	var taken: bool = Behavior.of(ff01_ship).command == Behavior.Command.MOVE and ff01_ship.get_node("Locomotion").has_destination
	var rig: Node3D = scene.get_node("CameraRig")
	var rig_before := rig.global_position
	var press := InputEventKey.new()
	press.physical_keycode = KEY_W
	press.keycode = KEY_W
	press.pressed = true
	Input.parse_input_event(press)
	for i in 30:
		await process_frame
	var release := press.duplicate()
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame
	var still: bool = ff01_ship.get_node("Locomotion").planar_position == position
	_check("while paused a right-click MOVE is taken (Behavior: Move) without moving the ship; the camera pans (%.1f u)" % rig.global_position.distance_to(rig_before),
		taken and still and rig.global_position.distance_to(rig_before) > 1.0)
	await _key(KEY_SPACE)
	await _run(3.0)
	var resumed := _state(e)
	_check("resumed: everything goes on, the ship moves toward its order", not scene.time_control.paused and resumed[0] > after[0] and resumed[3] > after[3]
		and ff01_ship.get_node("Locomotion").planar_position.distance_to(position) > 0.5)


func _s4_dilation() -> void:
	print("\n=== S4 time dilation")
	var e := await _economy()
	var rates := {}
	for setting in [["1x", 0], ["2x", 1], ["0.25x", -2], ["back to 1x", 1]]:
		for i in absi(setting[1]):
			scene.time_control.step_speed(signi(setting[1]))
		await physics_frame
		var a := _state(e)
		for i in 120:
			await physics_frame
		var b := _state(e)
		rates[setting[0]] = [snappedf((b[0] - a[0]) / 2.0, 0.01), snappedf((b[3] - a[3]) / 2.0, 0.01), scene.time_control.label()]
	print("  per real second at 60 frames: [clock s, construction s, label] %s" % str(rates))
	var near := func(value: float, want: float) -> bool: return absf(value - want) <= want * 0.05 + 0.01
	_check("the clock and ship construction advance 1x / 2x / 0.25x per frame, and 1x again after (%s)" % str(rates),
		near.call(rates["1x"][0], 1.0) and near.call(rates["2x"][0], 2.0) and near.call(rates["0.25x"][0], 0.25) and near.call(rates["back to 1x"][0], 1.0)
		and near.call(rates["2x"][1], 2.0) and near.call(rates["0.25x"][1], 0.25))


## Gate 1 verification: every ship the Shipyard can build (its RECIPES: Mining Ship and
## Transport Ship; it builds no warships), through the real production path (order,
## construction, deployment), compared with the starting ship of the same variant.
func _s6_produced() -> void:
	print("\n=== S6 ships produced by the Shipyard")
	var e := await _economy()
	var shipyard: Node = e.shipyard
	_check("the Shipyard builds exactly the Mining Ship and the Transport Ship (%s), from miner_unit / transporter_unit" % str(shipyard.RECIPES.keys()),
		shipyard.RECIPES.keys() == [&"mining_ship", &"transport_ship"] and shipyard.RECIPES.mining_ship.scene.resource_path == "res://game/ships/miner_unit.tscn"
		and shipyard.RECIPES.transport_ship.scene.resource_path == "res://game/ships/transporter_unit.tscn")
	var deployed := []
	shipyard.ship_deployed.connect(func(ship: Node3D) -> void: deployed.append(ship))
	var raider: Node3D = load("res://game/ships/ff01_unit.tscn").instantiate()
	raider.name = "Raider"
	raider.get_node("Combat").faction = 1
	raider.get_node("Combat").stance = CombatShip.Stance.HOLD_FIRE
	var lab_markers: Dictionary = scene._markers
	var names := []
	# The Mining Ship was ordered in _economy(); each produced ship is verified and destroyed
	# before the next order (an idle ship on the deployment point holds the next deployment).
	for pair in [[&"mining_ship", "Miner2"], [&"transport_ship", "Transporter"]]:
		if pair[0] == &"transport_ship":
			var yard_station: Node3D = scene.get_node("Stations/Shipyard")
			for entry in [[&"iron_ingot", 300], [&"titanium_ingot", 100], [&"cobalt_ingot", 50]]:
				yard_station.storage.add(entry[0], entry[1])
			shipyard.order(&"transport_ship")
		var count := deployed.size()
		scene.time_control.step_speed(1)
		await _run(100.0, func() -> bool: return deployed.size() > count)
		scene.time_control.step_speed(-1)
		var ship: Node3D = deployed[count] if deployed.size() > count else null
		var reference := _ship(pair[1])
		names.append(String(ship.name) if ship != null else "none")
		if ship == null:
			continue
		var combat = CombatShip.of(ship)
		var components := func(s: Node) -> Array: return s.get_children().map(func(n: Node) -> Array:
			return [String(n.name), n.get_script().resource_path if n.get_script() != null else "", n.process_physics_priority])
		var combats: int = ship.get_children().filter(func(n: Node) -> bool: return n.get_script() != null and n.get_script().resource_path == "res://game/combat/combat_ship.gd").size()
		var same: bool = ship.scene_file_path == reference.scene_file_path and components.call(ship) == components.call(reference)
		_check("%s: same variant and runtime components as the starting %s (%s); one Combat, hull 150, player faction, no weapons, no Behavior" % [ship.name, pair[1], ship.scene_file_path.get_file()],
			same and combats == 1 and is_equal_approx(combat.health, 150.0) and combat.faction == 0 and combat.weapons.is_empty() and ship.get_node_or_null("Behavior") == null
			and ship.get_node("Weapons").get_child_count() == 0)
		_check("%s: registered (selectable, pick boxes, marker, destruction hooks) and on the world services (projectiles, contacts)" % ship.name,
			scene.selection().selectable(ship) and scene.selection()._parts.has(ship) and lab_markers.has(ship)
			and combat.destroyed.is_connected(scene._on_destroyed) and combat.removing.is_connected(scene._on_removing)
			and combat.projectiles == scene.get_node("Projectiles") and combat.contacts == scene.get_node("Contacts"))
		# Hostile sensor contact, target authorization and damage.
		if not raider.is_inside_tree():
			raider.transform = Transform3D(Basis(), ship.global_position + Vector3(30, 0, 0))
			scene.get_node("Ships").add_child(raider)
			scene.register_ship(raider)
		raider.get_node("Locomotion").place(Vector2(ship.global_position.x + 30.0, ship.global_position.z), 0.0)
		await physics_frame
		scene.sensors.evaluate()
		var detected: bool = scene.sensors.detected(1, ship)
		var authorized: bool = CombatShip.of(raider).assign_target(ship)
		var projectiles: Node = scene.get_node("Projectiles")
		var id: int = projectiles.spawn(raider, 1, ship.global_position + Vector3(0, 0, -12), Vector3(0, 0, 40), 12.0, 90.0, 2.5, ship)
		await _run(1.0)
		_check("%s: detected by the hostile faction, a valid manual target for it, damaged once by its round (hull %.0f)" % [ship.name, combat.health],
			detected and authorized and projectiles.damage_events.get(id, 0) == 1 and is_equal_approx(combat.health, 138.0))
		# Destruction: deselected at once, unregistered once the hulk is removed.
		scene.selection().set_selection([ship])
		var registered: int = scene.selection().registered_count()
		var label := String(ship.name)
		combat.destroy()
		var dropped: bool = not scene.selection().selected.has(ship) and CombatShip.of(raider).manual_target == null
		var gone: WeakRef = weakref(ship)
		ship = null
		combat = null
		await _run(4.0, func() -> bool: return gone.get_ref() == null)
		var clean: bool = scene.selection().registered_count() == registered - 1 and not lab_markers.keys().any(func(k: Variant) -> bool: return not is_instance_valid(k))
		for other: Node in scene.get_node("Ships").get_children():
			clean = clean and not other.get_node("Avoidance").encounters.keys().any(func(k: Variant) -> bool: return not is_instance_valid(k))
		_check("%s destroyed: deselected and dropped as a target at once; freed, unregistered, no marker or avoidance record left" % label,
			dropped and gone.get_ref() == null and clean)
	_check("both recipes deployed through order, construction and deployment (%s)" % str(names), names.size() == 2 and not names.has("none"))
