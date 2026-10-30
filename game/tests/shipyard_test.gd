extends SceneTree
## Headless Phase 4 suite on the playable main scene: the Shipyard station (authoring
## and placement geometry), the unit scenes' configuration parity with the authored
## ships, and the production cycle stepped deterministically: ordering and waiting
## without consumption, cancellation, atomic consumption, inventory contention with a
## Transporter, timed construction, deployment (pose, idle state, fuel, naming,
## registration), blocked deployment at the exact clearance boundary and repeated
## production. Ship physics is stepped manually at 60 Hz in the game's order (as
## silicon_shortage_test), over every child of Ships, then the stations, the refinery
## and the shipyard; deployed ships get their component physics switched off on
## deployment so the stepping stays in charge (shipyard_runtime_test covers the
## uninterrupted game loop).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/shipyard_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const STATION_SCENE := "res://game/stations/station.tscn"
const MINER_UNIT := preload("res://game/ships/miner_unit.tscn")
const TRANSPORTER_UNIT := preload("res://game/ships/transporter_unit.tscn")
const Station := preload("res://game/stations/station.gd")
const Shipyard := preload("res://game/shipyard/shipyard.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const Docking := preload("res://game/stations/docking.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const Scanner := preload("res://game/survey/scanner.gd")
## Unit scene, its archetype, its hull (architecture migration).
const VARIANTS := [
	[preload("res://game/ships/ff01_unit.tscn"), "res://game/ships/archetypes/warship.tscn", "res://game/ships/ff01.tscn"],
	[MINER_UNIT, "res://game/ships/archetypes/mining_ship.tscn", "res://game/ships/miner.tscn"],
	[TRANSPORTER_UNIT, "res://game/ships/archetypes/transport_ship.tscn", "res://game/ships/transporter.tscn"],
]
## The variant of every starting ship in main.tscn.
const STARTING := {"Miner1": "res://game/ships/miner_unit.tscn",
	"Miner2": "res://game/ships/miner_unit.tscn", "Transporter": "res://game/ships/transporter_unit.tscn"}
## The station scene of every station in main.tscn.
const STATIONS := {"Station": "res://game/stations/station.tscn", "Station2": "res://game/stations/refinery_station.tscn",
	"Shipyard": "res://game/stations/shipyard_station.tscn"}
const DT := 1.0 / 60.0
const CLASSES := ["FF01", "Miner1", "Transporter"] # One ship per hull class (the FF-01 is added to the scene).
const PARK := {"FF01": Vector2(40, -5), "Miner1": Vector2(40, -20), "Miner2": Vector2(40, -32)}
const IRON := &"iron_ingot"
const NICKEL := &"nickel_ingot"
const SILICON := &"silicon_ingot"
const TITANIUM := &"titanium_ingot"
const COBALT := &"cobalt_ingot"
## Settings compared per component (authored configuration; no runtime fields).
const PROPS := {
	"Locomotion": ["max_speed", "max_reverse_speed", "max_lateral_speed", "forward_accel", "reverse_accel", "lateral_accel",
		"max_turn_rate_deg", "turn_accel_deg", "collision_path"],
	"RouteFollower": ["ship_radius", "clearance_margin", "lookahead_reserve", "turn_brake_share", "maneuver_window_factor", "navigation_path"],
	"Avoidance": ["size_class", "separation_margin", "ships_path", "navigation_path"],
	"Cargo": ["capacity"],
	"Extractor": ["extraction_rate", "working_range", "field_path"],
	"Mining": ["field_path", "navigation_path", "ships_path"],
	"Transport": [],
	"Scanner": ["kind", "radius", "cooldown", "survey_path"],
	"Docking": ["navigation_path"],
	"Fuel": ["capacity", "consumption", "start_level"],
}

var _failures := 0
var _checks := 0
var _main: Node
var _nav: Node
var _field: Node
var _yard_station: Station
var _yard: Shipyard
var _deployment: Node3D
var _deployed: Array[Node3D] = []
var _notices: Array[String] = []


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	var ff01: Node3D = load("res://game/ships/ff01_unit.tscn").instantiate()
	ff01.name = "FF01"
	ff01.position = Vector3(14, 1.5, 0)
	_main.get_node("Ships").add_child(ff01)
	root.add_child(_main)
	_nav = _main.get_node("StaticNavigation")
	_field = _main.get_node("Asteroids")
	_yard_station = _main.get_node("Stations/Shipyard")
	_yard = _yard_station.get_node("Shipyard")
	_deployment = _yard_station.get_node("Deployment")
	_yard.ship_deployed.connect(_on_deployed)
	_yard.notice.connect(func(text: String) -> void: _notices.append(text))
	_main.get_node("Survey").set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		for child in ship.get_children():
			child.set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	_main.get_node("Stations/Station2/Refinery").set_physics_process(false)
	_yard.set_physics_process(false)
	for ship_name in CLASSES:
		while not _nav.is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame
	for ship_name: String in PARK:
		_locomotion(ship_name).place(PARK[ship_name], 0.0)

	_test_authoring()
	_test_placement()
	_test_parity()
	_test_ordering()
	_test_contention()
	_test_construction_and_deployment()
	_test_blocked_deployment()
	_test_repeated_production()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _on_deployed(ship: Node3D) -> void:
	_deployed.append(ship)
	for child in ship.get_children():
		child.set_physics_process(false) # Stepped manually with the other ships.


# --- 1. Authoring -----------------------------------------------------------------

func _test_authoring() -> void:
	var stations := _main.get_node("Stations").get_children()
	var yards := stations.filter(func(s: Node) -> bool: return s.get_node_or_null("Shipyard") != null)
	var refineries := stations.filter(func(s: Node) -> bool: return s.get_node_or_null("Refinery") != null)
	_check("1. third station: a shipyard_station.tscn instance (station.tscn layout) in the station group, with the Shipyard component and a Deployment marker",
		_yard_station.scene_file_path == "res://game/stations/shipyard_station.tscn"
		and (load(_yard_station.scene_file_path) as PackedScene).get_state().get_node_instance(0).resource_path == STATION_SCENE
		and _yard_station.is_in_group(Station.GROUP) and stations.size() == 3
		and yards == [_yard_station] and refineries == [_main.get_node("Stations/Station2")] and _deployment is Marker3D)
	var expected := Transform3D(Basis(Vector3(0.857167, 0, -0.515038), Vector3(0, 1, 0), Vector3(0.515038, 0, 0.857167)), Vector3(-31, 1.5, -113))
	_check("1. approved transform (-31, 1.5, -113), yaw +31 deg; Deployment local (0, 0, -16) -> (%.2f, %.2f, %.2f), bow (%.3f, %.3f)" % [
		_deployment.global_position.x, _deployment.global_position.y, _deployment.global_position.z, -_deployment.global_basis.z.x, -_deployment.global_basis.z.z],
		_yard_station.transform.is_equal_approx(expected) and is_equal_approx(_yard_station.rotation_degrees.y, 31.0)
		and _deployment.transform.is_equal_approx(Transform3D(Basis(), Vector3(0, 0, -16)))
		and _deployment.global_position.distance_to(Vector3(-39.2406, 1.5, -126.7147)) < 0.001)
	_check("1. recipes: Mining Ship iron 200 / nickel 100 / silicon 50 in 60 s; Transport Ship iron 300 / titanium 100 / cobalt 50 in 90 s",
		Shipyard.RECIPES[&"mining_ship"].ingots == {IRON: 200, NICKEL: 100, SILICON: 50} and Shipyard.RECIPES[&"mining_ship"].duration == 60.0
		and Shipyard.RECIPES[&"transport_ship"].ingots == {IRON: 300, TITANIUM: 100, COBALT: 50} and Shipyard.RECIPES[&"transport_ship"].duration == 90.0
		and Shipyard.RECIPES[&"mining_ship"].scene == MINER_UNIT and Shipyard.RECIPES[&"transport_ship"].scene == TRANSPORTER_UNIT)
	_check("1. navigation and collision read 36 asteroids + 9 station boxes; idle shipyard, empty storage",
		_nav._obstacles.size() == 45 and _main.get_node("PlanarCollision")._obstacles.size() == 45
		and _yard.state == Shipyard.State.IDLE and _yard_station.storage.quantity() == 0)


# --- 2. Placement geometry ----------------------------------------------------------

func _test_placement() -> void:
	var worst := INF
	var worst_label := ""
	var deploy := _planar(_deployment.global_position)
	var points := []
	for i in 2:
		var berth = _yard_station.berths[i]
		for c in berth.corners():
			points.append([c, "rectangle corner"])
		for s in CLASSES:
			var r := _r(s)
			points.append([berth.park_point(r), "parking point " + s])
			points.append([berth.handover_point(r), "handover point " + s])
			for side in [1, -1]:
				var legs: Array = berth.exit_legs(r, side)
				points.append([legs[0].move, "exit back point " + s])
				points.append([legs[2].move, "exit end point"])
	for hold in _yard_station.holds:
		points.append([hold.point, "holding position"])
	points.append([deploy, "deployment point"])
	for p in points:
		var d := _asteroid_gap(p[0])
		if d < worst:
			worst = d
			worst_label = p[1]
	_check("2. every docking, holding, exit and deployment point >= 15.0 u from asteroid surfaces (worst %.6f u, %s)" % [worst, worst_label], worst >= 15.0)

	var docking_ok := true
	for s in CLASSES:
		for i in 2:
			var berth = _yard_station.berths[i]
			docking_ok = docking_ok and _nav.segment_clear(berth.handover_point(_r(s)), berth.park_point(_r(s)), _r(s)) \
				and _yard_station.exit_sides(i, _r(s)).size() == 2
		docking_ok = docking_ok and _docking(s).can_dock(_yard_station)
	_check("2. every class: straight entry clear and both exit sides usable at both berths; can_dock(Shipyard) from its position", docking_ok)

	var holds_ok := true
	for hold in _yard_station.holds:
		for s in CLASSES:
			var pr: float = _node(s, "RouteFollower").planning_radius()
			holds_ok = holds_ok and _nav.closest_point(pr, hold.point).distance_to(hold.point) < 0.01 and _nav.surface_distance(hold.point) > _r(s)
	_check("2. every holding position fits every class's planning radius", holds_ok)

	var routes_ok := true
	var longest := 0.0
	for s in CLASSES:
		var pr: float = _node(s, "RouteFollower").planning_radius()
		for from_name in ["Station", "Station2"]:
			var from_station: Station = _main.get_node("Stations/" + from_name)
			for fi in 2:
				for ti in 2:
					var b: Vector2 = _yard_station.berths[ti].handover_point(_r(s))
					var route: PackedVector2Array = _nav.plan(pr, from_station.berths[fi].handover_point(_r(s)), b)
					routes_ok = routes_ok and route.size() >= 2 and route[route.size() - 1].distance_to(b) < 0.25
					longest = maxf(longest, _length(route))
	_check("2. routes from both berths of Station (Base) and Station2 (Refinery) reach both Shipyard handovers, every class (longest %.0f u)" % longest, routes_ok)

	var t := _r("Transporter")
	var static_gap: float = _nav.surface_distance(deploy) - t
	var rect_gap := minf(_yard_station.berths[0].rect_gap(deploy), _yard_station.berths[1].rect_gap(deploy)) - t
	var hold_gap := INF
	for hold in _yard_station.holds:
		hold_gap = minf(hold_gap, deploy.distance_to(hold.point) - t - _r("FF01") - Shipyard.DEPLOY_MARGIN)
	var path_gap := INF
	for i in 2:
		var berth = _yard_station.berths[i]
		for s in CLASSES:
			var r := _r(s)
			path_gap = minf(path_gap, _poly_point(PackedVector2Array([berth.handover_point(r), berth.park_point(r)]), deploy) - r - t)
			for side in _yard_station.exit_sides(i, r):
				var legs: Array = berth.exit_legs(r, side)
				path_gap = minf(path_gap, _poly_point(PackedVector2Array([berth.park_point(r), legs[0].move, legs[2].move]), deploy) - r - t)
	var edge := 150.0 - maxf(absf(deploy.x), absf(deploy.y)) - t
	_check("2. deployment clear for the Transporter: static %.2f, berth rectangles %.2f, holds (with an FF-01 + 1 u) %.2f, station-controlled paths %.2f, map edge %.2f u" % [
		static_gap, rect_gap, hold_gap, path_gap, edge], static_gap > 0.0 and rect_gap > 0.0 and hold_gap > 0.0 and path_gap > 0.0 and edge > 0.0)


# --- 3. Configuration parity (authored settings, hull, footprint) --------------------

func _test_parity() -> void:
	var reference := MAIN.instantiate() # Not in the tree: authored values, nothing initialized.
	var pairs := [[MINER_UNIT, "Miner1"], [MINER_UNIT, "Miner2"], [TRANSPORTER_UNIT, "Transporter"]]
	for pair in pairs:
		var unit: Node3D = (pair[0] as PackedScene).instantiate()
		var authored: Node3D = reference.get_node("Ships/" + pair[1])
		var differences := _differences(unit, authored)
		_check("3. %s unit scene = %s in main.tscn: components, order, scripts, settings, hull, footprint%s" % [
			"Miner" if pair[0] == MINER_UNIT else "Transporter", pair[1], "" if differences.is_empty() else " - " + ", ".join(differences)],
			differences.is_empty())
		unit.free()
	# Architecture migration: each unit scene is a variant of its role archetype, with
	# the existing hull scene instanced as its Model.
	for variant: Array in VARIANTS:
		var unit: Node3D = (variant[0] as PackedScene).instantiate()
		var base: String = (variant[0] as PackedScene).get_state().get_node_instance(0).resource_path
		var model := unit.get_node_or_null("Model")
		_check("3. %s inherits %s, hull %s under Model" % [(variant[0] as PackedScene).resource_path.get_file(), variant[1].get_file(), variant[2].get_file()],
			base == variant[1] and model != null and model.scene_file_path == variant[2])
		unit.free()
	# Starting ships are plain instances of their variants: only the transform is
	# overridden in main.tscn and nothing is added under them.
	var ships_plain := _plain_instances("Ships", STARTING)
	_check("3. starting ships are instances of their variants with only the transform overridden, nothing added%s" % ships_plain[1], ships_plain[0])
	var stations_plain := _plain_instances("Stations", STATIONS)
	_check("3. stations are instances of their station scenes with only the transform overridden, nothing added%s" % stations_plain[1], stations_plain[0])
	var same_definition := true
	for recipe: Dictionary in Shipyard.RECIPES.values():
		for ship: Node in reference.get_node("Ships").get_children():
			if String(ship.name).begins_with(recipe.series):
				same_definition = same_definition and ship.scene_file_path == (recipe.scene as PackedScene).resource_path
	_check("3. produced and starting ships of each series use the same variant (Miner: %s, Transporter: %s)" % [
		Shipyard.RECIPES[&"mining_ship"].scene.resource_path.get_file(), Shipyard.RECIPES[&"transport_ship"].scene.resource_path.get_file()], same_definition)
	reference.free()


# Whether every node under `parent` in main.tscn is an instance of its expected scene
# (expected: name -> scene path) overriding only its transform, with nothing added under
# it; [ok, details when not].
func _plain_instances(parent: String, expected: Dictionary) -> Array:
	var state := MAIN.get_state()
	var found := {}
	var extra: Array[String] = []
	for i in state.get_node_count():
		var path := String(state.get_node_path(i)).trim_prefix("./")
		if not path.begins_with(parent + "/"):
			continue
		var node_name := path.get_slice("/", 1)
		if path.count("/") > 1 or not expected.has(node_name):
			extra.append(path)
			continue
		var properties: Array[String] = []
		for p in state.get_node_property_count(i):
			properties.append(String(state.get_node_property_name(i, p)))
		var instance := state.get_node_instance(i)
		found[node_name] = [instance.resource_path if instance != null else "", properties]
	var ok := extra.is_empty() and found.size() == expected.size()
	for node_name: String in expected:
		ok = ok and found.has(node_name) and found[node_name][0] == expected[node_name] and found[node_name][1] == ["transform"]
	return [ok, "" if ok else " - %s, extra %s" % [str(found), str(extra)]]


# Differences in components (order, scripts, settings) and hull parts (meshes found at
# any depth, keyed by name, transform relative to the ship, mesh and bounds).
func _differences(unit: Node3D, authored: Node3D) -> Array[String]:
	var found: Array[String] = []
	var unit_names := _components(unit).map(func(n: Node) -> String: return String(n.name))
	var authored_names := _components(authored).map(func(n: Node) -> String: return String(n.name))
	if unit_names != authored_names:
		found.append("components %s vs %s" % [str(unit_names), str(authored_names)])
		return found
	for child in _components(authored):
		var mine := unit.get_node(NodePath(child.name))
		var script_a: Script = child.get_script()
		var script_b: Script = mine.get_script()
		# Combat migration: `Weapons` is a script-less container (its hardpoints are compared
		# as hull parts below); every other component must carry the same script.
		if script_a == null and script_b == null and child.get_class() == mine.get_class() and String(child.name) == "Weapons":
			continue
		if script_a == null or script_b == null or script_a.resource_path != script_b.resource_path:
			found.append("script of " + String(child.name))
			continue
		for property: String in PROPS.get(String(child.name), ["<unlisted component>"]):
			if mine.get(property) != child.get(property):
				found.append("%s.%s %s vs %s" % [child.name, property, str(mine.get(property)), str(child.get(property))])
	var parts_a := _hull_parts(authored)
	var parts_b := _hull_parts(unit)
	if parts_a.keys() != parts_b.keys():
		found.append("hull parts %s vs %s" % [str(parts_b.keys()), str(parts_a.keys())])
	else:
		for part: String in parts_a:
			if parts_a[part] != parts_b[part]:
				found.append("hull part " + part)
	if _reach(unit) != _reach(authored):
		found.append("hull reach %.3f vs %.3f" % [_reach(unit), _reach(authored)])
	return found


# The ship's component nodes (every child except hull meshes and the Model).
func _components(ship: Node3D) -> Array[Node]:
	return ship.get_children().filter(func(n: Node) -> bool: return not (n is MeshInstance3D or n.name == &"Model"))


# Hull meshes at any depth: name -> [transform relative to the ship, mesh, bounds].
func _hull_parts(ship: Node3D) -> Dictionary:
	var parts := {}
	for part: MeshInstance3D in ship.find_children("*", "MeshInstance3D", true, false):
		parts[String(part.name)] = [_relative(part, ship), part.mesh.resource_path, part.mesh.get_aabb()]
	return parts


# A node's transform relative to an ancestor (works outside the tree).
func _relative(node: Node3D, ancestor: Node3D) -> Transform3D:
	var result := node.transform
	var parent := node.get_parent() as Node3D
	while parent != ancestor:
		result = parent.transform * result
		parent = parent.get_parent() as Node3D
	return result


# Farthest hull corner from the ship's centre on the plane (selection ring size).
func _reach(ship: Node3D) -> float:
	var reach := 0.0
	for part: MeshInstance3D in ship.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = _relative(part, ship) * part.get_aabb()
		for i in 8:
			reach = maxf(reach, Vector2(box.get_endpoint(i).x, box.get_endpoint(i).z).length())
	return reach


# --- 4. Ordering, waiting, cancellation, atomic start ---------------------------------

func _test_ordering() -> void:
	var storage := _yard_station.storage
	_check("4. order with no ingots: accepted, Waiting for Materials, storage unchanged",
		_yard.order(&"mining_ship") and _yard.state == Shipyard.State.WAITING and _yard.recipe == &"mining_ship" and storage.quantity() == 0)
	_check("4. second orders (either type) refused, the active order unchanged", not _yard.order(&"transport_ship") and not _yard.order(&"mining_ship")
		and _yard.state == Shipyard.State.WAITING and _yard.recipe == &"mining_ship")
	storage.add(IRON, 200)
	storage.add(NICKEL, 100)
	storage.add(SILICON, 49)
	_steps(120)
	_check("4. some ingredients (silicon 49 of 50): still waiting, nothing consumed or reserved, missing {silicon 1}",
		_yard.state == Shipyard.State.WAITING and storage.quantity_of(IRON) == 200 and storage.quantity_of(NICKEL) == 100
		and storage.quantity_of(SILICON) == 49 and _yard.missing(&"mining_ship") == {SILICON: 1} and _yard.progress() == 0.0)
	var outside := Inventory.new()
	outside.capacity = 1000
	storage.transfer_to(outside, 30, IRON)
	_steps(1)
	_check("4. ingots removed while waiting: shortages recalculated (iron 30, silicon 1), still waiting",
		_yard.state == Shipyard.State.WAITING and _yard.missing(&"mining_ship") == {IRON: 30, SILICON: 1})
	_check("4. cancel a waiting order: Idle, storage unchanged (iron 170, nickel 100, silicon 49); cancel when idle refused",
		_yard.cancel() and _yard.state == Shipyard.State.IDLE and _yard.recipe == &"" and storage.quantity_of(IRON) == 170
		and storage.quantity_of(NICKEL) == 100 and storage.quantity_of(SILICON) == 49 and not _yard.cancel())
	outside.transfer_to(storage, 30, IRON)
	storage.add(SILICON, 11)
	storage.add(IRON, 50)
	_yard.order(&"mining_ship")
	_check("4. order with every ingredient present: construction starts at once, exactly the recipe consumed (left: iron 50, silicon 10)",
		_yard.state == Shipyard.State.CONSTRUCTING and storage.quantity_of(IRON) == 50 and storage.quantity_of(NICKEL) == 0
		and storage.quantity_of(SILICON) == 10 and _yard.elapsed == 0.0)
	_check("4. during construction: cancel and new orders refused", not _yard.cancel() and not _yard.order(&"transport_ship")
		and _yard.state == Shipyard.State.CONSTRUCTING and _yard.recipe == &"mining_ship")
	_steps(60)
	storage.add(IRON, 200)
	_steps(60)
	_check("4. ingots delivered during construction are stored and change nothing (elapsed %.3f s, iron 250, still constructing)" % _yard.elapsed,
		absf(_yard.elapsed - 2.0) < 0.0001 and storage.quantity_of(IRON) == 250 and _yard.state == Shipyard.State.CONSTRUCTING)
	# Finish this ship for the deployment checks (section 6) later; here only the waiting rules.


# --- 5. Contention with a Transporter loading from the Shipyard -----------------------

func _test_contention() -> void:
	# The Mining Ship of section 4 is under construction; let it finish and deploy first.
	_until(func() -> bool: return _yard.state == Shipyard.State.IDLE, 60 * 70)
	_clear_deployment_area() # Miner3 moved away.
	var storage := _yard_station.storage
	for resource in storage.amounts.keys():
		storage.remove(resource, storage.amounts[resource])
	_locomotion("Transporter").place(_nav.closest_point(_node("Transporter", "RouteFollower").planning_radius(), Vector2(10, -125)), 0.0)
	_docking("Transporter").dock(_yard_station)
	var docked := _until(func() -> bool: return _docking("Transporter").state == Docking.State.DOCKED, 60 * 120)
	storage.add(IRON, 300)
	storage.add(TITANIUM, 100)
	_yard.order(&"transport_ship") # Cobalt missing: waits.
	var cargo: Inventory = _node("Transporter", "Cargo").inventory
	_docking("Transporter").load_cargo(IRON, 150)
	var conserved := true
	var negative := false
	var consumed := 0
	var started_at := -1
	for tick in 60 * 12:
		if tick == 60:
			storage.add(COBALT, 50) # Complete except for the iron being loaded away.
		if tick == 60 * 6:
			_docking("Transporter").unload() # The iron comes back: the recipe completes.
		var before := _yard.state
		_steps(1)
		if before == Shipyard.State.WAITING and _yard.state == Shipyard.State.CONSTRUCTING:
			consumed += 300
			started_at = tick
		negative = negative or storage.quantity_of(IRON) < 0 or cargo.quantity_of(IRON) < 0
		conserved = conserved and storage.quantity_of(IRON) + cargo.quantity_of(IRON) + consumed == 300
	_check("5. Transporter docked at the Shipyard (%.0f s) loads 150 iron while a Transport Ship order waits; cobalt arrives mid-load: the order keeps waiting" % (docked / 60.0),
		docked >= 0 and started_at > 60 * 6)
	_check("5. the returned iron completes the recipe: consumed exactly once (at %.2f s); iron conserved every tick, never negative" % (started_at / 60.0),
		conserved and not negative and consumed == 300 and storage.quantity_of(IRON) == 0 and storage.quantity_of(TITANIUM) == 0 and storage.quantity_of(COBALT) == 0)
	_docking("Transporter").undock()
	_until(func() -> bool: return _docking("Transporter").state == Docking.State.NONE, 60 * 90)
	_locomotion("Transporter").place(Vector2(-80, 30), 0.0)
	_until(func() -> bool: return _yard.state == Shipyard.State.IDLE, 60 * 95)


# --- 6. Construction and deployment -------------------------------------------------

func _test_construction_and_deployment() -> void:
	# Sections 4 and 5 produced Miner3 and Transporter2; this section produces Miner4
	# from a clean start and checks the deployment itself.
	_clear_deployment_area()
	var storage := _yard_station.storage
	storage.add(IRON, 200)
	storage.add(NICKEL, 100)
	storage.add(SILICON, 50)
	var fuel_stock := _yard_station.fuel_stock
	var ships_before := _main.get_node("Ships").get_child_count()
	var children_before := _main.get_child_count()
	var rings_before: int = _main.get_node("Selection")._rings.size()
	_deployed.clear()
	_notices.clear()
	_yard.order(&"mining_ship")
	var ticks := _until(func() -> bool: return not _deployed.is_empty(), 60 * 70)
	_check("6. construction takes 60 s (%d ticks) and deploys at once when clear (no Awaiting Deployment state)" % ticks,
		absi(ticks - 3600) <= 1 and _yard.state == Shipyard.State.IDLE and _yard.recipe == &"" and _yard.elapsed == 0.0)
	var ship: Node3D = _deployed[0] if not _deployed.is_empty() else null
	if ship == null:
		return
	var loco := ship.get_node("Locomotion") as ShipLocomotion
	var deploy := _planar(_deployment.global_position)
	_check("6. exactly one ship added, named Miner4 (after Miner1-3), under Ships (player-owned)",
		_main.get_node("Ships").get_child_count() == ships_before + 1 and ship.name == "Miner4" and ship.get_parent() == _main.get_node("Ships")
		and _yard.last_completed == "Miner4")
	_check("6. at the marker: position %s, heading %.2f deg (marker %.2f), at rest" % [str(loco.planar_position), rad_to_deg(loco.heading), _deployment.global_rotation_degrees.y],
		loco.planar_position.distance_to(deploy) < 0.001 and absf(angle_difference(loco.heading, _deployment.global_rotation.y)) < 0.0001
		and loco.velocity == Vector2.ZERO and is_equal_approx(ship.global_position.y, 1.5))
	var mining := ship.get_node("Mining") as MiningOperation
	_check("6. idle: no order, route, mining assignment, dock request or transfer",
		not loco.has_destination and (ship.get_node("RouteFollower") as RouteFollower).status == RouteFollower.RouteStatus.NONE
		and mining.status == MiningOperation.Status.NONE and mining.target == -1 and (ship.get_node("Docking") as Docking).state == Docking.State.NONE)
	var fuel := ship.get_node("Fuel")
	_check("6. full tank (%.0f / %.0f) without taking station fuel (%.0f -> %.0f); propulsion on; Mining Scanner" % [fuel.fuel, fuel.capacity, fuel_stock, _yard_station.fuel_stock],
		fuel.fuel == fuel.capacity and _yard_station.fuel_stock == fuel_stock and loco.propulsion
		and (ship.get_node("Scanner") as Scanner).kind == Scanner.Kind.MINING)
	_check("6. notice once: \"%s\"" % (_notices[0] if not _notices.is_empty() else ""), _notices == ["Shipyard: Miner4 completed"])
	# Registration (selection and the scene's command layer), idempotent.
	var selection := _main.get_node("Selection")
	var connected := 0
	for node_name in ["RouteFollower", "Mining", "Docking", "Fuel"]:
		for connection: Dictionary in ship.get_node(node_name).notice.get_connections():
			if connection.callable.get_object() == _main:
				connected += 1
	_check("6. registered: selection hull boxes and one ring, movement indicator (no node per ship), 4 notice signals connected once",
		selection._parts.has(ship) and selection._rings.size() == rings_before + 1 and _main._registered.has(ship)
		and _main.get_child_count() == children_before and connected == 4)
	selection.register_ship(ship)
	_main.register_ship(ship)
	var connected_again := 0
	for node_name in ["RouteFollower", "Mining", "Docking", "Fuel"]:
		connected_again += ship.get_node(node_name).notice.get_connections().filter(func(c: Dictionary) -> bool: return c.callable.get_object() == _main).size()
	_check("6. registering again changes nothing (rings, markers, connections)", selection._rings.size() == rings_before + 1
		and _main.get_child_count() == children_before and connected_again == 4)
	selection.set_selection([ship])
	_check("6. selectable: the selection holds the new ship", selection.selected == [ship])
	selection.set_selection([])


# --- 7. Blocked deployment ----------------------------------------------------------

func _test_blocked_deployment() -> void:
	# Miner4 (section 6) stays at the marker; a Transport Ship completes behind it.
	var blocker: Node3D = _deployed[0]
	var storage := _yard_station.storage
	storage.add(IRON, 300)
	storage.add(TITANIUM, 100)
	storage.add(COBALT, 50)
	_deployed.clear()
	var ships_before := _main.get_node("Ships").get_child_count()
	_yard.order(&"transport_ship")
	var stock_after_start := storage.quantity()
	_until(func() -> bool: return _yard.state == Shipyard.State.AWAITING_DEPLOYMENT, 60 * 95)
	_steps(60 * 30)
	_check("7. completed while Miner4 holds the deployment point: Awaiting Deployment, no ship added, nothing consumed again (30 s)",
		_yard.state == Shipyard.State.AWAITING_DEPLOYMENT and _deployed.is_empty() and _main.get_node("Ships").get_child_count() == ships_before
		and storage.quantity() == stock_after_start and _yard.progress() == 1.0)
	var deploy := _planar(_deployment.global_position)
	var limit: float = _r("Transporter") + blocker.get_node("RouteFollower").ship_radius + Shipyard.DEPLOY_MARGIN
	(blocker.get_node("Locomotion") as ShipLocomotion).place(deploy + Vector2(1, 0) * (limit - 0.01), 0.0)
	_steps(1)
	var still := _yard.state == Shipyard.State.AWAITING_DEPLOYMENT and _deployed.is_empty()
	(blocker.get_node("Locomotion") as ShipLocomotion).place(deploy + Vector2(1, 0) * (limit + 0.01), 0.0)
	_steps(1)
	_check("7. boundary: still blocked at %.2f u (both footprints + 1 u - 0.01), deployed in the tick it is %.2f u" % [limit - 0.01, limit + 0.01],
		still and _deployed.size() == 1 and _yard.state == Shipyard.State.IDLE)
	_steps(60)
	var names := _main.get_node("Ships").get_children().map(func(n: Node) -> String: return String(n.name))
	_check("7. exactly one Transporter3 (after Transporter, Transporter2), never overlapping Miner4 (gap %.2f u)" % (
		_planar(_deployed[0].global_position).distance_to(_planar(blocker.global_position)) - limit + Shipyard.DEPLOY_MARGIN),
		_deployed.size() == 1 and _deployed[0].name == "Transporter3" and names.count("Transporter3") == 1
		and _main.get_node("Ships").get_child_count() == ships_before + 1)


# --- 8. Repeated production ---------------------------------------------------------

func _test_repeated_production() -> void:
	var storage := _yard_station.storage
	_deployed.clear()
	_clear_deployment_area()
	var results: Array[String] = []
	for round_index in 2:
		storage.add(IRON, 200)
		storage.add(NICKEL, 100)
		storage.add(SILICON, 50)
		var ok := _yard.order(&"mining_ship")
		_until(func() -> bool: return _deployed.size() == round_index + 1, 60 * 70)
		ok = ok and _deployed.size() == round_index + 1 and _yard.state == Shipyard.State.IDLE and _yard.recipe == &"" and _yard.elapsed == 0.0
		results.append("%s %s" % [_deployed.back().name if _deployed.size() == round_index + 1 else "none", "ok" if ok else "FAILED"])
		_clear_deployment_area() # The player moves the new ship away.
	_check("8. two successive orders produce two ships (%s) with no stale order or occupancy" % ", ".join(results),
		results.size() == 2 and results.all(func(r: String) -> bool: return r.ends_with("ok")) and _deployed[0].name == "Miner5" and _deployed[1].name == "Miner6")
	var all_names := _main.get_node("Ships").get_children().map(func(n: Node) -> String: return String(n.name))
	var unique := {}
	for n in all_names:
		unique[n] = true
	_check("8. ship names unique: %s" % ", ".join(all_names), unique.size() == all_names.size())


# Moves every ship near the deployment point well away (test fixture).
func _clear_deployment_area() -> void:
	var deploy := _planar(_deployment.global_position)
	var k := 0
	for ship: Node3D in _main.get_node("Ships").get_children():
		var loco := ship.get_node("Locomotion") as ShipLocomotion
		if loco.planar_position.distance_to(deploy) < 20.0:
			loco.place(Vector2(60.0 + 12.0 * k, 80.0), 0.0)
			k += 1


# --- Stepping and helpers -----------------------------------------------------------

func _steps(count: int) -> void:
	for i in count:
		var ships := _main.get_node("Ships").get_children()
		for ship in ships:
			ship.get_node("RouteFollower")._physics_process(DT)
			ship.get_node("Avoidance")._physics_process(DT)
		for ship in ships:
			(ship.get_node("Locomotion") as ShipLocomotion)._step(DT)
		for ship in ships:
			for child in ["Mining", "Transport"]:
				var node := ship.get_node_or_null(child)
				if node != null:
					node._physics_process(DT)
			ship.get_node("Docking")._physics_process(DT)
			ship.get_node("Fuel")._physics_process(DT)
			ship.get_node("Scanner")._physics_process(DT)
		for station in _main.get_node("Stations").get_children():
			station._physics_process(DT)
		_main.get_node("Stations/Station2/Refinery")._physics_process(DT)
		_yard._physics_process(DT)


func _until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_steps(1)
	return -1


func _asteroid_gap(point: Vector2) -> float:
	var best := INF
	for id in _field.ids():
		best = minf(best, _field.surface_distance(id, point))
	return best


func _poly_point(path: PackedVector2Array, point: Vector2) -> float:
	var best := INF
	for i in path.size() - 1:
		best = minf(best, Geometry2D.get_closest_point_to_segment(point, path[i], path[i + 1]).distance_to(point))
	return best


func _length(route: PackedVector2Array) -> float:
	var total := 0.0
	for i in route.size() - 1:
		total += route[i].distance_to(route[i + 1])
	return total


func _r(ship_name: String) -> float:
	return _node(ship_name, "RouteFollower").ship_radius


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _locomotion(ship_name: String) -> ShipLocomotion:
	return _node(ship_name, "Locomotion") as ShipLocomotion


func _docking(ship_name: String) -> Docking:
	return _node(ship_name, "Docking") as Docking


static func _planar(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
