extends SceneTree
## Headless Stage 4 avoidance prototype checks on the real lab scene.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/avoidance_test.gd
## Scenarios from scenes/avoidance_scenarios.gd: head-on, crossing from either side
## and overtaking for every ship pairing (smaller/faster ship first), a moving ship
## past a parked ship (centred and offset), and the combined encounter. Physics is
## stepped manually at 60 Hz in the game's order (per ship RouteFollower then
## Avoidance, then every Locomotion).
## PASS/FAIL: locomotion limits (acceleration ellipse, turn rate and acceleration),
## no ship footprint overlap with an obstacle, no contact between ship footprints
## (bounding circles). Reported: outcome (arrived / stable WAITING / still moving),
## added time against the same move alone, actual minimum footprint gap, route
## deviation, drift and turn-rate reversals (alone -> contested), the avoidance
## responses and decision changes, and the avoidance cost per ship per tick.

const LAB := preload("res://game/scenes/movement_test.tscn")
const Scenarios := preload("res://game/scenes/avoidance_scenarios.gd")
const DT := 1.0 / 60.0
const TIME_LIMIT := 180.0 # s per scenario
const STABLE_WAIT := 10.0 # s waiting with no change ends a scenario as a stable wait
const SLACK := 1.0e-4
const DRIFT_SHARE := 0.2 # of max_speed, as locomotion_test
const REVERSAL_RATE := 1.0 # deg/s; turn-rate sign changes above this count as reversals
const SHIPS := ["Frigate", "Gunship", "Destroyer"]
const PAIRS := [["Frigate", "Gunship"], ["Frigate", "Destroyer"], ["Gunship", "Destroyer"]]

var _failures := 0
var _lab: Node
var _obstacles: Array[Dictionary] = []
var _costs: Array[int] = []
var _alone := {} # "ship start target" -> run result


func _initialize() -> void:
	await process_frame
	_lab = LAB.instantiate()
	root.add_child(_lab)
	_read_obstacles()
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance"]:
			_node(ship_name, child).set_physics_process(false)
	for ship_name in SHIPS:
		while not _lab.get_node("StaticNavigation").is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame
	var profiles := {}
	for ship_name in SHIPS:
		var loco := _node(ship_name, "Locomotion")
		profiles[ship_name] = [loco.max_speed, loco.forward_accel]
	var scenarios := []
	for pair in PAIRS:
		scenarios.append(Scenarios.head_on(pair[0], pair[1], 0.0))
		scenarios.append(Scenarios.crossing(pair[0], pair[1], true, profiles))
		scenarios.append(Scenarios.crossing(pair[0], pair[1], false, profiles))
		scenarios.append(Scenarios.overtake(pair[0], pair[1]))
	for mover in [["Frigate", "Destroyer"], ["Gunship", "Destroyer"], ["Destroyer", "Gunship"]]:
		scenarios.append(Scenarios.parked(mover[0], mover[1], 0.0))
		scenarios.append(Scenarios.parked(mover[0], mover[1], 3.0))
	scenarios.append(Scenarios.combined())
	# Stage 5.3: shallow convergence (about 18 deg between the courses), the other ship
	# from either side, every pairing; appended so the accepted rows keep their order.
	for pair in PAIRS:
		scenarios.append(Scenarios.converging(pair[0], pair[1], true))
		scenarios.append(Scenarios.converging(pair[0], pair[1], false))
	print("scenario                                    ship       outcome          +time s  min gap u  responses                                    deviation u  drift s      reversals  changes r/u/s/f  checks")
	for scenario: Dictionary in scenarios:
		_contested(scenario)
	var costs := _costs.duplicate()
	costs.sort()
	var total := 0
	for cost in costs:
		total += cost
	print("avoidance step cost (all ships, contested runs): %d ship-ticks, mean %.1f us, 99th percentile %d us, max %d us" % [
		costs.size(), float(total) / costs.size(), costs[int(costs.size() * 0.99)], costs[costs.size() - 1]])
	print("RESULT: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


func _contested(scenario: Dictionary) -> void:
	var result := _simulate(scenario.movers, scenario.parked, true)
	var first := true
	for entry: Dictionary in scenario.movers:
		var ship_name: String = entry.ship
		var own: Dictionary = result.ships[ship_name]
		var alone := _alone_run(entry)
		var alone_own: Dictionary = alone.ships[ship_name]
		var added := "-"
		if own.arrived and alone_own.arrived:
			added = "%+.1f" % (own.time - alone_own.time)
		var errors: Array[String] = own.errors.duplicate()
		if first:
			errors.append_array(result.errors)
		_failures += 1 if not errors.is_empty() else 0
		var checks := "PASS" if errors.is_empty() else "FAIL: " + ", ".join(errors.slice(0, 3)) + (" (%d events)" % errors.size())
		print("%-43s %-10s %-16s %7s  %9s  %-44s %5.2f->%5.2f  %4.1f->%4.1f  %3d->%3d  %d/%d/%d/%d  %s" % [
			scenario.name if first else "", ship_name, own.outcome, added,
			"%.2f" % result.min_gap if first else "", ", ".join(own.responses) if not own.responses.is_empty() else "-",
			alone_own.deviation, own.deviation, alone_own.drift, own.drift, alone_own.reversals, own.reversals,
			own.counters[0], own.counters[1], own.counters[2], own.counters[3], checks])
		first = false


func _alone_run(entry: Dictionary) -> Dictionary:
	var key := "%s %s %s" % [entry.ship, entry.start, entry.target]
	if not _alone.has(key):
		_alone[key] = _simulate([entry], [], false)
	return _alone[key]


# Places the ships (movers facing their targets, named parked ships, the rest at the
# far parking points), orders the movers, and steps until every mover has arrived or
# waited STABLE_WAIT, or TIME_LIMIT.
func _simulate(movers: Array, parked: Array, record_costs: bool) -> Dictionary:
	var placements := {}
	for entry: Dictionary in parked:
		placements[entry.ship] = [entry.point, 0.0]
	for entry: Dictionary in movers:
		var travel: Vector2 = entry.target - entry.start
		placements[entry.ship] = [entry.start, atan2(-travel.x, -travel.y)]
	var parking := 0
	for ship_name in SHIPS:
		var placement: Array = placements.get(ship_name, [])
		if placement.is_empty():
			placement = [Scenarios.PARKING[parking], 0.0]
			parking += 1
		_node(ship_name, "Locomotion").place(placement[0], placement[1])
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
	var ships := {}
	for entry: Dictionary in movers:
		var follower := _node(entry.ship, "RouteFollower")
		follower.order(entry.target)
		ships[entry.ship] = {"route": follower.route.duplicate(), "arrived": false, "time": 0.0, "waiting_since": -1.0,
			"outcome": "", "errors": [] as Array[String], "deviation": 0.0, "drift": 0.0, "reversals": 0,
			"last_sign": 0.0, "responses": [] as Array[String], "counters": [0, 0, 0, 0]}
	var errors: Array[String] = []
	var min_gap := INF
	var t := 0.0
	while t < TIME_LIMIT:
		var before := {}
		for ship_name in SHIPS:
			var loco := _node(ship_name, "Locomotion")
			before[ship_name] = [loco.velocity, loco.angular_velocity, loco.heading, loco.arrived]
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			var avoidance := _node(ship_name, "Avoidance")
			avoidance._physics_process(DT)
			if record_costs:
				_costs.append(avoidance.last_step_usec)
		for ship_name in SHIPS:
			_node(ship_name, "Locomotion")._step(DT)
		t += DT
		# Ship footprints against each other (independent of the avoidance code).
		for i in SHIPS.size():
			for j in range(i + 1, SHIPS.size()):
				var gap: float = _node(SHIPS[i], "Locomotion").planar_position.distance_to(_node(SHIPS[j], "Locomotion").planar_position) \
					- _node(SHIPS[i], "RouteFollower").ship_radius - _node(SHIPS[j], "RouteFollower").ship_radius
				if not (SHIPS[i] in ships or SHIPS[j] in ships):
					continue
				if Scenarios.PARKING.has(_node(SHIPS[i], "Locomotion").planar_position) or Scenarios.PARKING.has(_node(SHIPS[j], "Locomotion").planar_position):
					continue
				min_gap = minf(min_gap, gap)
				if gap < 0.0:
					errors.append("CONTACT %s-%s %.2f u at %.1f s" % [SHIPS[i], SHIPS[j], -gap, t])
		var done := true
		for ship_name: String in ships:
			var record: Dictionary = ships[ship_name]
			_check_ship(ship_name, record, before[ship_name], t)
			if record.arrived:
				continue
			var loco := _node(ship_name, "Locomotion")
			if loco.arrived:
				record.arrived = true
				record.time = t
				record.outcome = "arrived %.1f s" % t
				continue
			var avoidance := _node(ship_name, "Avoidance")
			if avoidance.state == avoidance.State.WAITING:
				if record.waiting_since < 0.0:
					record.waiting_since = t
				if t - record.waiting_since < STABLE_WAIT:
					done = false
			else:
				record.waiting_since = -1.0
				done = false
		if done:
			break
	for ship_name: String in ships:
		var record: Dictionary = ships[ship_name]
		if not record.arrived:
			record.outcome = "WAITING %.0f s" % (t - record.waiting_since) if record.waiting_since >= 0.0 else "MOVING at limit"
		var avoidance := _node(ship_name, "Avoidance")
		record.counters = [avoidance.role_changes, avoidance.response_changes, avoidance.restarts, avoidance.side_flips]
	return {"ships": ships, "errors": errors, "min_gap": min_gap}


func _check_ship(ship_name: String, record: Dictionary, before: Array, t: float) -> void:
	var loco := _node(ship_name, "Locomotion")
	var follower := _node(ship_name, "RouteFollower")
	var avoidance := _node(ship_name, "Avoidance")
	var errors: Array[String] = record.errors
	var dv: Vector2 = loco.velocity - before[0]
	if loco.arrived and not before[3]:
		if dv.length() > loco.ARRIVE_SPEED + loco.forward_accel * DT:
			errors.append("settle jump")
	elif _ellipse_size(loco, dv / DT, before[2]) > 1.0 + SLACK:
		errors.append("acceleration limit at %.1f s" % t)
	var max_rate := deg_to_rad(loco.max_turn_rate_deg)
	if absf(loco.angular_velocity) > max_rate * (1.0 + SLACK) or absf(loco.angular_velocity - before[1]) > deg_to_rad(loco.turn_accel_deg) * DT * (1.0 + SLACK):
		errors.append("turn limit at %.1f s" % t)
	var clearance: float = _surface_distance(loco.planar_position) - follower.ship_radius
	if clearance < 0.0:
		errors.append("FOOTPRINT OVERLAP %.2f u at %.1f s" % [-clearance, t])
	if record.arrived:
		return
	record.deviation = maxf(record.deviation, _route_distance(record.route, loco.planar_position))
	if absf(loco.local_velocity().y) > DRIFT_SHARE * loco.max_speed:
		record.drift += DT
	var w: float = loco.angular_velocity
	if absf(w) > deg_to_rad(REVERSAL_RATE):
		if record.last_sign != 0.0 and signf(w) != record.last_sign:
			record.reversals += 1
		record.last_sign = signf(w)
	for other: Node in avoidance.encounters:
		var encounter: Dictionary = avoidance.encounters[other]
		var text := "%s:%s" % [other.name.substr(0, 1), _response_text(avoidance, encounter)]
		if not record.responses.has(text):
			record.responses.append(text)


func _response_text(avoidance: Node, encounter: Dictionary) -> String:
	if not encounter.give_way:
		return "stand-on"
	if encounter.response == avoidance.Response.PASS:
		return "pass %s%s%s%s" % ["stbd" if encounter.side > 0 else "port", " astern" if encounter.astern != 0 else "", " conv" if encounter.converging != 0 else "", " (lim)" if encounter.limited else ""]
	return "yield conv" if encounter.converging != 0 else "yield"


func _route_distance(route: PackedVector2Array, point: Vector2) -> float:
	var nearest := INF
	for i in route.size() - 1:
		nearest = minf(nearest, Geometry2D.get_closest_point_to_segment(point, route[i], route[i + 1]).distance_to(point))
	return nearest


func _node(ship_name: String, child: String) -> Node:
	return _lab.get_node("Ships/%s/%s" % [ship_name, child])


func _read_obstacles() -> void:
	for child in _lab.get_node("Obstacles").get_children():
		var mesh_instance := child as MeshInstance3D
		var center := Vector2(mesh_instance.global_position.x, mesh_instance.global_position.z)
		var x_axis := Vector2(mesh_instance.global_basis.x.x, mesh_instance.global_basis.x.z).normalized()
		if mesh_instance.mesh is CylinderMesh:
			_obstacles.append({"circle": true, "center": center, "radius": (mesh_instance.mesh as CylinderMesh).top_radius})
		else:
			var size := (mesh_instance.mesh as BoxMesh).size
			_obstacles.append({"circle": false, "center": center, "x_axis": x_axis, "half": Vector2(size.x, size.z) * 0.5})


func _surface_distance(point: Vector2) -> float:
	var nearest := INF
	for obstacle in _obstacles:
		if obstacle.circle:
			nearest = minf(nearest, point.distance_to(obstacle.center) - obstacle.radius)
		else:
			var offset: Vector2 = point - obstacle.center
			var x_axis: Vector2 = obstacle.x_axis
			var local := Vector2(offset.dot(x_axis), offset.dot(Vector2(-x_axis.y, x_axis.x)))
			var d: Vector2 = local.abs() - obstacle.half
			nearest = minf(nearest, Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() + minf(maxf(d.x, d.y), 0.0))
	return nearest


func _ellipse_size(loco: Node, accel: Vector2, h: float) -> float:
	var f := accel.dot(Vector2(-sin(h), -cos(h)))
	var l := accel.dot(Vector2(cos(h), -sin(h)))
	var axis_limit: float = loco.forward_accel if f >= 0.0 else loco.reverse_accel
	return sqrt(pow(f / axis_limit, 2) + pow(l / loco.lateral_accel, 2))
