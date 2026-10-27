extends SceneTree
## Headless Phase 2 Stage 4 checks on the playable main scene: fuel consumption by
## committed movement (every hull), standing, blocked and rotating ships, the three
## warnings, empty tanks (ship immobilized without translation or rotation, orders
## kept, new orders accepted, scanning, treated as stationary by avoidance and
## passed by other ships), restored movement and turning, automatic refueling at the station (every hull), station fuel
## accounting (shared, insufficient and empty stock), undocking, docking and cargo
## transfers with fuel active, panel and hover. Ship physics is stepped manually at
## 60 Hz in the game's order (per ship RouteFollower then Avoidance, then
## Locomotion, then Mining, Docking and Fuel, then the station).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/fuel_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const Inventory := preload("res://game/cargo/inventory.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const Fuel := preload("res://game/fuel/fuel.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const ShipAvoidance := preload("res://game/avoidance/ship_avoidance.gd")
const DT := 1.0 / 60.0
const EPS := 0.000001
const SHIPS := ["Miner3", "Transporter", "FF01", "Miner1", "Miner2"]
const HULLS := ["Miner3", "Transporter", "FF01", "Miner1"]
const PARK := {"Miner3": Vector2(40, 30), "Transporter": Vector2(40, 15), "FF01": Vector2(40, -5), "Miner1": Vector2(40, -20), "Miner2": Vector2(40, -32)}
const STARTS := [Vector2(-10, -40), Vector2(-10, 2), Vector2(-62, -40), Vector2(-62, 2)] # Near the station, off its approach lanes.

var _failures := 0
var _checks := 0
var _main: Node
var _station: Station
var _navigation: Node
var _notices: Array = [] # [text, fuel ratio of the ship when given]


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	# One ship per hull class besides the scene's Miners and Transporter: a third Miner and an FF-01.
	for added: Array in [["Miner3", "res://game/ships/miner_unit.tscn", Vector3(-12, 1.5, 0)], ["FF01", "res://game/ships/ff01_unit.tscn", Vector3(14, 1.5, 0)]]:
		var ship: Node3D = load(added[1]).instantiate()
		ship.name = added[0]
		ship.position = added[2]
		_main.get_node("Ships").add_child(ship)
	root.add_child(_main)
	_station = _main.get_node("Stations/Station")
	_navigation = _main.get_node("StaticNavigation")
	_main.get_node("Survey").set_physics_process(false)
	_station.set_physics_process(false)
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.set_physics_process(false)
		var fuel := _fuel(ship_name)
		fuel.notice.connect(func(text: String) -> void: _notices.append([text, fuel.ratio()]))
	for ship_name in SHIPS:
		while not _navigation.is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame

	_test_setup()
	_test_consumption()
	_test_unchanged_movement()
	_test_standing_and_rotation()
	_test_blocked()
	_test_warnings_and_empty()
	await _test_orders_when_empty()
	_test_stranded_encounters()
	_test_empty_every_hull()
	_test_refuel_every_hull()
	_test_undock_interrupts()
	_test_station_stock()
	_test_docking_and_cargo()
	_test_panel_and_hover()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _test_setup() -> void:
	var all := true
	for ship_name in SHIPS:
		var fuel := _fuel(ship_name)
		all = all and fuel != null and is_equal_approx(fuel.fuel, fuel.capacity) and _locomotion(ship_name).propulsion
	_check("every ship has a Fuel node, starts full with propulsion on", all)
	_check("station has a separate fuel stock (1000 / 2000), storage untouched", is_equal_approx(_station.fuel_stock, 1000.0)
		and is_equal_approx(_station.fuel_capacity, 2000.0) and _station.storage.quantity() == 0)


# 1. Fuel used = consumption x the sum of committed displacements, for every hull.
func _test_consumption() -> void:
	for ship_name in SHIPS:
		_reset()
		var fuel := _fuel(ship_name)
		_place(ship_name, Vector2(-15, -10))
		_node(ship_name, "RouteFollower").order(Vector2(15, -10))
		var committed := 0.0
		var traveled := 0.0
		var ticks := 0
		while _locomotion(ship_name).has_destination and ticks < 60 * 60:
			var last := _position(ship_name)
			_steps(1)
			ticks += 1
			committed += _locomotion(ship_name).committed_motion.length()
			traveled += _position(ship_name).distance_to(last)
		var used := fuel.capacity - fuel.fuel
		_check("%s: fuel used %.3f = %.2f/u x %.3f u traveled (%.1f s)" % [ship_name, used, fuel.consumption, traveled, ticks * DT],
			ticks > 0 and absf(used - fuel.consumption * committed) < EPS and absf(committed - traveled) < 0.0001 and traveled > 29.9)


# With fuel available the ships move exactly as without the Fuel node stepping.
func _test_unchanged_movement() -> void:
	var tracks := []
	var used := 0.0
	for with_fuel in [true, false]:
		_reset()
		_place("Transporter", Vector2(-15, -10))
		_node("Transporter", "RouteFollower").order(Vector2(20, 12))
		var track := []
		for tick in 60 * 20:
			_steps(1, with_fuel)
			track.append(_position("Transporter"))
		tracks.append(track)
		if with_fuel:
			used = _fuel("Transporter").capacity - _fuel("Transporter").fuel
	_check("with fuel (%.2f used), the Transporter's route is identical tick by tick to one without fuel processing" % used,
		tracks[0] == tracks[1] and used > 1.0)


# 2 and 4: no fuel standing still or rotating in place.
func _test_standing_and_rotation() -> void:
	_reset()
	_place("Miner3", Vector2(0, 0))
	_steps(300)
	_check("a stationary ship uses no fuel (5 s)", _fuel("Miner3").fuel == _fuel("Miner3").capacity)
	var locomotion := _locomotion("FF01")
	var fuel := _fuel("FF01")
	_place("FF01", Vector2(0, -10))
	locomotion._target_heading = 3.0 # Rotate in place, no destination.
	_steps(60 * 3)
	var turning := rad_to_deg(absf(locomotion.angular_velocity))
	fuel._set_fuel(0.0)
	var heading := locomotion.heading
	var held := true
	for tick in 180:
		_steps(1)
		held = held and locomotion.heading == heading and locomotion.angular_velocity == 0.0
	_check("empty: a turning ship stops turning at once (was %.1f deg/s), heading held, no turn rate kept" % turning, turning > 5.0 and held)
	fuel._set_fuel(fuel.capacity)
	_steps(60 * 12)
	_check("refueled: the turn resumes and completes; rotation alone used no fuel (FF01 turned %.2f rad in place)" % absf(locomotion.heading),
		absf(locomotion.heading - 3.0) < 0.01 and _position("FF01") == Vector2(0, -10) and fuel.fuel == fuel.capacity)


# 3. Pushing into the station: only the committed (not the proposed) motion uses fuel.
func _test_blocked() -> void:
	_reset()
	var locomotion := _locomotion("Miner3")
	_place("Miner3", Vector2(-36, -14))
	locomotion.move_to(Vector2(-36, -30)) # Straight into the station's body (no route).
	_run_until(func() -> bool: return not locomotion.contacts.is_empty(), 600)
	var before := _fuel("Miner3").fuel
	var proposed := 0.0
	var committed := 0.0
	for tick in 300:
		_steps(1)
		proposed += locomotion.proposed_motion.length()
		committed += locomotion.committed_motion.length()
	var used := before - _fuel("Miner3").fuel
	_check("collision-blocked movement uses no fuel (5 s pushing: proposed %.3f u, committed %.4f u, used %.5f)" % [proposed, committed, used],
		proposed > 0.4 and committed < proposed * 0.02 and absf(used - committed * _fuel("Miner3").consumption) < EPS and locomotion.has_destination)


# 5, 6, 8, 9, 10 and the depletion cycle (Miner3, consumption 1 per u for a short run).
func _test_warnings_and_empty() -> void:
	_reset()
	var fuel := _fuel("Miner3")
	var locomotion := _locomotion("Miner3")
	fuel.consumption = 1.0
	fuel._set_fuel(15.5)
	_notices.clear()
	_place("Miner3", Vector2(-20, 0))
	_node("Miner3", "RouteFollower").order(Vector2(20, 0))
	var lowest := INF
	for tick in 60 * 60:
		if fuel.fuel <= 0.0:
			break
		_steps(1)
		lowest = minf(lowest, fuel.fuel)
	var texts := _notices.map(func(entry: Array) -> String: return entry[0])
	_check("warnings in order: Low Fuel, Fuel Warning, Critical Fuel, then out of fuel", texts.size() == 4 and texts[0].contains("Low Fuel")
		and texts[1].contains("Fuel Warning") and texts[2].contains("Critical Fuel") and texts[3].contains("out of fuel"))
	var crossed := texts.size() == 4
	for i in mini(3, _notices.size()):
		var threshold: float = Fuel.THRESHOLDS[i]
		crossed = crossed and _notices[i][1] < threshold and _notices[i][1] > threshold - 0.002
	_check("each warning given as the fuel crossed 15 %, 10 %, 5 %", crossed)
	var at := _position("Miner3")
	var heading := locomotion.heading
	var held := true
	for tick in 300:
		_steps(1)
		held = held and _position("Miner3") == at and locomotion.heading == heading and locomotion.velocity == Vector2.ZERO
		held = held and locomotion.angular_velocity == 0.0 and not locomotion.propulsion
	_check("empty: immobilized (position and heading held, no linear or angular velocity), fuel exactly 0 (never negative)",
		held and fuel.fuel == 0.0 and lowest >= 0.0)
	_check("warnings not repeated while below the thresholds (5 s empty)", _notices.size() == 4)
	_check("empty: the order stays assigned", locomotion.has_destination and locomotion.destination.distance_to(Vector2(20, 0)) < 0.3
		and _node("Miner3", "RouteFollower").status != 0)
	_check("scanning is usable when empty and uses no fuel", _node("Miner3", "Scanner").activate() and fuel.fuel == 0.0)
	fuel._set_fuel(50.0)
	_steps(1)
	var first_speed := locomotion.velocity.length()
	_run_until(func() -> bool: return not locomotion.has_destination, 60 * 60)
	_check("restored fuel: starts again from rest (%.3f u/s after one tick) and completes the order" % first_speed,
		first_speed > 0.0 and first_speed <= locomotion.forward_accel * DT + EPS and _position("Miner3").distance_to(Vector2(20, 0)) < 0.1)
	_notices.clear()
	_node("Miner3", "RouteFollower").order(Vector2(-20, 0))
	fuel._set_fuel(15.5)
	_run_until(func() -> bool: return fuel.fuel <= 0.0, 60 * 60)
	_check("after refueling the warnings are given again in the next depletion", _notices.size() == 4)
	fuel.consumption = 0.25


# 7. With an empty tank a right-click still gives the ship a new order (behind it):
# accepted, but the ship neither moves nor turns toward it until refueled.
func _test_orders_when_empty() -> void:
	_reset()
	var fuel := _fuel("Miner3")
	var locomotion := _locomotion("Miner3")
	_place("Miner3", Vector2(0, 0))
	fuel._set_fuel(0.0)
	_frame(Vector2(0, 0), 30.0)
	_main.get_node("Selection").set_selection([_ship("Miner3")])
	await process_frame
	var camera: Camera3D = _main.get_node("CameraRig/Camera3D")
	var target := Vector3(12, 0, 10)
	var follower := _node("Miner3", "RouteFollower")
	var plans: int = follower.plans
	_right_click(camera.unproject_position(target))
	_steps(120)
	_check("empty: a right-click MOVE is accepted (new destination); the ship neither moves nor turns toward it", follower.plans == plans + 1
		and follower.requested.distance_to(Vector2(target.x, target.z)) < 0.3 and locomotion.has_destination
		and _position("Miner3") == Vector2(0, 0) and locomotion.heading == 0.0 and locomotion.angular_velocity == 0.0)
	fuel._set_fuel(fuel.capacity)
	_run_until(func() -> bool: return not locomotion.has_destination, 60 * 60)
	_check("refueled: turns (heading %.2f rad) and flies to the order given while empty" % locomotion.heading,
		absf(locomotion.heading) > 1.5 and _position("Miner3").distance_to(Vector2(target.x, target.z)) < 0.1)
	_main.get_node("Selection").set_selection([])


# A stranded ship (empty, order kept) reports no available speed, so avoidance
# treats it as stationary and passes it (the eight encounters of the investigation).
func _test_stranded_encounters() -> void:
	const CASES := [
		# [stranded ship, its order, mover, mover start, mover destination]; stranded at (0, 0)
		["Miner3", Vector2(30, 0), "Transporter", Vector2(-25, 0), Vector2(25, 0)],
		["Miner3", Vector2(-30, 0), "Transporter", Vector2(-25, 0), Vector2(25, 0)],
		["Miner3", Vector2(0, 30), "Transporter", Vector2(-25, 0), Vector2(25, 0)],
		["Transporter", Vector2(30, 0), "Miner3", Vector2(-25, 0), Vector2(25, 0)],
		["Transporter", Vector2(-30, 0), "Miner3", Vector2(-25, 0), Vector2(25, 0)],
		["FF01", Vector2(0, -30), "Miner3", Vector2(-25, 0), Vector2(25, 0)],
		["FF01", Vector2(-30, 0), "Transporter", Vector2(-25, 3), Vector2(25, 3)],
		["Miner3", Vector2(30, 0), "FF01", Vector2(-25, 0), Vector2(25, 0)],
	]
	var all_waiting := true
	var results: Array[String] = []
	var passed := 0
	for c: Array in CASES:
		_reset()
		var stranded := _locomotion(c[0])
		var mover := _locomotion(c[2])
		_place(c[0], Vector2.ZERO)
		_place(c[2], c[3])
		_fuel(c[0])._set_fuel(0.0)
		_node(c[0], "RouteFollower").order(c[1])
		_node(c[2], "RouteFollower").order(c[4])
		var ticks := 0
		while mover.has_destination and ticks < 60 * 90:
			_steps(1)
			ticks += 1
			all_waiting = all_waiting and ShipAvoidance._is_waiting(stranded)
		var contacts := mover.collision_count + stranded.collision_count
		var ok := not mover.has_destination and contacts == 0 and stranded.planar_position == Vector2.ZERO and stranded.has_destination
		passed += 1 if ok else 0
		results.append("%.1f s%s" % [ticks * DT, "" if ok else " FAIL (%d contacts)" % contacts])
	_check("a stranded ship (order kept) counts as waiting, i.e. stationary, for avoidance in every encounter", all_waiting)
	_check("8 encounters: the mover passes the stranded ship, 0 contacts (%s)" % ", ".join(results), passed == CASES.size())
	_fuel(CASES[5][0])._set_fuel(_fuel(CASES[5][0]).capacity) # Last placed again: the FF01, order clear of the mover.
	_steps(1)
	var restored := _locomotion(CASES[5][0])
	_check("refueled: normal speed reporting (not waiting), then completes its order", not ShipAvoidance._is_waiting(restored)
		and restored.avoidance_cap == INF and _run_until(func() -> bool: return not restored.has_destination, 60 * 60) >= 0)


# 8-10 for every hull: stop at zero mid-route, order kept, moves again with fuel.
func _test_empty_every_hull() -> void:
	for ship_name in HULLS:
		_reset()
		var fuel := _fuel(ship_name)
		var locomotion := _locomotion(ship_name)
		_place(ship_name, Vector2(-15, -10))
		_node(ship_name, "RouteFollower").order(Vector2(15, -10))
		_run_until(func() -> bool: return locomotion.velocity.length() > locomotion.max_speed * 0.6, 60 * 30)
		var speed := locomotion.velocity.length()
		fuel._set_fuel(0.0)
		_steps(1)
		var at := _position(ship_name)
		_steps(120)
		var stopped := _position(ship_name) == at and locomotion.velocity == Vector2.ZERO and locomotion.has_destination
		fuel._set_fuel(fuel.capacity)
		_run_until(func() -> bool: return not locomotion.has_destination, 60 * 60)
		_check("%s: stops at zero from %.2f u/s (one more tick at most), keeps its order, completes it once refueled" % [ship_name, speed],
			stopped and _position(ship_name).distance_to(Vector2(15, -10)) < 0.1)


# 11, 12, 14 for every hull: docked ships refuel at the station's rate up to capacity.
func _test_refuel_every_hull() -> void:
	for ship_name in HULLS:
		_reset()
		var fuel := _fuel(ship_name)
		fuel._set_fuel(fuel.capacity * 0.2)
		_place(ship_name, STARTS[0])
		_docking(ship_name).dock(_station)
		var docked := _run_until(func() -> bool: return _docking(ship_name).state == Docking.State.DOCKED, 60 * 120)
		var at_dock := fuel.fuel
		var stock := _station.fuel_stock
		_steps(60)
		var gained := fuel.fuel - at_dock
		var one_second := docked >= 0 and absf(gained - _station.refuel_rate) < 0.0001 and absf((stock - _station.fuel_stock) - gained) < EPS
		_run_until(func() -> bool: return not fuel.refueling, 60 * 120)
		_steps(60)
		_check("%s: docked refuels %.2f units in 1 s, then to %.1f / %.0f; station lost exactly what was delivered" % [ship_name, gained, fuel.fuel, fuel.capacity],
			one_second and fuel.fuel <= fuel.capacity and is_equal_approx(fuel.fuel, fuel.capacity)
			and absf((stock - _station.fuel_stock) - (fuel.fuel - at_dock)) < 0.0001 and fuel.warned == 0)


# 15. Undocking stops refueling.
func _test_undock_interrupts() -> void:
	_reset()
	var fuel := _fuel("Transporter")
	fuel._set_fuel(20.0)
	_place("Transporter", STARTS[0])
	_docking("Transporter").dock(_station)
	_run_until(func() -> bool: return _docking("Transporter").state == Docking.State.DOCKED, 60 * 120)
	_steps(60)
	_docking("Transporter").undock()
	var stock := _station.fuel_stock
	var at := fuel.fuel
	_steps(300)
	_check("undocking stops refueling (station stock unchanged, tank only used since: %.1f -> %.1f)" % [at, fuel.fuel],
		_station.fuel_stock == stock and fuel.fuel < at and not fuel.refueling and fuel.fuel < fuel.capacity)


# 12, 13, 17: shared, insufficient and empty station stock.
func _test_station_stock() -> void:
	_reset()
	_station.fuel_stock = 0.0 # Until both are docked.
	var ff01 := _fuel("FF01")
	var transporter := _fuel("Transporter")
	ff01._set_fuel(60.0)
	transporter._set_fuel(20.0)
	_place("FF01", STARTS[0])
	_place("Transporter", STARTS[3])
	_docking("FF01").dock(_station)
	_docking("Transporter").dock(_station)
	var docked := _run_until(func() -> bool: return _docking("FF01").state == Docking.State.DOCKED and _docking("Transporter").state == Docking.State.DOCKED, 60 * 120)
	_station.fuel_stock = 150.0
	var before := [ff01.fuel, transporter.fuel]
	var lowest := INF
	for tick in 60 * 10:
		_steps(1)
		lowest = minf(lowest, _station.fuel_stock)
	var gains := [ff01.fuel - before[0], transporter.fuel - before[1]]
	_check("two docked ships share one stock of 150: %.2f + %.2f delivered, stock 0, never negative" % gains,
		docked >= 0 and absf(gains[0] - 75.0) < 0.0001 and absf(gains[1] - 75.0) < 0.0001 and _station.fuel_stock == 0.0 and lowest >= 0.0)
	var held := [ff01.fuel, transporter.fuel]
	_steps(120)
	_check("empty station stock: docked ships stay docked without refueling, no errors", ff01.fuel == held[0] and transporter.fuel == held[1]
		and not ff01.refueling and not transporter.refueling and _docking("FF01").state == Docking.State.DOCKED)
	_station.fuel_stock = 30.0
	_steps(60 * 5)
	_check("insufficient stock: exactly the remaining 30 units are delivered", absf(ff01.fuel + transporter.fuel - held[0] - held[1] - 30.0) < 0.0001
		and _station.fuel_stock == 0.0)
	_station.fuel_stock = _station.fuel_capacity
	_steps(60 * 30)
	_check("plenty of stock: both tanks full, not beyond capacity", ff01.fuel == ff01.capacity and transporter.fuel == transporter.capacity)


# 16. Docking queue and cargo transfers work with fuel processing active.
func _test_docking_and_cargo() -> void:
	_reset()
	var cargo: Inventory = _node("Miner1", "Cargo").inventory
	cargo.add(&"iron", 300)
	_fuel("Miner1")._set_fuel(30.0)
	_place("Miner1", STARTS[0])
	_place("Miner3", STARTS[3])
	_docking("Miner1").dock(_station)
	_docking("Miner3").dock(_station)
	_run_until(func() -> bool: return _docking("Miner1").state == Docking.State.DOCKED and _docking("Miner3").state == Docking.State.DOCKED, 60 * 120)
	_place("Transporter", STARTS[2])
	_docking("Transporter").dock(_station)
	_steps(1)
	var waited := _docking("Transporter").state == Docking.State.WAITING
	_docking("Miner1").unload()
	_run_until(func() -> bool: return _docking("Miner1").transfer == Docking.Transfer.NONE, 60 * 30)
	_check("docked miner unloads (300 units) while refueling", cargo.quantity() == 0 and _station.storage.quantity() == 300 and _fuel("Miner1").fuel > 30.0)
	_docking("Miner1").load_cargo(&"iron", 100)
	_run_until(func() -> bool: return _docking("Miner1").transfer == Docking.Transfer.NONE, 60 * 30)
	_check("docked miner loads 100 units back", cargo.quantity() == 100 and _station.storage.quantity() == 200)
	_docking("Miner3").undock()
	var docked := _run_until(func() -> bool: return _docking("Transporter").state == Docking.State.DOCKED, 60 * 180)
	_check("queue: third ship waited, got the released slot and docked", waited and docked >= 0)


func _test_panel_and_hover() -> void:
	_reset()
	var panel := _main.get_node("ShipPanel")
	var rows := panel.get_node("Panel/Layout/Scroll/Body/Status/Fuel")
	_fuel("Miner3")._set_fuel(12.0)
	_main.get_node("Selection").set_selection([_ship("Miner3")])
	panel._process(0.0)
	_check("panel: fuel quantity, capacity, percentage, bar and warning", rows.visible and rows.get_node("Amount").text == "Fuel: 12.0 / 100 (12%)"
		and is_equal_approx(rows.get_node("Bar").value, 0.12) and rows.get_node("Status").text == "Low Fuel")
	_place("Miner3", STARTS[0])
	_docking("Miner3").dock(_station)
	_run_until(func() -> bool: return _docking("Miner3").state == Docking.State.DOCKED, 60 * 120)
	_steps(1)
	panel._process(0.0)
	var refueling: String = rows.get_node("Status").text
	_station.fuel_stock = 0.0
	_steps(1)
	panel._process(0.0)
	_check("panel: refueling status while docked (\"%s\", then \"%s\")" % [refueling, rows.get_node("Status").text],
		refueling.ends_with("Refueling") and rows.get_node("Status").text.ends_with("Station out of fuel"))
	_main.get_node("Selection").set_selection([_ship("FF01")])
	panel._process(0.0)
	_check("panel: combat ships show fuel too", rows.visible and rows.get_node("Amount").text.begins_with("Fuel: 400.0 / 400") and not rows.get_node("Status").visible)
	_check("station hover shows its fuel stock", _station.describe().contains("Fuel: 0 / 2000"))
	_main.get_node("Selection").set_selection([])


func _reset() -> void:
	for ship_name in SHIPS:
		_docking(ship_name).phase = Docking.Phase.NONE # Stage 2b: cancel() is refused during station control.
		_docking(ship_name).hold_command(Callable())
		_docking(ship_name).cancel()
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
		_place(ship_name, PARK[ship_name])
		var fuel := _fuel(ship_name)
		fuel._set_fuel(fuel.capacity)
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
	_station.fuel_stock = 1000.0
	_notices.clear()


func _run_until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_steps(1)
	for ship_name in SHIPS: # Diagnostics for the failing wait.
		var locomotion := _locomotion(ship_name)
		print("    timeout: %-9s %-28s at (%.1f, %.1f) moving %s fuel %.2f" % [ship_name, _docking(ship_name).state_name(),
			locomotion.planar_position.x, locomotion.planar_position.y, locomotion.has_destination, _fuel(ship_name).fuel])
	return -1


func _steps(count: int, with_fuel := true) -> void:
	for i in count:
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_locomotion(ship_name)._step(DT)
		for ship_name in SHIPS:
			var mining := _main.get_node_or_null("Ships/%s/Mining" % ship_name)
			if mining != null:
				mining._physics_process(DT)
			_docking(ship_name)._physics_process(DT)
			if with_fuel:
				_fuel(ship_name)._physics_process(DT)
		_station._physics_process(DT)


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
	_locomotion(ship_name).place(point, 0.0)


func _position(ship_name: String) -> Vector2:
	return _locomotion(ship_name).planar_position


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _locomotion(ship_name: String) -> ShipLocomotion:
	return _node(ship_name, "Locomotion") as ShipLocomotion


func _fuel(ship_name: String) -> Fuel:
	return _node(ship_name, "Fuel") as Fuel


func _docking(ship_name: String) -> Docking:
	return _node(ship_name, "Docking") as Docking


func _mining(miner: String) -> MiningOperation:
	return _node(miner, "Mining") as MiningOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-110s %s" % [label, "PASS" if ok else "FAIL"])
