extends SceneTree
## Headless Phase 3 integration scenario on the playable main scene: a Silicon
## shortage solved by informed exploration and logistics. Miner1's Mining Scanner
## surveys the field; the analyzed asteroid with the most Silicon (composition x
## reserves, as the hover shows them) is chosen. Station2's refinery has both slots on
## Silicon and waits; the Transporter (Load at Station, Unload at Station2, Silicon 30 %
## of its hold = 300) waits for the resources; Miner1 mines the asteroid (base
## Station) with automated mining: the delivered Silicon is the predicted share; the
## Transporter leaves only with all 300 aboard, delivers them, and the refinery turns
## them into 300 Silicon Ingots; then 100 ingots are transported back to Station with
## the same cargo system. Every tick, every unit in every inventory (ingots counted as
## their mineral) equals what the asteroids have given: nothing created or lost. Ship
## physics is stepped manually at 60 Hz in the game's order (as transport_test), then
## the stations and the refinery.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/silicon_shortage_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const Survey := preload("res://game/survey/survey.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const Refinery := preload("res://game/refining/refinery.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const DT := 1.0 / 60.0
const SEED := 20261014
const SHIPS := ["Miner1", "Miner2", "Transporter"]
const PARK := {"Miner2": Vector2(40, -32)}
const SILICON := &"silicon"
const INGOT := &"silicon_ingot"
const CARGO_SHIPS := ["Miner1", "Miner2", "Transporter"]

var _failures := 0
var _checks := 0
var _main: Node
var _field: AsteroidField
var _survey: Survey
var _a: Station # Station: mining base and loading station.
var _b: Station # Station2: the refinery.
var _refinery: Refinery
var _ticks := 0
var _conserved := true
var _violation := ""


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_field = _main.get_node("Asteroids")
	_survey = _main.get_node("Survey")
	_a = _main.get_node("Stations/Station")
	_b = _main.get_node("Stations/Station2")
	_refinery = _b.get_node("Refinery")
	_survey.set_physics_process(false)
	for ship_name in SHIPS:
		for child in _ship(ship_name).get_children():
			child.set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	_refinery.set_physics_process(false)
	for ship_name in SHIPS:
		while not _main.get_node("StaticNavigation").is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame
	_field.generate(SEED)
	for ship_name: String in PARK:
		_locomotion(ship_name).place(PARK[ship_name], 0.0)

	var target := _test_survey()
	if target < 0:
		print("RESULT: FAIL (no surveyed asteroid to mine)")
		quit(1)
		return
	_test_shortage(target)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# 1. Survey with the Mining Scanner; choose the analyzed asteroid with the most Silicon.
func _test_survey() -> int:
	var scanner := _node("Miner1", "Scanner")
	scanner.activate()
	for i in 60 * 120:
		if _survey.active_scans() == 0 and _survey.analyzing_ids().is_empty():
			break
		_steps(1)
	var best := -1
	var best_units := 0.0
	var analyzed := 0
	for id: int in _field.ids():
		var deposit := _field.deposit(id)
		if _survey.level_of(id) != Survey.Level.ANALYZED or deposit.family != AsteroidField.Family.MINERALS:
			continue
		analyzed += 1
		var units: float = deposit.composition[SILICON] * deposit.reserves / 100.0
		if units > best_units and _mining().can_mine(id):
			best = id
			best_units = units
	if best < 0:
		_check("survey: an analyzed mineral asteroid with a working position", false)
		return -1
	var deposit := _field.deposit(best)
	var hover: String = _main.get_node("AsteroidHover").describe(best)
	_check("survey: %d mineral asteroids analyzed; most Silicon: asteroid %d, Silicon %d%% of %d reserves (about %d units), shown in its hover" % [analyzed,
		best, deposit.composition[SILICON], deposit.reserves, roundi(best_units)], hover.contains("Silicon %d%%" % deposit.composition[SILICON])
		and hover.contains("Remaining reserves: %d units" % deposit.reserves) and best_units >= 600.0)
	return best


func _test_shortage(target: int) -> void:
	var deposit := _field.deposit(target)
	var percent: int = deposit.composition[SILICON]
	var transport := _transport()
	var transporter_dock := _docking("Transporter")
	var mining := _mining()
	# 2. The refinery waits for Silicon.
	for index in 2:
		_refinery.set_mineral(index, SILICON)
		_refinery.set_enabled(index, true)
	_steps(60 * 5)
	_check("shortage: both refinery slots on Silicon wait (Waiting for Silicon), nothing processed", _b.storage.quantity() == 0
		and _refinery.status(0) == "Waiting for Silicon" and _refinery.status(1) == "Waiting for Silicon")
	# 3. Transport configured in percent of the hold; it waits for the Silicon.
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(SILICON, 30, true)
	transport.start()
	var waiting := _until(func() -> bool: return transporter_dock.waiting, 60 * 240)
	_check("transport Silicon 30%% of the hold (%d units): docks at Station, finds no Silicon, waits in the berth with the slot held (%s)" % [transport.required_units(SILICON),
		transport.activity()], waiting >= 0 and transport.required_units(SILICON) == 300 and transport.activity() == "Waiting for Resources"
		and _cargo("Transporter").quantity() == 0 and _a.slot_of(_main.get_node("Ships/Transporter")) >= 0)
	# 4. Mining the surveyed asteroid (automated, base Station).
	mining.set_base(_a)
	mining.assign(target)
	var first_unload := _until(func() -> bool: return mining.activity() == "Leaving Base", 60 * 60 * 5)
	var extracted: int = deposit.extracted_total
	var silicon: int = deposit.extracted[SILICON]
	var at_station := _a.storage.quantity_of(SILICON) + _cargo("Transporter").quantity_of(SILICON)
	_check("first load delivered (%d units): Silicon %d = %d%% of it within one unit (%.1f predicted), all at Station or already loaded (%d)" % [extracted,
		silicon, percent, percent * extracted / 100.0, at_station], first_unload >= 0 and extracted == _cargo("Miner1").capacity
		and absf(silicon - percent * extracted / 100.0) < 1.0 and at_station == silicon and _cargo("Miner1").quantity() == 0)
	# 5. The Transporter leaves only with all 300 aboard.
	var early := false
	var ticks := 0
	while transport.status == TransportOperation.Status.LOADING and ticks < 60 * 60 * 20:
		_steps(1)
		ticks += 1
	early = _cargo("Transporter").quantity_of(SILICON) != 300
	_check("Transporter departs only once all 300 Silicon are aboard (%.0f s after mining started), nothing else loaded; Station keeps %s" % [
		(ticks + first_unload) * DT, _a.storage.describe()], transport.status == TransportOperation.Status.DELIVERING and not early
		and _cargo("Transporter").amounts == {SILICON: 300})
	# 6. Delivered to Station2; the refinery starts at once.
	var delivered := _until(func() -> bool: return transport.deliveries == 1, 60 * 60 * 5)
	transport.cancel() # The player pauses the assignment after one delivery.
	_check("delivered to Station2: Silicon + Silicon Ingots = 300, nothing else there (%s)" % _b.storage.describe(), delivered >= 0
		and _b.storage.quantity_of(SILICON) + _b.storage.quantity_of(INGOT) == 300 and _b.storage.quantity() == 300)
	# 7. Refined: two slots at 2.5 / s.
	var refined := _until(func() -> bool: return _b.storage.quantity_of(INGOT) == 300, 60 * 120)
	_steps(60 * 5)
	_check("refined: 300 Silicon Ingots, no Silicon left, slots waiting again (%s; done %.0f s after the delivery)" % [_b.storage.describe(),
		refined * DT], refined >= 0 and _b.storage.amounts == {INGOT: 300} and _refinery.status(0) == "Waiting for Silicon"
		and _refinery.slots[0].processed + _refinery.slots[1].processed == 300)
	# 8. Ingots travel with the same cargo system (100 back to Station).
	transport.set_load_station(_b)
	transport.set_unload_station(_a)
	transport.set_requirement(INGOT, 100)
	transport.set_requirement(SILICON, 0)
	transport.start()
	var back := _until(func() -> bool: return transport.deliveries == 1, 60 * 60 * 6)
	transport.cancel()
	_check("100 Silicon Ingots loaded at Station2 and delivered to Station; 200 stay at Station2", back >= 0 and _a.storage.quantity_of(INGOT) == 100
		and _b.storage.amounts == {INGOT: 200})
	# 9. Conservation over the whole run.
	_check("every tick of %.0f s: all inventories (ingots as their mineral) = what the asteroids gave; nothing created or lost %s" % [_ticks * DT,
		_violation], _conserved and _totals_match())
	_check("no ship contacts and no station-control refusals", _contacts() == 0 and SHIPS.all(func(ship_name: String) -> bool:
		return _docking(ship_name).refused_during_control == 0))


func _until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_steps(1)
	print("    timeout: Transporter %s, Miner1 %s, Station %s, Station2 %s" % [_transport().activity(), _mining().activity(),
		_a.storage.describe(), _b.storage.describe()])
	return -1


func _steps(count: int) -> void:
	for i in count:
		_ticks += 1
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_locomotion(ship_name)._step(DT)
		for ship_name in SHIPS:
			for child in ["Mining", "Transport"]:
				var node := _ship(ship_name).get_node_or_null(child)
				if node != null:
					node._physics_process(DT)
			_docking(ship_name)._physics_process(DT)
			_node(ship_name, "Fuel")._physics_process(DT)
			_node(ship_name, "Scanner")._physics_process(DT)
		_survey.advance(DT)
		for station in _main.get_node("Stations").get_children():
			station._physics_process(DT)
		_refinery._physics_process(DT)
		if _conserved and not _totals_match():
			_conserved = false
			_violation = "(first difference at %.2f s)" % (_ticks * DT)


# Units held anywhere (ingots as their mineral) equal the units extracted, per resource.
func _totals_match() -> bool:
	var held := {}
	var inventories: Array[Inventory] = [_a.storage, _b.storage]
	for ship_name in CARGO_SHIPS:
		inventories.append(_cargo(ship_name))
	for inventory in inventories:
		for resource: StringName in inventory.amounts:
			var raw := StringName(String(resource).trim_suffix("_ingot"))
			held[raw] = held.get(raw, 0) + inventory.amounts[resource]
	var given := {}
	for id: int in _field.ids():
		var extracted: Dictionary = _field.deposit(id).extracted
		for resource: StringName in extracted:
			if extracted[resource] > 0:
				given[resource] = given.get(resource, 0) + extracted[resource]
	return held == given


func _contacts() -> int:
	var total := 0
	for ship_name in SHIPS:
		total += _locomotion(ship_name).collision_count
	return total


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _locomotion(ship_name: String) -> ShipLocomotion:
	return _node(ship_name, "Locomotion") as ShipLocomotion


func _cargo(ship_name: String) -> Inventory:
	return _node(ship_name, "Cargo").inventory


func _docking(ship_name: String) -> Docking:
	return _node(ship_name, "Docking") as Docking


func _mining() -> MiningOperation:
	return _node("Miner1", "Mining") as MiningOperation


func _transport() -> TransportOperation:
	return _node("Transporter", "Transport") as TransportOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
