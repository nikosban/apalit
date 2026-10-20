extends SceneTree
## Headless UX round P2 checks (T04 / T05) on the playable main scene: commands given
## while the station moves a ship (controlled entry or exit) are checked in two stages.
## At issue only their intent (target exists, the ship can carry the command out; no
## route from the guided position): a refused intent changes nothing and the last
## valid held command stays; a valid one replaces it (latest valid wins). When control
## ends the held command runs, checked from the ship's actual position; refused then:
## its notice, the held command is gone, nothing else changes. A held MOVE shows its
## destination marker at once. Navigation is a StaticNavigation subclass whose plans
## can be refused to or from a chosen point. Ship physics is stepped manually at 60 Hz
## in the game's order (as station_docking_test).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/held_command_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2", "Transporter"]
const PARK := {"Frigate": Vector2(40, 30), "Gunship": Vector2(40, 15), "Destroyer": Vector2(40, -5), "Miner1": Vector2(40, -20),
	"Miner2": Vector2(40, -32), "Transporter": Vector2(60, 50)}
const BLOCK_RADIUS := 3.0
const NAVIGATION_SOURCE := """extends "res://game/navigation/static_navigation.gd"
var blocked_to := Vector2.INF # Plans ending within 3 u of this point are refused.
var blocked_from := Vector2.INF # Plans starting within 3 u of this point are refused.
func plan(radius: float, from: Vector2, to: Vector2) -> PackedVector2Array:
	if to.distance_to(blocked_to) < 3.0 or from.distance_to(blocked_from) < 3.0:
		return PackedVector2Array()
	return super.plan(radius, from, to)
"""

var _main: Node
var _a: Station
var _b: Station
var _nav: Node
var _failures := 0
var _checks := 0
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
	_a = _main.get_node("Stations/Station")
	_b = _main.get_node("Stations/Station2")
	_nav = _main.get_node("StaticNavigation")
	_main.get_node("Survey").set_physics_process(false)
	for station in [_a, _b]:
		station.set_physics_process(false)
	for s in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Transport", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [s, child])
			if node != null:
				node.set_physics_process(false)
	for s in SHIPS:
		while not _nav.is_ready(_n(s, "RouteFollower").planning_radius()):
			await physics_frame
	await _test_invalid_keeps_valid()
	await _test_latest_valid_wins()
	await _test_entry_marker_and_own_station()
	await _test_route_from_release_position()
	await _test_refused_at_release()
	await _test_held_mine()
	_check("no order reached a guided ship (RouteFollower refusals + Locomotion guard: %d)" % _guard_counts(), _guard_counts() == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# Valid MOVE, then a Mine of a missing asteroid and a Dock at a node that is no station:
# both refused at once, the MOVE stays held and shown, and runs when control ends.
func _test_invalid_keeps_valid() -> void:
	var first := _planar(_a) + Vector2(24, -12)
	await _dock_selected("Miner1")
	_dk("Miner1").undock()
	_steps(60)
	_right_click(first)
	var held := _dk("Miner1").held_command()
	var marker_ok := _marker_at("Miner1", first)
	_notices.clear()
	_main._order(_ship("Miner1"), {"kind": _main.CommandKind.MINE, "asteroid": 999})
	_notices.append(_notice_text())
	_main._show_notice("")
	_main._order(_ship("Miner1"), {"kind": _main.CommandKind.DOCK, "station": _main.get_node("Asteroids").get_child(0)})
	_notices.append(_notice_text())
	var kept := _dk("Miner1").held_command() == held and _marker_at("Miner1", first)
	_check("exit: a valid MOVE is held and its marker shown at the clicked point at once (%s)" % marker_ok, held.is_valid() and marker_ok)
	_check("exit: Mine of a missing asteroid and Dock at a non-station are refused at once (notices %s); the held MOVE and its marker stay" % str(_notices),
		kept and _notices.all(func(t: String) -> bool: return t == "Miner1: order not possible - held order kept"))
	_until(func() -> bool: return not _dk("Miner1").under_control(), 60 * 60)
	_step()
	_main._process(0.0)
	_check("released: the held MOVE runs from the exit point (requested %s), marker now at the ordered destination" % str(_n("Miner1", "RouteFollower").requested),
		_n("Miner1", "RouteFollower").requested.distance_to(first) < 0.5 and _lo("Miner1").has_destination and not _dk("Miner1").has_held_command()
		and _marker_at("Miner1", _lo("Miner1").destination))


# Several MOVEs during the exit: the latest is held, shown and executed.
func _test_latest_valid_wins() -> void:
	var points := [_planar(_a) + Vector2(24, -12), _planar(_a) + Vector2(30, 8), _planar(_a) + Vector2(36, -4)]
	await _dock_selected("Miner1")
	_dk("Miner1").undock()
	_steps(60)
	var shown := true
	for point: Vector2 in points:
		_right_click(point)
		_steps(10)
		shown = shown and _marker_at("Miner1", point)
	_until(func() -> bool: return not _dk("Miner1").under_control(), 60 * 60)
	_step()
	_check("three MOVEs during the exit: each shown when given, the latest executed after control (requested %s)" % str(_n("Miner1", "RouteFollower").requested),
		shown and _n("Miner1", "RouteFollower").requested.distance_to(points[2]) < 0.5 and _lo("Miner1").has_destination)


# MOVE during the entry: shown through the entry and the controlled exit that follows;
# a Dock on the station it is entering meanwhile changes nothing (the MOVE stays held).
func _test_entry_marker_and_own_station() -> void:
	var first := _planar(_a) + Vector2(24, -12)
	_reset()
	_main.get_node("Selection").set_selection([_ship("Miner1")])
	_a.slots[1].ship = _ship("Gunship")
	_place("Miner1", _planar(_a) + Vector2(55, 0))
	_frame(_planar(_a) + Vector2(30, 0), 40.0) # UX round P6: targets left of the right-side panel
	await process_frame
	_dk("Miner1").dock(_a)
	_until(func() -> bool: return _dk("Miner1").under_control(), 60 * 60)
	_right_click(first)
	var held := _dk("Miner1").held_command()
	_right_click(_planar(_a)) # Dock at the station it is entering.
	var own_kept := _dk("Miner1").held_command() == held
	var always_shown := true
	var exited := false
	var ticks := 0
	while (_dk("Miner1").under_control() or _dk("Miner1").state == Docking.State.DOCKED) and ticks < 60 * 120:
		ticks += 1
		_step()
		exited = exited or _dk("Miner1").state == Docking.State.UNDOCKING
		if _dk("Miner1").has_held_command():
			always_shown = always_shown and _marker_at("Miner1", first)
	_step()
	_check("entry: Dock on the station being entered changes nothing (the held MOVE stays)", own_kept)
	_check("entry: the MOVE's marker shown through the entry and the controlled exit (%s); then the MOVE runs" % always_shown,
		always_shown and exited and _n("Miner1", "RouteFollower").requested.distance_to(first) < 0.5 and _lo("Miner1").has_destination)


# A MOVE with no route from the guided position (plans from there refused) is accepted
# at issue and runs from the exit point.
func _test_route_from_release_position() -> void:
	var target := _planar(_a) + Vector2(30, 8)
	await _dock_selected("Miner1")
	_dk("Miner1").undock()
	_steps(5)
	var issued_at := _lo("Miner1").planar_position
	_nav.blocked_from = issued_at
	var from_here: int = _nav.plan(_n("Miner1", "RouteFollower").planning_radius(), issued_at, target).size()
	_right_click(target)
	var held := _dk("Miner1").has_held_command()
	_until(func() -> bool: return not _dk("Miner1").under_control(), 60 * 60)
	var released_at := _lo("Miner1").planar_position
	_step()
	_nav.blocked_from = Vector2.INF
	_check("no route from the guided position (%d points): accepted at issue, executed from the exit point %.1f u away" % [from_here, released_at.distance_to(issued_at)],
		from_here == 0 and held and _n("Miner1", "RouteFollower").requested.distance_to(target) < 0.5 and _lo("Miner1").has_destination)


# A held MOVE that has no route when control ends: its notice, the held command and the
# marker are gone, no order, mining configuration and docking state untouched.
func _test_refused_at_release() -> void:
	var target := _planar(_a) + Vector2(30, 8)
	await _dock_selected("Miner1")
	_mining("Miner1").target = 5
	_dk("Miner1").undock()
	_steps(60)
	_right_click(target)
	var shown := _marker_at("Miner1", target)
	_nav.blocked_to = target
	_notices.clear()
	_until(func() -> bool: return not _dk("Miner1").under_control(), 60 * 60)
	_step()
	_main._process(0.0)
	_nav.blocked_to = Vector2.INF
	var marker: Node3D = _main._markers[_ship("Miner1")][0]
	_check("no route when control ends: refused ('%s'), held command and marker gone, no order, nothing else changed" % _notice_text(),
		shown and _notice_text() == "No route found" and not _dk("Miner1").has_held_command() and not marker.visible
		and not _lo("Miner1").has_destination and _dk("Miner1").state == Docking.State.NONE and _mining("Miner1").target == 5
		and _mining("Miner1").status == MiningOperation.Status.NONE)
	_mining("Miner1").target = -1


# Mine given during the exit: held (no ground marker), assigned when control ends.
func _test_held_mine() -> void:
	await _dock_selected("Miner1")
	_dk("Miner1").undock()
	_steps(60)
	var asteroid := _nearest_asteroid(_planar(_a) + Vector2(40, 0))
	_main._order(_ship("Miner1"), {"kind": _main.CommandKind.MINE, "asteroid": asteroid})
	var held := _dk("Miner1").has_held_command() and not (_main._markers[_ship("Miner1")][0] as Node3D).visible
	_until(func() -> bool: return not _dk("Miner1").under_control(), 60 * 60)
	_step()
	_check("Mine during the exit: held without a ground marker, assigned after control (asteroid %d, %s)" % [asteroid, _mining("Miner1").status_name()],
		held and _mining("Miner1").target == asteroid and _mining("Miner1").is_active())


# ------------------------------------------------------------------ helpers (as station_docking_test)
func _notice_text() -> String:
	return (_main.get_node("NoticeUI/Notice") as Label).text


func _marker_at(s: String, point: Vector2) -> bool:
	_main._process(0.0)
	var marker: Node3D = _main._markers[_ship(s)][0]
	return marker.visible and Vector2(marker.global_position.x, marker.global_position.z).distance_to(point) < 0.01


func _dock_selected(s: String) -> void:
	_reset()
	_main.get_node("Selection").set_selection([_ship(s)])
	_a.slots[1].ship = _ship("Gunship")
	_place(s, _planar(_a) + Vector2(55, 0))
	_dk(s).dock(_a)
	_until(func() -> bool: return _dk(s).state == Docking.State.DOCKED, 60 * 150)
	_a.slots[1].ship = null
	_frame(_planar(_a) + Vector2(30, 0), 40.0) # UX round P6: targets left of the right-side panel
	await process_frame


func _step() -> void:
	for s in SHIPS:
		_n(s, "RouteFollower")._physics_process(DT)
		_n(s, "Avoidance")._physics_process(DT)
	for s in SHIPS:
		_lo(s)._step(DT)
	for s in SHIPS:
		for child in ["Mining", "Transport"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [s, child])
			if node != null:
				node._physics_process(DT)
		_dk(s)._physics_process(DT)
		_n(s, "Fuel")._physics_process(DT)
	for station in [_a, _b]:
		station._physics_process(DT)


func _steps(count: int) -> void:
	for i in count:
		_step()


func _until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_step()
	return -1


func _reset() -> void:
	for s in SHIPS:
		var dk := _dk(s)
		dk.phase = Docking.Phase.NONE
		dk.hold_command(Callable())
		_lo(s).place(PARK[s], 0.0)
		dk.cancel()
		dk.state = Docking.State.NONE
		dk.transfer = Docking.Transfer.NONE
		_n(s, "RouteFollower").clear()
		_n(s, "Avoidance").reset()
		_n(s, "Fuel")._set_fuel(_n(s, "Fuel").capacity)
	for m in ["Miner1", "Miner2"]:
		var mining := _mining(m)
		mining.cancel()
		mining.target = -1
		mining.status = MiningOperation.Status.NONE
		mining._route_pending = false
	var transport := _main.get_node("Ships/Transporter/Transport") as TransportOperation
	transport.cancel()
	transport.status = TransportOperation.Status.NONE
	for st in [_a, _b]:
		for slot in st.slots:
			slot.ship = null
			slot.leaving = false
		for h in st.holds:
			h.ship = null
		st.queue.clear()
		st._exiting.clear()
	_notices.clear()


func _frame(center: Vector2, zoom: float) -> void:
	var rig := _main.get_node("CameraRig")
	rig.global_position = Vector3(center.x, 0, center.y)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = zoom
	rig._apply_zoom()


func _right_click(point: Vector2) -> void:
	var camera: Camera3D = _main.get_node("CameraRig/Camera3D")
	var screen := camera.unproject_position(Vector3(point.x, 0, point.y))
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = pressed
		event.position = screen
		event.global_position = screen
		event.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		root.push_input(event, true)


func _nearest_asteroid(from: Vector2) -> int:
	var field := _main.get_node("Asteroids")
	var best := -1
	for id: int in field.ids():
		var center: Vector3 = field.center(id)
		var best_center: Vector3 = field.center(best) if best >= 0 else Vector3.INF
		if best < 0 or Vector2(center.x, center.z).distance_to(from) < Vector2(best_center.x, best_center.z).distance_to(from):
			best = id
	return best


func _guard_counts() -> int:
	var total := 0
	for s in SHIPS:
		total += _n(s, "RouteFollower").guided_refusals + _lo(s).guided_order_errors
	return total


func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)


func _place(s: String, point: Vector2) -> void:
	_lo(s).place(_nav.closest_point(_n(s, "RouteFollower").planning_radius(), point), 0.0)


func _ship(s: String) -> Node3D:
	return _main.get_node("Ships/" + s)


func _n(s: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [s, child])


func _lo(s: String) -> ShipLocomotion:
	return _n(s, "Locomotion") as ShipLocomotion


func _dk(s: String) -> Docking:
	return _n(s, "Docking") as Docking


func _mining(s: String) -> MiningOperation:
	return _n(s, "Mining") as MiningOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
