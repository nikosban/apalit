extends SceneTree
## Headless Phase 2.5 checks on the playable main scene: transport configuration
## edits during an active assignment. A station change (also clearing it) or all
## requirements set to zero pauses the assignment once, with one notice: docked it
## stays docked with the transfer stopped, undocking finishes its departure,
## otherwise the dock request and its reservations are released; cargo, fuel and the
## edited configuration are kept, and an invalid configuration never reaches
## Docking.dock(). Setting an existing value changes nothing; valid requirement
## edits stay live. Resume with cargo aboard is unchanged (to the loading station
## first). Phase 3 (appended): requirements in percent of the hold's total capacity,
## mixed with units (rounding down, independent of stock and free space, cargo aboard
## counts, shortage waiting, live edits, all at 0 %), edits exceeding the capacity
## rejected without changing anything, and the panel's requirement row. Ship physics
## is stepped manually at 60 Hz in the game's order, as in transport_test.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/transport_config_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const Inventory := preload("res://game/cargo/inventory.gd")
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
const SILICON := &"silicon"

const STATION_CHANGED := "Transporter: transport paused - station changed"
const NO_CARGO := "Transporter: transport paused - no cargo required"
const INVALID := "Transporter: transport paused - choose two different stations and a cargo requirement"

var _failures := 0
var _checks := 0
var _main: Node
var _a: Station # Loading station.
var _b: Station # Unloading station.
var _field: Node
var _navigation: Node
var _notices: Array[String] = []
var _null_requests := 0 # Ticks the Transporter's Docking spent requesting a dock at no station.


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

	_test_station_cleared_while_docked()
	_test_station_cleared_while_undocking()
	_test_same_station_for_both_ends()
	_test_stations_swapped_mid_trip()
	_test_requirements_cleared_while_traveling()
	_test_requirements_cleared_while_docked()
	_test_station_cleared_while_waiting_for_stock()
	_test_existing_values()
	_test_live_requirement_edits()
	_test_invalid_configuration_guard()
	_test_percent_units()
	_test_capacity_rejection()
	_test_percent_loading()
	_test_percent_shortage_and_aboard()
	_test_percent_live_edits()
	await _test_percent_panel()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# P1: Unload at cleared while docked and loading.
func _test_station_cleared_while_docked() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_until(func() -> bool: return docking.state == Docking.State.DOCKED, 60 * 120)
	_steps(60)
	var cargo := _cargo().quantity()
	var stock := _a.storage.quantity()
	_notices.clear()
	transport.set_unload_station(null)
	_check("P1. Unload at cleared while docked and loading: paused at once with one notice", transport.status == TransportOperation.Status.PAUSED
		and _notices == [STATION_CHANGED])
	_check("P1. stays docked at Station (slot held), transfer stopped, cargo kept (%d)" % cargo, docking.state == Docking.State.DOCKED
		and docking.station == _a and _a.slot_of(_ship()) >= 0 and docking.transfer == Docking.Transfer.NONE and _cargo().quantity() == cargo)
	_steps(60 * 10)
	_check("P1. 10 s later: still docked, nothing loaded, no dock request without a station, no further notices", docking.state == Docking.State.DOCKED
		and _cargo().quantity() == cargo and _a.storage.quantity() == stock and _null_requests == 0 and _notices.size() == 1)
	_check("P1. edited configuration kept (load Station, unload none, Metal 300), Resume unavailable", transport.load_station == _a
		and transport.unload_station == null and transport.required[METAL] == 300 and not transport.can_resume())


# P1: Unload at cleared while leaving the loading station: the departure finishes.
func _test_station_cleared_while_undocking() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_until(func() -> bool: return docking.state == Docking.State.UNDOCKING, 60 * 180)
	_notices.clear()
	transport.set_unload_station(null)
	_check("P1. Unload at cleared while undocking: paused with one notice, departure still under way", transport.status == TransportOperation.Status.PAUSED
		and _notices == [STATION_CHANGED] and docking.state == Docking.State.UNDOCKING)
	var done := _until(func() -> bool: return docking.state == Docking.State.NONE, 60 * 60)
	_steps(60 * 5)
	var released := _a.slots.all(func(slot: Dictionary) -> bool: return slot.ship != _ship())
	_check("P1. departure finished, slot released, no new dock request, cargo kept (300)", done >= 0 and released
		and docking.state == Docking.State.NONE and _null_requests == 0 and _cargo().quantity() == 300 and _notices.size() == 1)


# P2: Load at set to the unloading station while travelling to load.
func _test_same_station_for_both_ends() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	var follower := _node("Transporter", "RouteFollower")
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_steps(120)
	_notices.clear()
	transport.set_load_station(_b)
	_check("P2. Load at = Unload at while travelling: paused at once with one notice", transport.status == TransportOperation.Status.PAUSED
		and _notices == [STATION_CHANGED])
	_check("P2. dock request released (no slot, queue entry or hold at Station), configuration kept, Resume unavailable",
		docking.state == Docking.State.NONE and docking.station == null and _a.slot_of(_ship()) < 0 and _a.queue_position(_ship()) < 0
		and _a.hold_of(_ship()) < 0 and transport.load_station == _b and transport.unload_station == _b and not transport.can_resume())
	var plans: int = follower.plans
	_steps(60 * 20)
	_check("P2. 20 s later: no orders, no loading or unloading anywhere (Station 1000, Station2 0), no further notices",
		follower.plans == plans and _a.storage.quantity() == 1000 and _b.storage.quantity() == 0 and _cargo().quantity() == 0
		and docking.state == Docking.State.NONE and _null_requests == 0 and _notices.size() == 1)


# P3: stations swapped while travelling to the old loading station.
func _test_stations_swapped_mid_trip() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(METAL, 1000)
	_b.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_steps(120)
	_notices.clear()
	transport.set_load_station(_b)
	transport.set_unload_station(_a)
	_check("P3. stations swapped while travelling: paused once (one notice), not redirected, swapped configuration kept",
		transport.status == TransportOperation.Status.PAUSED and _notices == [STATION_CHANGED] and docking.state == Docking.State.NONE
		and transport.load_station == _b and transport.unload_station == _a and transport.can_resume())
	transport.start()
	_check("P3. Resume uses the new configuration (to Station2 to load)", transport.status == TransportOperation.Status.LOADING
		and docking.station == _b)
	var done := _until(func() -> bool: return transport.deliveries == 1, 60 * 300)
	_check("P3. loads at Station2 and delivers to Station (Station2 %d, Station %d)" % [_b.storage.quantity(), _a.storage.quantity()],
		done >= 0 and _b.storage.quantity() == 700 and _a.storage.quantity() == 1300)


# P4: every requirement set to zero while travelling to the destination.
func _test_requirements_cleared_while_traveling() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	var follower := _node("Transporter", "RouteFollower")
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING and docking.state == Docking.State.APPROACHING, 60 * 240)
	_notices.clear()
	transport.set_requirement(METAL, 0)
	transport.set_requirement(ICE, 0)
	_check("P4. requirements cleared while delivering: paused at once with one notice, dock request at Station2 released, 300 aboard",
		transport.status == TransportOperation.Status.PAUSED and _notices == [NO_CARGO] and docking.state == Docking.State.NONE
		and _b.slot_of(_ship()) < 0 and _b.queue_position(_ship()) < 0 and _cargo().quantity() == 300)
	var plans: int = follower.plans
	var fuel_a := _a.fuel_stock
	var fuel_b := _b.fuel_stock
	_steps(60 * 30)
	_check("P4. 30 s later: no round trips (no orders, no deliveries, station fuel untouched), cargo kept, no further notices",
		follower.plans == plans and transport.deliveries == 0 and _b.storage.quantity() == 0 and _a.fuel_stock == fuel_a
		and _b.fuel_stock == fuel_b and _cargo().quantity() == 300 and _notices.size() == 1)
	transport.set_requirement(METAL, 300)
	transport.start()
	_check("P4. Resume with the cargo aboard: unchanged behaviour, to the loading station first", transport.status == TransportOperation.Status.LOADING
		and docking.station == _a)
	var left := _until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 240)
	_check("P4. requirement already met by the cargo kept aboard: departs with the same 300, nothing more loaded", left >= 0
		and _cargo().quantity() == 300 and _a.storage.quantity() == 700)


# P4 (docked): every requirement set to zero while loading.
func _test_requirements_cleared_while_docked() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	var fuel := _node("Transporter", "Fuel") as Fuel
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	fuel._set_fuel(150.0)
	transport.start()
	_until(func() -> bool: return docking.state == Docking.State.DOCKED, 60 * 120)
	_steps(60)
	var cargo := _cargo().quantity()
	_notices.clear()
	transport.set_requirement(METAL, 0)
	_check("P4. requirements cleared while docked and loading: paused, stays docked (slot held), transfer stopped, cargo kept (%d)" % cargo,
		transport.status == TransportOperation.Status.PAUSED and _notices == [NO_CARGO] and docking.state == Docking.State.DOCKED
		and _a.slot_of(_ship()) >= 0 and docking.transfer == Docking.Transfer.NONE and _cargo().quantity() == cargo)
	_steps(60 * 5)
	_check("P4. 5 s later: still docked, nothing loaded, refueling goes on (%.1f / %d)" % [fuel.fuel, roundi(fuel.capacity)],
		docking.state == Docking.State.DOCKED and _cargo().quantity() == cargo and _a.storage.quantity() == 1000 - cargo and fuel.fuel > 150.0)


# P5: Load at cleared while waiting in the berth for stock (UX round P4: the wait is docked).
func _test_station_cleared_while_waiting_for_stock() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 200) # No ice in stock: waits in the berth.
	transport.start()
	_until(func() -> bool: return docking.waiting, 60 * 240)
	_notices.clear()
	transport.set_load_station(null)
	_check("P5. Load at cleared while waiting docked for stock: paused with one notice, stays docked with the slot held (as P4), transfer stopped, 300 Metal kept",
		transport.status == TransportOperation.Status.PAUSED and _notices == [STATION_CHANGED] and docking.state == Docking.State.DOCKED
		and _a.slot_of(_ship()) >= 0 and docking.transfer == Docking.Transfer.NONE and not docking.waiting and _cargo().quantity_of(METAL) == 300)
	transport.set_requirement(METAL, 400)
	_a.storage.add(ICE, 500)
	_steps(60 * 5)
	_check("P5. later requirement edit and new stock: nothing loaded, no dock request (none without a station), no further notices",
		transport.status == TransportOperation.Status.PAUSED and docking.state == Docking.State.DOCKED and docking.transfer == Docking.Transfer.NONE
		and _null_requests == 0 and _notices.size() == 1 and _cargo().quantity() == 300)


# Setting a station or requirement to its existing value changes nothing.
func _test_existing_values() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_steps(120)
	var state := docking.state
	_notices.clear()
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(METAL, 300)
	transport.set_requirement(ICE, 0)
	transport.set_requirement(ICE, -5) # Clamped to the existing 0.
	_check("existing values while travelling: still active, same dock request, no notice", transport.status == TransportOperation.Status.LOADING
		and docking.station == _a and docking.state == state and _notices.is_empty())


# Valid requirement edits stay live (while travelling and while docked).
func _test_live_requirement_edits() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_steps(120)
	_notices.clear()
	transport.set_requirement(METAL, 200)
	transport.set_requirement(ICE, 50)
	_check("valid edits while travelling: still active toward Station, no notice", transport.status == TransportOperation.Status.LOADING
		and docking.station == _a and _notices.is_empty())
	transport.set_requirement(ICE, 0)
	_until(func() -> bool: return docking.transfer == Docking.Transfer.LOAD, 60 * 120)
	_steps(30)
	transport.set_requirement(METAL, 500)
	_steps(1)
	_check("valid edit while loading: transfer re-sized to the raised requirement (500)", transport.is_active()
		and docking.transfer == Docking.Transfer.LOAD and docking.load_amount - docking.moved == transport.missing(METAL))
	transport.set_requirement(ICE, 100)
	transport.set_requirement(METAL, 0)
	_check("one family cleared while another is required: still active, no notice", transport.is_active()
		and not _notices.has(NO_CARGO) and not _notices.has(STATION_CHANGED))
	transport.set_requirement(METAL, 250)
	transport.set_requirement(ICE, 0)
	var left := _until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 120)
	_check("Metal 250 again, Ice back to 0: loads to the requirement and departs as before (Metal %d, Ice %d)" % [_cargo().quantity_of(METAL),
		_cargo().quantity_of(ICE)], left >= 0 and transport.is_active() and _cargo().quantity_of(METAL) == 250 and _cargo().quantity_of(ICE) == 0
		and not _notices.has(NO_CARGO))


# An invalid configuration written without the setters never reaches Docking.dock().
func _test_invalid_configuration_guard() -> void:
	_reset()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(METAL, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_until(func() -> bool: return docking.state == Docking.State.UNDOCKING, 60 * 180)
	_notices.clear()
	transport.unload_station = null # Bypasses set_unload_station().
	_until(func() -> bool: return docking.state == Docking.State.NONE, 60 * 60)
	_steps(60 * 5)
	_check("invalid configuration found by the operation itself: paused once with a notice, no dock request without a station",
		transport.status == TransportOperation.Status.PAUSED and _notices == [INVALID] and docking.state == Docking.State.NONE
		and _null_requests == 0 and _cargo().quantity() == 300)


# Phase 3: percentages of the hold's total capacity (1000), mixed with units.
func _test_percent_units() -> void:
	_reset()
	_clear_requirements()
	var transport := _transport()
	transport.set_requirement(SILICON, 30, true)
	var thirty := transport.required_units(SILICON)
	transport.set_requirement(METAL, 250)
	_check("percent: Silicon 30%% = %d units of the 1000 hold; mixed with Iron 250 units: %d in all, configured once stations are set" % [thirty, transport.total_required()],
		thirty == 300 and transport.total_required() == 550 and transport.describe_requirements() == "Iron 250, Silicon 30% (300)")
	_cargo().add(SILICON, 200)
	_a.storage.amounts.clear()
	_check("percent of the total capacity, not of free space or stock (200 aboard, none in stock): still 300, 100 missing",
		transport.required_units(SILICON) == 300 and transport.missing(SILICON) == 100)
	_cargo().amounts.clear()
	_cargo().capacity = 333
	var rounded := transport.required_units(SILICON)
	_cargo().capacity = _node("Transporter", "Cargo").capacity
	transport.set_requirement(ICE, 150, true)
	_check("rounding down: 30%% of 333 = %d (99.9); Ice 150%% (limited to 100%%) on top of 550 is rejected" % rounded, rounded == 99
		and transport.required[ICE] == 0 and _notices.size() == 1)
	_clear_requirements()
	transport.set_requirement(ICE, 150, true)
	_check("Ice 150% alone is limited to 100% (1000 units)", transport.required[ICE] == 100 and transport.percent[ICE] and transport.required_units(ICE) == 1000)
	_clear_requirements()


# Edits that would exceed the hold are rejected; the previous configuration stays.
func _test_capacity_rejection() -> void:
	_reset()
	_clear_requirements()
	var transport := _transport()
	transport.set_requirement(METAL, 700)
	_notices.clear()
	var accepted := transport.set_requirement(SILICON, 40, true)
	_check("Iron 700 + Silicon 40%% (400) > 1000: rejected with a notice, Silicon unchanged (%s)" % str(_notices), not accepted
		and transport.required[SILICON] == 0 and not transport.percent[SILICON] and _notices.size() == 1 and _notices[0].contains("exceed the cargo capacity"))
	_check("exactly the capacity is allowed (Iron 700 + Silicon 30% = 1000)", transport.set_requirement(SILICON, 30, true) and transport.total_required() == 1000)
	_check("raising Iron to 701 then: rejected, Iron stays 700", not transport.set_requirement(METAL, 701) and transport.required[METAL] == 700)
	_check("switching Iron 700 units to 700% (limited to 100%: 1000 units): rejected, still 700 units",
		not transport.set_requirement(METAL, 700, true) and transport.required[METAL] == 700 and not transport.percent[METAL])
	_clear_requirements()
	_a.storage.add(METAL, 1000)
	_a.storage.add(SILICON, 1000)
	_configure(_a, _b, 300, 0)
	transport.start()
	_until(func() -> bool: return _docking().transfer == Docking.Transfer.LOAD, 60 * 120)
	_steps(30)
	var loading := _docking().load_amount
	_notices.clear()
	accepted = transport.set_requirement(SILICON, 80, true)
	_steps(1)
	_check("rejected while loading: nothing changes (still active, same transfer, one notice, no pause)", not accepted and transport.is_active()
		and _docking().transfer == Docking.Transfer.LOAD and _docking().load_amount == loading and _notices.size() == 1
		and transport.status == TransportOperation.Status.LOADING)
	_clear_requirements()


# Mixed units and percent: loads exactly the requirements, leaves the rest of the hold empty.
func _test_percent_loading() -> void:
	_reset()
	_clear_requirements()
	var transport := _transport()
	_a.storage.add(METAL, 1000)
	_a.storage.add(SILICON, 1000)
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(METAL, 100)
	transport.set_requirement(SILICON, 25, true)
	transport.start()
	var left := _until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 240)
	_check("Iron 100 + Silicon 25%%: departs with exactly 100 + 250, 650 of the hold left unallocated (%s)" % _cargo().describe(), left >= 0
		and _cargo().amounts == {METAL: 100, SILICON: 250} and _cargo().free_space() == 650)
	var done := _until(func() -> bool: return transport.deliveries == 1, 60 * 240)
	_check("delivered: Station2 holds Iron 100, Silicon 250; nothing created or lost", done >= 0 and _b.storage.amounts == {METAL: 100, SILICON: 250}
		and _a.storage.quantity() + _b.storage.quantity() + _cargo().quantity() == 2000)
	transport.cancel()
	_clear_requirements()


# A percentage waits for its whole amount, like units; cargo aboard counts.
func _test_percent_shortage_and_aboard() -> void:
	_reset()
	_clear_requirements()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(SILICON, 120)
	_cargo().add(SILICON, 50) # Already aboard: counts toward the requirement.
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(SILICON, 30, true)
	transport.start()
	var blocked := _until(func() -> bool: return docking.waiting, 60 * 240)
	_steps(60 * 5)
	_check("Silicon 30%% (300) with 50 aboard and 120 in stock: loads the 120, waits in the berth with the slot held (Waiting for Resources), does not leave (%d aboard)" % _cargo().quantity(),
		blocked >= 0 and _cargo().quantity_of(SILICON) == 170 and transport.activity() == "Waiting for Resources" and transport.status == TransportOperation.Status.LOADING
		and _a.slot_of(_ship()) >= 0)
	_a.storage.add(SILICON, 200)
	var left := _until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 240)
	_check("stock arrives: loads the missing 130 and departs with exactly 300 (%d left in stock)" % _a.storage.quantity_of(SILICON), left >= 0
		and _cargo().quantity_of(SILICON) == 300 and _a.storage.quantity_of(SILICON) == 70)
	transport.cancel()
	_clear_requirements()


# Percent edits during an active transport follow the Phase 2.5 rules.
func _test_percent_live_edits() -> void:
	_reset()
	_clear_requirements()
	var transport := _transport()
	var docking := _docking()
	_a.storage.add(SILICON, 1000)
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(SILICON, 50, true)
	transport.start()
	_until(func() -> bool: return _cargo().quantity() >= 100, 60 * 240)
	_notices.clear()
	transport.set_requirement(SILICON, 40, true)
	_steps(1)
	_check("50% -> 40% while loading: transfer re-sized to the 400 (no notice)", transport.is_active() and docking.transfer == Docking.Transfer.LOAD
		and docking.load_amount - docking.moved == transport.missing(SILICON) and transport.required_units(SILICON) == 400 and _notices.is_empty())
	transport.set_requirement(SILICON, 0, true)
	var aboard := _cargo().quantity()
	_check("every requirement at 0%%: paused once (no cargo required), stays docked, cargo kept (%d)" % aboard,
		transport.status == TransportOperation.Status.PAUSED and _notices == [NO_CARGO] and docking.state == Docking.State.DOCKED
		and docking.transfer == Docking.Transfer.NONE and aboard > 0)
	transport.set_requirement(SILICON, 20, true)
	transport.start()
	var left := _until(func() -> bool: return transport.status == TransportOperation.Status.DELIVERING, 60 * 240)
	_check("Resume with Silicon 20%%: tops up to 200 (never unloads what is aboard) and departs (%d aboard, %d before)" % [_cargo().quantity(), aboard],
		left >= 0 and _cargo().quantity() == maxi(aboard, 200) and _cargo().quantity() + _a.storage.quantity() == 1000)
	transport.cancel()
	_clear_requirements()


func _test_percent_panel() -> void:
	_reset()
	_clear_requirements()
	var transport := _transport()
	var panel := _main.get_node("ShipPanel")
	var rows := panel.get_node("Panel/Layout/Scroll/Body/Actions/Transport")
	# UX round P7: through the transport editor (the requirement row was replaced); edits
	# go to the editor's draft, Apply saves the whole draft or nothing.
	var editor := panel.get_node("TransportEditor")
	_main.get_node("Selection").set_selection([_ship()])
	await process_frame
	(rows.get_node("Configure") as Button).pressed.emit()
	var silicon: Node = editor.row(0, SILICON)
	silicon.get_node("Mode").button(1).button_pressed = true
	(silicon.get_node("Amount") as SpinBox).value = 30
	editor.apply()
	panel._process(0.0)
	_check("editor: Silicon, %%, 30 + Apply: Silicon 30%% saved, the row limited to 100, summary shown (%s)" % (rows.get_node("Required") as Label).text,
		transport.required[SILICON] == 30 and transport.percent[SILICON] and (silicon.get_node("Amount") as SpinBox).max_value == 100
		and (rows.get_node("Required") as Label).text == "Required: Silicon 30% (300)")
	var iron: Node = editor.row(0, METAL)
	var amount := iron.get_node("Amount") as SpinBox
	_check("editor: the Iron row shows its own saved requirement (0 units, limit 1000)", amount.value == 0 and iron.get_node("Mode").selected == 0 and amount.max_value == 1000)
	_notices.clear()
	amount.value = 800
	var rejected: bool = not editor.apply()
	_check("editor: Iron 800 with Silicon 30%% + Apply exceeds the hold: rejected, Iron stays 0 saved, one notice, the draft keeps 800 (%d)" % amount.value,
		rejected and transport.required[METAL] == 0 and _notices.size() == 1 and editor.draft[METAL] == 800 and amount.value == 800)
	amount.value = 700
	_check("editor: Iron 700 + Apply accepted (1000 in all)", editor.apply() and transport.required[METAL] == 700 and transport.total_required() == 1000)
	# Typed, then the Transporter deselected before Apply: the deselection applies
	# nothing; Apply saves the draft to that Transporter.
	amount.get_line_edit().text = "250"
	amount.get_line_edit().text_changed.emit("250")
	await process_frame
	_main.get_node("Selection").set_selection([])
	await process_frame
	var unchanged: bool = transport.required[METAL] == 700
	editor.apply()
	_check("editor: Iron 250 typed, the ship deselected (nothing saved by that: %s), then Apply: saved to that Transporter (Iron %d)" % [unchanged, transport.required[METAL]],
		unchanged and transport.required[METAL] == 250)
	_main.get_node("Selection").set_selection([_ship()])
	amount.get_line_edit().text = "300"
	amount.get_line_edit().text_changed.emit("300")
	await process_frame
	_main.get_node("Selection").set_selection([_main.get_node("Ships/Frigate")])
	await process_frame
	unchanged = transport.required[METAL] == 250
	editor.apply()
	_check("editor: ... also when another ship (no transport) was selected meanwhile (nothing saved by that: %s; Iron %d)" % [unchanged, transport.required[METAL]],
		unchanged and transport.required[METAL] == 300)
	editor.close()
	_main.get_node("Selection").set_selection([])
	_clear_requirements()


func _clear_requirements() -> void:
	var transport := _transport()
	transport.cancel()
	transport.status = TransportOperation.Status.NONE
	for resource in Inventory.RESOURCES:
		transport.required[resource] = 0
		transport.percent[resource] = false


func _configure(load: Station, unload: Station, metal: int, ice: int) -> void:
	var transport := _transport()
	transport.set_load_station(load)
	transport.set_unload_station(unload)
	transport.set_requirement(METAL, metal)
	transport.set_requirement(ICE, ice)


func _reset() -> void:
	_field.generate(SEED)
	for ship_name in SHIPS:
		_node(ship_name, "Docking").phase = Docking.Phase.NONE # Stage 2b: cancel() is refused during station control.
		_node(ship_name, "Docking").hold_command(Callable())
		_node(ship_name, "Docking").cancel()
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
		_locomotion(ship_name).place(PARK[ship_name], 0.0)
		var fuel := _node(ship_name, "Fuel") as Fuel
		fuel._set_fuel(fuel.capacity)
	for miner in ["Miner1", "Miner2"]:
		var mining := _node(miner, "Mining") as MiningOperation
		mining.cancel()
		mining.target = -1
		mining.status = MiningOperation.Status.NONE
		_node(miner, "Cargo").inventory.amounts.clear()
	var transport := _transport()
	transport.cancel()
	transport.status = TransportOperation.Status.NONE
	transport.deliveries = 0
	_cargo().amounts.clear()
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
	_locomotion("Transporter").place(NEAR_A, 0.0)
	_notices.clear()
	_null_requests = 0


func _until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_steps(1)
	print("    timeout: Transporter %s / dock %s at %s, cargo %d" % [_transport().activity(), _docking().state_name(),
		_locomotion("Transporter").planar_position, _cargo().quantity()])
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
			_node(ship_name, "Docking")._physics_process(DT)
			_node(ship_name, "Fuel")._physics_process(DT)
		for station in _main.get_node("Stations").get_children():
			station._physics_process(DT)
		if _docking().state == Docking.State.REQUESTING and _docking().station == null:
			_null_requests += 1


func _ship() -> Node3D:
	return _main.get_node("Ships/Transporter")


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _locomotion(ship_name: String) -> ShipLocomotion:
	return _node(ship_name, "Locomotion") as ShipLocomotion


func _cargo() -> Inventory:
	return _node("Transporter", "Cargo").inventory


func _docking() -> Docking:
	return _node("Transporter", "Docking") as Docking


func _transport() -> TransportOperation:
	return _node("Transporter", "Transport") as TransportOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
