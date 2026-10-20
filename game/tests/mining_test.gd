extends SceneTree
## Headless Phase 2 Stage 2 checks on the playable main scene: the Miner graybox,
## raw cargo inventory, mining assignments (right-click), extraction and the
## panel. Ship physics is stepped manually at 60 Hz in the game's order (per ship
## RouteFollower then Avoidance, then Locomotion, then the mining operations).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/mining_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const Survey := preload("res://game/survey/survey.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2"]
const SEED := 20261014
const NEAR := 29 # Asteroid north of the spawn, used for right-click checks.

var _failures := 0
var _checks := 0
var _main: Node
var _field: AsteroidField
var _survey: Survey
var _navigation: Node
var _selection: Node
var _camera: Camera3D
var _rig: Node3D
var _notices: Array[String] = []


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_field = _main.get_node("Asteroids")
	_survey = _main.get_node("Survey")
	_navigation = _main.get_node("StaticNavigation")
	_selection = _main.get_node("Selection")
	_camera = _main.get_node("CameraRig/Camera3D")
	_rig = _main.get_node("CameraRig")
	_survey.set_physics_process(false)
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.set_physics_process(false)
	for ship_name in SHIPS:
		while not _navigation.is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame
	for miner in ["Miner1", "Miner2"]:
		_mining(miner).notice.connect(func(text: String) -> void: _notices.append(text))
	_field.generate(SEED)

	_test_geometry_and_profile()
	_test_selection()
	_test_inventory()
	_test_frame_rate()
	_test_right_click_mining()
	_test_redirect_and_cancel()
	_test_group_and_other_ships()
	_test_capacity()
	_test_depletion_and_two_miners()
	_test_families()
	_test_unreachable()
	await _test_feedback()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _test_geometry_and_profile() -> void:
	var miner := _ship("Miner1")
	var bounds := AABB()
	var total := AABB()
	var reach := 0.0
	var boxes := 0
	var thrusters := 0
	var thruster_node := miner.get_node("Model/Thrusters")
	for part: MeshInstance3D in miner.find_children("*", "MeshInstance3D", true, false):
		# UX round T25: the thruster parts (Model/Thrusters) are counted apart from the
		# original hull and included in the total bounds and the reach.
		var is_thruster := thruster_node.is_ancestor_of(part)
		var box: AABB = (part.get_parent() as Node3D).transform * part.transform * part.get_aabb() if is_thruster else part.transform * part.get_aabb()
		if is_thruster:
			thrusters += 1
		else:
			boxes += 1 if part.mesh is BoxMesh else 0
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
		total = box if total.size == Vector3.ZERO else total.merge(box)
		for i in 8:
			var corner := box.get_endpoint(i)
			reach = maxf(reach, Vector2(corner.x, corner.z).length())
	_check("Miner: 3 box parts, %.2f u long (Z) x %.2f u wide (X), symmetric" % [bounds.size.z, bounds.size.x],
		boxes == 3 and is_equal_approx(bounds.size.z, 2.4) and is_equal_approx(bounds.size.x, 1.6) and is_equal_approx(bounds.get_center().x, 0.0))
	_check("Miner: with its 9 thruster parts, %.2f u long (Z) x %.2f u wide (X), symmetric, larger than the hull alone" % [total.size.z, total.size.x],
		thrusters == 9 and total.size.z > bounds.size.z and total.size.x > bounds.size.x and is_equal_approx(total.get_center().x, 0.0) and total.encloses(bounds))
	_check("Miner: hull inside the 1.6 u collision radius (farthest corner %.2f u)" % reach, reach <= 1.6)
	var same := true
	for property in ["max_speed", "max_reverse_speed", "max_lateral_speed", "forward_accel", "reverse_accel", "lateral_accel", "max_turn_rate_deg", "turn_accel_deg"]:
		same = same and _node("Miner1", "Locomotion").get(property) == _node("Frigate", "Locomotion").get(property)
		same = same and _node("Miner2", "Locomotion").get(property) == _node("Frigate", "Locomotion").get(property)
	for property in ["ship_radius", "clearance_margin"]:
		same = same and _node("Miner1", "RouteFollower").get(property) == _node("Frigate", "RouteFollower").get(property)
	_check("Miner: Frigate locomotion, collision radius and clearance", same)


# 1: the Miners select like the other ships (click, Shift-click, box).
func _test_selection() -> void:
	_frame(Vector2(0, 14), 30.0)
	_click(_screen("Miner1"))
	var single: bool = _selection.selected == [_ship("Miner1")]
	_click(_screen("Miner2"), true)
	var added: bool = _selection.selected == [_ship("Miner1"), _ship("Miner2")]
	_click(_screen("Miner1"), true)
	var removed: bool = _selection.selected == [_ship("Miner2")]
	var rect := Rect2(_screen("Miner1"), Vector2.ZERO).expand(_screen("Miner2")).grow(20.0)
	_drag(rect.position, rect.end)
	var boxed: bool = _selection.selected == [_ship("Miner1"), _ship("Miner2")]
	_check("1. Miners: click, Shift-click and box selection", single and added and removed and boxed)
	_selection.set_selection([])


func _test_inventory() -> void:
	var inventory := Inventory.new(100)
	var added := inventory.add(&"iron", 30) + inventory.add(&"iron", 10)
	added += inventory.add(&"silicon", 20) + inventory.add(&"ice", 25)
	# Phase 3: replaces "identical chunks share a lot, other compositions stay apart".
	_check("inventory: each resource is one count, others kept apart", inventory.amounts == {&"iron": 40, &"silicon": 20, &"ice": 25})
	var over := inventory.add(&"ice", 50)
	_check("inventory: quantity, free space, never beyond capacity", added == 85 and over == 15 and inventory.quantity() == 100
		and inventory.free_space() == 0 and inventory.add(&"ice", 1) == 0)
	_check("inventory: quantity per resource", inventory.quantity_of(&"iron") == 40 and inventory.quantity_of(&"silicon") == 20
		and inventory.quantity_of(&"ice") == 40)


# Extraction totals do not depend on the physics rate.
func _test_frame_rate() -> void:
	var id := _find(AsteroidField.Family.MINERALS, 0)
	var extractor := _node("Miner1", "Extractor")
	var before := _field.deposit(id).reserves
	var totals := []
	for rate in [30, 60, 144]:
		var inventory := Inventory.new(100000)
		extractor.reset()
		for tick in 3 * rate:
			extractor.extract(id, inventory, 1.0 / rate)
		totals.append(inventory.quantity())
	var removed := before - _field.deposit(id).reserves
	_field.deposit(id).reserves = before
	var expected := roundi(3.0 * extractor.extraction_rate)
	_check("3 s of extraction at 30 / 60 / 144 Hz: %s units (rate %.0f/s)" % [str(totals), extractor.extraction_rate],
		totals.all(func(total: int) -> bool: return absi(total - expected) <= 1) and removed == totals[0] + totals[1] + totals[2])


# 2, 5-8, 11, 15 and the working position, through a right-click on an unscanned asteroid.
func _test_right_click_mining() -> void:
	_reset()
	_survey._levels[NEAR] = Survey.Level.UNKNOWN
	_frame(Vector2(4, 40), 40.0)
	_selection.set_selection([_ship("Miner1")])
	var click := _camera.unproject_position(_field.center(NEAR))
	_check("layout: the click point is on screen and over the asteroid", root.get_visible_rect().has_point(click)
		and _field.pick(_camera.project_ray_origin(click), _camera.project_ray_normal(click)) == NEAR)
	var plans: int = _node("Miner1", "RouteFollower").plans
	_right_click(click)
	_check("2. right-click on an asteroid assigns it", _mining("Miner1").target == NEAR and _mining("Miner1").status == MiningOperation.Status.TRAVELING)
	_steps(1)
	var work: Vector2 = _mining("Miner1").work_point
	var center := Vector2(_field.center(NEAR).x, _field.center(NEAR).z)
	var radius := _field.radius(NEAR)
	var follower := _node("Miner1", "RouteFollower")
	_check("working point: one route order to it, not the asteroid's centre", follower.plans == plans + 1 and follower.requested == work
		and _node("Miner1", "Locomotion").destination.distance_to(work) < 0.01)
	_check("working point: outside the asteroid by the ship's clearance (%.2f u from its outline)" % (work.distance_to(center) - radius),
		work.distance_to(center) - radius >= follower.planning_radius() and _navigation.closest_point(follower.planning_radius(), work).distance_to(work) < 0.25)
	_check("working point: within the working range", work.distance_to(center) - radius <= _node("Miner1", "Extractor").working_range)
	var reserves := _field.deposit(NEAR).reserves
	var early := false
	var ticks := 0
	var cargo := _cargo("Miner1")
	while _mining("Miner1").status != MiningOperation.Status.MINING and ticks < 60 * 40:
		var had := cargo.quantity()
		_steps(1)
		ticks += 1
		early = early or (cargo.quantity() > had and not _node("Miner1", "Extractor").in_range(NEAR))
	var first := ticks
	var gained := 0
	for tick in 60 * 10:
		var had := cargo.quantity()
		_steps(1)
		gained = maxi(gained, cargo.quantity() - had)
		early = early or (cargo.quantity() > had and not _node("Miner1", "Extractor").in_range(NEAR))
	_check("mining starts after %.1f s of travel" % (first * DT), _mining("Miner1").status == MiningOperation.Status.MINING)
	_check("6. extraction only within the working range, holding position", not early)
	_check("7./8. cargo +%d, reserves -%d" % [cargo.quantity(), reserves - _field.deposit(NEAR).reserves], cargo.quantity() > 0 and cargo.quantity() == reserves - _field.deposit(NEAR).reserves)
	_check("no movement orders while mining (1 order in %.0f s)" % ((first + 600) * DT), follower.plans == plans + 1)
	var deposit := _field.deposit(NEAR)
	# Phase 3: replaces "one lot with the asteroid's family and its composition".
	_check("11./12. the cargo holds the asteroid's raw resources, each within 1 unit of its share (%s)" % cargo.describe(),
		_proportional(cargo, deposit))
	_check("5. an unscanned asteroid is mined and stays unscanned", _survey.level_of(NEAR) == Survey.Level.UNKNOWN
		and _main.get_node("AsteroidHover").describe(NEAR) == "Asteroid\nNot scanned")
	_survey._levels[NEAR] = Survey.Level.ANALYZED
	_steps(60)
	_check("15. an analyzed survey shows the reduced reserves (%d)" % deposit.reserves,
		_main.get_node("AsteroidHover").describe(NEAR).contains("Remaining reserves: %d units" % deposit.reserves))
	_survey._levels.erase(NEAR)


# 3, 13: right-click elsewhere replaces mining; right-click another asteroid replaces the target.
func _test_redirect_and_cancel() -> void:
	# Continues from the previous test: Miner1 is mining NEAR.
	var other := _nearest_other(NEAR)
	var near := Vector2(_field.center(NEAR).x, _field.center(NEAR).z)
	var far := Vector2(_field.center(other).x, _field.center(other).z)
	_frame((near + far) * 0.5, 40.0)
	var click := _camera.unproject_position(_field.center(other))
	_check("layout: the second asteroid is on screen under the click", root.get_visible_rect().has_point(click)
		and _field.pick(_camera.project_ray_origin(click), _camera.project_ray_normal(click)) == other)
	_right_click(click)
	_check("right-click another asteroid replaces the target", _mining("Miner1").target == other and _mining("Miner1").status == MiningOperation.Status.TRAVELING)
	_steps(30)
	var cargo := _cargo("Miner1").quantity()
	var miner: Vector2 = _node("Miner1", "Locomotion").planar_position
	var ground := _ground_click(miner + (miner - near).normalized() * 8.0) # Open space, away from the asteroid.
	_check("layout: the empty-space click is on screen, over no asteroid", root.get_visible_rect().has_point(ground[0])
		and _field.pick(_camera.project_ray_origin(ground[0]), _camera.project_ray_normal(ground[0])) == -1)
	_right_click(ground[0])
	var follower := _node("Miner1", "RouteFollower")
	_check("3. right-click on empty space: MOVE to the clicked point", follower.requested.distance_to(ground[1]) < 0.01)
	_check("13. the manual order cancels mining and keeps the target", _mining("Miner1").status == MiningOperation.Status.CANCELED and _mining("Miner1").target == other)
	var plans: int = follower.plans
	_steps(240)
	_check("13. after cancellation no mining orders and cargo kept (%d)" % cargo, follower.plans == plans and _cargo("Miner1").quantity() == cargo)


# 4: group MOVE unchanged, also over an asteroid; other classes keep normal right-click.
func _test_group_and_other_ships() -> void:
	_reset()
	_mining("Miner1").assign(NEAR)
	_steps(1)
	_frame(Vector2(4, 40), 40.0)
	var ships := [_ship("Frigate"), _ship("Miner1")]
	_selection.set_selection(ships)
	var click := _camera.unproject_position(_field.center(NEAR))
	var hit: Vector3 = Plane(Vector3.UP, 0.0).intersects_ray(_camera.project_ray_origin(click), _camera.project_ray_normal(click))
	var expected: Dictionary = _main.get_node("GroupOrders").assign(ships, Vector2(hit.x, hit.z))
	_right_click(click)
	var same := not expected.is_empty()
	for ship: Node in expected:
		same = same and ship.get_node("Locomotion").destination.distance_to(expected[ship]) < 0.01
	_check("4. group right-click over an asteroid: the usual group MOVE", same)
	_check("4. the group MOVE cancels the miner's assignment, keeps the target", _mining("Miner1").status == MiningOperation.Status.CANCELED and _mining("Miner1").target == NEAR)
	_reset()
	_selection.set_selection([_ship("Frigate")])
	var plans: int = _node("Frigate", "RouteFollower").plans
	_right_click(click)
	_check("a Frigate's right-click over an asteroid is a normal MOVE", _node("Frigate", "RouteFollower").plans == plans + 1
		and _node("Frigate", "RouteFollower").requested.distance_to(Vector2(hit.x, hit.z)) < 0.01)
	_selection.set_selection([])


# 9: the cargo never exceeds its capacity.
func _test_capacity() -> void:
	_reset()
	var id := _find(AsteroidField.Family.MINERALS, 0)
	_stage("Miner1", id, 0.0)
	_cargo("Miner1").capacity = 50
	var reserves := _field.deposit(id).reserves
	_mining("Miner1").assign(id)
	_run_until_stopped(["Miner1"])
	var full := _cargo("Miner1").quantity()
	_steps(120)
	_check("9. cargo stops at its capacity: %d / 50, returning to base (Stage 5)" % full, full == 50 and _cargo("Miner1").quantity() == 50
		and _mining("Miner1").status == MiningOperation.Status.RETURNING and reserves - _field.deposit(id).reserves == 50)
	_cargo("Miner1").capacity = _node("Miner1", "Cargo").capacity


# 10, 14: depletion, and two miners on one asteroid.
func _test_depletion_and_two_miners() -> void:
	_reset()
	var id := _find(AsteroidField.Family.MINERALS, 1)
	_field.deposit(id).reserves = 37
	_stage("Miner1", id, 0.0)
	_mining("Miner1").assign(id)
	_run_until_stopped(["Miner1"])
	_check("10. extraction stops at depletion: 37 units aboard, reserves 0, final return (Stage 5)", _cargo("Miner1").quantity() == 37
		and _field.deposit(id).reserves == 0 and _mining("Miner1").status == MiningOperation.Status.RETURNING
		and _mining("Miner1").activity().ends_with("(asteroid depleted)"))
	_reset()
	_field.deposit(id).reserves = 151
	_stage("Miner1", id, -0.5)
	_stage("Miner2", id, 0.5)
	_mining("Miner1").assign(id)
	_mining("Miner2").assign(id)
	var contacts_before: int = _node("Miner1", "Locomotion").collision_count + _node("Miner2", "Locomotion").collision_count
	_run_until_stopped(["Miner1", "Miner2"])
	var a := _cargo("Miner1").quantity()
	var b := _cargo("Miner2").quantity()
	var apart: float = _mining("Miner1").work_point.distance_to(_mining("Miner2").work_point)
	_check("14. two miners: %d + %d = 151, reserves 0, both on their final return" % [a, b], a + b == 151 and a > 0 and b > 0
		and _field.deposit(id).reserves == 0 and _mining("Miner1").status == MiningOperation.Status.RETURNING
		and _mining("Miner2").status == MiningOperation.Status.RETURNING)
	_check("14. separate working points %.1f u apart, no contacts" % apart, apart >= 2.0 * 1.6 + MiningOperation.SHIP_GAP
		and _node("Miner1", "Locomotion").collision_count + _node("Miner2", "Locomotion").collision_count == contacts_before)


# 11, 12 (Phase 3): a mineral asteroid gives its six raw minerals in proportion, an
# ice asteroid gives ice only; each resource is counted on its own.
func _test_families() -> void:
	_reset()
	var metal := _find(AsteroidField.Family.MINERALS, 2)
	var ice := _find(AsteroidField.Family.ICE, 0)
	for id in [metal, ice]:
		_stage("Miner1", id, 0.0)
		_mining("Miner1").assign(id)
		_steps(60 * 20)
	var cargo := _cargo("Miner1")
	var minerals: Dictionary = _field.deposit(metal).extracted
	var ok := cargo.quantity_of(&"ice") > 0 and _field.deposit(ice).extracted == {&"ice": cargo.quantity_of(&"ice")}
	for mineral: StringName in AsteroidField.MINERALS:
		ok = ok and minerals[mineral] > 0 and cargo.quantity_of(mineral) == minerals[mineral]
	_check("11. a mineral asteroid gives its six raw minerals (%s)" % cargo.describe(), ok and _proportional_counts(minerals, _field.deposit(metal)))
	_check("12. an ice asteroid gives ice only, counted on its own", ok and cargo.quantity() == _field.deposit(metal).extracted_total + cargo.quantity_of(&"ice"))


# Every resource of the deposit within 1 unit of its share of what the cargo holds.
func _proportional(cargo: Inventory, deposit) -> bool:
	return cargo.amounts.keys().all(func(resource: StringName) -> bool: return deposit.composition.has(resource)) \
		and _proportional_counts(cargo.amounts, deposit)


func _proportional_counts(counts: Dictionary, deposit) -> bool:
	var total := 0
	for resource: StringName in counts:
		total += counts[resource]
	for resource: StringName in deposit.composition:
		if absf(counts.get(resource, 0) - deposit.composition[resource] * total / 100.0) >= 1.0:
			return false
	return total > 0


func _test_unreachable() -> void:
	_reset()
	var extractor := _node("Miner1", "Extractor")
	var working_range: float = extractor.working_range
	extractor.working_range = 1.0 # Inside the ship's clearance: no navigable working point.
	var plans: int = _node("Miner1", "RouteFollower").plans
	_notices.clear()
	_mining("Miner1").assign(NEAR)
	_steps(30)
	_check("no working position: Unreachable, no movement order, a notice", _mining("Miner1").status == MiningOperation.Status.UNREACHABLE
		and _node("Miner1", "RouteFollower").plans == plans and _notices.size() == 1)
	extractor.working_range = working_range


func _test_feedback() -> void:
	_reset()
	var id := _find(AsteroidField.Family.MINERALS, 0)
	_stage("Miner1", id, 0.0)
	_mining("Miner1").assign(id)
	while _mining("Miner1").status != MiningOperation.Status.MINING:
		_steps(1)
	_steps(60)
	_selection.set_selection([_ship("Miner1")])
	await process_frame
	await process_frame # process_frame is emitted before _process runs.
	var panel := _main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Actions/Mining")
	var cargo := _cargo("Miner1")
	# UX round P6: the Cargo section's tiles show the raw resources aboard (was the
	# "Collected" line; Phase 3 before that: "Metal Chunks n").
	var tiles := _tiles(_main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Cargo/Tiles"))
	_check("panel: target, status, cargo and cargo tiles (%s; tiles %s)" % [cargo.describe(), str(tiles)], panel.visible
		and panel.get_node("Target").text == "Target: Asteroid %d" % id and _main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Status/Activity").text == "Status: Mining"
		and _main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Cargo/Summary").text == "Cargo: %d / 1000" % cargo.quantity()
		and tiles == cargo.amounts and cargo.quantity() > 0)
	_check("extraction beam drawn while mining", _main.get_node("MiningView").beam_count == 1)
	_selection.set_selection([_ship("Frigate")])
	await process_frame
	_check("panel: no mining rows for a Frigate", not panel.visible)
	_selection.set_selection([])


# Puts a miner at rest 12 u outside an asteroid (towards the map centre, turned by
# `turn` radians), facing it, on its navigable area.
func _stage(miner: String, id: int, turn: float) -> void:
	var center := Vector2(_field.center(id).x, _field.center(id).z)
	var direction := (-center).normalized().rotated(turn) if center.length() > 1.0 else Vector2.RIGHT
	var radius: float = _node(miner, "RouteFollower").planning_radius()
	var point: Vector2 = _navigation.closest_point(radius, center + direction * (_field.radius(id) + 12.0))
	var toward := center - point
	_node(miner, "Locomotion").place(point, atan2(-toward.x, -toward.y))


# Until extraction has ended (Stage 5: a full or depleted miner then returns to base).
func _run_until_stopped(miners: Array) -> void:
	for i in 60 * 120:
		if miners.all(func(miner: String) -> bool: return not _mining(miner).status in [MiningOperation.Status.TRAVELING, MiningOperation.Status.MINING]):
			return
		_steps(1)


func _reset() -> void:
	var spawn := {"Frigate": Vector2(-12, 0), "Gunship": Vector2(0, 0), "Destroyer": Vector2(14, 0), "Miner1": Vector2(-8, 14), "Miner2": Vector2(8, 14)}
	for ship_name in SHIPS:
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
		_node(ship_name, "Locomotion").place(spawn[ship_name], 0.0)
	for miner in ["Miner1", "Miner2"]:
		var mining := _mining(miner)
		mining.target = -1
		mining.status = MiningOperation.Status.NONE
		mining._route_pending = false
		_cargo(miner).amounts.clear()
		_cargo(miner).capacity = _node(miner, "Cargo").capacity
	_field.generate(SEED)


func _steps(count: int) -> void:
	for i in count:
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_node(ship_name, "Locomotion")._step(DT)
		for miner in ["Miner1", "Miner2"]:
			_mining(miner)._physics_process(DT)
		_survey.advance(DT)


# k-th asteroid of a family by id (from this seed's field).
func _find(family: int, k: int) -> int:
	var found := _field.ids().filter(func(id: int) -> bool: return _field.deposit(id).family == family)
	return found[k]


func _nearest_other(id: int) -> int:
	var center := Vector2(_field.center(id).x, _field.center(id).z)
	var best := -1
	for other: int in _field.ids():
		if other != id and (best < 0 or _field.surface_distance(other, center) < _field.surface_distance(best, center)):
			best = other
	return best


func _frame(center: Vector2, zoom: float) -> void:
	_rig.global_position = Vector3(center.x, 0, center.y)
	_rig.rotation = Vector3.ZERO
	_rig.zoom_distance = zoom
	_rig._apply_zoom()


# [screen point, ground point] for a ground position.
func _ground_click(point: Vector2) -> Array:
	return [_camera.unproject_position(Vector3(point.x, 0, point.y)), point]


func _screen(ship_name: String) -> Vector2:
	return _camera.unproject_position(_ship(ship_name).global_position)


func _click(position: Vector2, shift := false) -> void:
	_button(MOUSE_BUTTON_LEFT, position, true, shift)
	_button(MOUSE_BUTTON_LEFT, position, false, shift)


func _right_click(position: Vector2) -> void:
	_button(MOUSE_BUTTON_RIGHT, position, true, false)
	_button(MOUSE_BUTTON_RIGHT, position, false, false)


func _drag(from: Vector2, to: Vector2) -> void:
	_button(MOUSE_BUTTON_LEFT, from, true, false)
	for k in range(1, 5):
		var motion := InputEventMouseMotion.new()
		motion.position = from.lerp(to, k / 4.0)
		motion.global_position = motion.position
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		root.push_input(motion, true)
	_button(MOUSE_BUTTON_LEFT, to, false, false)


func _button(index: MouseButton, position: Vector2, pressed: bool, shift: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	event.position = position
	event.global_position = position
	event.shift_pressed = shift
	event.button_mask = (MOUSE_BUTTON_MASK_LEFT if index == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if pressed else 0
	root.push_input(event, true)


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _mining(miner: String) -> MiningOperation:
	return _node(miner, "Mining") as MiningOperation


func _cargo(miner: String) -> Inventory:
	return _node(miner, "Cargo").inventory


# Resource -> units shown by the visible resource tiles of a panel's tile container.
func _tiles(container: Node) -> Dictionary:
	var shown := {}
	for tile in container.get_children():
		if tile.visible:
			shown[tile.resource] = int((tile.get_node("Amount") as Label).text)
	return shown


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-90s %s" % [label, "PASS" if ok else "FAIL"])
