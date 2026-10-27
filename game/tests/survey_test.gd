extends SceneTree
## Headless Phase 2 Stage 1 checks on the playable main scene: asteroid deposits,
## the fleet survey, scanners, markers and hover text. Ship physics is stepped
## manually at 60 Hz in the game's order (per ship RouteFollower then Avoidance,
## then Locomotion), followed by the scanners and the survey.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/survey_test.gd
## The Transporter carries the Generic Scanner, the Miners the Mining Scanner.
## Every check is PASS/FAIL; scan coverage is expected from the scene layout
## (asteroid transforms, unit sphere radius 0.5), not from the survey code.

const MAIN := preload("res://main.tscn")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const Survey := preload("res://game/survey/survey.gd")
const SurveyView := preload("res://game/survey/survey_view.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Transporter", "FF01", "Miner1", "Miner2"]
const SEED := 20261014
const SCAN_POINT := Vector2(85, 52) # Open space next to a small asteroid cluster.
const SIX := ["cobalt", "gold", "iron", "nickel", "silicon", "titanium"]

var _failures := 0
var _checks := 0
var _main: Node
var _field: AsteroidField
var _survey: Survey
var _view: SurveyView
var _hover: Node
var _started: Array = [] # [tick, id] per analysis_started
var _surveyed: Array = [] # [id, level] per surveyed
var _tick := 0


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	var ff01: Node3D = load("res://game/ships/ff01_unit.tscn").instantiate() # A warship (Generic Scanner).
	ff01.name = "FF01"
	ff01.position = Vector3(14, 1.5, 0)
	_main.get_node("Ships").add_child(ff01)
	root.add_child(_main)
	_field = _main.get_node("Asteroids")
	_survey = _main.get_node("Survey")
	_view = _main.get_node("SurveyView")
	_hover = _main.get_node("AsteroidHover")
	_survey.set_physics_process(false)
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.set_physics_process(false)
	for ship_name in SHIPS:
		while not _main.get_node("StaticNavigation").is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame
	_survey.analysis_started.connect(func(id: int) -> void: _started.append([_tick, id]))
	_survey.surveyed.connect(func(id: int, level: int) -> void: _surveyed.append([id, level]))
	_field.generate(SEED)

	_test_deposits()
	_test_reproducible()
	_test_geometry_untouched()
	_test_generic_scan()
	_test_mining_scan()
	_test_no_downgrade_no_reanalysis()
	_test_upgrade_and_concurrency()
	_test_shared()
	_test_origin_fixed()
	_test_cooldowns()
	_test_orders_untouched()
	_test_markers()
	_test_hover()
	await _test_ui()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# 1-3: every deposit of this field and of 50 other seeds.
func _test_deposits() -> void:
	var minerals_ok := true
	var ice_ok := true
	var reserves_ok := true
	var read_only := true
	var families := {}
	for field_seed in range(1, 51) + [SEED]:
		for id: int in _field.ids():
			var deposit := AsteroidField.make_deposit(field_seed, id, _field.mineral_share, _field.min_reserves, _field.max_reserves)
			families[deposit.family] = true
			read_only = read_only and deposit.composition.is_read_only()
			if deposit.family == AsteroidField.Family.MINERALS:
				var keys := []
				var total := 0
				for key: StringName in deposit.composition:
					keys.append(String(key))
					var percent: int = deposit.composition[key]
					total += percent
					minerals_ok = minerals_ok and percent >= 1
				keys.sort()
				minerals_ok = minerals_ok and keys == SIX and total == 100
			else:
				ice_ok = ice_ok and deposit.composition == {&"ice": 100}
			reserves_ok = reserves_ok and deposit.reserves > 0 and deposit.reserves >= _field.min_reserves and deposit.reserves <= _field.max_reserves
	_check("1. mineral compositions: the six minerals, each >= 1 %, total 100 %", minerals_ok)
	_check("2. ice compositions: ice 100 % only", ice_ok)
	_check("3. finite reserves within %d-%d units" % [_field.min_reserves, _field.max_reserves], reserves_ok)
	_check("both families generated", families.size() == 2)
	_check("compositions are read-only", read_only)


func _test_reproducible() -> void:
	var ids := _field.ids()
	var by_meta := []
	for child in _field.get_children():
		by_meta.append(child.get_meta(AsteroidField.ID_META))
	by_meta.sort()
	_check("36 stable ids from node metadata (1-36)", ids.size() == 36 and ids == by_meta and ids == range(1, 37))
	var first := _snapshot()
	_field.generate(SEED + 1)
	var other := _snapshot()
	_field.generate(SEED)
	_check("4. the same seed reproduces the same deposits", _snapshot() == first)
	_check("a different seed gives a different field", other != first)
	var families := {}
	for id: int in ids:
		families[_field.deposit(id).family] = true
	_check("this seed's field holds both families", families.size() == 2)


# The resource data leaves the asteroid meshes, navigation and collision alone.
func _test_geometry_untouched() -> void:
	var fresh := MAIN.instantiate()
	var same := true
	for child: Node3D in _field.get_children():
		var original := fresh.get_node("Asteroids/" + String(child.name)) as MeshInstance3D
		same = same and original.transform == child.transform and original.mesh.radius == (child as MeshInstance3D).mesh.radius
	fresh.free()
	_check("asteroid transforms and meshes as saved", same)
	# 36 asteroids plus each station's body and two arms (Stage 3; two stations since Stage 6, three since Phase 4).
	_check("navigation and collision read the 36 asteroids (+9 station boxes)", _main.get_node("StaticNavigation")._obstacles.size() == 45
		and _main.get_node("PlanarCollision")._obstacles.size() == 45)


func _test_generic_scan() -> void:
	_reset()
	_place("Transporter", SCAN_POINT)
	var radius: float = _scanner("Transporter").radius
	var expected := _within(SCAN_POINT, radius)
	_check("layout: some asteroids inside and some outside the scan", not expected.is_empty() and expected.size() < 36)
	_scanner("Transporter").activate()
	_run_until_idle()
	var ok := true
	var texts_ok := true
	for id: int in _field.ids():
		var level := _survey.level_of(id)
		ok = ok and level == (Survey.Level.IDENTIFIED if expected.has(id) else Survey.Level.UNKNOWN)
		if expected.has(id):
			var text: String = _hover.describe(id)
			texts_ok = texts_ok and not text.contains("%") and not text.contains("units")
	_check("5. Generic Scanner identifies the families only (%d asteroids)" % expected.size(), ok and texts_ok)
	_check("9. only asteroids within the activation radius are affected", ok)


func _test_mining_scan() -> void:
	_reset()
	_place("Miner1", SCAN_POINT)
	var radius: float = _scanner("Miner1").radius
	var expected := _within(SCAN_POINT, radius)
	var activation := _tick
	_scanner("Miner1").activate()
	_run_until_idle()
	var ok := true
	for id: int in _field.ids():
		ok = ok and _survey.level_of(id) == (Survey.Level.ANALYZED if expected.has(id) else Survey.Level.UNKNOWN)
	var detail := true
	for id: int in expected:
		detail = detail and _hover.describe(id).contains("Remaining reserves: %d units" % _field.deposit(id).reserves)
	_check("6. Mining Scanner reveals composition and reserves", ok and detail)
	# Detection is progressive: in order of distance, when the pulse front arrives.
	var order := []
	var timing := true
	for entry: Array in _started:
		order.append(entry[1])
		var reach := _field.surface_distance(entry[1], SCAN_POINT)
		timing = timing and absf((entry[0] - activation) * DT - reach / _survey.pulse_speed) <= 2.0 * DT
	var by_distance := expected.duplicate()
	by_distance.sort_custom(func(a: int, b: int) -> bool: return _field.surface_distance(a, SCAN_POINT) < _field.surface_distance(b, SCAN_POINT))
	_check("detection in order of distance, as the pulse front arrives", order == by_distance and timing)


func _test_no_downgrade_no_reanalysis() -> void:
	# Continues from the Mining scan: everything in range is ANALYZED.
	var analyzed := _within(SCAN_POINT, _scanner("Miner1").radius)
	_started.clear()
	_place("Transporter", SCAN_POINT)
	_scanner("Transporter").activate()
	_run_until_idle()
	var kept := true
	for id: int in analyzed:
		kept = kept and _survey.level_of(id) == Survey.Level.ANALYZED
	_check("7. a later Generic scan does not downgrade analyzed asteroids", kept)
	_check("13. known information is not reanalyzed (Generic over analyzed)", _started.is_empty())
	_scanner("Miner1").cooldown_left = 0.0
	_scanner("Miner1").activate()
	_run_until_idle()
	_check("13. known information is not reanalyzed (Mining over analyzed)", _started.is_empty())


func _test_upgrade_and_concurrency() -> void:
	_reset()
	_place("Transporter", SCAN_POINT)
	_place("Miner1", SCAN_POINT + Vector2(0, 12))
	var expected := _within(SCAN_POINT, _scanner("Transporter").radius)
	_scanner("Transporter").activate()
	_run_until_idle()
	_started.clear()
	_scanner("Transporter").cooldown_left = 0.0
	_scanner("Transporter").activate()
	_run_until_idle()
	_check("13. identified asteroids are not reanalyzed at the same level", _started.is_empty())
	var both := _within(SCAN_POINT, _scanner("Transporter").radius).filter(func(id: int) -> bool:
		return _field.surface_distance(id, SCAN_POINT + Vector2(0, 12)) <= _scanner("Miner1").radius)
	_scanner("Miner1").activate()
	_run_until_idle()
	var upgraded := true
	for id: int in both:
		upgraded = upgraded and _survey.level_of(id) == Survey.Level.ANALYZED
	var started_ids := _started.map(func(entry: Array) -> int: return entry[1])
	_check("an Identified asteroid upgrades to Analyzed with a new analysis", upgraded and not both.is_empty() and started_ids.has(both[0]))

	# Two scans over the same asteroids at once (Generic and Mining, same point and
	# tick), and a Mining scan arriving while a Generic analysis is uploading.
	_reset()
	_place("Transporter", SCAN_POINT)
	_place("Miner1", SCAN_POINT)
	both = _within(SCAN_POINT, _scanner("Miner1").radius)
	_scanner("Transporter").activate()
	_scanner("Miner1").activate()
	_run_until_idle()
	var counts := {}
	for entry: Array in _started:
		counts[entry[1]] = counts.get(entry[1], 0) + 1
	var single := true
	for id: int in counts:
		single = single and counts[id] == 1
	var final_ok := true
	for id: int in expected:
		final_ok = final_ok and _survey.level_of(id) == (Survey.Level.ANALYZED if both.has(id) else Survey.Level.IDENTIFIED)
	_check("concurrent scans: one analysis per asteroid, the higher level kept", single and final_ok)
	_reset()
	_place("Transporter", SCAN_POINT)
	_place("Miner1", SCAN_POINT)
	_scanner("Transporter").activate()
	var target: int = _within(SCAN_POINT, _scanner("Transporter").radius)[0]
	while _survey.analysis(target).is_empty() or _survey.analysis(target).phase != Survey.Phase.UPLOADING:
		_steps(1)
	_scanner("Miner1").activate()
	_run_until_idle()
	var levels := _surveyed.filter(func(entry: Array) -> bool: return entry[0] == target).map(func(entry: Array) -> int: return entry[1])
	_check("7. Mining during a Generic upload: Identified, then Analyzed, never down (%s)" % str(levels),
		levels == [Survey.Level.IDENTIFIED, Survey.Level.ANALYZED] and _survey.level_of(target) == Survey.Level.ANALYZED)
	var never_down := true
	var last := {}
	for entry: Array in _surveyed:
		never_down = never_down and entry[1] >= last.get(entry[0], Survey.Level.UNKNOWN)
		last[entry[0]] = entry[1]
	_check("7. surveyed levels never decrease", never_down)


func _test_shared() -> void:
	_reset()
	_place("Transporter", SCAN_POINT)
	_scanner("Transporter").activate()
	_run_until_idle()
	var id: int = _within(SCAN_POINT, _scanner("Transporter").radius)[0]
	var texts := []
	for ship_name in SHIPS:
		_main.get_node("Selection").set_selection([_ship(ship_name)])
		texts.append(_hover.describe(id))
	_main.get_node("Selection").set_selection([])
	_check("8. one fleet survey: both scanners report to it", _scanner("Transporter")._survey == _survey and _scanner("Miner1")._survey == _survey)
	_check("8. a Transporter survey reads the same whichever ship is selected", texts[0] == texts[1] and texts[1] == texts[2] and _survey.level_of(id) == Survey.Level.IDENTIFIED)


func _test_origin_fixed() -> void:
	_reset()
	var pulse_speed := _survey.pulse_speed
	var radius: float = _scanner("Miner1").radius
	_survey.pulse_speed = 2.0 # Slow pulse: the ship travels far while it expands.
	_scanner("Miner1").radius = 20.0
	_place("Miner1", SCAN_POINT)
	var destination := Vector2(60, -15)
	_node("Miner1", "RouteFollower").order(destination)
	_scanner("Miner1").activate()
	_run_until_idle()
	var end := _node("Miner1", "Locomotion").planar_position as Vector2
	var from_origin := _within(SCAN_POINT, 20.0)
	var from_end := _within(end, 20.0)
	var ok := true
	for id: int in _field.ids():
		ok = ok and (_survey.level_of(id) == Survey.Level.ANALYZED) == from_origin.has(id)
	_check("layout: the ship ends %.0f u away with different asteroids in range" % end.distance_to(SCAN_POINT), from_end != from_origin)
	_check("10. coverage stays at the activation point while the ship moves", ok)
	_survey.pulse_speed = pulse_speed
	_scanner("Miner1").radius = radius


func _test_cooldowns() -> void:
	_reset()
	_place("Transporter", SCAN_POINT)
	_place("Miner1", SCAN_POINT + Vector2(0, 12))
	_check("Transporter, FF01: Generic; Miners: Mining", _scanner("Transporter").kind == 0
		and _scanner("FF01").kind == 0 and _scanner("Miner1").kind == 1 and _scanner("Miner2").kind == 1)
	var first: bool = _scanner("Transporter").activate()
	var again: bool = _scanner("Transporter").activate()
	var other: bool = _scanner("Miner1").activate()
	_check("11. the Transporter's cooldown blocks only the Transporter", first and not again and other)
	_steps(roundi(2.9 / DT))
	var early: bool = _scanner("Transporter").activate()
	_steps(roundi(0.15 / DT))
	var ready: bool = _scanner("Transporter").activate()
	_check("cooldown of %.0f s from activation" % _scanner("Transporter").cooldown, not early and ready)
	_run_until_idle()


# 12: the same order flown with and without scans gives the same trajectory.
func _test_orders_untouched() -> void:
	var runs := []
	for scanning in [false, true]:
		_reset()
		_place("Transporter", Vector2(-12, 0))
		_place("Miner1", SCAN_POINT)
		_place("FF01", Vector2(14, 0))
		_node("Miner1", "RouteFollower").order(Vector2(60, -15))
		var plans: int = _node("Miner1", "RouteFollower").plans
		var destination: Vector2 = _node("Miner1", "Locomotion").destination
		for tick in 600:
			if scanning and tick % 200 == 0:
				_scanner("Miner1").activate()
			_steps(1)
		var locomotion := _node("Miner1", "Locomotion")
		runs.append([locomotion.planar_position, locomotion.velocity, locomotion.heading,
			_node("Miner1", "RouteFollower").plans - plans, locomotion.destination == destination])
	_check("12. scanning leaves the order alone (no replans, same destination)", runs[1][3] == 0 and runs[1][4])
	_check("12. the same trajectory with and without scans", runs[0][0] == runs[1][0] and runs[0][1] == runs[1][1] and runs[0][2] == runs[1][2])


func _test_markers() -> void:
	_reset()
	_place("Miner1", SCAN_POINT)
	var expected := _within(SCAN_POINT, _scanner("Miner1").radius)
	var id: int = expected[0]
	_check("14. marker before scanning: Asteroid", _view.marker_of(id) == SurveyView.Marker.ASTEROID)
	_scanner("Miner1").activate()
	while _survey.analysis(id).is_empty():
		_steps(1)
	var during: bool = _view.marker_of(id) == SurveyView.Marker.ASTEROID and _hover.describe(id) == "Asteroid\nNot scanned"
	while _survey.analysis(id).is_empty() or _survey.analysis(id).phase != Survey.Phase.UPLOADING:
		_steps(1)
	during = during and _view.marker_of(id) == SurveyView.Marker.ASTEROID and _survey.level_of(id) == Survey.Level.UNKNOWN
	_check("nothing is revealed before the upload completes", during)
	_run_until_idle()
	var ok := true
	for target: int in expected:
		var family := _field.deposit(target).family
		ok = ok and _view.marker_of(target) == (SurveyView.Marker.MINERALS if family == AsteroidField.Family.MINERALS else SurveyView.Marker.ICE)
	_check("14. after analysis the marker matches the family (analyzed minerals: Minerals)", ok)
	_check("marker for each level and family", SurveyView.marker_for(Survey.Level.IDENTIFIED, AsteroidField.Family.ICE) == SurveyView.Marker.ICE
		and SurveyView.marker_for(Survey.Level.ANALYZED, AsteroidField.Family.MINERALS) == SurveyView.Marker.MINERALS
		and SurveyView.marker_for(Survey.Level.UNKNOWN, AsteroidField.Family.MINERALS) == SurveyView.Marker.ASTEROID)


func _test_hover() -> void:
	_reset()
	var mineral := -1
	var ice := -1
	for id: int in _field.ids():
		if _field.deposit(id).family == AsteroidField.Family.MINERALS and mineral < 0:
			mineral = id
		elif _field.deposit(id).family == AsteroidField.Family.ICE and ice < 0:
			ice = id
	var deposit := _field.deposit(mineral)
	var ok: bool = _hover.describe(mineral) == "Asteroid\nNot scanned" and _hover.describe(ice) == "Asteroid\nNot scanned"
	_survey._levels[mineral] = Survey.Level.IDENTIFIED
	_survey._levels[ice] = Survey.Level.IDENTIFIED
	ok = ok and _hover.describe(mineral) == "Asteroid Minerals\nComposition unknown\nReserves unknown"
	ok = ok and _hover.describe(ice) == "Asteroid Ice\nReserves unknown"
	_survey._levels[mineral] = Survey.Level.ANALYZED
	_survey._levels[ice] = Survey.Level.ANALYZED
	var lines := ["Asteroid Minerals"]
	for title in ["Iron", "Nickel", "Silicon", "Cobalt", "Gold", "Titanium"]:
		lines.append("%s %d%%" % [title, deposit.composition[StringName(title.to_lower())]])
	lines.append("Remaining reserves: %d units" % deposit.reserves)
	ok = ok and _hover.describe(mineral) == "\n".join(lines)
	ok = ok and _hover.describe(ice) == "Asteroid Ice\nRemaining reserves: %d units" % _field.deposit(ice).reserves
	_check("15. hover text for each survey level and family", ok)
	var before := deposit.reserves
	deposit.reserves -= 100
	_check("analyzed reserves are read live", _hover.describe(mineral).contains("Remaining reserves: %d units" % (before - 100)))
	deposit.reserves = before


# Ship panel and hover through input events pushed into the viewport (the GUI sees
# them first, as in the game).
func _test_ui() -> void:
	_reset()
	var selection := _main.get_node("Selection")
	var panel := _main.get_node("ShipPanel")
	var rig := _main.get_node("CameraRig")
	var camera: Camera3D = _main.get_node("CameraRig/Camera3D")
	_place("Miner1", SCAN_POINT)
	_place("Transporter", SCAN_POINT + Vector2(-8, 4))
	rig.global_position = Vector3(SCAN_POINT.x, 0, SCAN_POINT.y)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = 40.0
	rig._apply_zoom()
	await process_frame
	var button: Button = panel.get_node("Panel/Layout/Scroll/Body/Actions/ScanArea")
	selection.set_selection([_ship("Miner1")])
	await process_frame
	_check("panel: one ship selected shows its scanner and Scan Area", panel.get_node("Panel").visible and button.visible
		and panel.get_node("Panel/Layout/Scroll/Body/Actions/Equipment").text == "Mining Scanner")
	selection.set_selection([_ship("Miner1"), _ship("Transporter")])
	await process_frame
	_check("panel: several ships selected, no shared Scan Area", not panel.get_node("Panel").visible)
	selection.set_selection([_ship("FF01")])
	await process_frame
	_check("panel: FF01 shows its Generic Scanner and Scan Area", panel.get_node("Panel").visible and button.visible
		and panel.get_node("Panel/Layout/Scroll/Body/Actions/Equipment").text == "Generic Scanner")
	# Every ship carries a scanner now: the no-scanner case with the FF01's taken off.
	var scanner := _scanner("FF01")
	_ship("FF01").remove_child(scanner)
	selection.set_selection([])
	selection.set_selection([_ship("FF01")])
	await process_frame
	_check("panel: a ship without a scanner shows No scanner, no Scan Area", panel.get_node("Panel").visible and not button.visible
		and panel.get_node("Panel/Layout/Scroll/Body/Actions/Equipment").text == "No scanner")
	_ship("FF01").add_child(scanner)
	scanner.set_physics_process(false)
	selection.set_selection([_ship("Miner1")])
	await process_frame
	var plans: int = _node("Miner1", "RouteFollower").plans
	_click(button.get_global_rect().get_center())
	await process_frame
	_check("Scan Area button: scan started, selection kept, no order", _scanner("Miner1").cooldown_left > 0.0 and _survey.active_scans() == 1
		and selection.selected == [_ship("Miner1")] and _node("Miner1", "RouteFollower").plans == plans)
	_check("Scan Area shows the cooldown and is disabled", button.disabled and button.text.begins_with("Scan Area ("))
	_click(button.get_global_rect().get_center())
	await process_frame
	_check("a click during the cooldown starts no second scan", _survey.active_scans() == 1)
	var ship_screen := camera.unproject_position(_ship("Transporter").global_position)
	_click(ship_screen)
	_check("clicking a ship still selects it with the panel shown", selection.selected == [_ship("Transporter")])
	_run_until_idle()
	# Headless runs have no real cursor: the screen-point lookup is checked directly.
	var view := root.get_visible_rect()
	var on_screen := _within(SCAN_POINT, _scanner("Miner1").radius).filter(func(target: int) -> bool:
		return view.has_point(camera.unproject_position(_field.center(target))))
	var id: int = on_screen[0]
	var empty := camera.unproject_position(Vector3(70, 0, 66))
	_check("hover lookup: the asteroid under a point", _hover.asteroid_at(camera.unproject_position(_field.center(id))) == id)
	_check("hover lookup: none over a ship or empty space", _hover.asteroid_at(camera.unproject_position(_ship("Transporter").global_position)) == -1
		and _hover.asteroid_at(empty) == -1)
	_click(empty)
	_check("clicking empty ground still clears the selection", selection.selected.is_empty())


func _click(position: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		event.global_position = position
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		root.push_input(event, true)


func _snapshot() -> Array:
	var rows := []
	for id: int in _field.ids():
		var deposit := _field.deposit(id)
		rows.append([id, deposit.family, deposit.composition.duplicate(), deposit.reserves])
	return rows


# Asteroids with any part within `radius` of a point (from the scene transforms).
func _within(point: Vector2, radius: float) -> Array:
	var ids := []
	for child: Node3D in _field.get_children():
		var center := Vector2(child.global_position.x, child.global_position.z)
		if center.distance_to(point) - 0.5 * child.scale.x <= radius:
			ids.append(child.get_meta(AsteroidField.ID_META))
	ids.sort()
	return ids


func _reset() -> void:
	_survey._levels.clear()
	_survey._analyses.clear()
	_survey._scans.clear()
	_started.clear()
	_surveyed.clear()
	for ship_name in SHIPS:
		var scanner := _scanner(ship_name)
		if scanner != null:
			scanner.cooldown_left = 0.0
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
	_place("Transporter", Vector2(-12, 0))
	_place("Miner1", Vector2(-8, 14))
	_place("Miner2", Vector2(8, 14))
	_place("FF01", Vector2(14, 0))


func _run_until_idle() -> void:
	for i in 60 * 120:
		if _survey.active_scans() == 0 and _survey.analyzing_ids().is_empty():
			return
		_steps(1)


func _steps(count: int) -> void:
	for i in count:
		_tick += 1
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_node(ship_name, "Locomotion")._step(DT)
		for ship_name in SHIPS:
			var scanner := _scanner(ship_name)
			if scanner != null:
				scanner._physics_process(DT)
		_survey.advance(DT)


func _place(ship_name: String, point: Vector2) -> void:
	_node(ship_name, "Locomotion").place(point, 0.0)


func _ship(ship_name: String) -> Node3D:
	return _main.get_node("Ships/" + ship_name)


func _node(ship_name: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [ship_name, child])


func _scanner(ship_name: String) -> Node:
	return _main.get_node_or_null("Ships/%s/Scanner" % ship_name)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-85s %s" % [label, "PASS" if ok else "FAIL"])
