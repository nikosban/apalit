extends SceneTree
## Headless Phase 2.5 checks on the playable main scene: a refused command changes
## nothing. Commands are real right-clicks through the scene input (movement_lab.gd
## `_command`), except Resume (the ship panel's call) and the queued order. Refusals
## are forced as the other suites force them: mining with Extractor.working_range
## 1.0 (no navigable working position), docking with every berth's handover point moved into the station body (docking
## positions inside the arms), and MOVE with a StaticNavigation that has no route to
## a small zone around NO_ROUTE (a real map always resolves to the closest reachable
## point). Ship physics is stepped manually at 60 Hz in the game's order (per ship
## RouteFollower then Avoidance, then Locomotion, then Mining and Docking, then the
## stations).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/order_consistency_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2", "Transporter"]
const PARK := {"Frigate": Vector2(40, 30), "Gunship": Vector2(40, 15), "Destroyer": Vector2(40, -5), "Miner1": Vector2(40, -20),
	"Miner2": Vector2(40, -32), "Transporter": Vector2(-80, 30)}
const NO_ROUTE := Vector2(20, -20) # Centre of the no-route zone (open space near the spawn).
const NO_ROUTE_RADIUS := 3.0
const NAVIGATION_SOURCE := """extends "res://game/navigation/static_navigation.gd"
func plan(radius: float, from: Vector2, to: Vector2) -> PackedVector2Array:
	if to.distance_to(Vector2(20, -20)) < 3.0:
		return PackedVector2Array()
	return super.plan(radius, from, to)
"""
const SEED := 20261014

var _failures := 0
var _checks := 0
var _main: Node
var _station: Station
var _station2: Station
var _field: AsteroidField
var _navigation: Node
var _camera: Camera3D
var _notices: Array[String] = []


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	var navigation := _main.get_node("StaticNavigation")
	var obstacles: NodePath = navigation.obstacles_path
	var script := GDScript.new()
	script.source_code = NAVIGATION_SOURCE
	script.reload()
	navigation.set_script(script)
	navigation.obstacles_path = obstacles
	root.add_child(_main)
	_station = _main.get_node("Stations/Station")
	_station2 = _main.get_node("Stations/Station2")
	_field = _main.get_node("Asteroids")
	_navigation = _main.get_node("StaticNavigation")
	_camera = _main.get_node("CameraRig/Camera3D")
	_main.get_node("Survey").set_physics_process(false)
	for station in [_station, _station2]:
		station.set_physics_process(false)
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Docking", "Fuel", "Transport"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.set_physics_process(false)
		_follower(ship_name).notice.connect(func(text: String) -> void: _notices.append(text))
		_docking(ship_name).notice.connect(func(text: String) -> void: _notices.append(text))
		if _mining(ship_name) != null:
			_mining(ship_name).notice.connect(func(text: String) -> void: _notices.append(text))

	# A queued order (map not ready yet) that then finds no route.
	var queued := _follower("Frigate").order(NO_ROUTE)
	var waiting := _follower("Frigate").status == RouteFollower.RouteStatus.WAITING
	for ship_name in SHIPS:
		while not _navigation.is_ready(_follower(ship_name).planning_radius()):
			await physics_frame
	_notices.clear()
	_steps(1)
	_check("queued order without a route: queued first, then refused; status and request restored, no movement, a notice",
		queued and waiting and _follower("Frigate").status == RouteFollower.RouteStatus.NONE and _follower("Frigate").requested == Vector2.ZERO
		and not _locomotion("Frigate").has_destination and _notices == ["No route found"])

	_test_move_direct()
	_test_move_routed()
	_test_move_keeps_assignments()
	_test_mining_refused_traveling()
	_test_mining_refused_docked()
	_test_dock_refused_mining()
	_test_dock_refused_docked()
	_test_same_station()
	_test_resume_refused()
	_test_accepted()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# MOVE without a route while on a direct move: refused, the move goes on with
# avoidance and arrives.
func _test_move_direct() -> void:
	_reset()
	_place("Gunship", Vector2(0, 0))
	_follower("Gunship").order(Vector2(0, 30))
	_steps(60)
	var before := _route_state("Gunship")
	_select(["Gunship"])
	_notices.clear()
	_right_click_at(NO_ROUTE)
	_check("MOVE without a route (direct move running): refused with a notice, RouteFollower and Locomotion unchanged",
		_notices == ["No route found"] and _route_state("Gunship") == before and _lab_notice() == "No route found")
	_steps(1)
	_check("... the running move is still followed (direct, avoidance active)", _follower("Gunship").status == RouteFollower.RouteStatus.DIRECT
		and _node("Gunship", "Avoidance").target.distance_to(_follower("Gunship").aim_point) < 0.001)
	var arrived := _run_until(func() -> bool: return not _locomotion("Gunship").has_destination, 60 * 30)
	_check("... and arrives at its destination", arrived >= 0 and _position("Gunship").distance_to(Vector2(0, 30)) < 0.1)


# The same while following a planned route (before: steered at a frozen aim point forever).
func _test_move_routed() -> void:
	_reset()
	_place("Gunship", Vector2(0, 30))
	_follower("Gunship").order(Vector2(120, 120))
	var routed := _follower("Gunship").status == RouteFollower.RouteStatus.ROUTE and _follower("Gunship").route.size() > 2
	_steps(120)
	var before := _route_state("Gunship")
	_select(["Gunship"])
	_notices.clear()
	_right_click_at(NO_ROUTE)
	_check("MOVE without a route (routed order running): refused, route, status and destination unchanged",
		routed and _notices == ["No route found"] and _route_state("Gunship") == before)
	var aim := _follower("Gunship").aim_point
	_steps(60)
	_check("... route following goes on (aim point advancing)", _follower("Gunship").aim_point.distance_to(aim) > 1.0)
	var arrived := _run_until(func() -> bool: return not _locomotion("Gunship").has_destination, 60 * 120)
	_check("... and arrives at its destination", arrived >= 0 and _position("Gunship").distance_to(Vector2(120, 120)) < 0.1)


# A refused MOVE does not cancel the ship's assignments.
func _test_move_keeps_assignments() -> void:
	_reset()
	var asteroid := _nearest_asteroid(Vector2(-8, 14))
	_place("Miner1", Vector2(-8, 14))
	_mining("Miner1").assign(asteroid)
	_run_until(func() -> bool: return _mining("Miner1").status == MiningOperation.Status.MINING, 60 * 60)
	var plans: int = _follower("Miner1").plans
	_select(["Miner1"])
	_right_click_at(NO_ROUTE)
	_steps(30)
	_check("MOVE without a route for a mining Miner: still Mining its target, no new order",
		_mining("Miner1").status == MiningOperation.Status.MINING and _mining("Miner1").target == asteroid and _follower("Miner1").plans == plans + 1
		and not _locomotion("Miner1").has_destination)


# Mining refused while traveling to another asteroid (before: target replaced,
# Unreachable, the ship still flying to the old working point).
func _test_mining_refused_traveling() -> void:
	_reset()
	var first := _nearest_asteroid(Vector2(-8, 14))
	var second := _nearest_asteroid(_planar(_field.center(first)), first)
	_place("Miner1", Vector2(-8, 14))
	_mining("Miner1").assign(first)
	_steps(30)
	var before := _route_state("Miner1")
	var work: Vector2 = _mining("Miner1").work_point
	_node("Miner1", "Extractor").working_range = 1.0
	_select(["Miner1"])
	_notices.clear()
	_right_click_asteroid(second)
	_steps(1)
	var unchanged: bool = _mining("Miner1").target == first and _mining("Miner1").status == MiningOperation.Status.TRAVELING \
		and _mining("Miner1").work_point == work and _route_state("Miner1") == before
	_node("Miner1", "Extractor").working_range = 4.5
	_check("mining refused while traveling: notice; target, status, working point and order unchanged",
		unchanged and _notices.is_empty() and _lab_notice() == "Miner1: no reachable working position at the asteroid")
	var mined := _run_until(func() -> bool: return _mining("Miner1").status == MiningOperation.Status.MINING, 60 * 60)
	_check("... and it mines its original target", mined >= 0 and _mining("Miner1").target == first)


# Mining refused while docked (before: docking released with the ship left at the
# dock and its slot held).
func _test_mining_refused_docked() -> void:
	_reset()
	_place("Miner2", Vector2(-10, -40))
	_docking("Miner2").dock(_station)
	var docked := _run_until(func() -> bool: return _docking("Miner2").state == Docking.State.DOCKED, 60 * 60)
	var slot: int = _station.slot_of(_ship("Miner2"))
	_node("Miner2", "Extractor").working_range = 1.0
	_select(["Miner2"])
	_right_click_asteroid(_nearest_asteroid(_planar(_station.global_position)))
	_steps(5)
	_node("Miner2", "Extractor").working_range = 4.5
	_check("mining refused while docked: still Docked in its slot (not leaving), no assignment, a notice",
		docked >= 0 and _docking("Miner2").state == Docking.State.DOCKED and _station.slot_of(_ship("Miner2")) == slot and not _station.slots[slot].leaving
		and _mining("Miner2").status == MiningOperation.Status.NONE and _lab_notice() == "Miner2: no reachable working position at the asteroid")


# Dock refused while mining (before: mining paused, Unable to Dock).
func _test_dock_refused_mining() -> void:
	_reset()
	var asteroid := _nearest_asteroid(Vector2(-8, 14))
	_place("Miner1", Vector2(-8, 14))
	_mining("Miner1").assign(asteroid)
	_run_until(func() -> bool: return _mining("Miner1").status == MiningOperation.Status.MINING, 60 * 60)
	var plans: int = _follower("Miner1").plans
	_block_berths(_station, true)
	_select(["Miner1"])
	_right_click_station(_station)
	_steps(5)
	_block_berths(_station, false)
	_check("dock refused while mining: still Mining, docking untouched, nothing reserved, no order, a notice",
		_mining("Miner1").status == MiningOperation.Status.MINING and _docking("Miner1").state == Docking.State.NONE and _docking("Miner1").station == null
		and _station.slot_of(_ship("Miner1")) < 0 and _station.queue.is_empty() and _follower("Miner1").plans == plans
		and _lab_notice() == "Miner1: unable to dock - no reachable docking position")


# Dock at Station2 refused while docked at Station (before: Station slot held by a
# ship no longer docked).
func _test_dock_refused_docked() -> void:
	_reset()
	_place("Miner2", Vector2(-10, -40))
	_docking("Miner2").dock(_station)
	_run_until(func() -> bool: return _docking("Miner2").state == Docking.State.DOCKED, 60 * 60)
	var slot: int = _station.slot_of(_ship("Miner2"))
	_block_berths(_station2, true)
	_select(["Miner2"])
	_right_click_station(_station2)
	_steps(5)
	_block_berths(_station2, false)
	_check("dock elsewhere refused while docked: still Docked at the first station in its slot, a notice",
		_docking("Miner2").state == Docking.State.DOCKED and _docking("Miner2").station == _station and _station.slot_of(_ship("Miner2")) == slot
		and not _station.slots[slot].leaving and _station2.queue.is_empty() and _lab_notice() == "Miner2: unable to dock - no reachable docking position")


# Dock on the station the ship is already heading for: nothing changes (before: the
# mining cycle's return was paused).
func _test_same_station() -> void:
	_reset()
	var asteroid := _nearest_asteroid(Vector2(-8, 14))
	_place("Miner1", Vector2(-8, 14))
	var cargo = _node("Miner1", "Cargo").inventory
	cargo.add(&"iron", cargo.capacity)
	_mining("Miner1").set_base(_station)
	_mining("Miner1").assign(asteroid) # Full: returns to the base first.
	_steps(30)
	var returning: bool = _mining("Miner1").status == MiningOperation.Status.RETURNING and _docking("Miner1").is_docking_at(_station)
	var state: int = _docking("Miner1").state
	var plans: int = _follower("Miner1").plans
	_select(["Miner1"])
	_right_click_station(_station)
	_steps(1)
	_check("Dock on the station it is already returning to: mining return and docking unchanged, no new order",
		returning and _mining("Miner1").status == MiningOperation.Status.RETURNING and _docking("Miner1").state == state and _follower("Miner1").plans == plans)
	cargo.amounts.clear()


# Resume refused (no working position): still paused, no order.
func _test_resume_refused() -> void:
	_reset()
	var asteroid := _nearest_asteroid(Vector2(-8, 14))
	_place("Miner1", Vector2(-8, 14))
	_mining("Miner1").assign(asteroid)
	_steps(30)
	_mining("Miner1").cancel()
	var plans: int = _follower("Miner1").plans
	_node("Miner1", "Extractor").working_range = 1.0
	_notices.clear()
	var resumed: bool = _mining("Miner1").resume()
	_steps(5)
	_node("Miner1", "Extractor").working_range = 4.5
	_check("Resume refused: still Assignment Paused with its target, no order, a notice", not resumed
		and _mining("Miner1").status == MiningOperation.Status.CANCELED and _mining("Miner1").target == asteroid and _follower("Miner1").plans == plans
		and _notices == ["Miner1: no reachable working position at the asteroid"])
	_check("... Resume once possible restarts it", _mining("Miner1").resume() and _mining("Miner1").status == MiningOperation.Status.TRAVELING)


# Accepted commands are unchanged: Dock pauses mining, Mine releases docking, MOVE
# cancels both, a MOVE inside the no-route zone's surroundings is taken.
func _test_accepted() -> void:
	_reset()
	var asteroid := _nearest_asteroid(Vector2(-8, 14))
	_place("Miner1", Vector2(-8, 14))
	_mining("Miner1").assign(asteroid)
	_steps(30)
	_select(["Miner1"])
	_right_click_station(_station)
	_check("accepted Dock: docking at the station, mining paused with its target",
		_docking("Miner1").is_docking_at(_station) and _mining("Miner1").status == MiningOperation.Status.CANCELED and _mining("Miner1").target == asteroid)
	_steps(30)
	_right_click_asteroid(asteroid)
	_check("accepted Mine: traveling, docking released", _mining("Miner1").status == MiningOperation.Status.TRAVELING
		and _docking("Miner1").state == Docking.State.NONE and _station.slot_of(_ship("Miner1")) < 0 and _station.queue.is_empty())
	var point := NO_ROUTE + Vector2(NO_ROUTE_RADIUS + 3.0, 0)
	_right_click_at(point)
	_check("accepted MOVE: taken, mining paused", _locomotion("Miner1").has_destination
		and _follower("Miner1").requested.distance_to(point) < 0.5 and _mining("Miner1").status == MiningOperation.Status.CANCELED)


# RouteFollower and Locomotion state that a refused order must leave alone.
func _route_state(ship_name: String) -> Array:
	var follower := _follower(ship_name)
	var locomotion := _locomotion(ship_name)
	return [follower.status, follower.route, follower.requested, follower.segment, locomotion.has_destination, locomotion.destination]


func _nearest_asteroid(from: Vector2, except := -1) -> int:
	var best := -1
	var best_distance := INF
	for asteroid: Node3D in _field.get_children():
		var id: int = asteroid.get_meta("asteroid_id")
		var distance := _planar(asteroid.global_position).distance_to(from)
		if id != except and distance < best_distance:
			best = id
			best_distance = distance
	return best


func _select(names: Array) -> void:
	_main.get_node("Selection").set_selection(names.map(func(ship_name: String) -> Node3D: return _ship(ship_name)))


func _right_click_at(point: Vector2) -> void:
	_frame(point)
	_right_click(_camera.unproject_position(Vector3(point.x, 0, point.y)))


func _right_click_asteroid(asteroid: int) -> void:
	var center := _field.center(asteroid)
	_frame(_planar(center))
	_right_click(_camera.unproject_position(center))


func _right_click_station(station: Station) -> void:
	_frame(_planar(station.global_position))
	_right_click(_camera.unproject_position(station.global_position))


func _frame(center: Vector2) -> void:
	var rig := _main.get_node("CameraRig")
	rig.global_position = Vector3(center.x, 0, center.y)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = 30.0
	rig._apply_zoom()


func _right_click(position: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = pressed
		event.position = position
		event.global_position = position
		event.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		root.push_input(event, true)


func _lab_notice() -> String:
	return (_main.get_node("NoticeUI/Notice") as Label).text


func _reset() -> void:
	_field.generate(SEED)
	(_main.get_node("NoticeUI/Notice") as Label).text = ""
	for ship_name in SHIPS:
		_docking(ship_name).phase = Docking.Phase.NONE # Stage 2b: cancel() is refused during station control.
		_docking(ship_name).hold_command(Callable())
		_docking(ship_name).cancel()
		var follower := _follower(ship_name)
		follower.status = RouteFollower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
		_place(ship_name, PARK[ship_name])
		var mining := _mining(ship_name)
		if mining != null:
			mining.target = -1
			mining.status = MiningOperation.Status.NONE
			mining._route_pending = false
			mining.set_base(null)
			_node(ship_name, "Cargo").inventory.amounts.clear()
	for station: Station in [_station, _station2]:
		for slot in station.slots:
			slot.ship = null
			slot.leaving = false
		for hold in station.holds:
			hold.ship = null
		station.queue.clear()
		station._exiting.clear()


func _run_until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_steps(1)
	return -1


func _steps(count: int) -> void:
	for i in count:
		for ship_name in SHIPS:
			_follower(ship_name)._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_locomotion(ship_name)._step(DT)
		for ship_name in SHIPS:
			if _mining(ship_name) != null:
				_mining(ship_name)._physics_process(DT)
			_docking(ship_name)._physics_process(DT)
		_station._physics_process(DT)
		_station2._physics_process(DT)


func _place(ship_name: String, point: Vector2) -> void:
	_locomotion(ship_name).place(point, 0.0)


func _position(ship_name: String) -> Vector2:
	return _locomotion(ship_name).planar_position


static func _planar(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _follower(ship_name: String) -> RouteFollower:
	return _node(ship_name, "RouteFollower") as RouteFollower


func _locomotion(ship_name: String) -> Node:
	return _node(ship_name, "Locomotion")


func _docking(ship_name: String) -> Docking:
	return _node(ship_name, "Docking") as Docking


func _mining(ship_name: String) -> MiningOperation:
	return _main.get_node_or_null("Ships/%s/Mining" % ship_name) as MiningOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-120s %s" % [label, "PASS" if ok else "FAIL"])


# Stage 2b: blocks (or restores) every berth's handover point by moving it into the station body.
var _handovers := {}


func _block_berths(station: Station, block: bool) -> void:
	for berth in station.berths:
		var handover := berth.get_node("Handover") as Node3D
		if block:
			_handovers[berth] = handover.position
			handover.global_position = station.global_position
		else:
			handover.position = _handovers[berth]
