extends SceneTree
## Headless UX round P4 (T09 / T10) checks on the playable main scene: persistent
## transport docking, acceptance cases A-J of the epic plus the scope boundary. An
## automated transport's blocked transfer waits in the berth (Docked, reservation kept,
## one notice per wait): loading until every requirement is met (switching to another
## missing resource that comes into stock), unloading until the hold is empty; then it
## continues the route. A valid manual departure pauses it (cargo and configuration
## kept) until Resume; an invalid command changes nothing; other ships queue, nobody is
## evicted. Miners and manual Load / Unload keep the leave-and-wait blocked transfer.
## Two extra Transporters (transporter_unit.tscn) are added at run time and registered
## as the Shipyard does. Navigation is a StaticNavigation subclass that can refuse
## routes to one point (the invalid command). Everything is stepped at 60 Hz in the
## game's order; every tick checks that every mineral (raw + ingot) and ice, summed over
## all ships' cargo and all stations, equals the start plus the test's own additions.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/transport_persistent_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const TRANSPORTER := preload("res://game/ships/transporter_unit.tscn")
const Inventory := preload("res://game/cargo/inventory.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const DT := 1.0 / 60.0
const PARK := {"Miner1": Vector2(40, -20),
	"Miner2": Vector2(40, -32), "Transporter": Vector2(-80, 30), "TransporterB": Vector2(-10, -45), "TransporterC": Vector2(10, -60)}
const NO_ROUTE := Vector2(20, -20)
const NAVIGATION_SOURCE := """extends "res://game/navigation/static_navigation.gd"
var blocked_to := Vector2.INF # Plans ending within 3 u of this point are refused.
func plan(radius: float, from: Vector2, to: Vector2) -> PackedVector2Array:
	if to.distance_to(blocked_to) < 3.0:
		return PackedVector2Array()
	return super.plan(radius, from, to)
"""

var _main: Node
var _a: Station # Station (loading)
var _b: Station # Station2 (unloading, refinery)
var _ships: Array[String] = []
var _failures := 0
var _checks := 0
var _time := 0.0
var _expected := {}
var _conserved := true
var _notices: Array[String] = []
var _states := {} # ship -> visited Docking states
var _exits := {} # ship -> number of controlled exits started
var _docks := {} # ship -> number of times Docked was reached


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
	for extra in ["TransporterB", "TransporterC"]:
		var ship: Node3D = TRANSPORTER.instantiate()
		ship.name = extra
		ship.position = Vector3(PARK[extra].x, 1.5, PARK[extra].y)
		_main.get_node("Ships").add_child(ship)
		_main.get_node("Selection").register_ship(ship)
		_main.register_ship(ship)
	for ship in _main.get_node("Ships").get_children():
		_ships.append(String(ship.name))
	_main.get_node("Survey").set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
		for child in station.get_children():
			child.set_physics_process(false)
	for s in _ships:
		for child in _ship(s).get_children():
			child.set_physics_process(false)
		for child in ["Docking", "Transport", "Mining"]:
			var node := _ship(s).get_node_or_null(child)
			if node != null:
				node.notice.connect(func(text: String) -> void: _notices.append(text))
	for s in _ships:
		while not navigation.is_ready(_n(s, "RouteFollower").planning_radius()):
			await physics_frame
	_test_a_partial_loading()
	_test_b_unloading()
	_test_c_staggered()
	_test_d_f_interrupt_and_resume()
	_test_e_interrupt_unloading()
	_test_g_congestion()
	_test_h_invalid_order()
	_test_i_cycles()
	await _test_j_deferred_move()
	_test_scope_boundary()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# A: 200 Iron + 100 Nickel required; 200 Iron + 30 Nickel in stock; 70 Nickel arrives 20 s after docking.
func _test_a_partial_loading() -> void:
	_reset()
	_add(_a, &"iron", 200)
	_add(_a, &"nickel", 30)
	_configure("Transporter", {&"iron": 200, &"nickel": 100})
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.DOCKED, 240.0)
	var docked_at := _time
	_run_until(func() -> bool: return _time - docked_at >= 20.0, 30.0)
	var waiting := _dk("Transporter").waiting and _dk("Transporter").transfer == Docking.Transfer.LOAD and _a.slot_of(_ship("Transporter")) >= 0
	var activity := _tr("Transporter").activity()
	var cargo := _cargo_text("Transporter")
	var wait_notices := _notices.filter(func(t: String) -> bool: return t == "Transporter: no Nickel in stock - waiting in the berth").size()
	_add(_a, &"nickel", 70)
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.UNDOCKING, 60.0)
	var left_with := _cargo_text("Transporter")
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.APPROACHING and not _dk("Transporter").under_control(), 120.0)
	_check("A: waits docked for the quota (%s, '%s', berth reserved, one notice: %d), loads the 70 Nickel on arrival, departs once with %s for Station2, never leaves to a hold"
		% [cargo, activity, wait_notices, left_with], waiting and activity == "Waiting for Resources" and cargo == "Iron 200, Nickel 30" and wait_notices == 1
		and left_with == "Iron 200, Nickel 100" and _exits["Transporter"] == 1 and _docks["Transporter"] == 1 and not _visited("Transporter", Docking.State.BLOCKED)
		and _dk("Transporter").station == _b and _conserved)


# B: 500 Iron aboard; Station2 has room for 200, 300 more frees 20 s after docking.
func _test_b_unloading() -> void:
	_reset()
	_fill(_b, 200)
	_add(_cargo("Transporter"), &"iron", 500)
	_configure("Transporter", {&"iron": 500})
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.UNDOCKING, 240.0) # Iron aboard: leaves Station at once.
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.DOCKED and _dk("Transporter").station == _b, 240.0)
	var docked_at := _time
	_run_until(func() -> bool: return _time - docked_at >= 20.0, 30.0)
	var waiting := _dk("Transporter").waiting and _b.slot_of(_ship("Transporter")) >= 0
	var activity := _tr("Transporter").activity()
	var aboard := _cargo("Transporter").quantity()
	var stored := _b.storage.quantity_of(&"iron")
	_take(_b, &"ice", 300)
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.UNDOCKING, 60.0)
	_check("B: unloads the 200 that fit, waits docked with %d aboard ('%s', berth reserved), unloads the rest as room appears, leaves only when empty (Station2 Iron %d -> %d, aboard %d)"
		% [aboard, activity, stored, _b.storage.quantity_of(&"iron"), _cargo("Transporter").quantity()], waiting and activity == "Waiting for Storage" and aboard == 300
		and stored == 200 and _b.storage.quantity_of(&"iron") == 500 and _cargo("Transporter").quantity() == 0 and not _visited("Transporter", Docking.State.BLOCKED) and _conserved)


# C: Iron, Nickel, Cobalt 100 each; none in stock at docking; Nickel at +10 s, Cobalt
# at +20 s, Iron at +30 s (the load waiting for Iron gives way to what arrives).
func _test_c_staggered() -> void:
	_reset()
	_configure("Transporter", {&"iron": 100, &"nickel": 100, &"cobalt": 100})
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.DOCKED, 240.0)
	var docked_at := _time
	var departed_early := false
	var loaded_before_iron := ""
	for step: Array in [[10.0, &"nickel"], [20.0, &"cobalt"], [30.0, &"iron"]]:
		_run_until(func() -> bool: return _time - docked_at >= step[0], 40.0)
		departed_early = departed_early or _dk("Transporter").state != Docking.State.DOCKED
		if step[1] == &"iron":
			loaded_before_iron = _cargo_text("Transporter")
		_add(_a, step[1], 100)
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.UNDOCKING, 60.0)
	_check("C: no departure before all three are complete; Nickel and Cobalt loaded while still waiting for Iron (%s); one departure %.1f s after docking with %s"
		% [loaded_before_iron, _time - docked_at, _cargo_text("Transporter")], not departed_early and loaded_before_iron == "Nickel 100, Cobalt 100"
		and _cargo_text("Transporter") == "Iron 100, Nickel 100, Cobalt 100" and _exits["Transporter"] == 1 and _conserved)


# D: a manual Undock (panel) while the loading quota is incomplete pauses the assignment.
# F: Resume afterwards: from where it is, nothing transferred twice.
func _test_d_f_interrupt_and_resume() -> void:
	_reset()
	_add(_a, &"iron", 250) # 50 more than required: a second Iron load would show.
	_add(_a, &"nickel", 30)
	_configure("Transporter", {&"iron": 200, &"nickel": 100})
	_run_until(func() -> bool: return _dk("Transporter").waiting, 240.0)
	_main.get_node("Selection").set_selection([_ship("Transporter")])
	(_main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Actions/Docking/Undock") as Button).pressed.emit()
	var paused := _tr("Transporter").status == TransportOperation.Status.PAUSED and _dk("Transporter").state == Docking.State.UNDOCKING
	_run_until(func() -> bool: return not _dk("Transporter").under_control(), 60.0)
	_add(_a, &"nickel", 70) # Stock arrives after the interruption: nothing may take it.
	var cargo := _cargo_text("Transporter")
	_run_until(func() -> bool: return false, 30.0)
	_check("D: Undock while loading is incomplete: Paused, controlled exit, then no loading, docking or route for 30 s; cargo %s and configuration kept" % cargo,
		paused and _tr("Transporter").status == TransportOperation.Status.PAUSED and _dk("Transporter").state == Docking.State.NONE
		and _cargo_text("Transporter") == "Iron 200, Nickel 30" and _a.storage.quantity_of(&"nickel") == 70 and _tr("Transporter").required[&"nickel"] == 100
		and _tr("Transporter").load_station == _a and _conserved)
	var iron_stock := _a.storage.quantity_of(&"iron")
	(_main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Actions/Transport/Start") as Button).pressed.emit()
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.UNDOCKING, 240.0)
	_check("F: Resume: back to the loading station, loads only the 70 Nickel missing (station Iron %d -> %d), departs with %s; nothing transferred twice"
		% [iron_stock, _a.storage.quantity_of(&"iron"), _cargo_text("Transporter")], _cargo_text("Transporter") == "Iron 200, Nickel 100"
		and _a.storage.quantity_of(&"iron") == iron_stock and _a.storage.quantity_of(&"nickel") == 0 and _tr("Transporter").status == TransportOperation.Status.LOADING
		and _conserved)
	_main.get_node("Selection").set_selection([])


# E: a manual MOVE while unloading waits for room: Paused, exit, the delivered part stays.
func _test_e_interrupt_unloading() -> void:
	_reset()
	_fill(_b, 200)
	_add(_cargo("Transporter"), &"iron", 500)
	_configure("Transporter", {&"iron": 500})
	_run_until(func() -> bool: return _dk("Transporter").waiting and _dk("Transporter").station == _b, 480.0)
	var point := Vector2(_b.global_position.x, _b.global_position.z) + Vector2(0, 40)
	_main._order(_ship("Transporter"), {"kind": _main.CommandKind.MOVE, "point": point})
	var paused := _tr("Transporter").status == TransportOperation.Status.PAUSED and _dk("Transporter").state == Docking.State.UNDOCKING
	_run_until(func() -> bool: return not _dk("Transporter").under_control(), 60.0)
	_take(_b, &"ice", 300) # Room appears after the interruption: nothing may use it.
	_run_until(func() -> bool: return false, 30.0)
	_check("E: MOVE while unloading waits: Paused, controlled exit, the MOVE runs; 200 Iron stay at Station2, 300 aboard, no unloading or docking afterwards",
		paused and _tr("Transporter").status == TransportOperation.Status.PAUSED and _b.storage.quantity_of(&"iron") == 200
		and _cargo("Transporter").quantity_of(&"iron") == 300 and _dk("Transporter").state == Docking.State.NONE
		and _n("Transporter", "RouteFollower").requested.distance_to(point) < 0.5 and _conserved)


# G: both berths of Station held by transports waiting for stock; a third queues and
# holds; nobody is evicted; a manual departure frees a berth; the third then docks.
func _test_g_congestion() -> void:
	_reset()
	_configure("Transporter", {&"silicon": 100})
	_configure("TransporterB", {&"silicon": 100})
	_run_until(func() -> bool: return _dk("Transporter").waiting and _dk("TransporterB").waiting, 300.0)
	_configure("TransporterC", {&"silicon": 100})
	_run_until(func() -> bool: return _dk("TransporterC").state == Docking.State.WAITING, 120.0)
	var queued: bool = _dk("TransporterC").state == Docking.State.WAITING and _a.hold_of(_ship("TransporterC")) >= 0
	_run_until(func() -> bool: return false, 60.0)
	var kept := _dk("Transporter").state == Docking.State.DOCKED and _dk("TransporterB").state == Docking.State.DOCKED \
		and _a.slot_of(_ship("Transporter")) >= 0 and _a.slot_of(_ship("TransporterB")) >= 0 and _dk("TransporterC").state == Docking.State.WAITING
	_main.get_node("Selection").set_selection([_ship("Transporter")])
	(_main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Actions/Docking/Undock") as Button).pressed.emit()
	_main.get_node("Selection").set_selection([])
	_run_until(func() -> bool: return _dk("TransporterC").state == Docking.State.DOCKED, 240.0)
	_check("G: both berths held by waiting transports, the third queues at a hold (%s); 60 s later nobody evicted (%s); a manual Undock frees a berth, the third docks (%s)"
		% [queued, kept, _dk("TransporterC").state_name()], queued and kept and _dk("TransporterC").state == Docking.State.DOCKED
		and _dk("TransporterB").state == Docking.State.DOCKED and _tr("Transporter").status == TransportOperation.Status.PAUSED and _conserved)


# H: a MOVE without a route given to a transport waiting in the berth changes nothing.
func _test_h_invalid_order() -> void:
	_reset()
	_add(_a, &"iron", 100)
	_configure("Transporter", {&"iron": 200})
	_run_until(func() -> bool: return _dk("Transporter").waiting, 240.0)
	var before := _cargo_text("Transporter")
	var slot: int = _a.slot_of(_ship("Transporter"))
	_main.get_node("StaticNavigation").blocked_to = NO_ROUTE
	_main._order(_ship("Transporter"), {"kind": _main.CommandKind.MOVE, "point": NO_ROUTE})
	_run_until(func() -> bool: return false, 5.0)
	_main.get_node("StaticNavigation").blocked_to = Vector2.INF
	_check("H: a refused MOVE while waiting in the berth: still Docked and waiting in the same berth, Loading, cargo %s, nothing held" % before,
		_dk("Transporter").state == Docking.State.DOCKED and _dk("Transporter").waiting and _a.slot_of(_ship("Transporter")) == slot
		and _tr("Transporter").status == TransportOperation.Status.LOADING and _cargo_text("Transporter") == before and not _dk("Transporter").has_held_command()
		and _conserved)


# I: Station -> Station2, Iron 200, three deliveries with stock arriving in parts and
# room at Station2 freed in parts: exactly one dock and one exit per station visit.
func _test_i_cycles() -> void:
	_reset()
	_fill(_b, 100)
	_configure("Transporter", {&"iron": 200})
	var next_stock := 0.0
	var next_room := 0.0
	var ticks := 0
	while _tr("Transporter").deliveries < 3 and ticks < int(1500.0 / DT):
		if _time >= next_stock:
			_add(_a, &"iron", 50)
			next_stock += 8.0
		if _time >= next_room:
			_take(_b, &"ice", mini(100, _b.storage.quantity_of(&"ice")))
			next_room += 10.0
		_tick()
		ticks += 1
	_check("I: 3 deliveries with intermittent stock and room in %.0f s: %d docks, %d exits (6 / 6), never at a hold, Station2 Iron %d, conserved every tick"
		% [_time, _docks["Transporter"], _exits["Transporter"], _b.storage.quantity_of(&"iron")], _tr("Transporter").deliveries == 3
		and _docks["Transporter"] == 6 and _exits["Transporter"] == 6 and not _visited("Transporter", Docking.State.BLOCKED)
		and _b.storage.quantity_of(&"iron") == 600 and _conserved)


# J: a waiting transport given a valid MOVE (exit starts), then two more valid MOVEs and an
# invalid one during the exit: the last valid one is shown and run; transport stays Paused.
func _test_j_deferred_move() -> void:
	_reset()
	_configure("Transporter", {&"silicon": 100})
	_run_until(func() -> bool: return _dk("Transporter").waiting, 240.0)
	_main.get_node("Selection").set_selection([_ship("Transporter")])
	var center := Vector2(_a.global_position.x, _a.global_position.z)
	var points := [center + Vector2(40, 20), center + Vector2(45, -10), center + Vector2(50, 25)]
	_main._order(_ship("Transporter"), {"kind": _main.CommandKind.MOVE, "point": points[0]})
	_run_until(func() -> bool: return false, 2.0)
	_main._order(_ship("Transporter"), {"kind": _main.CommandKind.MOVE, "point": points[1]})
	_main._order(_ship("Transporter"), {"kind": _main.CommandKind.MOVE, "point": points[2]})
	_main._order(_ship("Transporter"), {"kind": _main.CommandKind.MOVE, "point": Vector2(500, 0)}) # Off the map: refused intent.
	_main._process(0.0)
	var marker: Node3D = _main._markers[_ship("Transporter")][0]
	var shown := marker.visible and Vector2(marker.global_position.x, marker.global_position.z).distance_to(points[2]) < 0.01
	var paused := _tr("Transporter").status == TransportOperation.Status.PAUSED
	_run_until(func() -> bool: return not _dk("Transporter").under_control(), 60.0)
	_run_until(func() -> bool: return false, 0.1)
	_check("J: valid MOVE while waiting starts the exit and pauses transport; later valid MOVEs replace it, an invalid one does not; the last shown during the exit and run after it",
		paused and shown and _n("Transporter", "RouteFollower").requested.distance_to(points[2]) < 0.5 and _tr("Transporter").status == TransportOperation.Status.PAUSED
		and _cargo("Transporter").quantity() == 0 and _conserved)
	_main.get_node("Selection").set_selection([])


# Scope: a Miner unloading into a full station and a manual Load of a resource out of
# stock keep today's blocked transfer (they leave the berth and wait at a hold).
func _test_scope_boundary() -> void:
	_reset()
	_fill(_a, 0)
	_add(_cargo("Miner1"), &"iron", 100)
	_lo("Miner1").place(_nav_point(Vector2(_a.global_position.x, _a.global_position.z) + Vector2(55, 0), "Miner1"), 0.0)
	_dk("Miner1").dock(_a)
	_run_until(func() -> bool: return _dk("Miner1").state == Docking.State.DOCKED, 240.0)
	_dk("Miner1").unload()
	_run_until(func() -> bool: return _dk("Miner1").state == Docking.State.BLOCKED, 120.0)
	var miner_left: bool = _dk("Miner1").state == Docking.State.BLOCKED and _a.slot_of(_ship("Miner1")) < 0
	var miner_state := _dk("Miner1").state_name()
	_reset()
	_lo("Transporter").place(_nav_point(Vector2(_a.global_position.x, _a.global_position.z) + Vector2(55, 0), "Transporter"), 0.0)
	_dk("Transporter").dock(_a)
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.DOCKED, 240.0)
	_dk("Transporter").load_cargo(&"gold", 50) # As the panel's Load does.
	_run_until(func() -> bool: return _dk("Transporter").state == Docking.State.BLOCKED, 120.0)
	_check("scope: a blocked Miner unload (%s) and a blocked manual Load (%s) still leave the berth and wait at a hold"
		% [miner_state, _dk("Transporter").state_name()], miner_left and _dk("Transporter").state == Docking.State.BLOCKED
		and _a.slot_of(_ship("Transporter")) < 0 and _conserved)


# ------------------------------------------------------------------ harness
func _configure(s: String, required: Dictionary) -> void:
	var transport := _tr(s)
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	for resource in Inventory.RESOURCES:
		transport.set_requirement(resource, 0)
	for resource: StringName in required:
		transport.set_requirement(resource, required[resource])
	transport.start()


func _run_until(condition: Callable, seconds: float) -> void:
	for i in int(seconds / DT):
		if condition.call():
			return
		_tick()


func _tick() -> void:
	for s in _ships:
		_n(s, "RouteFollower")._physics_process(DT)
		_n(s, "Avoidance")._physics_process(DT)
	for s in _ships:
		_lo(s)._step(DT)
	for s in _ships:
		var before: int = _dk(s).state
		for child in ["Mining", "Transport"]:
			var node := _ship(s).get_node_or_null(child)
			if node != null:
				node._physics_process(DT)
		_dk(s)._physics_process(DT)
		_n(s, "Fuel")._physics_process(DT)
		var after: int = _dk(s).state
		if after != before:
			(_states[s] as Dictionary)[after] = true
			if after == Docking.State.UNDOCKING:
				_exits[s] += 1
			if after == Docking.State.DOCKED:
				_docks[s] += 1
	for station in _main.get_node("Stations").get_children():
		station._physics_process(DT)
	_b.get_node("Refinery")._physics_process(DT)
	_time += DT
	_conserved = _conserved and _totals() == _expected


func _visited(s: String, state: int) -> bool:
	return (_states[s] as Dictionary).has(state)


func _totals() -> Dictionary:
	var totals := {}
	var inventories: Array = []
	for s in _ships:
		var cargo := _ship(s).get_node_or_null("Cargo")
		if cargo != null:
			inventories.append(cargo.inventory)
	for station in _main.get_node("Stations").get_children():
		inventories.append(station.storage)
	for inventory: Inventory in inventories:
		for resource: StringName in inventory.amounts:
			var family := String(resource).trim_suffix("_ingot")
			totals[family] = totals.get(family, 0) + inventory.amounts[resource]
	return totals


func _add(target: Variant, resource: StringName, amount: int) -> void:
	var inventory: Inventory = target if target is Inventory else target.storage
	inventory.add(resource, amount)
	_expected[String(resource).trim_suffix("_ingot")] = _expected.get(String(resource).trim_suffix("_ingot"), 0) + amount


func _take(station: Node3D, resource: StringName, amount: int) -> void:
	station.storage.remove(resource, amount)
	_expected[String(resource)] = _expected.get(String(resource), 0) - amount


func _fill(station: Node3D, room: int) -> void:
	_add(station, &"ice", station.storage.free_space() - room)


func _reset() -> void:
	for s in _ships:
		var dk := _dk(s)
		dk.phase = Docking.Phase.NONE
		dk.hold_command(Callable())
		_lo(s).place(_nav_point(PARK[s], s), 0.0)
		dk.cancel()
		dk.state = Docking.State.NONE
		dk.transfer = Docking.Transfer.NONE
		dk.waiting = false
		_n(s, "RouteFollower").clear()
		_n(s, "Avoidance").reset()
		_n(s, "Fuel")._set_fuel(_n(s, "Fuel").capacity)
		var cargo := _ship(s).get_node_or_null("Cargo")
		if cargo != null:
			cargo.inventory.amounts.clear()
		var mining := _ship(s).get_node_or_null("Mining") as MiningOperation
		if mining != null:
			mining.cancel()
			mining.target = -1
			mining.status = MiningOperation.Status.NONE
		var transport := _ship(s).get_node_or_null("Transport") as TransportOperation
		if transport != null:
			transport.cancel()
			transport.status = TransportOperation.Status.NONE
			transport.deliveries = 0
			transport._leaving = false
			transport._returning = false
		_states[s] = {}
		_exits[s] = 0
		_docks[s] = 0
	for station in _main.get_node("Stations").get_children():
		for slot in station.slots:
			slot.ship = null
			slot.leaving = false
		for h in station.holds:
			h.ship = null
		station.queue.clear()
		station._exiting.clear()
		station.storage.amounts.clear()
		station.fuel_stock = 1000.0
	_main.get_node("Selection").set_selection([])
	_notices.clear()
	_time = 0.0
	_expected = _totals()
	_conserved = true


func _nav_point(point: Vector2, s: String) -> Vector2:
	return _main.get_node("StaticNavigation").closest_point(_n(s, "RouteFollower").planning_radius(), point)


func _cargo_text(s: String) -> String:
	return _cargo(s).describe("empty")


func _cargo(s: String) -> Inventory:
	return _n(s, "Cargo").inventory


func _ship(s: String) -> Node3D:
	return _main.get_node("Ships/" + s)


func _n(s: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [s, child])


func _lo(s: String) -> Node:
	return _n(s, "Locomotion")


func _dk(s: String) -> Docking:
	return _n(s, "Docking") as Docking


func _tr(s: String) -> TransportOperation:
	return _n(s, "Transport") as TransportOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
