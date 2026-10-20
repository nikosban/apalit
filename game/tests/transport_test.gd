extends SceneTree
## Headless Phase 2 Stage 6 checks on the playable main scene: the Transporter
## graybox and its movement, the second station, the transport assignment (load at
## one station, unload at another, Iron / Ice quantities since Phase 3), departure only
## once the requirements are met, empty source, edited requirements, full
## destination, return, three unattended deliveries, manual override and Resume,
## shared slots and queue, refueling, empty fuel, cargo conservation through
## interruptions, miners at either station, and the panel. Ship physics is stepped
## manually at 60 Hz in the game's order (per ship RouteFollower then Avoidance,
## then Locomotion, then Mining / Transport, Docking and Fuel, then the stations).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/transport_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const Inventory := preload("res://game/cargo/inventory.gd")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const Fuel := preload("res://game/fuel/fuel.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2", "Transporter"]
const PARK := {"Frigate": Vector2(40, 30), "Gunship": Vector2(40, 15), "Destroyer": Vector2(40, -5), "Miner1": Vector2(40, -20),
	"Miner2": Vector2(40, -32), "Transporter": Vector2(-80, 30)}
const NEAR_A := Vector2(-10, -40) # East of the loading station, off its approach lanes.
const SEED := 20261014
const METAL := &"iron" # Phase 3: a raw resource in place of the retired Metal Chunks.
const ICE := &"ice"


var _failures := 0
var _checks := 0
var _main: Node
var _a: Station # Loading station.
var _b: Station # Unloading station.
var _field: Node
var _navigation: Node
var _notices: Array[String] = []


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_a = _main.get_node("Stations/Station")
	_b = _main.get_node("Stations/Station2")
	_field = _main.get_node("Asteroids")
	_navigation = _main.get_node("StaticNavigation")
	_main.get_node("Survey").set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Transport", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.set_physics_process(false)
		for child in ["Transport", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.notice.connect(func(text: String) -> void: _notices.append(text))
	for ship_name in SHIPS:
		while not _navigation.is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame

	_test_geometry()
	_test_navigation_and_docking()
	_test_configuration()
	_test_one_delivery()
	_test_three_deliveries()
	_test_empty_source()
	_test_edit_requirements()
	_test_full_destination()
	_test_manual_override_and_resume()
	_test_shared_slots()
	_test_fuel()
	_test_interruption_conservation()
	_test_miners_at_either_station()
	await _test_panel()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# 1. Graybox and movement configuration.
func _test_geometry() -> void:
	var ship := _ship("Transporter")
	var bounds := AABB()
	var farthest := 0.0
	var symmetric := true
	# UX round T25: the thruster parts (Model/Thrusters) are counted apart from the
	# original sections and included in the total bounds and the farthest corner.
	var thruster_node := ship.get_node("Model/Thrusters")
	var parts := ship.find_children("*", "MeshInstance3D", true, false).filter(func(n: Node) -> bool: return not thruster_node.is_ancestor_of(n))
	var thrusters := thruster_node.find_children("*", "MeshInstance3D", true, false)
	var total := AABB()
	for i in parts.size():
		var part := parts[i] as MeshInstance3D
		var box: AABB = part.transform * part.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
		symmetric = symmetric and absf(box.get_center().x) < 0.001
		for x in [box.position.x, box.end.x]:
			for z in [box.position.z, box.end.z]:
				farthest = maxf(farthest, Vector2(x, z).length())
	total = bounds
	for part: MeshInstance3D in thrusters:
		var box: AABB = thruster_node.transform * part.transform * part.get_aabb()
		total = total.merge(box)
		for x in [box.position.x, box.end.x]:
			for z in [box.position.z, box.end.z]:
				farthest = maxf(farthest, Vector2(x, z).length())
	var forward := (ship.get_node("Model/Forward") as MeshInstance3D).position.z
	var radius: float = _node("Transporter", "RouteFollower").ship_radius
	_check("graybox: three sections, %.2f long (Z) x %.1f wide x %.1f high, symmetric, bow -Z, cargo section largest" % [bounds.size.z, bounds.size.x, bounds.size.y],
		parts.size() == 3 and is_equal_approx(bounds.size.x, 2.6) and bounds.size.z > 7.2 and bounds.size.y <= 1.2 and symmetric and forward < 0.0
		and ((ship.get_node("Model/CargoSection") as MeshInstance3D).mesh as BoxMesh).size == Vector3(2.6, 0.9, 4.6))
	_check("graybox with its %d thruster parts: %.2f long (Z) x %.2f wide, larger than the sections alone, symmetric" % [thrusters.size(), total.size.z, total.size.x],
		thrusters.size() == 9 and total.size.z > bounds.size.z and total.size.x > bounds.size.x and absf(total.get_center().x) < 0.001 and total.encloses(bounds))
	_check("collision radius %.1f u encloses the hull (farthest corner %.2f u)" % [radius, farthest], radius >= farthest and radius - farthest < 0.5)
	var same := true
	for property in ["max_speed", "max_reverse_speed", "max_lateral_speed", "forward_accel", "reverse_accel", "lateral_accel", "max_turn_rate_deg", "turn_accel_deg"]:
		same = same and _node("Transporter", "Locomotion").get(property) == _node("Gunship", "Locomotion").get(property)
	_check("movement: the Gunship's locomotion profile, clearance margin and size class", same
		and _node("Transporter", "RouteFollower").clearance_margin == _node("Gunship", "RouteFollower").clearance_margin
		and _node("Transporter", "Avoidance").size_class == _node("Gunship", "Avoidance").size_class)
	# Phase 4: a third station on the same layout, the Shipyard (Station2 and the Shipyard
	# are station scenes that inherit Station's layout scene).
	var base_of := func(station: Node) -> String:
		return (load(station.scene_file_path) as PackedScene).get_state().get_node_instance(0).resource_path
	_check("three ordinary station instances (same layout scene, all obstacles, all in the station group)", base_of.call(_b) == _a.scene_file_path
		and base_of.call(_main.get_node("Stations/Shipyard")) == _a.scene_file_path
		and _main.get_tree().get_nodes_in_group(Station.GROUP).size() == 3 and _main.get_tree().get_nodes_in_group(&"static_obstacle").size() == 9)


# The longer hull crosses the asteroid field and docks bow-in at every slot of both stations.
func _test_navigation_and_docking() -> void:
	_reset()
	var radius: float = _node("Transporter", "RouteFollower").ship_radius
	_place("Transporter", Vector2(-80, 30))
	var target: Vector2 = _navigation.closest_point(_node("Transporter", "RouteFollower").planning_radius(), Vector2(100, 60))
	_node("Transporter", "RouteFollower").order(target)
	var gap := INF
	var ticks := 0
	while _locomotion("Transporter").has_destination and ticks < 60 * 180:
		_steps(1)
		ticks += 1
		gap = minf(gap, _navigation.surface_distance(_position("Transporter")) - radius)
	_check("crosses the asteroid field (%.0f s), footprint never inside an obstacle (closest %.2f u), 0 contacts" % [ticks * DT, gap],
		not _locomotion("Transporter").has_destination and gap >= -0.001 and _locomotion("Transporter").collision_count == 0)
	var results: Array[String] = []
	var all_ok := true
	for station: Station in [_a, _b]:
		for side in [1.0, -1.0]:
			_reset()
			var start: Vector2 = Vector2(station.global_position.x + side * 30.0, station.global_position.z - 30.0)
			_place("Transporter", _navigation.closest_point(_node("Transporter", "RouteFollower").planning_radius(), start))
			_docking("Transporter").dock(station)
			var docked := _until(func() -> bool: return _docking("Transporter").state == Docking.State.DOCKED, 60 * 90)
			var slot: int = _docking("Transporter").slot
			var axis: Vector2 = station.slots[slot].axis
			var bow := Vector2(-sin(_locomotion("Transporter").heading), -cos(_locomotion("Transporter").heading))
			var off := rad_to_deg(bow.angle_to(-axis))
			var clearance: float = _navigation.surface_distance(_position("Transporter")) - radius
			var ok := docked >= 0 and absf(off) <= 0.5 and clearance >= -0.001
			all_ok = all_ok and ok
			results.append("%s slot %d %+.0f deg" % [station.name, slot, off])
	_check("docks bow-in at both slots of both stations (%s)" % ", ".join(results), all_ok)


# 2, 4: configuration and validation.
func _test_configuration() -> void:
	_reset()
	var transport := _transport()
	_place("Transporter", NEAR_A)
	var order := transport.stations_by_distance()
	_check("2. stations listed nearest first (from near the loading station: Station, Shipyard, Station2)", order.size() == 3 and order[0] == _a
		and order[1] == _main.get_node("Stations/Shipyard") and order[2] == _b)
	transport.set_load_station(_a)
	transport.set_unload_station(_a)
	transport.set_requirement(METAL, 400)
	_check("4. the same station for both ends is not a valid assignment", not transport.is_configured())
	transport.set_unload_station(_b)
	transport.set_requirement(METAL, 0)
	transport.start()
	_check("4. no cargo required: Start refused with a notice, nothing ordered", transport.status == TransportOperation.Status.NONE
		and _notices.has("Transporter: choose two different stations and a cargo requirement"))
	transport.set_requirement(METAL, 400)
	transport.set_requirement(ICE, -5)
	_check("4. requirements: exact quantities per family (negative clamped to 0), configured", transport.required[METAL] == 400
		and transport.required[ICE] == 0 and transport.is_configured())


# 3, 5, 6, 9, 10, 13, 18: one delivery of two families.
func _test_one_delivery() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking("Transporter")
	var fuel := _fuel("Transporter")
	var cargo := _cargo("Transporter")
	_a.storage.add(METAL, 1000)
	_a.storage.add(ICE, 1000)
	_configure(400, 200)
	fuel._set_fuel(120.0)
	transport.start()
	_check("3. starts toward the loading station", transport.status == TransportOperation.Status.LOADING and docking.station == _a
		and transport.activity() == "Traveling to Loading Base")
	_until(func() -> bool: return docking.state == Docking.State.DOCKED, 60 * 90)
	var at_dock := fuel.fuel
	var stock := _a.fuel_stock
	_steps(60)
	_check("9. timed loading: %d units after 1 s at 50 / s (Loading Cargo)" % cargo.quantity(), cargo.quantity() >= 49 and cargo.quantity() <= 51
		and transport.activity() == "Loading Cargo")
	var early := true
	var ticks := 0
	while transport.status == TransportOperation.Status.LOADING and docking.state == Docking.State.DOCKED and ticks < 60 * 60:
		early = early and not (docking.state == Docking.State.UNDOCKING and not transport.requirements_met())
		_steps(1)
		ticks += 1
	_check("5, 6. loaded both families (Metal %d, Ice %d), then left (not before)" % [cargo.quantity_of(METAL), cargo.quantity_of(ICE)],
		cargo.quantity_of(METAL) == 400 and cargo.quantity_of(ICE) == 200 and early and docking.state == Docking.State.UNDOCKING)
	_check("18. refueled while loading: %.1f -> %.1f, the station's stock fell by the same" % [at_dock, fuel.fuel], fuel.fuel == fuel.capacity
		and absf((stock - _a.fuel_stock) - (fuel.capacity - at_dock)) < 0.0001)
	_until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING and docking.state == Docking.State.APPROACHING, 60 * 30)
	_check("3. then heads for the unloading station (Traveling to Destination)", docking.station == _b and transport.activity() == "Traveling to Destination")
	_until(func() -> bool: return docking.transfer == Docking.Transfer.UNLOAD, 60 * 90)
	_steps(60)
	_check("9. timed unloading (Unloading Cargo, %d left after 1 s)" % cargo.quantity(), cargo.quantity() >= 549 and cargo.quantity() <= 551
		and transport.activity() == "Unloading Cargo")
	_until(func() -> bool: return transport.deliveries == 1, 60 * 60)
	# Phase 3: the retired "composition unchanged" clause is now "only those resources".
	_check("3, 10. delivered: Station2 holds 400 Iron + 200 Ice (nothing else); Station keeps 600 + 800", _b.storage.amounts == {METAL: 400, ICE: 200}
		and _a.storage.quantity() == 1400 and cargo.quantity() == 0)
	_steps(1)
	_check("13. after the delivery it returns to the loading station (Returning to Base)", transport.status == TransportOperation.Status.LOADING
		and docking.station == _a and transport.activity() == "Returning to Base")


# 14: three deliveries from one Start.
func _test_three_deliveries() -> void:
	_reset()
	var transport := _transport()
	var follower := _node("Transporter", "RouteFollower")
	_a.storage.add(METAL, 1200)
	_configure(400, 0)
	var plans: int = follower.plans
	transport.start()
	var ticks := 0
	while transport.deliveries < 3 and ticks < 60 * 60 * 6:
		_steps(1)
		ticks += 1
	_check("14. three unattended deliveries: %d delivered, %d orders, %.0f s, %d contacts" % [_b.storage.quantity(), follower.plans - plans, ticks * DT,
		_locomotion("Transporter").collision_count], transport.deliveries == 3 and _b.storage.quantity() == 1200 and _a.storage.quantity() == 0
		and follower.plans - plans <= 3 * 6 + 1 and _locomotion("Transporter").collision_count == 0)


# 7: the source runs short: keeps what it loaded, waits in the berth (UX round P4), resumes.
func _test_empty_source() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking("Transporter")
	var follower := _node("Transporter", "RouteFollower")
	_a.storage.add(METAL, 250)
	_configure(400, 0)
	transport.start()
	var blocked := _until(func() -> bool: return docking.waiting, 60 * 120)
	_until(func() -> bool: return not _locomotion("Transporter").has_destination, 60 * 60)
	var plans: int = follower.plans
	_steps(60 * 20)
	_check("7. source short: 250 kept aboard, waits in the berth with the slot held, no hold (Waiting for Resources), no orders in 20 s",
		blocked >= 0 and _cargo("Transporter").quantity() == 250 and _a.slot_of(_ship("Transporter")) >= 0 and _a.hold_of(_ship("Transporter")) < 0
		and transport.is_active() and transport.activity() == "Waiting for Resources" and follower.plans == plans)
	_a.storage.add(METAL, 300)
	var left := _until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 120)
	_check("7. stock arrives: loads the missing 150 in the berth, departs with exactly 400", left >= 0 and _cargo("Transporter").quantity() == 400
		and _a.storage.quantity() == 150)


# 8: requirements edited during loading.
func _test_edit_requirements() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking("Transporter")
	_a.storage.add(METAL, 1000)
	_configure(400, 200) # No ice in stock.
	transport.start()
	_until(func() -> bool: return docking.waiting, 60 * 120)
	_steps(60)
	var waited := transport.activity() == "Waiting for Resources" and _cargo("Transporter").quantity_of(METAL) == 400
	transport.set_requirement(ICE, 0)
	_steps(2)
	var exiting := docking.state == Docking.State.UNDOCKING and _cargo("Transporter").quantity() == 400
	_until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 60)
	_check("8. ice requirement removed while waiting for ice in the berth: the controlled exit starts within 2 ticks with the 400 Metal, then on to Station2",
		waited and exiting and transport.status == TransportOperation.Status.DELIVERING and docking.station == _b and _cargo("Transporter").quantity() == 400)
	_reset()
	_a.storage.add(METAL, 1000)
	_configure(400, 0)
	transport.start()
	_until(func() -> bool: return _cargo("Transporter").quantity() >= 100, 60 * 120)
	transport.set_requirement(METAL, 150)
	_until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 60)
	_check("8. requirement lowered during loading (400 -> 150): stops at %d and departs" % _cargo("Transporter").quantity(),
		_cargo("Transporter").quantity() == 150 and _a.storage.quantity() == 850)
	_reset()
	_a.storage.add(METAL, 1000)
	_configure(100, 0)
	transport.start()
	_until(func() -> bool: return _cargo("Transporter").quantity() >= 50, 60 * 120)
	transport.set_requirement(METAL, 300)
	_until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 60)
	_check("8. requirement raised during loading (100 -> 300): loads %d before departing" % _cargo("Transporter").quantity(),
		_cargo("Transporter").quantity() == 300)
	_reset()
	_cargo("Transporter").add(ICE, 80) # Not required: kept and delivered.
	_a.storage.add(METAL, 1000)
	_configure(200, 0)
	transport.start()
	_until(func() -> bool: return transport.deliveries == 1, 60 * 150)
	_check("8. cargo not in the requirements is never discarded (80 Ice delivered with the 200 Metal)", _b.storage.quantity_of(ICE) == 80
		and _b.storage.quantity_of(METAL) == 200)


# 11, 12: destination full: never beyond its capacity, waits in the berth with the rest (UX round P4), resumes.
func _test_full_destination() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking("Transporter")
	var follower := _node("Transporter", "RouteFollower")
	_a.storage.add(METAL, 1000)
	_b.storage.capacity = 250
	_configure(400, 0)
	transport.start()
	var most := 0
	var blocked := -1
	for tick in 60 * 240:
		_steps(1)
		most = maxi(most, _b.storage.quantity())
		if transport.status == TransportOperation.Status.DELIVERING and docking.waiting:
			blocked = tick
			break
	_until(func() -> bool: return not _locomotion("Transporter").has_destination, 60 * 60)
	var plans: int = follower.plans
	_steps(60 * 20)
	_check("11. never beyond the destination's capacity (at most %d / 250)" % maxi(most, _b.storage.quantity()), maxi(most, _b.storage.quantity()) <= 250)
	_check("12. destination full: 150 kept aboard, waits docked at Station2 with the slot held (Waiting for Storage), no orders in 20 s",
		blocked >= 0 and _cargo("Transporter").quantity() == 150 and docking.state == Docking.State.DOCKED and _b.slot_of(_ship("Transporter")) >= 0
		and transport.activity() == "Waiting for Storage" and follower.plans == plans and transport.is_active())
	_b.storage.capacity = _b.storage_capacity
	var done := _until(func() -> bool: return transport.deliveries == 1, 60 * 120)
	_check("12. storage free: unloads the rest (400 in all) and returns to base", done >= 0 and _b.storage.quantity() == 400
		and _cargo("Transporter").quantity() == 0)


# 15, 16: manual Move / Dock pause the operation and keep its configuration; Start resumes.
func _test_manual_override_and_resume() -> void:
	_reset()
	var transport := _transport()
	_a.storage.add(METAL, 1000)
	_configure(300, 100)
	transport.start()
	_steps(120)
	_manual_move("Transporter", Vector2(-20, -50))
	_check("15. manual Move pauses the operation (Assignment Paused), configuration kept, dock request released",
		transport.status == TransportOperation.Status.PAUSED and transport.activity() == "Assignment Paused" and transport.load_station == _a
		and transport.unload_station == _b and transport.required[METAL] == 300 and transport.required[ICE] == 100
		and _docking("Transporter").state == Docking.State.NONE and transport.can_resume())
	transport.set_requirement(ICE, 0)
	transport.start()
	var done := _until(func() -> bool: return transport.deliveries == 1, 60 * 150)
	_check("16. Start / Resume restarts the saved assignment without reconfiguring and delivers", done >= 0 and _b.storage.quantity_of(METAL) == 300)
	_manual_dock("Transporter", _b)
	_check("15. manual Dock pauses it too", transport.status == TransportOperation.Status.PAUSED and _docking("Transporter").station == _b)


# 17: two docked combat ships fill the loading station; the Transporter queues.
func _test_shared_slots() -> void:
	_reset()
	var transport := _transport()
	_place("Frigate", Vector2(-10, -40))
	_place("Gunship", Vector2(-62, -40))
	_docking("Frigate").dock(_a)
	_docking("Gunship").dock(_a)
	_until(func() -> bool: return _docking("Frigate").state == Docking.State.DOCKED and _docking("Gunship").state == Docking.State.DOCKED, 60 * 90)
	_a.storage.add(METAL, 400)
	_configure(400, 0)
	_place("Transporter", Vector2(-36, 20))
	transport.start()
	_until(func() -> bool: return transport.activity() == "Waiting for Dock" and not _locomotion("Transporter").has_destination, 60 * 60)
	var queued := _a.queue_position(_ship("Transporter")) == 0 and _a.hold_of(_ship("Transporter")) >= 0
	# The east berth is released (the Frigate leaves): before stage 2b the Transporter
	# stalled permanently against it across the route from Hold1 (the west berth was used
	# here instead); the controlled exit now leaves away from the waiting ship.
	_docking("Frigate").undock()
	var loaded := _until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 180)
	_check("17. both slots taken: queued at a holding position (Waiting for Dock), docks once a slot is released, loads and leaves",
		queued and loaded >= 0 and _docking("Gunship").state == Docking.State.DOCKED and _cargo("Transporter").quantity() == 400)


# 19: empty fuel holds the ship with its assignment; refueled it carries on.
func _test_fuel() -> void:
	_reset()
	var transport := _transport()
	var fuel := _fuel("Transporter")
	_a.storage.add(METAL, 400)
	_configure(400, 0)
	fuel._set_fuel(30.5) # Just above 15 %: the trip crosses it.
	_notices.clear()
	transport.start()
	_steps(120)
	fuel._set_fuel(0.0)
	_steps(1)
	var at := _position("Transporter")
	_steps(60 * 10)
	_check("19. empty: immobilized, assignment kept (Traveling to Loading Base - Out of Fuel); low fuel warned only",
		_position("Transporter") == at and transport.status == TransportOperation.Status.LOADING
		and transport.activity() == "Traveling to Loading Base - Out of Fuel" and _notices.any(func(text: String) -> bool: return text.contains("Low Fuel")))
	fuel._set_fuel(fuel.capacity)
	var left := _until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 120)
	_check("19. refueled: carries on, loads and departs", left >= 0)


# 20: interruptions never lose or duplicate cargo.
func _test_interruption_conservation() -> void:
	_reset()
	var transport := _transport()
	_a.storage.add(METAL, 1000)
	_configure(400, 0)
	transport.start()
	_until(func() -> bool: return _cargo("Transporter").quantity() >= 200, 60 * 120)
	_manual_move("Transporter", Vector2(-20, -50))
	_steps(120)
	var loading_total := _a.storage.quantity() + _cargo("Transporter").quantity()
	transport.start()
	_until(func() -> bool: return _docking("Transporter").transfer == Docking.Transfer.UNLOAD and _b.storage.quantity() >= 100, 60 * 200)
	_manual_move("Transporter", Vector2(-110, 40))
	_steps(120)
	var unloading_total := _a.storage.quantity() + _cargo("Transporter").quantity() + _b.storage.quantity()
	_check("20. interrupted while loading (%d aboard) and while unloading (%d delivered): every unit accounted for (1000)" % [loading_total - _a.storage.quantity(),
		_b.storage.quantity()], loading_total == 1000 and unloading_total == 1000 and _docking("Transporter").transfer == Docking.Transfer.NONE)


# Miners can use either station as their base.
func _test_miners_at_either_station() -> void:
	_reset()
	var mining := _node("Miner1", "Mining") as MiningOperation
	var deposit = _field.deposit(19)
	_place("Miner1", Vector2(-75, 10))
	_cargo("Miner1").add(METAL if deposit.family == AsteroidField.Family.MINERALS else ICE, _cargo("Miner1").free_space())
	mining.set_base(_b)
	mining.assign(19)
	var back := _until(func() -> bool: return mining.activity() == "Returning to Asteroid", 60 * 120)
	_check("a Miner with Station2 as its base unloads there (%d)" % _b.storage.quantity(), back >= 0 and _b.storage.quantity() == _cargo("Miner1").capacity)
	mining.cancel()
	_docking("Miner1").cancel()
	mining.set_base(null)


func _test_panel() -> void:
	_reset()
	var transport := _transport()
	var panel := _main.get_node("ShipPanel")
	var rows := panel.get_node("Panel/Layout/Scroll/Body/Actions/Transport")
	transport.set_load_station(null) # Unconfigured, as at the start of a game.
	transport.set_unload_station(null)
	transport.set_requirement(METAL, 0)
	transport.set_requirement(ICE, 0)
	_place("Transporter", NEAR_A)
	_main.get_node("Selection").set_selection([_ship("Transporter")])
	await process_frame
	var load_at: OptionButton = rows.get_node("LoadRow/Station")
	var unload_at: OptionButton = rows.get_node("UnloadRow/Station")
	_check("panel: Transport section (no Mining section), stations nearest first in both selectors", rows.visible
		and not panel.get_node("Panel/Layout/Scroll/Body/Actions/Mining").visible and load_at.item_count == 4 and load_at.get_item_metadata(1) == _a
		and load_at.get_item_metadata(2) == _main.get_node("Stations/Shipyard") and load_at.get_item_metadata(3) == _b
		and load_at.selected == 0 and (rows.get_node("Start") as Button).disabled)
	load_at.select(1)
	load_at.item_selected.emit(1)
	unload_at.select(3) # Station2 (Phase 4: the Shipyard is listed before it from here).
	unload_at.item_selected.emit(3)
	_requirement(rows, METAL, 400) # Phase 3: one requirement row (resource, amount) replaced the Metal / Ice rows.
	_requirement(rows, ICE, 200)
	panel._process(0.0)
	_check("panel: choosing stations and quantities configures the assignment; Start enabled", transport.load_station == _a and transport.unload_station == _b
		and transport.required[METAL] == 400 and transport.required[ICE] == 200 and not (rows.get_node("Start") as Button).disabled)
	(rows.get_node("Start") as Button).pressed.emit()
	_requirement(rows, ICE, 0)
	panel._process(0.0)
	_check("panel: Start runs it (status line), editing a quantity while active does not cancel, cargo shown",
		transport.status == TransportOperation.Status.LOADING and transport.required[ICE] == 0
		and (panel.get_node("Panel/Layout/Scroll/Body/Status/Activity") as Label).text == "Status: Traveling to Loading Base"
		and (panel.get_node("Panel/Layout/Scroll/Body/Cargo/Summary") as Label).text == "Cargo: 0 / 1000 (empty)")
	_main.get_node("Selection").set_selection([])


# Sets one requirement through the panel (UX round P7: Configure Cargo, the resource's
# row in the transport editor, Apply; before, the single requirement row).
func _requirement(rows: Node, resource: StringName, amount: int) -> void:
	var editor := _main.get_node("ShipPanel/TransportEditor")
	(rows.get_node("Configure") as Button).pressed.emit()
	(editor.row(0 if Inventory.RAW.has(resource) else 1, resource).get_node("Amount") as SpinBox).value = amount
	editor.apply()
	editor.close()


func _configure(metal: int, ice: int) -> void:
	var transport := _transport()
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(METAL, metal)
	transport.set_requirement(ICE, ice)


func _reset() -> void:
	_field.generate(SEED)
	for ship_name in SHIPS:
		_docking(ship_name).phase = Docking.Phase.NONE # Stage 2b: cancel() is refused during station control.
		_docking(ship_name).hold_command(Callable())
		_docking(ship_name).cancel()
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
		_place(ship_name, PARK[ship_name])
		_fuel(ship_name)._set_fuel(_fuel(ship_name).capacity)
	for miner in ["Miner1", "Miner2"]:
		var mining := _node(miner, "Mining") as MiningOperation
		mining.cancel()
		mining.target = -1
		mining.status = MiningOperation.Status.NONE
		_cargo(miner).amounts.clear()
	var transport := _transport()
	transport.cancel()
	transport.status = TransportOperation.Status.NONE
	transport.deliveries = 0
	_cargo("Transporter").amounts.clear()
	for station: Station in [_a, _b]:
		for slot in station.slots:
			slot.ship = null
			slot.leaving = false
		for hold in station.holds:
			hold.ship = null
		station.queue.clear()
		station._exiting.clear()
		station.storage.amounts.clear()
		station.storage.capacity = station.storage_capacity
		station.fuel_stock = 1000.0
	_place("Transporter", NEAR_A)
	_notices.clear()


func _manual_move(ship_name: String, point: Vector2) -> void:
	# As the scene input does for a MOVE: order, then pause automation and release docking.
	_node(ship_name, "RouteFollower").order(point)
	_transport().cancel()
	_docking(ship_name).cancel()


func _manual_dock(ship_name: String, station: Station) -> void:
	# As the scene input does for a right-click on a station.
	_transport().cancel()
	_docking(ship_name).dock(station)


func _until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_steps(1)
	print("    timeout: Transporter %s / dock %s at %s, cargo %d" % [_transport().activity(), _docking("Transporter").state_name(),
		_position("Transporter"), _cargo("Transporter").quantity()])
	return -1


func _steps(count: int) -> void:
	for i in count:
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_locomotion(ship_name)._step(DT)
		for ship_name in SHIPS:
			for child in ["Mining", "Transport"]:
				var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
				if node != null:
					node._physics_process(DT)
			_docking(ship_name)._physics_process(DT)
			_fuel(ship_name)._physics_process(DT)
		for station in _main.get_node("Stations").get_children():
			station._physics_process(DT)


func _place(ship_name: String, point: Vector2) -> void:
	_locomotion(ship_name).place(point, 0.0)


func _position(ship_name: String) -> Vector2:
	return _locomotion(ship_name).planar_position


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _locomotion(ship_name: String) -> ShipLocomotion:
	return _node(ship_name, "Locomotion") as ShipLocomotion


func _cargo(ship_name: String) -> Inventory:
	return _node(ship_name, "Cargo").inventory


func _fuel(ship_name: String) -> Fuel:
	return _node(ship_name, "Fuel") as Fuel


func _docking(ship_name: String) -> Docking:
	return _node(ship_name, "Docking") as Docking


func _transport() -> TransportOperation:
	return _node("Transporter", "Transport") as TransportOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
