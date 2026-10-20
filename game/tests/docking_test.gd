extends SceneTree
## Headless Phase 2 Stage 3 checks on the playable main scene: the station as a
## static obstacle, docking positions for every hull, slots, the FIFO queue and
## holding positions, Dock / Undock / cancellation (also through right-clicks),
## unreachable docking, station storage and timed Unload / Load with partial,
## blocked and interrupted transfers. Ship physics is stepped manually at 60 Hz in
## the game's order (per ship RouteFollower then Avoidance, then Locomotion, then
## Mining and Docking, then the station).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/docking_test.gd
## Every check is PASS/FAIL. Ships start apart (not from the clustered spawn,
## where simultaneous departures can hit the known Movement V3 traffic stall).

const MAIN := preload("res://main.tscn")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2"]
const PARK := {"Frigate": Vector2(40, 30), "Gunship": Vector2(40, 15), "Destroyer": Vector2(40, -5), "Miner1": Vector2(40, -20), "Miner2": Vector2(40, -32)}
const STARTS := [Vector2(-10, -40), Vector2(-10, 2), Vector2(-62, -40), Vector2(-62, 2)] # Near the station, off its approach lanes.
const SEED := 20261014
# Station obstacle rectangles in the station's frame: [centre, half size].
const RECTS := [[Vector2(0, 0), Vector2(4, 3)], [Vector2(6, 0), Vector2(2, 0.6)], [Vector2(-6, 0), Vector2(2, 0.6)]]

var _failures := 0
var _checks := 0
var _main: Node
var _station: Station
var _field: AsteroidField
var _navigation: Node
var _notices: Array[String] = []
var _min_gap := INF # Smallest gap between any ship's footprint and the station's obstacles.
var _ticks := 0


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_station = _main.get_node("Stations/Station")
	_field = _main.get_node("Asteroids")
	_navigation = _main.get_node("StaticNavigation")
	_main.get_node("Survey").set_physics_process(false)
	_station.set_physics_process(false)
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.set_physics_process(false)
		_docking(ship_name).notice.connect(func(text: String) -> void: _notices.append(text))
	for ship_name in SHIPS:
		while not _navigation.is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame

	_test_obstacles()
	_test_positions()
	_test_prototype()
	_test_every_class()
	_test_queue()
	_test_cancellation()
	_test_input_and_mining()
	_test_unreachable()
	_test_inventory()
	_test_unload_load()
	_test_partial_and_blocked()
	_test_empty_source()
	_test_interruption()
	await _test_panel()
	_check("no ship footprint ever inside the station (smallest gap %.2f u)" % _min_gap, _min_gap >= -0.001)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _test_obstacles() -> void:
	var group := _main.get_tree().get_nodes_in_group(&"static_obstacle")
	var names := group.map(func(node: Node) -> String: return String(node.name))
	# Two stations since Stage 6, three since Phase 4 (the Shipyard): each body and two arms.
	_check("station body and arms are static obstacles, docking heads are not", names.size() == 9 and names.count("Body") == 3
		and names.count("ArmEast") == 3 and names.count("ArmWest") == 3)
	var navigation_nodes: Array = _main.get_node("PlanarCollision")._obstacles.map(func(obstacle: Dictionary) -> Node: return obstacle.node)
	_check("navigation and collision read 36 asteroids + 9 station boxes", _navigation._obstacles.size() == 45
		and navigation_nodes.size() == 45 and group.all(func(node: Node) -> bool: return navigation_nodes.has(node)))
	_check("the station is not a resource asteroid", _field.ids().size() == 36 and _station.get_parent().name == "Stations")
	_check("Movement V3 profiles unchanged by Stage 3 (Destroyer 3 u/s, radius 6.2)", _node("Destroyer", "Locomotion").max_speed == 3.0
		and _node("Destroyer", "RouteFollower").ship_radius == 6.2)


# Docking positions and holding positions for every hull, from the station layout.
func _test_positions() -> void:
	var outside := true
	var navigable := true
	var asteroids := true
	for ship_name in ["Frigate", "Gunship", "Destroyer", "Miner1"]:
		var follower := _node(ship_name, "RouteFollower")
		for i in 2:
			for point: Vector2 in [_station.berths[i].park_point(follower.ship_radius), _station.berths[i].handover_point(follower.ship_radius)]:
				outside = outside and _station_gap(point, follower.ship_radius) >= follower.clearance_margin
				navigable = navigable and _navigation.closest_point(follower.planning_radius(), point).distance_to(point) < 0.25
				for id: int in _field.ids():
					asteroids = asteroids and _field.surface_distance(id, point) >= follower.planning_radius()
	_check("docking and approach points outside the station by the clearance (all hulls, both arms)", outside)
	_check("docking and approach points navigable for each hull", navigable)
	_check("docking and approach points clear of every asteroid", asteroids)
	var largest: float = _node("Destroyer", "RouteFollower").planning_radius()
	var apart := _station.berths[0].park_point(6.2).distance_to(_station.berths[1].park_point(6.2))
	_check("two docked Destroyers %.1f u apart (footprints + 1.5 u: %.1f u)" % [apart, 2 * 6.2 + 1.5], apart >= 2 * 6.2 + 1.5)
	var holds_ok := true
	for hold: Dictionary in _station.holds:
		holds_ok = holds_ok and _navigation.closest_point(largest, hold.point).distance_to(hold.point) < 0.25
		for i in 2:
			var lane := Geometry2D.get_closest_point_to_segment(hold.point, _station.slots[i].end, _station.berths[i].handover_point(6.2))
			holds_ok = holds_ok and hold.point.distance_to(lane) >= 2 * 6.2 + 1.5
	_check("holding positions navigable for a Destroyer and clear of both approach lanes", holds_ok)


# The prototype sequence: two ships take the two arms, a third waits, an undock advances the queue.
func _test_prototype() -> void:
	_reset()
	_place("Frigate", STARTS[0])
	_place("Miner1", STARTS[1])
	_place("Gunship", STARTS[2])
	for ship_name in ["Frigate", "Miner1", "Gunship"]:
		_docking(ship_name).dock(_station)
	var ticks := _run_until(func() -> bool: return _is_docked("Frigate") and _is_docked("Miner1"), 60 * 180)
	_check("1./2. first two ships docked on different arms in %.1f s" % (ticks * DT), ticks >= 0 and _docking("Frigate").slot != _docking("Miner1").slot)
	_check("docked ships settled at their docking positions (within %.2f u)" % Docking.DOCK_TOLERANCE, _settled("Frigate") and _settled("Miner1"))
	_run_until(func() -> bool: return not _node("Gunship", "Locomotion").has_destination, 60 * 120)
	var hold: int = _station.hold_of(_ship("Gunship"))
	_check("3. third ship waits at a holding position, queued", _docking("Gunship").state == Docking.State.WAITING and hold >= 0
		and _station.queue_position(_ship("Gunship")) == 0 and _position("Gunship").distance_to(_station.holds[hold].point) < 0.3)
	var freed: int = _docking("Frigate").slot
	_docking("Frigate").undock()
	ticks = _run_until(func() -> bool: return _is_docked("Gunship"), 60 * 180)
	_check("4. undocking released slot %d to the waiting ship (docked after %.1f s)" % [freed, ticks * DT], ticks >= 0 and _docking("Gunship").slot == freed
		and _station.hold_of(_ship("Gunship")) < 0 and _station.queue.is_empty())
	_check("undocked ship left towards an exit off the approach lane", _docking("Frigate").state == Docking.State.NONE
		and not _station.berths[freed].overlaps(_position("Frigate"), 1.6))
	_check("no ship contacts in the prototype", _contacts() == 0)


# Every hull class docks on each arm, arriving bow-in.
func _test_every_class() -> void:
	var report := []
	var ok := true
	for ship_name in ["Destroyer", "Gunship", "Frigate", "Miner2"]:
		for arm in 2:
			_reset()
			if arm == 1:
				# Occupy the east arm first so this ship takes the west one.
				_place("Miner1", STARTS[1])
				_docking("Miner1").dock(_station)
				_run_until(func() -> bool: return _is_docked("Miner1"), 60 * 120)
			_place(ship_name, STARTS[0] if arm == 0 else STARTS[2])
			_docking(ship_name).dock(_station)
			var ticks := _run_until(func() -> bool: return _is_docked(ship_name), 60 * 240)
			var slot: int = _docking(ship_name).slot
			var bow := Vector2(-sin(_node(ship_name, "Locomotion").heading), -cos(_node(ship_name, "Locomotion").heading))
			var off := rad_to_deg(bow.angle_to(-_station.slots[maxi(slot, 0)].axis))
			ok = ok and ticks >= 0 and slot == arm and _settled(ship_name) and absf(off) <= 0.5
			report.append("%s %s %.0f s %+.0f°" % [ship_name, "E" if arm == 0 else "W", ticks * DT, off])
	_check("every hull docks on both arms, settled, bow-in within 0.5° (%s)" % ", ".join(report), ok and _contacts() == 0)


# FIFO queue, one entry per ship, granted in request order.
func _test_queue() -> void:
	_reset()
	_place("Frigate", STARTS[0])
	_place("Miner1", STARTS[1])
	_docking("Frigate").dock(_station)
	_docking("Miner1").dock(_station)
	_run_until(func() -> bool: return _is_docked("Frigate") and _is_docked("Miner1"), 60 * 180)
	_place("Gunship", STARTS[2])
	_place("Miner2", STARTS[3])
	_place("Destroyer", Vector2(-36, 30))
	for ship_name in ["Miner2", "Gunship", "Destroyer"]:
		_docking(ship_name).dock(_station)
	_docking("Gunship").dock(_station)
	_station.request(_ship("Gunship"), [0, 1])
	var order := _station.queue.map(func(entry: Dictionary) -> String: return String(entry.ship.name))
	_check("queue in request order, one entry per ship (%s)" % ", ".join(order), order == ["Miner2", "Gunship", "Destroyer"])
	_run_until(func() -> bool: return SHIPS.all(func(name: String) -> bool: return not _node(name, "Locomotion").has_destination), 60 * 120)
	var holds := ["Miner2", "Gunship", "Destroyer"].map(func(name: String) -> int: return _station.hold_of(_ship(name)))
	_check("three waiting ships hold at three different holding positions %s" % str(holds), not holds.has(-1)
		and holds[0] != holds[1] and holds[1] != holds[2] and holds[0] != holds[2])
	_check("a ship never holds two slots or a slot and a queue entry", _station.slots.filter(func(slot: Dictionary) -> bool: return slot.ship == _ship("Frigate")).size() == 1
		and _station.queue_position(_ship("Frigate")) < 0)
	_docking("Frigate").undock()
	_run_until(func() -> bool: return _is_docked("Miner2"), 60 * 180)
	_docking("Miner1").undock()
	var ticks := _run_until(func() -> bool: return _is_docked("Gunship"), 60 * 240)
	_check("slots granted first in, first out (Miner2, then Gunship); Destroyer still waiting", ticks >= 0 and _is_docked("Miner2")
		and _docking("Destroyer").state == Docking.State.WAITING and _station.queue_position(_ship("Destroyer")) == 0)
	_check("no ship contacts around the busy station", _contacts() == 0)


# A manual order releases a docked slot, an approach and a queue entry.
func _test_cancellation() -> void:
	_reset()
	_place("Frigate", STARTS[0])
	_place("Miner1", STARTS[1])
	_place("Gunship", STARTS[2])
	_place("Miner2", STARTS[3])
	for ship_name in ["Frigate", "Miner1", "Gunship"]:
		_docking(ship_name).dock(_station)
	_run_until(func() -> bool: return _is_docked("Frigate") and _is_docked("Miner1"), 60 * 180)
	_manual_move("Gunship", Vector2(-62, 8))
	_check("cancel while waiting: out of the queue, holding position released", _station.queue.is_empty()
		and _station.hold_of(_ship("Gunship")) < 0 and _docking("Gunship").state == Docking.State.NONE)
	var slot: int = _docking("Frigate").slot
	_manual_move("Frigate", Vector2(-10, -40))
	_check("cancel while docked: the slot is held until the ship is clear", _station.slots[slot].leaving and _docking("Frigate").state == Docking.State.NONE)
	_docking("Miner2").dock(_station)
	var ticks := _run_until(func() -> bool: return _is_docked("Miner2"), 60 * 180)
	_check("... then released to the next ship (docked after %.1f s)" % (ticks * DT), ticks >= 0 and _docking("Miner2").slot == slot)
	_docking("Miner1").undock()
	_run_until(func() -> bool: return _station.slots.any(func(entry: Dictionary) -> bool: return entry.ship == null), 60 * 120)
	_docking("Gunship").dock(_station)
	_steps(60)
	var approach: int = _docking("Gunship").slot
	_manual_move("Gunship", Vector2(-62, 8))
	_steps(5)
	_check("cancel while approaching: the reservation is released", _docking("Gunship").state == Docking.State.NONE and approach >= 0
		and _station.slots[approach].ship == null)


# Right-clicks: station docks, asteroid mines (miner), empty space moves; mining and docking exclude each other.
func _test_input_and_mining() -> void:
	_reset()
	var asteroid := 19 # Nearest asteroid to the station.
	_place("Miner1", Vector2(-60, -12))
	_mining("Miner1").assign(asteroid)
	_run_until(func() -> bool: return _mining("Miner1").status == MiningOperation.Status.MINING, 60 * 120)
	var between := (_station.global_position + _field.center(asteroid)) * 0.5
	_frame(Vector2(between.x, between.z), 40.0)
	_main.get_node("Selection").set_selection([_ship("Miner1")])
	var camera: Camera3D = _main.get_node("CameraRig/Camera3D")
	var on_station := camera.unproject_position(_station.global_position)
	var on_asteroid := camera.unproject_position(_field.center(asteroid))
	var view := root.get_visible_rect()
	var panel: Rect2 = _main.get_node("ShipPanel/Panel").get_global_rect()
	_check("layout: station and asteroid on screen, clear of the ship panel", view.has_point(on_station) and view.has_point(on_asteroid)
		and not panel.has_point(on_station) and not panel.has_point(on_asteroid))
	_right_click(on_station)
	_check("right-click station: Dock, mining cancelled with its target kept", _docking("Miner1").station == _station
		and _docking("Miner1").state != Docking.State.NONE and _mining("Miner1").status == MiningOperation.Status.CANCELED and _mining("Miner1").target == asteroid)
	_steps(30)
	_right_click(on_asteroid)
	_check("right-click asteroid (Miner): Mine, docking released", _mining("Miner1").status == MiningOperation.Status.TRAVELING
		and _docking("Miner1").state == Docking.State.NONE and _station.slot_of(_ship("Miner1")) < 0 and _station.queue.is_empty())
	_main.get_node("Selection").set_selection([_ship("Destroyer")])
	_place("Destroyer", STARTS[0])
	_right_click(on_station)
	_check("right-click station with a combat ship: Dock", _docking("Destroyer").station == _station and _docking("Destroyer").state == Docking.State.APPROACHING)
	var ground := camera.unproject_position(Vector3(-20, 0, -2))
	_right_click(ground)
	_check("right-click empty space: Move, docking released", _docking("Destroyer").state == Docking.State.NONE
		and _node("Destroyer", "RouteFollower").requested.distance_to(Vector2(-20, -2)) < 0.5 and _station.slot_of(_ship("Destroyer")) < 0)
	_place("Frigate", STARTS[1])
	_place("Gunship", STARTS[2])
	var ships := [_ship("Frigate"), _ship("Gunship")]
	_main.get_node("Selection").set_selection(ships)
	var hit: Vector3 = Plane(Vector3.UP, 0.0).intersects_ray(camera.project_ray_origin(on_station), camera.project_ray_normal(on_station))
	var expected: Dictionary = _main.get_node("GroupOrders").assign(ships, Vector2(hit.x, hit.z))
	_right_click(on_station)
	var same := true
	for ship: Node in expected:
		same = same and ship.get_node("Locomotion").destination.distance_to(expected[ship]) < 0.01 and ship.get_node("Docking").state == Docking.State.NONE
	_check("group right-click over the station: the usual group MOVE, no docking", same)
	_main.get_node("Selection").set_selection([])


func _test_unreachable() -> void:
	_reset()
	_place("Frigate", STARTS[0])
	_block_berths(_station, true) # Handover points inside the station body: not navigable.
	var plans: int = _node("Frigate", "RouteFollower").plans
	_notices.clear()
	_docking("Frigate").dock(_station)
	_steps(10)
	_check("unreachable docking positions: Unable to Dock, no order, nothing reserved, a notice", _docking("Frigate").state == Docking.State.UNABLE
		and _node("Frigate", "RouteFollower").plans == plans and _station.slots.all(func(slot: Dictionary) -> bool: return slot.ship == null)
		and _station.queue.is_empty() and _notices.size() == 1)
	_block_berths(_station, false)


func _test_inventory() -> void:
	_field.generate(SEED)
	var a := Inventory.new(100)
	var b := Inventory.new(50)
	a.add(&"silicon", 40)
	a.add(&"ice", 20)
	a.add(&"iron", 30)
	var moved := a.transfer_to(b, 80)
	# Phase 3: resources go in Inventory's fixed order (was: oldest lots first).
	_check("transfer stops at the destination's capacity (50 of 80), resources in their fixed order", moved == 50 and b.quantity() == 50 and a.quantity() == 40
		and b.amounts == {&"iron": 30, &"silicon": 20})
	var c := Inventory.new(100)
	var ice := a.transfer_to(c, 100, &"ice") + b.transfer_to(c, 100, &"ice")
	_check("transfer of one resource keeps the others in place", ice == 20 and c.amounts == {&"ice": 20} and a.amounts == {&"silicon": 20})


func _test_unload_load() -> void:
	var cargo := _dock_miner_with_cargo([[0, 300], [1, 200]], 120)
	var total := cargo.quantity() + _station.storage.quantity()
	_check("docking alone moves no cargo", cargo.quantity() == 620 and _station.storage.quantity() == 0)
	_docking("Miner1").unload()
	var conserved := true
	for tick in 120:
		_steps(1)
		conserved = conserved and cargo.quantity() + _station.storage.quantity() == total
	var after_two := _station.storage.quantity()
	_check("timed unload: %d units in 2 s at %.0f/s" % [after_two, _station.transfer_rate], absi(after_two - roundi(2.0 * _station.transfer_rate)) <= 1 and conserved)
	_run_until(func() -> bool: return _docking("Miner1").transfer == Docking.Transfer.NONE, 60 * 30)
	_check("unload complete: everything in station storage, ship still docked", cargo.quantity() == 0 and _station.storage.quantity() == total
		and _is_docked("Miner1"))
	# Phase 3: replaces "compositions preserved in station storage (3 lots, same compositions)".
	_check("resources preserved in station storage (%s)" % _station.storage.describe(), _station.storage.amounts == {&"iron": 300, &"silicon": 200, &"ice": 120})
	_docking("Miner1").load_cargo(&"iron", 150)
	var ticks := _run_until(func() -> bool: return _docking("Miner1").transfer == Docking.Transfer.NONE, 60 * 30)
	_check("timed load of 150 Iron in %.1f s, only that resource" % (ticks * DT), cargo.quantity() == 150
		and cargo.amounts == {&"iron": 150} and _station.storage.quantity_of(&"iron") == 150 and absf(ticks * DT - 3.0) < 0.2)


# Unloading into a nearly full station: partial, then the slot is freed and the ship comes back.
func _test_partial_and_blocked() -> void:
	var cargo := _dock_miner_with_cargo([[0, 200]], 0)
	_station.storage.capacity = 60
	var total := cargo.quantity()
	_docking("Miner1").unload()
	_run_until(func() -> bool: return _docking("Miner1").state != Docking.State.DOCKED, 60 * 10)
	var slot: int = _station.slots.find_custom(func(entry: Dictionary) -> bool: return entry.ship == _ship("Miner1"))
	_check("station full: 60 of 200 unloaded, request kept, 140 still aboard", _station.storage.quantity() == 60 and cargo.quantity() == 140
		and _docking("Miner1").transfer == Docking.Transfer.UNLOAD and _docking("Miner1").moved == 60)
	var exiting: bool = _docking("Miner1").state == Docking.State.UNDOCKING and _docking("Miner1").under_control() and slot >= 0 and _station.slots[slot].leaving
	_run_until(func() -> bool: return _docking("Miner1").state == Docking.State.BLOCKED, 60 * 60)
	_check("blocked (stage 2b): the berth is left through the controlled exit, then a holding position", exiting and _station.hold_of(_ship("Miner1")) >= 0)
	_run_until(func() -> bool: return not _node("Miner1", "Locomotion").has_destination, 60 * 120)
	_check("blocked ship waits at its holding position", _docking("Miner1").state == Docking.State.BLOCKED
		and _position("Miner1").distance_to(_station.holds[_station.hold_of(_ship("Miner1"))].point) < 0.3)
	_station.storage.capacity = 5000 # Space becomes available.
	var ticks := _run_until(func() -> bool: return _docking("Miner1").transfer == Docking.Transfer.NONE, 60 * 240)
	_check("space again: the ship docks again and finishes (%.1f s), nothing lost" % (ticks * DT), ticks >= 0 and cargo.quantity() == 0
		and _station.storage.quantity() == total and _is_docked("Miner1"))


func _test_empty_source() -> void:
	var cargo := _dock_miner_with_cargo([], 0)
	_docking("Miner1").load_cargo(&"ice", 80)
	_steps(5)
	var exiting: bool = _docking("Miner1").state == Docking.State.UNDOCKING and _docking("Miner1").under_control()
	_run_until(func() -> bool: return _docking("Miner1").state == Docking.State.BLOCKED, 60 * 60)
	_check("load with no stock: request kept, the ship leaves the berth (controlled exit) to wait", exiting and _docking("Miner1").state == Docking.State.BLOCKED
		and _docking("Miner1").transfer == Docking.Transfer.LOAD and cargo.quantity() == 0)
	_steps(60 * 10)
	_check("still waiting while there is no stock", _docking("Miner1").state == Docking.State.BLOCKED)
	_station.storage.add(&"ice", 50)
	_run_until(func() -> bool: return _docking("Miner1").state == Docking.State.BLOCKED and _is_back(), 60 * 240)
	_check("stock arrives: docks again, takes the 50 available and waits for the rest", cargo.quantity_of(&"ice") == 50
		and _station.storage.quantity() == 0 and _docking("Miner1").moved == 50)
	_station.storage.add(&"ice", 100)
	_run_until(func() -> bool: return _docking("Miner1").transfer == Docking.Transfer.NONE, 60 * 240)
	_check("... and completes the 80 when more arrives", cargo.quantity() == 80 and _station.storage.quantity() == 70)


func _test_interruption() -> void:
	var cargo := _dock_miner_with_cargo([[0, 400], [1, 100]], 0)
	var total := cargo.quantity()
	_docking("Miner1").unload()
	_steps(90)
	var moved: int = _docking("Miner1").moved
	_manual_move("Miner1", STARTS[1])
	_steps(120)
	_check("interrupted unload: %d units moved stay moved, %d stay aboard, none lost or duplicated" % [moved, cargo.quantity()],
		moved > 0 and moved < total and _station.storage.quantity() == moved and cargo.quantity() == total - moved
		and _docking("Miner1").transfer == Docking.Transfer.NONE)


func _test_panel() -> void:
	var cargo := _dock_miner_with_cargo([[0, 100]], 0)
	var selection := _main.get_node("Selection")
	selection.set_selection([_ship("Miner1")])
	await process_frame
	await process_frame
	var rows := _main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Actions/Docking")
	_check("panel: docked Miner shows Docked, Undock, storage, Unload and Load", rows.visible and _main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Status/Dock").text.begins_with("Dock: Docked")
		and rows.get_node("Undock").visible and rows.get_node("Transfer").visible and not rows.get_node("Transfer/Unload").disabled)
	_docking("Miner1").unload()
	_steps(30)
	await process_frame
	await process_frame
	_check("panel: transfer progress and quantity", rows.get_node("Transfer/Progress").visible
		and rows.get_node("Transfer/ProgressLabel").text == "Unloading %d / 100" % _docking("Miner1").moved)
	_place("Destroyer", STARTS[2])
	_docking("Destroyer").dock(_station)
	_run_until(func() -> bool: return _is_docked("Destroyer"), 60 * 240)
	selection.set_selection([_ship("Destroyer")])
	await process_frame
	await process_frame
	_check("panel: docked Destroyer (no cargo hold) shows Undock but no cargo actions", rows.get_node("Undock").visible
		and not rows.get_node("Transfer").visible and _docking("Destroyer").state == Docking.State.DOCKED)
	_check("station hover text: storage and docks", _station.describe().contains("Storage: ") and _station.describe().contains("Docks in use: 2 / 2"))
	selection.set_selection([])


# Miner1 docked at the station with the given cargo ([0 iron / 1 silicon, units];
# plus `ice` units of ice), station storage empty.
func _dock_miner_with_cargo(lots: Array, ice: int) -> Inventory:
	_reset()
	var cargo: Inventory = _node("Miner1", "Cargo").inventory
	for entry: Array in lots:
		cargo.add([&"iron", &"silicon"][entry[0]], entry[1]) # Phase 3: index -> raw mineral (was: a mineral asteroid's composition).
	if ice > 0:
		cargo.add(&"ice", ice)
	_place("Miner1", STARTS[0])
	_docking("Miner1").dock(_station)
	_run_until(func() -> bool: return _is_docked("Miner1"), 60 * 120)
	return cargo


func _is_back() -> bool:
	return _docking("Miner1").moved > 0


func _reset() -> void:
	_field.generate(SEED)
	for ship_name in SHIPS:
		_docking(ship_name).phase = Docking.Phase.NONE # Stage 2b: cancel() is refused during station control.
		_docking(ship_name).hold_command(Callable())
		_node(ship_name, "Locomotion").place(PARK[ship_name], 0.0)
		_docking(ship_name).cancel()
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
		_place(ship_name, PARK[ship_name])
	for miner in ["Miner1", "Miner2"]:
		var mining := _mining(miner)
		mining.target = -1
		mining.status = MiningOperation.Status.NONE
		mining._route_pending = false
		_node(miner, "Cargo").inventory.amounts.clear()
	for slot in _station.slots:
		slot.ship = null
		slot.leaving = false
	for hold in _station.holds:
		hold.ship = null
	_station.queue.clear()
	_station._exiting.clear()
	_station.storage.amounts.clear()
	_station.storage.capacity = _station.storage_capacity


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


func _manual_move(ship_name: String, point: Vector2) -> void:
	# As the scene input does for a MOVE: order, then cancel mining and docking.
	_node(ship_name, "RouteFollower").order(point)
	if _main.get_node_or_null("Ships/%s/Mining" % ship_name) != null:
		_mining(ship_name).cancel()
	_docking(ship_name).cancel()


func _run_until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_steps(1)
	for ship_name in SHIPS: # Diagnostics for the failing wait.
		var locomotion := _node(ship_name, "Locomotion")
		print("    timeout: %-9s %-28s at (%.1f, %.1f) moving %s contacts %d" % [ship_name, _docking(ship_name).state_name(),
			locomotion.planar_position.x, locomotion.planar_position.y, locomotion.has_destination, locomotion.collision_count])
	return -1


func _steps(count: int) -> void:
	for i in count:
		_ticks += 1
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_node(ship_name, "Locomotion")._step(DT)
		for ship_name in SHIPS:
			var mining := _main.get_node_or_null("Ships/%s/Mining" % ship_name)
			if mining != null:
				mining._physics_process(DT)
			_docking(ship_name)._physics_process(DT)
		_station._physics_process(DT)
		for ship_name in SHIPS:
			_min_gap = minf(_min_gap, _station_gap(_position(ship_name), _node(ship_name, "RouteFollower").ship_radius))


# Gap between a footprint (circle) and the station's obstacle boxes.
func _station_gap(point: Vector2, radius: float) -> float:
	var local3 := _station.global_transform.affine_inverse() * Vector3(point.x, _station.global_position.y, point.y)
	var local := Vector2(local3.x, local3.z)
	var gap := INF
	for rect: Array in RECTS:
		var d: Vector2 = (local - rect[0]).abs() - rect[1]
		var outside := Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() + minf(maxf(d.x, d.y), 0.0)
		gap = minf(gap, outside - radius)
	return gap


func _is_docked(ship_name: String) -> bool:
	return _docking(ship_name).state == Docking.State.DOCKED


func _settled(ship_name: String) -> bool:
	var docking := _docking(ship_name)
	return _position(ship_name).distance_to(docking.dock_point) <= Docking.DOCK_TOLERANCE and _node(ship_name, "Locomotion").velocity.length() <= 0.05


func _contacts() -> int:
	var total := 0
	for ship_name in SHIPS:
		total += _node(ship_name, "Locomotion").collision_count
	return total


func _composition(family: int, k: int) -> Dictionary:
	var found := _field.ids().filter(func(id: int) -> bool: return _field.deposit(id).family == family)
	return _field.deposit(found[k]).composition


func _frame(center: Vector2, zoom: float) -> void:
	var rig := _main.get_node("CameraRig")
	rig.global_position = Vector3(center.x, 0, center.y)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = zoom
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


func _place(ship_name: String, point: Vector2) -> void:
	_node(ship_name, "Locomotion").place(point, 0.0)


func _position(ship_name: String) -> Vector2:
	return _node(ship_name, "Locomotion").planar_position


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _docking(ship_name: String) -> Docking:
	return _node(ship_name, "Docking") as Docking


func _mining(miner: String) -> MiningOperation:
	return _node(miner, "Mining") as MiningOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-100s %s" % [label, "PASS" if ok else "FAIL"])
