extends "res://game/tests/combat/launch_profiles_test.gd"
## Barrage correction: deterministic physical flight telemetry on Combat Test.
## Append -- --measure-only to capture a pre-correction baseline without accuracy gates.
## Append -- --visual for the rendered production-scene inspection inherited below.

const AGILE_UNIT := preload("res://game/ships/miner_unit.tscn") # The most agile hull (small-hull handling).

var measured: Dictionary = {}
var measure_only := false
var case_label := ""
var motion_control := {}


func _initialize() -> void:
	if "--visual" in OS.get_cmdline_user_args():
		DisplayServer.window_set_title("Apalit - Barrage correction inspection")
		await super._initialize()
		return
	await process_frame
	measure_only = "--measure-only" in OS.get_cmdline_user_args()
	await _acceleration_profile()
	await _stationary_samples()
	await _acquisition_boundary()
	await _committed_continuation()
	await _moving_samples()
	await _agile_controls()
	await _missile_signatures()
	scene.free()
	await process_frame
	_check("trajectory telemetry leaves no orphan nodes", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if failures == 0 else "FAIL", failures, checks])
	quit(1 if failures else 0)


func _acceleration_profile() -> void:
	await _prepare(45.0, 1.0, 1, "configured acceleration control")
	var authoritative: Resource = barrage.config
	barrage.config = authoritative.duplicate(true)
	var acceleration: float = barrage.config.ordnance.acceleration
	var locomotion := victim.get_node("Locomotion")
	locomotion.move_to(SITE + Vector2(45, -80))
	for frame in 120:
		locomotion._physics_process(DT)
	scene.sensors.evaluate()
	var actual: Array = barrage._solution(victim)
	barrage.config.ordnance.acceleration = acceleration * 2.0
	var faster: Array = barrage._solution(victim)
	barrage.config.ordnance.acceleration = acceleration
	_check("initial intercept uses the configured acceleration, without mutating the shared resource",
		actual[0] and faster[0] and actual[2] > faster[2] and (actual[1] as Vector3).distance_to(faster[1]) > 0.1 and authoritative.ordnance.acceleration == acceleration)
	barrage.step(DT)
	var rocket: Node3D = projectiles.ordnance[0]
	_check("salvo captures the intercept computed for the actual acceleration", rocket.locked_point.is_equal_approx(actual[1]))
	while rocket.phase != "flight":
		projectiles._physics_process(DT)
	var start_speed: float = rocket.speed()
	var half_speed := 0.0
	var continuous := true
	for frame in 44:
		var previous: Vector3 = rocket.velocity
		projectiles._physics_process(DT)
		continuous = continuous and rocket.velocity.distance_to(previous) <= acceleration * DT + 0.0001 and rocket.velocity.angle_to(previous) < 0.0001
		if frame == 21:
			half_speed = rocket.speed()
	_check("30 u/s2 ramp stays continuous and straight: 8 to 19 to 30 u/s over 44 ticks",
		continuous and absf(start_speed - 8.0) < 0.001 and absf(half_speed - 19.0) < 0.001 and absf(rocket.speed() - 30.0) < 0.001)
	print("ACCELERATION_PROFILE acceleration=%.1f; start=%.6f; at_0.366667s=%.6f; at_0.733333s=%.6f; lead_time=%.6f; doubled_acceleration_lead_time=%.6f" % [acceleration, start_speed, half_speed, rocket.speed(), actual[2], faster[2]])


func _prepare(distance: float, side: float, seed_value: int, label: String) -> void:
	await _load(distance, side, seed_value)
	wayfarer.enabled = false
	measured.clear()
	case_label = label
	projectiles.ordnance_launched.connect(func(n: Node3D) -> void:
		if n.kind == &"rocket":
			measured[n.id] = {"node": n, "last": n.global_position, "closest_center": INF, "point": n.locked_point, "transition": {}, "max_dv": 0.0, "last_velocity": n.velocity, "locked": true})


func _tick(move_owner := false, move_target := false, defend := false) -> void:
	super._tick(move_owner, move_target, defend)
	for id: int in measured:
		var sample: Dictionary = measured[id]
		if sample.get("ended", false):
			continue
		var n: Node3D = sample.node
		if not is_instance_valid(n):
			continue
		var position: Vector3 = n.global_position if n.is_inside_tree() else sample.last
		if not n.live:
			for record: Dictionary in projectiles.ordnance_records:
				if record.id == id:
					position = record.point
					break
		var near := Geometry3D.get_closest_point_to_segment(victim.global_position, sample.last, position)
		sample.closest_center = minf(sample.closest_center, near.distance_to(victim.global_position))
		sample.last = position
		sample.max_dv = maxf(sample.max_dv, n.velocity.distance_to(sample.last_velocity))
		sample.last_velocity = n.velocity
		sample.locked = sample.locked and n.locked_point == sample.point and not n.homing()
		if n.live and n.phase == "flight" and sample.transition.is_empty():
			var ray: Vector3 = n.dispersion * (n.locked_point - position).normalized()
			sample.transition = {"age": n.age, "elapsed": n.transition_elapsed,
				"end": "timeout" if n.transition_elapsed >= n.config.transition_timeout - 0.000001 else "aligned",
				"position": _xyz(position), "heading": _xyz(n.forward()), "velocity": _xyz(n.velocity),
				"nose_error_deg": rad_to_deg(n.forward().angle_to(ray)), "velocity_error_deg": rad_to_deg(n.velocity.angle_to(ray))}
		sample["ended"] = not n.live


func _xyz(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


func _report() -> Dictionary:
	var records: Array = projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.kind == "rocket")
	var hits := 0
	var aligned := 0
	var timed_out := 0
	var misses: Array[float] = []
	var max_velocity_error := 0.0
	var max_dv := 0.0
	for record: Dictionary in records:
		var sample: Dictionary = measured[record.id]
		hits += int(record.outcome == "damage")
		if record.outcome != "damage":
			misses.append(sample.closest_center)
		if not sample.transition.is_empty():
			aligned += int(sample.transition.end == "aligned")
			timed_out += int(sample.transition.end == "timeout")
			max_velocity_error = maxf(max_velocity_error, sample.transition.velocity_error_deg)
		max_dv = maxf(max_dv, sample.max_dv)
		print("ROCKET " + JSON.stringify({"case": case_label, "id": record.id, "outcome": record.outcome,
			"closest_center_u": sample.closest_center, "traveled_u": record.traveled, "end_age_s": record.age,
			"launch_point": _xyz(record.origin), "end_position": _xyz(record.point), "locked_intercept": _xyz(sample.point),
			"transition": sample.transition, "max_tick_velocity_change": sample.max_dv, "solution_unchanged": sample.locked}))
	var summary := {"case": case_label, "launched": barrage.shots, "hits": hits, "aligned": aligned, "timeouts": timed_out,
		"miss_closest_center_u": misses, "max_transition_velocity_error_deg": max_velocity_error, "max_tick_velocity_change": max_dv,
		"authorization": barrage.reason}
	print("SUMMARY " + JSON.stringify(summary))
	return summary


func _stationary_samples() -> void:
	# All distances here are target-center distance from the fire-control muzzle.
	for distance in [25.0, 45.0, 55.0, 60.0]:
		for side in [-1.0, 1.0]:
			var total_hits := 0
			var total_launched := 0
			for seed_value in [1, 2, 3, 4, 5]:
				await _prepare_muzzle(distance, side, seed_value, "muzzle stationary %+.0fu seed %d" % [side * distance, seed_value])
				await _run(4.9)
				var summary := _report()
				total_hits += summary.hits
				total_launched += summary.launched
				_check("stationary muzzle-distance telemetry accounts for launches", summary.launched == 8 and measured.size() == summary.launched and physical)
			if not measure_only:
				_check("stationary %+.0f u: dispersed salvos produce physical hits" % (side * distance), total_hits > 0)
			print("DISTRIBUTION muzzle %+.0fu: %d/%d physical hits (seeds 1-5)" % [side * distance, total_hits, total_launched])
	# Central, dispersion-free controls distinguish steering defects from legitimate spread.
	for distance in [25.0, 45.0, 55.0, 60.0]:
		for side in [-1.0, 1.0]:
			await _prepare_muzzle(distance, side, 1, "muzzle central control %+.0fu" % (side * distance))
			barrage.config = barrage.config.duplicate(true)
			barrage.config.dispersion_max_deg = 0.0
			await _run(4.9)
			var summary := _report()
			if not measure_only:
				_check("central stationary control hits every rocket at %+.0f u" % (side * distance), summary.hits == 8 and summary.aligned == 8 and summary.max_transition_velocity_error_deg < 0.01)


func _prepare_muzzle(distance: float, side: float, seed_value: int, label: String) -> void:
	await _prepare(distance, side, seed_value, label)
	var reference: Vector3 = barrage.muzzle.global_position
	_place(victim, Vector2(reference.x + side * distance, reference.z))
	scene.sensors.evaluate()
	_check("%s: measured from the fire-control muzzle" % label, absf(reference.distance_to(victim.global_position) - distance) < 0.0001)


func _acquisition_boundary() -> void:
	for side in [-1.0, 1.0]:
		for distance in [60.01, 61.0, 65.0, 70.0]:
			await _prepare_muzzle(distance, side, 1, "outside acquisition %+.2fu" % (side * distance))
			var assessment: Dictionary = barrage.assess(victim)
			await _run(1.2)
			_check("%s: cannot initiate a salvo beyond acquisition" % case_label,
				assessment.state == CombatShip.TargetState.OUT_OF_RANGE and barrage.shots == 0 and barrage.salvos == 0
				and barrage.rounds_left() == 48 and projectiles.launched == 0 and barrage.offensive_reach() == 60.0)
			_report()


func _committed_continuation() -> void:
	for side in [-1.0, 1.0]:
		await _prepare_muzzle(60.0, side, 1, "committed continuation %+.0fu" % (side * 60))
		barrage.config = barrage.config.duplicate(true)
		barrage.config.dispersion_max_deg = 0.0
		var reference: Vector3 = barrage.muzzle.global_position
		barrage.step(DT)
		var locked: Vector3 = barrage.salvo_point
		# Let the committed rockets pass their aim point, with no hull there to stop them.
		_place(victim, Vector2(2000, 2000))
		scene.sensors.evaluate()
		await _run(4.9)
		var summary := _report()
		var records: Array = projectiles.ordnance_records.filter(func(r: Dictionary) -> bool: return r.kind == "rocket")
		var radii := records.map(func(r: Dictionary) -> float: return reference.distance_to(r.point))
		_check("committed rockets continue beyond 60 u without updating the solution",
			summary.launched == 8 and records.size() == 8 and measured.values().all(func(s: Dictionary) -> bool: return s.locked and s.point == locked)
			and records.all(func(r: Dictionary) -> bool: return r.outcome == "expired" and absf(r.traveled - 70.0) < 0.0001 and r.age < 4.0 and reference.distance_to(r.point) > 60.0) and physical)
		print("CONTINUATION " + JSON.stringify({"case": case_label, "end_distance_from_fire_control_muzzle_u": radii, "acquisition_u": barrage.config.weapon_range, "total_travel_allowance_u": barrage.config.ordnance.max_travel}))


func _moving_samples() -> void:
	for side in [-1.0, 1.0]:
		for mode in ["steady", "abrupt", "moving launcher", "rotating launcher"]:
			await _prepare(45.0, side, 7, "%s %+.0fu" % [mode, side * 45])
			var owner_motion: bool = mode in ["moving launcher", "rotating launcher"]
			var target_motion: bool = mode in ["steady", "abrupt"]
			if mode == "moving launcher":
				attacker.get_node("Locomotion").move_to(SITE + Vector2(0, -80))
				for frame in 120:
					attacker.get_node("Locomotion")._physics_process(DT)
			elif mode == "rotating launcher":
				attacker.get_node("Locomotion").face(PI * 0.5)
			if target_motion:
				victim.get_node("Locomotion").move_to(SITE + Vector2(45 * side, -80))
				for frame in 120:
					victim.get_node("Locomotion")._physics_process(DT)
			for frame in 300:
				_tick(owner_motion, target_motion)
				if frame == 60 and mode == "abrupt":
					victim.get_node("Locomotion").move_to(SITE + Vector2(90 * side, 50))
			var summary := _report()
			_check("%s: all rockets retain one solution" % case_label, measured.size() == 8 and measured.values().all(func(s: Dictionary) -> bool: return s.locked))
			if not measure_only:
				_check("%s: finite launch and continuous attack acceleration" % case_label, physical and summary.max_tick_velocity_change <= barrage.config.ordnance.acceleration * DT + 0.001)
			if mode == "steady":
				motion_control[str(side)] = summary.hits
			elif mode == "abrupt" and not measure_only:
				_check("sudden target course change can evade the committed solution", summary.hits < 8)


func _missile_signatures() -> void:
	for distance in [25.0, 45.0, 60.0]:
		for side in [-1.0, 1.0]:
			await _load(distance, side)
			barrage.enabled = false
			var trace: Array = []
			for frame in 550:
				super._tick()
				for node in projectiles.ordnance:
					if node.kind == &"missile":
						trace.append([node.phase, _xyz(node.global_position), _xyz(node.velocity), _xyz(node.goal)])
			print("WAYFARER_SIGNATURE %+.0fu %s" % [side * distance, JSON.stringify(trace).sha256_text()])


func _agile_controls() -> void:
	# Use the production Miner's real small-hull handling for a sharper maneuver; no movement
	# parameters, velocities or positions are changed after its initial placement.
	for side in [-1.0, 1.0]:
		var steady_hits := 0
		for abrupt in [false, true]:
			await _prepare(25.0, side, 7, "agile %s control %+.0fu" % ["abrupt" if abrupt else "steady", side * 25])
			_place(victim, Vector2(2000, 2000))
			victim = AGILE_UNIT.instantiate()
			victim.name = "AgileTarget"
			victim.position.y = 1.5
			victim.get_node("Combat").faction = 1
			scene.get_node("Ships").add_child(victim)
			scene.register_ship(victim)
			_quiet(victim)
			_place(victim, SITE + Vector2(side * 25, 0))
			var locomotion := victim.get_node("Locomotion")
			locomotion.move_to(SITE + Vector2(side * 25, -80))
			for frame in 120:
				locomotion._physics_process(DT)
			scene.sensors.evaluate()
			CombatShip.of(attacker).assign_target(victim)
			CombatShip.of(attacker).target = victim
			barrage.config = barrage.config.duplicate(true)
			barrage.config.dispersion_max_deg = 0.0
			for frame in 300:
				_tick(false, true)
				if abrupt and frame == 15:
					locomotion.move_to(SITE + Vector2(side * 90, 40))
			var summary := _report()
			if not abrupt:
				steady_hits = summary.hits
			elif not measure_only:
				_check("production small-hull (Miner) maneuver defeats hits from the same locked solution", steady_hits > 0 and summary.hits < steady_hits)


func _preview() -> void:
	# Hold an actual simulated impact frame for inspection, then continue the normal
	# moving/rotating preview. Pausing changes no trajectory or collision result.
	for side in [-1.0, 1.0]:
		await _load(45.0, side)
		scene.set_meta("visual_case", "%+.0f u, stationary" % (45 * side))
		await _run(3.25)
		scene.get_node("VisualInfo").text += " | paused impact inspection"
		paused = true
		await create_timer(20.0, true).timeout
		paused = false
	await super._preview()
