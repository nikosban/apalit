extends SceneTree
## Headless Phase 3 stage 1 checks: the resource-count inventory and deterministic,
## proportional extraction of raw minerals (no movement involved). Every deposit of
## three seeds is extracted completely: total mass equals the reserves, every
## mineral stays within one unit of its share after every unit, ice asteroids give
## ice only, and the split depends only on how much an asteroid has given (unit by
## unit, in uneven chunks, through the Extractor at 30 / 60 / 144 Hz, or shared by
## two miners). Cargo limits, partial transfers and conservation per resource.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/resources_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const SEEDS := [20261014, 7, 424242]
const SEED := 20261014

var _failures := 0
var _checks := 0
var _main: Node
var _field: AsteroidField


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_field = _main.get_node("Asteroids")
	_main.get_node("Survey").set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		for child in ship.get_children():
			child.set_physics_process(false)

	_test_inventory()
	_test_full_extraction()
	_test_chunk_independence()
	_test_extractor_rates()
	_test_two_miners()
	_test_cargo_limit()
	_test_partial_transfers()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _test_inventory() -> void:
	_check("resources: six minerals and ice, six ingots, one fixed order", Inventory.RAW.size() == 7 and Inventory.INGOTS.size() == 6
		and Inventory.RESOURCES.size() == 13 and Inventory.RAW.slice(0, 6) == AsteroidField.MINERALS and Inventory.RAW[6] == AsteroidField.ICE)
	_check("names: Silicon, Silicon Ingots, Ice; ingot of silicon", Inventory.display_name(&"silicon") == "Silicon"
		and Inventory.display_name(&"silicon_ingot") == "Silicon Ingots" and Inventory.display_name(&"ice") == "Ice"
		and Inventory.ingot_of(&"silicon") == &"silicon_ingot")
	var inventory := Inventory.new(50)
	var added := inventory.add(&"gold", 20) + inventory.add(&"iron", 40)
	var removed := inventory.remove(&"gold", 25) + inventory.remove(&"cobalt", 5)
	_check("add never beyond capacity (60 asked, %d added), remove never beyond stock (%d)" % [added, removed], added == 50
		and removed == 20 and inventory.amounts == {&"iron": 30} and inventory.free_space() == 20 and inventory.describe() == "Iron 30")


# Every deposit of three seeds, unit by unit until depleted.
func _test_full_extraction() -> void:
	var deposits := 0
	var worst := 0.0
	var mass_ok := true
	var ice_ok := true
	var minerals_seen := 0
	for field_seed: int in SEEDS:
		_field.generate(field_seed)
		for id: int in _field.ids():
			var deposit := _field.deposit(id)
			var reserves := deposit.reserves
			var counts := {}
			var given := 0
			while deposit.reserves > 0:
				var units := _field.extract(id, 1)
				for resource: StringName in units:
					counts[resource] = counts.get(resource, 0) + units[resource]
					given += units[resource]
				for resource: StringName in deposit.composition:
					worst = maxf(worst, absf(counts.get(resource, 0) - deposit.composition[resource] * given / 100.0))
			deposits += 1
			mass_ok = mass_ok and given == reserves and counts == _nonzero(deposit.extracted) and deposit.extracted_total == reserves
			if deposit.family == AsteroidField.Family.ICE:
				ice_ok = ice_ok and counts == {AsteroidField.ICE: reserves}
			else:
				minerals_seen += 1
				ice_ok = ice_ok and counts.size() == 6
	_check("%d deposits fully extracted (%d mineral): total mass = reserves, counts = the deposit's record" % [deposits, minerals_seen], mass_ok and deposits == 108)
	_check("every mineral within 1 unit of its share after every unit (largest deviation %.3f)" % worst, worst < 1.0)
	_check("mineral asteroids give all six minerals, ice asteroids ice only", ice_ok)
	_field.generate(SEED)
	_check("compositions unchanged and read-only after extraction", _field.deposit(1).composition.is_read_only())


# The same totals in uneven chunks give exactly the same split.
func _test_chunk_independence() -> void:
	var id := _mineral(0)
	var reference := _split_by(id, [1])
	var same := true
	for sizes: Array in [[7], [3, 50, 1, 12], [999]]:
		same = same and _split_by(id, sizes) == reference
	_check("split independent of chunk sizes (1, 7, mixed, 999): %s" % str(reference), same)


func _test_extractor_rates() -> void:
	var id := _mineral(1)
	var extractor := _main.get_node("Ships/Miner1/Extractor")
	var results := []
	for rate in [30, 60, 144]:
		_field.generate(SEED)
		var cargo := Inventory.new(100000)
		extractor.reset()
		for tick in 10 * rate:
			extractor.extract(id, cargo, 1.0 / rate)
		results.append([cargo.quantity(), cargo.amounts.duplicate(), _field.deposit(id).extracted.duplicate()])
	var ok := true
	for result: Array in results:
		ok = ok and result[1] == _nonzero(result[2])
	var expected := _expected_split(id, results[1][0])
	_check("Extractor at 30 / 60 / 144 Hz: cargo = the asteroid's sequence (%d / %d / %d units)" % [results[0][0], results[1][0], results[2][0]],
		ok and results[1][1] == expected and absi(results[0][0] - 200) <= 1 and absi(results[2][0] - 200) <= 1)


# Two miners alternating on one asteroid: together exactly one miner's split.
func _test_two_miners() -> void:
	var id := _mineral(2)
	_field.generate(SEED)
	var a := Inventory.new(1000)
	var b := Inventory.new(1000)
	for turn in 300:
		var units := _field.extract(id, 1 + turn % 3)
		for resource: StringName in units:
			(a if turn % 2 == 0 else b).add(resource, units[resource])
	var together := {}
	for cargo: Inventory in [a, b]:
		for resource: StringName in cargo.amounts:
			together[resource] = together.get(resource, 0) + cargo.amounts[resource]
	_check("two miners (%d + %d): combined split = one miner's split for the same total" % [a.quantity(), b.quantity()],
		together == _expected_split(id, a.quantity() + b.quantity()) and a.quantity() > 0 and b.quantity() > 0)


func _test_cargo_limit() -> void:
	var id := _mineral(3)
	_field.generate(SEED)
	var extractor := _main.get_node("Ships/Miner1/Extractor")
	var cargo := Inventory.new(7)
	var reserves := _field.deposit(id).reserves
	extractor.reset()
	for tick in 600:
		extractor.extract(id, cargo, 1.0 / 60.0)
	_check("cargo capacity 7: stops at 7, reserves fell by 7, the first 7 units of the sequence (%s)" % cargo.describe(), cargo.quantity() == 7
		and reserves - _field.deposit(id).reserves == 7 and cargo.amounts == _nonzero(_field.deposit(id).extracted))


func _test_partial_transfers() -> void:
	var source := Inventory.new(1000)
	for resource: StringName in Inventory.RESOURCES:
		source.add(resource, 10)
	var before := source.amounts.duplicate()
	var small := Inventory.new(25)
	var moved := source.transfer_to(small, 40)
	var silicon := Inventory.new(100)
	var only := source.transfer_to(silicon, 4, &"silicon_ingot") + source.transfer_to(silicon, 100, &"silicon")
	var ok := true
	for resource: StringName in before:
		ok = ok and source.quantity_of(resource) + small.quantity_of(resource) + silicon.quantity_of(resource) == before[resource]
	_check("partial transfer limited by the destination (25 of 40), fixed order: %s" % small.describe(), moved == 25
		and small.amounts == {&"iron": 10, &"nickel": 10, &"silicon": 5})
	_check("transfer of one resource: 4 Silicon Ingots, then the 5 Silicon left; every resource conserved", only == 9
		and silicon.amounts == {&"silicon_ingot": 4, &"silicon": 5} and ok and source.quantity() == 130 - 34)


# Resource counts of an asteroid's first `total` units (fresh field), or of all units
# extracted in chunks cycling through `sizes`.
func _expected_split(id: int, total: int) -> Dictionary:
	_field.generate(SEED)
	var counts := {}
	var units := _field.extract(id, total)
	for resource: StringName in units:
		counts[resource] = units[resource]
	_field.generate(SEED)
	return counts


func _split_by(id: int, sizes: Array) -> Dictionary:
	_field.generate(SEED)
	var k := 0
	while _field.deposit(id).reserves > 0:
		_field.extract(id, sizes[k % sizes.size()])
		k += 1
	return _field.deposit(id).extracted.duplicate()


func _nonzero(counts: Dictionary) -> Dictionary:
	var kept := {}
	for resource: StringName in counts:
		if counts[resource] > 0:
			kept[resource] = counts[resource]
	return kept


func _mineral(k: int) -> int:
	_field.generate(SEED)
	return _field.ids().filter(func(id: int) -> bool: return _field.deposit(id).family == AsteroidField.Family.MINERALS)[k]


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%s: %s" % ["PASS" if ok else "FAIL", label])
