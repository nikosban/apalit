extends SceneTree
## Headless Stage 3 navigation checks on the real lab scene (obstacles, maps, profiles).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/navigation_test.gd
## Each ship flies each scenario; physics is stepped manually at 60 Hz.
## PASS/FAIL (technical and navigation): locomotion limits, one route per command,
## segment progress only across segment boundaries, aim line clear of obstacles by
## the ship radius plus the reserved share of the margin, no ship-footprint (bounding circle) overlap with an obstacle on
## the actual trajectory, arrival. Everything else is reported only, including the
## final approach: overshoot along the approach direction from the first tick the
## ship must brake for its destination (direct move, or aim point = destination),
## and backing up (most negative speed
## toward the destination after that; values near 0 are settling creep).
## Trajectory geometry here is computed independently of static_navigation.gd.
## No result here means collision-free: there is no collision, and the bounding
## circle only approximates the hull.
## Stage 4: the other ships are parked far away and each ship's Avoidance is stepped
## too (between RouteFollower and Locomotion); any avoidance request is a failure,
## since no other ship is near (Stage 3 movement must be unchanged).

const LAB := preload("res://game/scenes/movement_test.tscn")
const DT := 1.0 / 60.0
const TIME_LIMIT := 240.0 # s per scenario
const SLACK := 1.0e-4
const HOVER_HEIGHT := 1.5
const SHIPS := ["Frigate", "Gunship", "Destroyer"]
const PARKING := [Vector2(-135, 135), Vector2(-135, -135), Vector2(-135, 0)]
const SCENARIOS := [
	{"name": "open direct", "start": Vector2(-100, -120), "target": Vector2(-60, -120)},
	{"name": "small round", "start": Vector2(0, -8), "target": Vector2(0, -45)},
	{"name": "medium round", "start": Vector2(-35, -8), "target": Vector2(-35, -55)},
	{"name": "large round", "start": Vector2(40, -12), "target": Vector2(40, -80)},
	{"name": "wall end", "start": Vector2(-20, -62), "target": Vector2(-20, -100)},
	{"name": "rotated block", "start": Vector2(-70, -55), "target": Vector2(-70, -90)},
	{"name": "gap", "start": Vector2(-1, 22), "target": Vector2(-1, 60)},
	{"name": "pocket", "start": Vector2(-30, 30), "target": Vector2(-62, 30)},
	{"name": "closed box", "start": Vector2(60, 20), "target": Vector2(60, 50)},
	{"name": "inside obstacle", "start": Vector2(10, -45), "target": Vector2(40, -45)},
	{"name": "slalom", "start": Vector2(-60, 75), "target": Vector2(60, 90)},
	{"name": "redirect mid-route", "start": Vector2(40, -12), "target": Vector2(40, -80), "redirect": Vector2(75, -45)},
]

var _failures := 0
var _obstacles: Array[Dictionary] = []
var _lab: Node
var _step_costs: Array[int] = []


func _initialize() -> void:
	await process_frame # The root is not inside the tree during _initialize().
	_lab = LAB.instantiate()
	root.add_child(_lab)
	_read_obstacles()
	for ship_name in SHIPS:
		_node(ship_name, "Locomotion").set_physics_process(false)
		_node(ship_name, "RouteFollower").set_physics_process(false)
		_node(ship_name, "Avoidance").set_physics_process(false)
	await _check_order_before_ready()
	print("ship      scenario            route  segs  time s  arrive  resolved u  max v  turns  worst entry (v/plan)  slowest turn (v/plan)  min clear u  overshoot  backs up  checks")
	for ship_name in SHIPS:
		for scenario in SCENARIOS:
			_run(ship_name, scenario)
	var costs := _step_costs.duplicate()
	costs.sort()
	var total := 0
	for cost in costs:
		total += cost
	if not costs.is_empty():
		print("route-following step cost: %d ticks, mean %.1f us, 99th percentile %d us, max %d us" % [
			costs.size(), float(total) / costs.size(), costs[int(costs.size() * 0.99)], costs[costs.size() - 1]])
	print("RESULT: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


# An order made before the map is ready is queued (not dropped) and runs once it is ready.
func _check_order_before_ready() -> void:
	var follower := _node("Frigate", "RouteFollower")
	var notices: Array[String] = []
	follower.notice.connect(func(text: String) -> void: notices.append(text))
	follower.order(Vector2(-6, -20))
	var queued: bool = follower.status == follower.RouteStatus.WAITING and follower.plans == 0 and notices.size() == 1
	var frames := 0
	while not _lab.get_node("StaticNavigation").is_ready(follower.planning_radius()) and frames < 120:
		await physics_frame
		frames += 1
	follower._physics_process(DT)
	var executed: bool = follower.plans == 1 and follower.status != follower.RouteStatus.WAITING
	print("order before map ready: queued=%s notice=\"%s\" ready after %d physics frames, executed=%s -> %s" % [
		queued, notices[0] if notices.size() > 0 else "", frames, executed, "PASS" if queued and executed else "FAIL"])
	if not (queued and executed):
		_failures += 1
	# Remaining ships' maps are built at the same time; wait for them too.
	for ship_name in SHIPS:
		var other := _node(ship_name, "RouteFollower")
		while not _lab.get_node("StaticNavigation").is_ready(other.planning_radius()):
			await physics_frame


func _run(ship_name: String, scenario: Dictionary) -> void:
	var ship := _lab.get_node("Ships/" + ship_name) as Node3D
	var loco := _node(ship_name, "Locomotion")
	var follower := _node(ship_name, "RouteFollower")
	var avoidance := _node(ship_name, "Avoidance")
	var radius: float = follower.ship_radius
	var parking := 0
	for other_name in SHIPS:
		if other_name != ship_name:
			_node(other_name, "Locomotion").place(PARKING[parking], 0.0)
			parking += 1
	_reset(ship, loco, follower, scenario.start)
	avoidance.reset()

	var errors: Array[String] = []
	var max_rate := deg_to_rad(loco.max_turn_rate_deg)
	var turn_accel := deg_to_rad(loco.turn_accel_deg)
	follower.order(scenario.target)
	var commands := 1
	var route_kind: String = follower.RouteStatus.keys()[follower.status]
	var segments: int = follower.route.size() - 1
	var resolved: float = follower.route[follower.route.size() - 1].distance_to(scenario.target) if follower.route.size() > 0 else -1.0
	var redirected := not scenario.has("redirect")
	var t := 0.0
	var command_time := 0.0
	var min_clear := INF
	var max_speed := 0.0
	# Route speed restrictions (turns, destination excluded): ship speed when its
	# progress enters each turn's maneuvering window, against the planned turn speed.
	var entered := 0
	var worst_entry := Vector2(-INF, 0.0) # (excess, index) -> printed as entry / plan
	var entries: Array[float] = []
	# Final approach: from the first tick the ship must brake for its destination.
	var approach_dir := Vector2.ZERO
	var approach_overshoot := 0.0
	var min_toward := 0.0

	while t < TIME_LIMIT and loco.has_destination:
		if not redirected and follower.segment >= 2:
			var v0: Vector2 = loco.velocity
			var w0: float = loco.angular_velocity
			follower.order(scenario.redirect)
			commands += 1
			redirected = true
			command_time = t
			route_kind = follower.RouteStatus.keys()[follower.status]
			segments = follower.route.size() - 1
			resolved = follower.route[follower.route.size() - 1].distance_to(scenario.redirect)
			approach_dir = Vector2.ZERO
			approach_overshoot = 0.0
			min_toward = 0.0
			entered = 0
			entries.clear()
			worst_entry = Vector2(-INF, 0.0)
			if loco.velocity != v0 or loco.angular_velocity != w0:
				errors.append("momentum not preserved on redirect")
		var previous_segment: int = follower.segment
		var velocity_before: Vector2 = loco.velocity
		var angular_before: float = loco.angular_velocity
		var heading_before: float = loco.heading
		var was_arrived: bool = loco.arrived
		follower._physics_process(DT)
		if follower.status == follower.RouteStatus.ROUTE:
			_step_costs.append(follower.last_step_usec)
		avoidance._physics_process(DT)
		if avoidance.offset != Vector2.ZERO or avoidance.speed_cap < INF:
			errors.append("avoidance active at %.1f s" % t)
		loco._step(DT)
		t += DT
		var position: Vector2 = loco.planar_position

		# Locomotion limits (the arrival tick is the documented settling exception).
		var dv: Vector2 = loco.velocity - velocity_before
		if loco.arrived and not was_arrived:
			if dv.length() > loco.ARRIVE_SPEED + loco.forward_accel * DT:
				errors.append("settle jump")
		elif _ellipse_size(loco, dv / DT, heading_before) > 1.0 + SLACK:
			errors.append("acceleration limit at %.1f s" % t)
		if absf(loco.angular_velocity) > max_rate * (1.0 + SLACK) or absf(loco.angular_velocity - angular_before) > turn_accel * DT * (1.0 + SLACK):
			errors.append("turn limit at %.1f s" % t)
		if not is_equal_approx(ship.global_position.y, HOVER_HEIGHT):
			errors.append("Y changed")

		# Progress: never backwards, and every advance across that segment's end boundary.
		if follower.segment < previous_segment:
			errors.append("progress went backwards at %.1f s" % t)
		for s in range(previous_segment, follower.segment):
			if not _crossed(follower.route, s, position):
				errors.append("segment %d skipped without crossing at %.1f s" % [s, t])

		# Aim line keeps the ship radius plus the margin reserve clear (independent geometry).
		var line_clearance: float = radius + follower.lookahead_reserve * follower.clearance_margin
		if follower.status == follower.RouteStatus.ROUTE and loco.has_destination and _segment_clearance(position, follower.aim_point) < line_clearance - 0.001:
			errors.append("aim line blocked at %.1f s" % t)

		# Actual trajectory: ship footprint (bounding circle) against obstacle geometry.
		var clearance := _surface_distance(position) - radius
		min_clear = minf(min_clear, clearance)
		if clearance < 0.0:
			errors.append("FOOTPRINT OVERLAP %.2f u at %.1f s" % [-clearance, t])

		max_speed = maxf(max_speed, loco.velocity.length())
		if follower.status == follower.RouteStatus.ROUTE:
			var turns: PackedVector3Array = follower.restrictions
			while entered < turns.size() - 1 and follower.progress >= turns[entered].x:
				var speed: float = loco.velocity.length()
				entries.append(speed)
				if speed - turns[entered].z > worst_entry.x:
					worst_entry = Vector2(speed - turns[entered].z, entered)
				entered += 1
		var to_destination: Vector2 = loco.destination - position
		var toward: float = loco.velocity.dot(to_destination.normalized())
		var final_approach: bool = follower.status != follower.RouteStatus.ROUTE or follower.aim_point.distance_to(loco.destination) < 0.001
		if redirected and final_approach and approach_dir == Vector2.ZERO and toward > 0.5 and toward > loco.desired_velocity.length() + 0.001:
			approach_dir = to_destination.normalized()
		if approach_dir != Vector2.ZERO:
			approach_overshoot = maxf(approach_overshoot, -to_destination.dot(approach_dir))
			min_toward = minf(min_toward, toward)

	if follower.plans != commands:
		errors.append("%d route calculations for %d commands" % [follower.plans, commands])
	if not loco.arrived:
		errors.append("no arrival within %.0f s" % TIME_LIMIT)
	_failures += 1 if not errors.is_empty() else 0
	var unique: Array[String] = []
	for error in errors:
		var kind := error.split(" at ")[0]
		if not unique.any(func(u: String) -> bool: return u.begins_with(kind)):
			unique.append(error)
	var checks := "PASS" if errors.is_empty() else "FAIL: " + ", ".join(unique.slice(0, 3)) + (" (%d events)" % errors.size())
	var turns: PackedVector3Array = follower.restrictions
	var turn_count := maxi(0, turns.size() - 1) if follower.status == follower.RouteStatus.ROUTE else 0
	var worst := "-"
	var slowest := "-"
	if not entries.is_empty():
		var w := int(worst_entry.y)
		worst = "%.2f / %.2f" % [entries[w], turns[w].z]
		var s := 0
		for k in entries.size():
			if turns[k].z < turns[s].z:
				s = k
		slowest = "%.2f / %.2f" % [entries[s], turns[s].z]
	print("%-10s %-19s %-6s %4d  %6.1f  %-6s  %10.2f  %5.2f  %5d  %20s  %21s  %11.2f  %9.2f  %8.2f  %s" % [
		ship_name, scenario.name, route_kind, segments, t - command_time, "yes" if loco.arrived else "NO", resolved,
		max_speed, turn_count, worst, slowest, min_clear, approach_overshoot, min_toward, checks])


func _reset(ship: Node3D, loco: Node, follower: Node, start: Vector2) -> void:
	ship.global_position = Vector3(start.x, HOVER_HEIGHT, start.y)
	ship.global_rotation = Vector3.ZERO
	loco.planar_position = start
	loco.velocity = Vector2.ZERO
	loco.heading = 0.0
	loco.angular_velocity = 0.0
	loco.has_destination = false
	loco.arrived = false
	loco._target_heading = 0.0
	loco._heading_frozen = false
	loco._steering = false
	follower.status = follower.RouteStatus.NONE
	follower.route = PackedVector2Array()
	follower.plans = 0


func _node(ship_name: String, child: String) -> Node:
	return _lab.get_node("Ships/%s/%s" % [ship_name, child])


# Boundary between segment s and s + 1: the line through their shared corner along
# the corner's bisector (re-implemented here, independently of the follower).
func _crossed(route: PackedVector2Array, s: int, position: Vector2) -> bool:
	var corner := route[s + 1]
	var normal := (corner - route[s]).normalized() + (route[s + 2] - corner).normalized()
	if normal.length() < 0.000001:
		normal = (corner - route[s]).normalized()
	return (position - corner).dot(normal) >= -0.000001


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
			nearest = minf(nearest, _box_distance(_box_local(obstacle, point), obstacle.half))
	return nearest


# Smallest distance from a segment to any obstacle surface (0 if it enters one).
func _segment_clearance(a: Vector2, b: Vector2) -> float:
	var nearest := INF
	for obstacle in _obstacles:
		if obstacle.circle:
			var closest := Geometry2D.get_closest_point_to_segment(obstacle.center, a, b)
			nearest = minf(nearest, maxf(0.0, closest.distance_to(obstacle.center) - obstacle.radius))
			continue
		# Box: distance between the segment and the rectangle in the box frame.
		var la := _box_local(obstacle, a)
		var lb := _box_local(obstacle, b)
		var half: Vector2 = obstacle.half
		var corners := [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]
		var d := maxf(0.0, minf(_box_distance(la, half), _box_distance(lb, half)))
		for i in 4:
			if Geometry2D.segment_intersects_segment(la, lb, corners[i], corners[(i + 1) % 4]) != null:
				d = 0.0
			d = minf(d, Geometry2D.get_closest_point_to_segment(corners[i], la, lb).distance_to(corners[i]))
		nearest = minf(nearest, d)
	return nearest


func _box_local(obstacle: Dictionary, point: Vector2) -> Vector2:
	var offset: Vector2 = point - obstacle.center
	var x_axis: Vector2 = obstacle.x_axis
	return Vector2(offset.dot(x_axis), offset.dot(Vector2(-x_axis.y, x_axis.x)))


func _box_distance(local: Vector2, half: Vector2) -> float:
	var d := local.abs() - half
	return Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() + minf(maxf(d.x, d.y), 0.0)


func _ellipse_size(loco: Node, accel: Vector2, h: float) -> float:
	var f := accel.dot(Vector2(-sin(h), -cos(h)))
	var l := accel.dot(Vector2(cos(h), -sin(h)))
	var axis_limit: float = loco.forward_accel if f >= 0.0 else loco.reverse_accel
	return sqrt(pow(f / axis_limit, 2) + pow(l / loco.lateral_accel, 2))
