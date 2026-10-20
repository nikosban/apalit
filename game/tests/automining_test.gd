extends SceneTree
## Headless Phase 2 Stage 5 checks on the playable main scene: the automated mining
## cycle (travel, extraction, return to the nearest or chosen base through the
## existing docking, timed unload, refueling, back to the same asteroid), three
## unattended cycles, depletion, full station storage, base selection, manual
## interruption and Resume, fuel, two miners sharing the station, and the panel.
## Ship physics is stepped manually at 60 Hz in the game's order (per ship
## RouteFollower then Avoidance, then Locomotion, then Mining, Docking and Fuel,
## then the station). Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/automining_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const STATION := preload("res://game/stations/station.tscn")
const Inventory := preload("res://game/cargo/inventory.gd")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const Fuel := preload("res://game/fuel/fuel.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2"]
const PARK := {"Frigate": Vector2(40, 30), "Gunship": Vector2(40, 15), "Destroyer": Vector2(40, -5), "Miner1": Vector2(40, -20), "Miner2": Vector2(40, -32)}
const SEED := 20261014
const ASTEROID := 19 # Nearest the station (as in docking_test).
const NEAR := Vector2(-60, -12) # Miner start near that asteroid.
const SMALL_HOLD := 200 # Cargo capacity for the quicker checks.

var _failures := 0
var _checks := 0
var _main: Node
var _station: Station
var _field: Node
var _navigation: Node
var _notices: Array[String] = []


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
		for child in ["Mining", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.notice.connect(func(text: String) -> void: _notices.append(text))
	for ship_name in SHIPS:
		while not _navigation.is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame

	_test_one_cycle()
	_test_three_cycles()
	_test_depletion()
	_test_base_selection()
	_test_full_storage()
	_test_two_miners()
	_test_manual_orders_and_resume()
	_test_interruptions()
	_test_fuel()
	_test_panel()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# 1-3, 5-11: one complete cycle with a small hold, no base chosen.
func _test_one_cycle() -> void:
	_reset(SMALL_HOLD)
	var mining := _mining("Miner1")
	var docking := _docking("Miner1")
	var fuel := _fuel("Miner1")
	var cargo := _cargo("Miner1")
	var follower := _node("Miner1", "RouteFollower")
	fuel._set_fuel(50.0)
	_field.deposit(ASTEROID).reserves = 1000
	var composition: Dictionary = _field.deposit(ASTEROID).composition
	var plans: int = follower.plans
	mining.assign(ASTEROID)
	_check("1. one assignment starts the cycle: Traveling to Asteroid", mining.status == MiningOperation.Status.TRAVELING
		and mining.activity() == "Traveling to Asteroid")
	var mined := _until(func() -> bool: return mining.status == MiningOperation.Status.MINING, 60 * 60)
	_check("2. reaches its working position and extracts (%.1f s)" % (mined * DT), mined >= 0
		and _node("Miner1", "Extractor").in_range(ASTEROID))
	var full := _until(func() -> bool: return mining.status == MiningOperation.Status.RETURNING, 60 * 60)
	_check("3. full cargo (%d / %d) starts the return to base on its own" % [cargo.quantity(), cargo.capacity], full >= 0
		and cargo.quantity() == SMALL_HOLD and mining.activity().begins_with("Returning to Base"))
	_check("5. no base chosen: the nearest eligible station", mining.base == null and mining.trip_base == _station
		and docking.station == _station)
	_check("6. the existing docking request: a slot reserved in the station", _station.slot_of(_ship("Miner1")) >= 0
		and docking.state == Docking.State.APPROACHING)
	var aboard := cargo.amounts.duplicate()
	_until(func() -> bool: return docking.state == Docking.State.DOCKED, 60 * 60)
	var at_dock := fuel.fuel # Fuel's first refueling tick is the docking tick itself: both read after it.
	var stock := _station.fuel_stock
	_steps(30)
	_check("7. docked: unloads with the timed transfer (Unloading %d left)" % cargo.quantity(), docking.transfer == Docking.Transfer.UNLOAD
		and mining.activity() == "Unloading" and cargo.quantity() > SMALL_HOLD - 40 and cargo.quantity() < SMALL_HOLD)
	var undocked := _until(func() -> bool: return mining.activity() == "Leaving Base", 60 * 60)
	var storage := _station.storage
	_check("8. station storage gained exactly what the ship unloaded: %d" % storage.quantity(), undocked >= 0
		and storage.quantity() == SMALL_HOLD and cargo.quantity() == 0)
	# Phase 3: replaces "lot composition unchanged (same family, composition and quantity)".
	_check("9. every resource unloaded unchanged (%s), only the asteroid's resources" % storage.describe(), storage.amounts == aboard
		and aboard.keys().all(func(resource: StringName) -> bool: return composition.has(resource)))
	_check("10. refueled before leaving: %.1f -> %.1f, station stock fell by the same" % [at_dock, fuel.fuel], fuel.fuel == fuel.capacity
		and absf((stock - _station.fuel_stock) - (fuel.capacity - at_dock)) < 0.0001)
	_until(func() -> bool: return mining.status == MiningOperation.Status.TRAVELING, 60 * 60)
	_check("11a. undocked and the slot released before heading back", _station.slot_of(_ship("Miner1")) < 0
		and docking.state == Docking.State.NONE and mining.activity() == "Returning to Asteroid")
	var again := _until(func() -> bool: return mining.status == MiningOperation.Status.MINING, 60 * 60)
	_check("11b. resumes extraction at the same asteroid (%d orders in the whole cycle)" % (follower.plans - plans), again >= 0
		and mining.target == ASTEROID and _node("Miner1", "Extractor").in_range(ASTEROID) and follower.plans - plans <= 6)


# 12: three full loads unattended from one assignment (default hold), the last one
# depleting the asteroid.
func _test_three_cycles() -> void:
	_reset(-1)
	var mining := _mining("Miner1")
	var follower := _node("Miner1", "RouteFollower")
	var capacity := _cargo("Miner1").capacity
	_field.deposit(ASTEROID).reserves = 3 * capacity
	var plans: int = follower.plans
	mining.assign(ASTEROID)
	var unloads := 0
	var was_unloading := false
	var ticks := 0
	while mining.status != MiningOperation.Status.DEPLETED and ticks < 60 * 60 * 10:
		_steps(1)
		ticks += 1
		var unloading := _docking("Miner1").transfer == Docking.Transfer.UNLOAD
		if was_unloading and not unloading:
			unloads += 1
		was_unloading = unloading
	var contacts: int = _node("Miner1", "Locomotion").collision_count
	_check("12. three cycles from one assignment: %d unloads, %d units delivered, %d orders, %.0f s, %d contacts" % [unloads,
		_station.storage.quantity(), follower.plans - plans, ticks * DT, contacts], unloads == 3
		and _station.storage.quantity() == 3 * capacity and mining.status == MiningOperation.Status.DEPLETED and contacts == 0
		and follower.plans - plans <= 3 * 4 + 1)


# 13, 14: depletion with a partial load returns, unloads, refuels, then waits.
func _test_depletion() -> void:
	_reset(SMALL_HOLD)
	var mining := _mining("Miner1")
	var follower := _node("Miner1", "RouteFollower")
	_field.deposit(ASTEROID).reserves = 130
	mining.assign(ASTEROID)
	_until(func() -> bool: return mining.status == MiningOperation.Status.RETURNING, 60 * 60)
	_check("13. depletion with partial cargo (130) starts a final return", _cargo("Miner1").quantity() == 130
		and mining.activity() == "Returning to Base (asteroid depleted)")
	var done := _until(func() -> bool: return mining.status == MiningOperation.Status.DEPLETED, 60 * 90)
	var plans: int = follower.plans
	_steps(60 * 20)
	_check("14. after unloading it undocks and waits for a new target (no new orders in 20 s)", done >= 0
		and _station.storage.quantity() == 130 and _cargo("Miner1").quantity() == 0 and follower.plans == plans
		and _station.slot_of(_ship("Miner1")) < 0 and mining.target == ASTEROID and not mining.is_active()
		and mining.activity() == "Asteroid Depleted - select a new target")
	mining.resume()
	_check("14. Resume is unavailable for the depleted asteroid (nothing happens)", not mining.can_resume()
		and mining.status == MiningOperation.Status.DEPLETED and follower.plans == plans)


# 4, 5 and no eligible base, with a second station added for this check only (not a
# navigation obstacle: navigation reads obstacles once at start).
func _test_base_selection() -> void:
	_reset(SMALL_HOLD)
	var far: Station = STATION.instantiate()
	far.position = Vector3(0, 1.5, 25)
	_main.get_node("Stations").add_child(far)
	var mining := _mining("Miner1")
	_place("Miner1", NEAR)
	var bases := mining.eligible_bases()
	_check("eligible bases sorted by distance (no names or scene paths)", bases.size() == 4 and bases[0] == _station
		and bases[1] == _main.get_node("Stations/Station2") and bases[2] == far and bases[3] == _main.get_node("Stations/Shipyard"))
	_fill("Miner1")
	mining.set_base(far)
	mining.assign(ASTEROID)
	_check("4. the chosen base is used even though another is nearer", mining.status == MiningOperation.Status.RETURNING
		and mining.trip_base == far and _docking("Miner1").station == far)
	_reset(SMALL_HOLD)
	_place("Miner1", NEAR)
	_fill("Miner1")
	mining.set_base(null)
	mining.assign(ASTEROID)
	_check("5. no base chosen: the nearer station", mining.trip_base == _station)
	_reset(SMALL_HOLD)
	_place("Miner1", NEAR)
	_fill("Miner1")
	for berth in far.berths: # Docking positions (the berths) off the map: unreachable.
		berth.position += Vector3(400, 0, 400)
	mining.set_base(far)
	_notices.clear()
	mining.assign(ASTEROID)
	_check("chosen base not eligible: Cargo Full - No Eligible Base, no silent change of base, no order", mining.status == MiningOperation.Status.CARGO_FULL
		and mining.activity() == "Cargo Full - No Eligible Base" and _docking("Miner1").state == Docking.State.NONE
		and _notices.has("Miner1: no eligible base - waiting"))
	mining.set_base(null)
	_main.get_node("Stations").remove_child(far)
	far.free()


# 15, 16: a full station: partial unload, waits at a holding position with the rest,
# assignment active, no repeated orders; resumes once storage is free.
func _test_full_storage() -> void:
	_reset(SMALL_HOLD)
	var mining := _mining("Miner1")
	var docking := _docking("Miner1")
	var follower := _node("Miner1", "RouteFollower")
	_station.storage.capacity = 50
	_field.deposit(ASTEROID).reserves = 1000
	_place("Miner1", NEAR)
	_fill("Miner1")
	mining.assign(ASTEROID)
	var blocked := _until(func() -> bool: return docking.state == Docking.State.BLOCKED, 60 * 90)
	_until(func() -> bool: return not _node("Miner1", "Locomotion").has_destination, 60 * 60)
	var plans: int = follower.plans
	_steps(60 * 30)
	_check("15. full station: 50 unloaded, 150 kept aboard, waits at a holding position (Waiting for Storage), no new orders in 30 s",
		blocked >= 0 and _station.storage.quantity() == 50 and _cargo("Miner1").quantity() == 150 and _station.hold_of(_ship("Miner1")) >= 0
		and _station.slot_of(_ship("Miner1")) < 0 and mining.is_active() and mining.activity() == "Waiting for Storage"
		and follower.plans == plans)
	_station.storage.capacity = _station.storage_capacity
	var back := _until(func() -> bool: return mining.status == MiningOperation.Status.TRAVELING, 60 * 90)
	_check("16. storage free: docks again, unloads the rest (200 in all), heads back to the asteroid", back >= 0
		and _station.storage.quantity() == SMALL_HOLD and _cargo("Miner1").quantity() == 0)


# 6, 22: two miners and a docked Frigate share the station's slots and queue.
func _test_two_miners() -> void:
	_reset(SMALL_HOLD)
	_field.deposit(ASTEROID).reserves = 1000
	_place("Frigate", Vector2(-10, -40))
	_docking("Frigate").dock(_station)
	_until(func() -> bool: return _docking("Frigate").state == Docking.State.DOCKED, 60 * 60)
	_place("Miner1", NEAR)
	_place("Miner2", Vector2(-10, 2))
	for miner in ["Miner1", "Miner2"]:
		_fill(miner)
		_mining(miner).assign(ASTEROID)
	var reserves: int = _field.deposit(ASTEROID).reserves
	var waited := false
	var reservations_ok := true
	var conserved := true
	var back := {}
	var ticks := 0
	while ticks < 60 * 240 and back.size() < 2:
		_steps(1)
		ticks += 1
		for miner in ["Miner1", "Miner2"]:
			waited = waited or _mining(miner).activity() == "Waiting for Dock"
			if _mining(miner).activity() == "Returning to Asteroid":
				back[miner] = true
		var holders := _station.slots.map(func(slot: Dictionary) -> Node: return slot.ship)
		reservations_ok = reservations_ok and holders.has(_ship("Frigate")) and not (holders[0] != null and holders[0] == holders[1])
		# Every unit is either aboard a miner or in storage: the two fills plus whatever was mined since.
		var mined: int = reserves - _field.deposit(ASTEROID).reserves
		conserved = conserved and _station.storage.quantity() + _cargo("Miner1").quantity() + _cargo("Miner2").quantity() == 2 * SMALL_HOLD + mined
	_check("6. the second miner queues behind the first (Waiting for Dock); the docked Frigate keeps its slot", waited and reservations_ok)
	# Phase 3: "one lot" became "only the asteroid's resources".
	var composition: Dictionary = _field.deposit(ASTEROID).composition
	_check("22. both unloaded and headed back (%.0f s); every tick storage + holds = fills + mined (no duplication or loss), %d of the asteroid's resources" % [ticks * DT,
		_station.storage.quantity()], back.size() == 2 and conserved and _station.storage.quantity() >= 2 * SMALL_HOLD
		and _station.storage.amounts.keys().all(func(resource: StringName) -> bool: return composition.has(resource)))


# 17-19: manual Move and Dock cancel the operation, keep its settings; Resume restarts it.
func _test_manual_orders_and_resume() -> void:
	_reset(SMALL_HOLD)
	var mining := _mining("Miner1")
	_field.deposit(ASTEROID).reserves = 1000
	_place("Miner1", NEAR)
	mining.set_base(_station)
	mining.assign(ASTEROID)
	_steps(60)
	_manual_move("Miner1", Vector2(-50, 10))
	_check("17. manual Move cancels the operation (Assignment Paused), keeps target and base", mining.status == MiningOperation.Status.CANCELED
		and mining.target == ASTEROID and mining.base == _station and mining.activity() == "Assignment Paused")
	mining.resume()
	var mined := _until(func() -> bool: return mining.status == MiningOperation.Status.MINING, 60 * 60)
	_steps(120)
	_check("19. Resume restarts the saved assignment at the same asteroid", mined >= 0 and mining.target == ASTEROID)
	mining.set_base(null)
	_check("changing the base does not cancel the active operation", mining.status == MiningOperation.Status.MINING)
	_manual_dock("Miner1")
	_until(func() -> bool: return _docking("Miner1").state == Docking.State.DOCKED, 60 * 60)
	var aboard := _cargo("Miner1").quantity()
	_steps(60 * 5)
	_check("18. manual Dock cancels the operation: docks, no automatic unload or departure", mining.status == MiningOperation.Status.CANCELED
		and _docking("Miner1").state == Docking.State.DOCKED and _cargo("Miner1").quantity() == aboard and aboard > 0)


# Interruptions by a manual Move while traveling, waiting for a dock, unloading and
# returning to the asteroid: operation paused, docking released, settings kept.
func _test_interruptions() -> void:
	# Traveling: covered by 17. Waiting for a dock: both slots taken.
	_reset(SMALL_HOLD)
	var mining := _mining("Miner1")
	_place("Frigate", Vector2(-10, -40))
	_place("Gunship", Vector2(-62, -40))
	_docking("Frigate").dock(_station)
	_docking("Gunship").dock(_station)
	_until(func() -> bool: return _docking("Frigate").state == Docking.State.DOCKED and _docking("Gunship").state == Docking.State.DOCKED, 60 * 90)
	_place("Miner1", NEAR)
	_fill("Miner1")
	mining.assign(ASTEROID)
	_until(func() -> bool: return mining.activity() == "Waiting for Dock" and _station.hold_of(_ship("Miner1")) >= 0, 60 * 10)
	var queued := _station.queue_position(_ship("Miner1")) >= 0
	_manual_move("Miner1", Vector2(-60, 20))
	_check("interrupted while waiting for a dock: paused, out of the queue and its holding position", queued
		and mining.status == MiningOperation.Status.CANCELED and _station.queue_position(_ship("Miner1")) < 0
		and _station.hold_of(_ship("Miner1")) < 0 and _cargo("Miner1").quantity() == SMALL_HOLD)
	# Docked and unloading.
	_reset(SMALL_HOLD)
	_place("Miner1", NEAR)
	_fill("Miner1")
	mining.assign(ASTEROID)
	_until(func() -> bool: return mining.activity() == "Unloading" and _station.storage.quantity() >= 60, 60 * 90)
	_manual_move("Miner1", Vector2(-60, 20))
	_steps(60)
	_check("interrupted while unloading: paused, transfer stopped, units moved stay moved (%d + %d = 200)" % [_station.storage.quantity(), _cargo("Miner1").quantity()],
		mining.status == MiningOperation.Status.CANCELED and _docking("Miner1").transfer == Docking.Transfer.NONE
		and _station.storage.quantity() + _cargo("Miner1").quantity() == SMALL_HOLD and _cargo("Miner1").quantity() > 0)
	# Returning to the asteroid.
	_reset(SMALL_HOLD)
	_place("Miner1", NEAR)
	_fill("Miner1")
	_field.deposit(ASTEROID).reserves = 1000
	mining.assign(ASTEROID)
	_until(func() -> bool: return mining.activity() == "Returning to Asteroid", 60 * 90)
	_steps(60)
	_manual_move("Miner1", Vector2(-60, 20))
	_check("interrupted while returning to the asteroid: paused, target kept", mining.status == MiningOperation.Status.CANCELED
		and mining.target == ASTEROID and _docking("Miner1").state == Docking.State.NONE)


# 20, 21: low fuel warns without changing the operation; empty fuel holds the ship
# with its assignment; refueled it carries on.
func _test_fuel() -> void:
	_reset(SMALL_HOLD)
	var mining := _mining("Miner1")
	var fuel := _fuel("Miner1")
	_field.deposit(ASTEROID).reserves = 1000
	_place("Miner1", Vector2(-60, 20))
	fuel._set_fuel(16.0)
	_notices.clear()
	mining.assign(ASTEROID)
	var mined := _until(func() -> bool: return mining.status == MiningOperation.Status.MINING, 60 * 60)
	_check("20. Low Fuel warned on the way, the operation went on (mining, no return)", mined >= 0
		and _notices.any(func(text: String) -> bool: return text.contains("Low Fuel")) and mining.trip_base == null)
	_reset(SMALL_HOLD)
	_place("Miner1", Vector2(-60, 20))
	mining.assign(ASTEROID)
	_steps(120)
	fuel._set_fuel(0.0)
	_steps(1)
	var at := _position("Miner1")
	_steps(60 * 10)
	_check("21. empty: immobilized, assignment kept (Traveling to Asteroid - Out of Fuel)", _position("Miner1") == at
		and mining.status == MiningOperation.Status.TRAVELING and mining.activity() == "Traveling to Asteroid - Out of Fuel")
	fuel._set_fuel(fuel.capacity)
	var mined_after := _until(func() -> bool: return mining.status == MiningOperation.Status.MINING, 60 * 60)
	_check("21. refueled: carries on to the asteroid and mines", mined_after >= 0)


# Panel: base list, status line, Start / Resume Mining.
func _test_panel() -> void:
	_reset(SMALL_HOLD)
	var mining := _mining("Miner1")
	var panel := _main.get_node("ShipPanel")
	var rows := panel.get_node("Panel/Layout/Scroll/Body/Actions/Mining")
	_place("Miner1", NEAR)
	mining.assign(ASTEROID)
	_manual_move("Miner1", Vector2(-60, 20))
	_main.get_node("Selection").set_selection([_ship("Miner1")])
	panel._process(0.0)
	var base: OptionButton = rows.get_node("BaseRow/Base")
	var resume: Button = rows.get_node("Resume")
	_check("panel: base list (Nearest station, then the three stations nearest first), paused status, Resume enabled", base.item_count == 4
		and base.get_item_text(0) == "Nearest station" and base.get_item_metadata(1) == _station
		and base.get_item_metadata(2) == _main.get_node("Stations/Station2") and base.get_item_metadata(3) == _main.get_node("Stations/Shipyard") and base.selected == 0
		and panel.get_node("Panel/Layout/Scroll/Body/Status/Activity").text == "Status: Assignment Paused" and not resume.disabled)
	base.select(1)
	base.item_selected.emit(1)
	resume.pressed.emit()
	panel._process(0.0)
	_check("panel: choosing the station sets the base; Resume restarts (Traveling to Asteroid), Resume disabled", mining.base == _station
		and mining.status == MiningOperation.Status.TRAVELING and panel.get_node("Panel/Layout/Scroll/Body/Status/Activity").text == "Status: Traveling to Asteroid" and resume.disabled)
	mining.set_base(null)
	_main.get_node("Selection").set_selection([])


func _reset(hold: int) -> void:
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
		var mining := _mining(miner)
		mining.cancel()
		mining.target = -1
		mining.base = null
		mining.trip_base = null
		mining.status = MiningOperation.Status.NONE
		_cargo(miner).amounts.clear()
		_cargo(miner).capacity = hold if hold > 0 else _node(miner, "Cargo").capacity
	for slot in _station.slots:
		slot.ship = null
		slot.leaving = false
	for hold_point in _station.holds:
		hold_point.ship = null
	_station.queue.clear()
	_station._exiting.clear()
	_station.storage.amounts.clear()
	_station.storage.capacity = _station.storage_capacity
	_station.fuel_stock = 1000.0
	_place("Miner1", NEAR)
	_notices.clear()


# Fills a miner's hold with the test asteroid's first resource (as if it had mined).
func _fill(miner: String) -> void:
	var deposit = _field.deposit(ASTEROID)
	_cargo(miner).add(deposit.composition.keys()[0], _cargo(miner).free_space())


func _manual_move(ship_name: String, point: Vector2) -> void:
	# As the scene input does for a MOVE: order, then cancel mining and docking.
	_node(ship_name, "RouteFollower").order(point)
	_mining(ship_name).cancel()
	_docking(ship_name).cancel()


func _manual_dock(ship_name: String) -> void:
	# As the scene input does for a right-click on the station.
	_mining(ship_name).cancel()
	_docking(ship_name).dock(_station)


func _until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_steps(1)
	print("    timeout: Miner1 %s / dock %s at %s; Miner2 %s" % [_mining("Miner1").activity(), _docking("Miner1").state_name(),
		_position("Miner1"), _mining("Miner2").activity()])
	return -1


func _steps(count: int) -> void:
	for i in count:
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
			_fuel(ship_name)._physics_process(DT)
		for station in _main.get_node("Stations").get_children():
			station._physics_process(DT)


func _place(ship_name: String, point: Vector2) -> void:
	_node(ship_name, "Locomotion").place(point, 0.0)


func _position(ship_name: String) -> Vector2:
	return _node(ship_name, "Locomotion").planar_position


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _cargo(miner: String) -> Inventory:
	return _node(miner, "Cargo").inventory


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
	print("%-120s %s" % [label, "PASS" if ok else "FAIL"])
