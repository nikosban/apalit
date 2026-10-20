extends SceneTree
## Headless reuse test (architecture migration): the ship variants and station scenes in
## a separate gameplay scene, `reuse_arena.tscn`, that follows the gameplay-scene layout
## contract (root children Asteroids with AsteroidField, StaticNavigation, PlanarCollision,
## Survey, Stations, Ships, Selection; no movement_lab.gd, so produced ships are
## registered in Selection by this test, as the scene's command layer would). Nothing in
## the arena is reconstructed by hand: every ship is an instance of its variant and every
## station of its station scene, with only a transform (the tri-dock layout,
## `game/tests/docking/tri_station.tscn`, also has its berth drawing off).
## R1 the environment contract resolves; R2 variants and instances of the archetypes;
## R3 a change to an archetype propagates to its variants unless they override it
## (in memory, no file changed); R4-R7 in the uninterrupted game loop: independent
## ships (mining cycle, transport delivery, a move, a dock at the three-berth layout),
## independent stations (storage, fuel, refinery slots and rates, reservations),
## Shipyard production into this scene from the same variant as the starting Miners,
## selection by click; R8 contacts and refusals.
## Run from the project folder (fixed 60 Hz, as fast as possible):
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/reuse_test.gd
## The tri-dock layout logs its three known navigation edge warnings (overlapping
## outlines, see HANDOFF). Every check is PASS/FAIL.

const ARENA := preload("res://game/tests/reuse_arena.tscn")
const Station := preload("res://game/stations/station.gd")
const Shipyard := preload("res://game/shipyard/shipyard.gd")
const Docking := preload("res://game/stations/docking.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const WARSHIP := "res://game/ships/archetypes/warship.tscn"
const VARIANT_OF := {"Frigate": "res://game/ships/frigate_unit.tscn", "Gunship": "res://game/ships/gunship_unit.tscn",
	"Destroyer": "res://game/ships/destroyer_unit.tscn", "Miner1": "res://game/ships/miner_unit.tscn",
	"Miner2": "res://game/ships/miner_unit.tscn", "Transporter1": "res://game/ships/transporter_unit.tscn",
	"Transporter2": "res://game/ships/transporter_unit.tscn"}
const IRON := &"iron"

var _failures := 0
var _checks := 0
var _arena: Node3D
var _ships: Node3D
var _a: Station
var _b: Station
var _yard_station: Station
var _tri: Station
var _yard: Shipyard
var _camera: Camera3D
var _produced: Node3D = null
var _reservation_errors := 0


func _initialize() -> void:
	await process_frame
	_arena = ARENA.instantiate()
	root.add_child(_arena)
	_ships = _arena.get_node("Ships")
	_a = _arena.get_node("Stations/RefineryA")
	_b = _arena.get_node("Stations/RefineryB")
	_yard_station = _arena.get_node("Stations/Yard")
	_tri = _arena.get_node("Stations/TriDepot")
	_yard = _yard_station.get_node("Shipyard")
	_camera = _arena.get_node("CameraRig/Camera3D")
	_yard.ship_deployed.connect(func(ship: Node3D) -> void:
		_arena.get_node("Selection").register_ship(ship)
		_produced = ship)
	_test_contract()
	_test_definitions()
	_test_propagation()
	var nav := _arena.get_node("StaticNavigation")
	while not (nav.is_ready(2.6) and nav.is_ready(5.1) and nav.is_ready(4.4) and nav.is_ready(7.2)):
		await physics_frame
	await _test_runtime()
	await _test_selection()
	_test_totals()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# --- R1. Environment contract ---------------------------------------------------------

func _test_contract() -> void:
	var unresolved: Array[String] = []
	for ship: Node in _ships.get_children():
		for component: Node in ship.get_children():
			for path: String in _node_paths(component):
				var target := component.get_node_or_null(component.get(path))
				if target == null or not _arena.is_ancestor_of(target):
					unresolved.append("%s/%s.%s" % [ship.name, component.name, path])
	_check("R1. every ship component's node path resolves inside the arena%s" % ("" if unresolved.is_empty() else ": " + str(unresolved)), unresolved.is_empty())
	var collision := _ships.get_children().all(func(ship: Node) -> bool: return ship.get_node("Locomotion")._collision == _arena.get_node("PlanarCollision"))
	_check("R1. every Locomotion enforces this scene's PlanarCollision (the optional path is not silently missing)", collision)
	var stations_ok := true
	for station: Station in _arena.get_node("Stations").get_children():
		stations_ok = stations_ok and station._navigation == _arena.get_node("StaticNavigation") and station.get_node(station.berth_ships_path) == _ships \
			and station.is_in_group(Station.GROUP)
	_check("R1. every station reads this scene's navigation and Ships and is in the station group; Shipyard uses Ships and its own Deployment",
		stations_ok and _yard._ships == _ships and _yard._deployment == _yard_station.get_node("Deployment"))
	var obstacles := get_nodes_in_group(&"static_obstacle").size()
	_check("R1. navigation and collision read the six asteroids and %d station outlines (3 x 3 two-arm boxes + 10 tri-dock parts)" % obstacles,
		obstacles == 19 and _arena.get_node("Asteroids").ids().size() == 6)


# --- R2. Variants and instances ---------------------------------------------------------

func _test_definitions() -> void:
	var scenes := true
	for ship: Node in _ships.get_children():
		scenes = scenes and ship.scene_file_path == VARIANT_OF[String(ship.name)]
	_check("R2. every ship is an instance of its variant (Frigate, Gunship, Destroyer, 2 Miners, 2 Transporters)", scenes and _ships.get_child_count() == 7)
	var war := ["Frigate", "Gunship", "Destroyer"].map(func(n: String) -> Node: return _ships.get_node(n))
	# Combat migration: the armed variants (Gunship, Destroyer) add a Behavior component (the
	# unarmed Frigate has none); every other component is the archetype's.
	var archetype := func(ship: Node) -> Array: return _components(ship).filter(func(c: Array) -> bool: return c[0] != "Behavior")
	var structure: bool = war.all(func(ship: Node) -> bool: return archetype.call(ship) == archetype.call(war[0])) \
		and war.map(func(ship: Node) -> bool: return ship.has_node("Behavior")) == [false, true, true]
	var profiles := war.map(func(ship: Node) -> Array: return [ship.get_node("Locomotion").max_speed, ship.get_node("RouteFollower").ship_radius,
		ship.get_node("Avoidance").size_class, ship.get_node("Fuel").capacity, ship.get_node("Scanner").radius])
	_check("R2. the three warship variants share the archetype's components, scripts, order and priorities %s; their own settings %s" % [
		str(_components(war[0]).map(func(c: Array) -> String: return c[0])), str(profiles)],
		structure and profiles == [[5.0, 1.6, 1, 100.0, 50.0], [4.5, 3.4, 2, 200.0, 50.0], [3.0, 6.2, 3, 400.0, 50.0]])
	_check("R2. instances of one variant are configured alike (Miner1 = Miner2, Transporter1 = Transporter2)",
		_config(_ships.get_node("Miner1")) == _config(_ships.get_node("Miner2")) and _config(_ships.get_node("Transporter1")) == _config(_ships.get_node("Transporter2")))
	var roles := [_names(_ships.get_node("Miner1")), _names(_ships.get_node("Transporter1"))]
	_check("R2. role archetypes: mining %s, transport %s" % roles, roles == [
		# Combat migration (2026-10-19): every archetype ends with Weapons (empty on civilian
		# ships) and Combat (hull, faction, targeting), before the variant's Model.
		["Locomotion", "RouteFollower", "Avoidance", "Cargo", "Extractor", "Mining", "Scanner", "Docking", "Fuel", "Weapons", "Combat", "Model"],
		["Locomotion", "RouteFollower", "Avoidance", "Cargo", "Transport", "Scanner", "Docking", "Fuel", "Weapons", "Combat", "Model"]])
	_check("R2. stations: two refinery_station instances, a shipyard_station and the tri-dock layout, all on station.gd (berths %d / %d / %d / %d)" % [
		_a.berths.size(), _b.berths.size(), _yard_station.berths.size(), _tri.berths.size()],
		_a.scene_file_path == "res://game/stations/refinery_station.tscn" and _b.scene_file_path == _a.scene_file_path
		and _yard_station.scene_file_path == "res://game/stations/shipyard_station.tscn" and _tri.get_script() == _a.get_script()
		and _a.berths.size() == 2 and _tri.berths.size() == 3 and _tri.holds.size() == 3 and _a.holds.size() == 4)


# --- R3. Archetype changes propagate unless overridden (in memory) ------------------------

func _test_propagation() -> void:
	var before := _warship_values()
	var original: PackedScene = load(WARSHIP)
	var edited := original.instantiate()
	edited.scene_file_path = "" # Packed as a plain scene, standing in for the edited archetype file.
	edited.get_node("Scanner").radius = 77.0 # No variant overrides it.
	edited.get_node("Fuel").capacity = 999.0 # Overridden by the Gunship and the Destroyer only.
	edited.get_node("Locomotion").max_speed = 99.0 # Overridden by every variant.
	var packed := PackedScene.new()
	packed.pack(edited)
	edited.free()
	packed.take_over_path(WARSHIP)
	var after := _warship_values()
	original.take_over_path(WARSHIP)
	var restored := _warship_values()
	_check("R3. archetype values (scanner radius, fuel capacity, max speed): before %s" % str(before),
		before == [[50.0, 100.0, 5.0], [50.0, 200.0, 4.5], [50.0, 400.0, 3.0]])
	_check("R3. edited archetype (radius 77, capacity 999, speed 99): %s - shared values propagate, every variant override is kept" % str(after),
		after == [[77.0, 999.0, 5.0], [77.0, 200.0, 4.5], [77.0, 400.0, 3.0]])
	_check("R3. archetype restored: %s" % str(restored), restored == before)


# Scanner radius, fuel capacity and max speed of freshly loaded Frigate, Gunship and
# Destroyer variants (loaded without the cache; their archetype comes from the cache).
func _warship_values() -> Array:
	var values := []
	for variant in ["frigate", "gunship", "destroyer"]:
		var scene: PackedScene = ResourceLoader.load("res://game/ships/%s_unit.tscn" % variant, "", ResourceLoader.CACHE_MODE_IGNORE)
		var ship := scene.instantiate()
		values.append([ship.get_node("Scanner").radius, ship.get_node("Fuel").capacity, ship.get_node("Locomotion").max_speed])
		ship.free()
	return values


# --- R4-R6. Uninterrupted game loop ------------------------------------------------------

func _test_runtime() -> void:
	var miner1 := _ships.get_node("Miner1")
	var miner2 := _ships.get_node("Miner2")
	var t1 := _ships.get_node("Transporter1")
	var t2 := _ships.get_node("Transporter2")
	var frigate := _ships.get_node("Frigate")
	var asteroid := _mineable_asteroid(miner1)
	var fuel_start := _stations().map(func(s: Station) -> float: return s.fuel_stock)
	# Independent assignments, orders and station set-ups.
	_b.storage.add(IRON, 100)
	t1.get_node("Transport").set_load_station(_b)
	t1.get_node("Transport").set_unload_station(_yard_station)
	t1.get_node("Transport").set_requirement(IRON, 100)
	t1.get_node("Transport").start()
	miner1.get_node("Mining").set_base(_a)
	miner1.get_node("Mining").assign(asteroid)
	var tri_ok: bool = miner2.get_node("Docking").can_dock(_tri)
	miner2.get_node("Docking").dock(_tri)
	var frigate_target := Vector2(-40, -60)
	var ordered: bool = frigate.get_node("RouteFollower").order(frigate_target)
	_a.get_node("Refinery").set_mineral(0, IRON)
	_a.get_node("Refinery").set_enabled(0, true)
	_a.get_node("Refinery").rates[IRON] = 8.0
	for ingot: StringName in Shipyard.RECIPES[&"mining_ship"].ingots:
		_yard_station.storage.add(ingot, Shipyard.RECIPES[&"mining_ship"].ingots[ingot])
	var accepted := _yard.order(&"mining_ship")
	_check("R4. set-up: Miner1 mines asteroid %d (base RefineryA), Transporter1 RefineryB -> Yard (iron 100), Miner2 docks at TriDepot (can dock %s), Frigate moves, RefineryA slot 1 iron at rate 8, Mining Ship ordered at the Yard" % [
		asteroid, tri_ok], asteroid > 0 and tri_ok and ordered and accepted and _yard.state == Shipyard.State.CONSTRUCTING)

	var produced_ordered := false
	var miner2_docked_at := -1
	var tri_slot := -1
	var miner1_returned := -1 # First frame Miner1 heads back to the asteroid after unloading.
	var a_storage_then := 0
	var a_raw_then := 0
	var start := Engine.get_physics_frames()
	for frame in 60 * 900:
		if miner1_returned >= 0 and t1.get_node("Transport").deliveries >= 1 and miner2_docked_at >= 0 \
				and _produced != null and produced_ordered and not _produced.get_node("Locomotion").has_destination:
			break
		_check_reservations()
		if miner1_returned < 0 and miner1.get_node("Mining").activity() == "Returning to Asteroid":
			miner1_returned = frame
			a_storage_then = _a.storage.quantity()
			a_raw_then = a_storage_then - _a.storage.quantity_of(&"iron_ingot")
		if miner2_docked_at < 0 and miner2.get_node("Docking").state == Docking.State.DOCKED:
			miner2_docked_at = frame
			tri_slot = miner2.get_node("Docking").slot
		if _produced != null and not produced_ordered:
			produced_ordered = _produced.get_node("RouteFollower").order(Vector2(30, -75))
		await physics_frame
	var seconds := (Engine.get_physics_frames() - start) / 60.0
	print("runtime phase: %.1f s simulated" % seconds)

	# R4. Ships: each runs only its own assignment or order.
	var m1_cargo: int = miner1.get_node("Cargo").inventory.quantity()
	var m2_cargo: int = miner2.get_node("Cargo").inventory.quantity()
	_check("R4. Miner1: full hold mined at asteroid %d, unloaded at RefineryA (storage %d incl. %d refined, at %.1f s), then back toward the asteroid" % [asteroid,
		a_storage_then, a_storage_then - a_raw_then, miner1_returned / 60.0], miner1_returned >= 0 and a_storage_then == 1000)
	_check("R4. Miner2: its own dock at TriDepot (slot %d of 3, bow offset %.2f deg), no mining assignment, empty hold (%d)" % [tri_slot,
		_bow_offset(miner2), m2_cargo], miner2_docked_at >= 0 and tri_slot >= 0 and absf(_bow_offset(miner2)) < 0.5
		and miner2.get_node("Mining").status == MiningOperation.Status.NONE and m2_cargo == 0)
	_check("R4. Transporter1 delivered 100 iron RefineryB -> Yard (deliveries %d); Transporter2 untouched (idle, empty, no assignment)" % t1.get_node("Transport").deliveries,
		t1.get_node("Transport").deliveries >= 1 and _yard_station.storage.quantity_of(IRON) == 100 and _b.storage.quantity_of(IRON) == 0
		and t2.get_node("Cargo").inventory.quantity() == 0 and not t2.get_node("Transport").is_active() and not t2.get_node("Locomotion").has_destination
		and t2.get_node("Docking").state == Docking.State.NONE)
	var fuels := ["Miner1", "Miner2", "Transporter1", "Transporter2", "Frigate", "Gunship", "Destroyer"].map(func(n: String) -> float:
		return snappedf(_ships.get_node(n).get_node("Fuel").fuel, 0.01))
	_check("R4. fuel per ship follows its own travel and refuelling %s: the idle Transporter2, Gunship and Destroyer full, the Frigate below full" % str(fuels),
		fuels[3] == 200.0 and fuels[5] == 200.0 and fuels[6] == 400.0 and fuels[4] < 100.0 and fuels[4] > 80.0)
	var loco: ShipLocomotion = frigate.get_node("Locomotion")
	_check("R4. Frigate arrived at its own destination (%.3f u off), the other warships never moved" % loco.planar_position.distance_to(frigate_target),
		not loco.has_destination and loco.planar_position.distance_to(frigate_target) < 0.5
		and _ships.get_node("Gunship/Locomotion").planar_position == Vector2(0, -25) and _ships.get_node("Destroyer/Locomotion").planar_position == Vector2(25, -25))

	# R5. Stations: storage, fuel, refining and reservations kept apart.
	var fuel_now := _stations().map(func(s: Station) -> float: return s.fuel_stock)
	var refined_a: int = _a.get_node("Refinery").slots[0].processed
	_check("R5. refinery slots and rates per station: RefineryA refined %d iron (rate %.1f), RefineryB none (rate %.1f, slot off)" % [refined_a,
		_a.get_node("Refinery").rates[IRON], _b.get_node("Refinery").rates[IRON]],
		refined_a > 0 and _a.storage.quantity_of(&"iron_ingot") == refined_a and _b.get_node("Refinery").slots[0].processed == 0
		and _a.get_node("Refinery").rates[IRON] == 8.0 and _b.get_node("Refinery").rates[IRON] == 4.0)
	_check("R5. storage per station: RefineryA %s, RefineryB %s, Yard %s, TriDepot %s" % [_a.storage.describe(), _b.storage.describe(),
		_yard_station.storage.describe(), _tri.storage.describe()], _tri.storage.quantity() == 0 and _b.storage.quantity() == 0
		and _yard_station.storage.quantity() == 100 and _a.storage.quantity() == 1000)
	_check("R5. fuel stock per station %s -> %s: each lost only what its own docked ships took" % [str(fuel_start), str(fuel_now)],
		fuel_now[0] < fuel_start[0] and fuel_now[1] < fuel_start[1] and fuel_now[2] < fuel_start[2] and fuel_now[3] < fuel_start[3])
	_check("R5. berth reservations: every reserved berth held only by a ship docking at that station, every tick (%d violations); TriDepot slot %d = Miner2" % [
		_reservation_errors, tri_slot], _reservation_errors == 0 and _tri.slot_of(miner2) == tri_slot and _a.slot_of(miner2) < 0)

	# R6. Shipyard production into this scene.
	var produced_name := String(_produced.name) if _produced != null else "none"
	_check("R6. the Yard built %s from %s (the starting Miners' variant) under this scene's Ships, registered, configured as Miner1" % [produced_name,
		_produced.scene_file_path.get_file() if _produced != null else "-"], _produced != null and _produced.get_parent() == _ships
		and _produced.scene_file_path == miner1.scene_file_path and _config(_produced) == _config(miner1)
		and _arena.get_node("Selection")._parts.has(_produced) and _yard.state == Shipyard.State.IDLE)
	var produced_loco: ShipLocomotion = _produced.get_node("Locomotion") if _produced != null else null
	_check("R6. %s took an order and arrived (%.3f u off)" % [produced_name, produced_loco.planar_position.distance_to(Vector2(30, -75)) if produced_loco else INF],
		produced_loco != null and produced_ordered and not produced_loco.has_destination and produced_loco.planar_position.distance_to(Vector2(30, -75)) < 0.5)

	# R4. The three-berth layout's controlled exit, same docking code.
	miner2.get_node("Docking").undock()
	var left := await _until(func() -> bool: return miner2.get_node("Docking").state == Docking.State.NONE, 60 * 120)
	_check("R4. Miner2 leaves TriDepot through its controlled exit (%.1f s); berth released" % (left / 60.0), left >= 0 and _tri.slot_of(miner2) < 0)


func _check_reservations() -> void:
	for station: Station in _stations():
		for slot: Dictionary in station.slots:
			if slot.ship != null and (slot.ship as Node).get_node("Docking").station != station:
				_reservation_errors += 1


# --- R7. Selection --------------------------------------------------------------------------

func _test_selection() -> void:
	var selection := _arena.get_node("Selection")
	var picked := []
	for ship_name in ["Frigate", "Destroyer", "Transporter2"]:
		var ship: Node3D = _ships.get_node(ship_name)
		var rig: Node3D = _arena.get_node("CameraRig")
		rig.global_position = Vector3(ship.global_position.x, 0, ship.global_position.z)
		await process_frame
		_click(_camera.unproject_position(ship.global_position))
		await process_frame
		picked.append(", ".join(selection.selected.map(func(s: Node) -> String: return String(s.name))))
	_check("R7. a click selects the intended ship: %s" % str(picked), picked == ["Frigate", "Destroyer", "Transporter2"])


# --- R8. Totals -----------------------------------------------------------------------------

func _test_totals() -> void:
	var contacts := 0
	var refusals := 0
	for ship: Node in _ships.get_children():
		contacts += ship.get_node("Locomotion").collision_count
		refusals += ship.get_node("RouteFollower").guided_refusals + ship.get_node("Docking").refused_during_control
	_check("R8. no contacts (%d) and no refusals during station control (%d)" % [contacts, refusals], contacts == 0 and refusals == 0)


# --- Helpers --------------------------------------------------------------------------------

func _stations() -> Array:
	return [_a, _b, _yard_station, _tri]


func _node_paths(component: Node) -> Array[String]:
	var paths: Array[String] = []
	for property: Dictionary in component.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.usage & PROPERTY_USAGE_STORAGE and property.type == TYPE_NODE_PATH:
			paths.append(property.name)
	return paths


# Component name, script, physics priority per component, in order.
func _components(ship: Node) -> Array:
	return ship.get_children().filter(func(n: Node) -> bool: return n.get_script() != null).map(func(n: Node) -> Array:
		return [String(n.name), n.get_script().resource_path, n.process_physics_priority])


func _names(ship: Node) -> Array:
	return ship.get_children().map(func(n: Node) -> String: return String(n.name))


# Every exported setting of every component (node paths as the target's scene path).
func _config(ship: Node) -> Dictionary:
	var config := {}
	for component: Node in ship.get_children():
		if component.get_script() == null:
			continue
		config[String(component.name) + " priority"] = component.process_physics_priority
		for property: Dictionary in component.get_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.usage & PROPERTY_USAGE_STORAGE:
				var value: Variant = component.get(property.name)
				if value is NodePath:
					value = str(_arena.get_path_to(component.get_node(value)))
				config["%s.%s" % [component.name, property.name]] = value
	return config


func _mineable_asteroid(ship: Node3D) -> int:
	var field := _arena.get_node("Asteroids")
	var best := -1
	var best_distance := INF
	for id: int in field.ids():
		var deposit = field.deposit(id)
		var distance: float = Vector2(field.center(id).x, field.center(id).z).distance_to(Vector2(ship.global_position.x, ship.global_position.z))
		if deposit.family == 0 and deposit.reserves >= 1000 and distance < best_distance and ship.get_node("Mining").can_mine(id):
			best = id
			best_distance = distance
	return best


func _bow_offset(ship: Node3D) -> float:
	var docking: Docking = ship.get_node("Docking")
	if docking.station == null or docking.slot < 0:
		return 999.0
	var heading: float = (ship.get_node("Locomotion") as ShipLocomotion).heading
	var bow := Vector2(-sin(heading), -cos(heading))
	return rad_to_deg(bow.angle_to(-docking.station.slots[docking.slot].axis))


func _until(condition: Callable, limit: int) -> int:
	for frame in limit:
		if condition.call():
			return frame
		await physics_frame
	return -1


func _click(position: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		event.global_position = position
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		root.push_input(event, true)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
