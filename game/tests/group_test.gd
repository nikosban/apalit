extends SceneTree
## Headless Stage 5.3 group MOVE checks on the real lab scene. Ship physics is
## stepped manually at 60 Hz in the game's order (per ship RouteFollower then
## Avoidance, then Locomotion). Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/group_test.gd
## PASS/FAIL: assignment succeeds (or is refused where expected), destination
## footprints at least the margin apart, every destination reachable (route ends
## there) and clear of obstacles, arrival, no ship contact, no obstacle overlap,
## locomotion limits, ships settled after arrival, plus per-scenario checks.
## Reported: assignment cost (candidates, fit and route queries, time), per ship
## the click-to-destination distance, route length, arrival time and time waiting.

const LAB := preload("res://game/scenes/movement_test.tscn")
const DT := 1.0 / 60.0
const TIME_LIMIT := 240.0 # s
const SETTLE_TIME := 5.0 # s watched after the last arrival
const SLACK := 1.0e-4
const SHIPS := ["Frigate", "Gunship", "Destroyer"]
const PARKING := [Vector2(-135, 135), Vector2(-135, -135), Vector2(-135, 0)]
const ENCLOSURE := Rect2(48, 38, 24, 24) # outer bounds of the closed box (x 48-72, z 38-62)

var _failures := 0
var _lab: Node
var _orders: Node
var _obstacles: Array[Dictionary] = []
var _costs := []


func _initialize() -> void:
	await process_frame
	_lab = LAB.instantiate()
	root.add_child(_lab)
	_orders = _lab.get_node("GroupOrders")
	_read_obstacles()
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance"]:
			_node(ship_name, child).set_physics_process(false)
	for ship_name in SHIPS:
		while not _lab.get_node("StaticNavigation").is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame

	_scenario("1 two ships, open space", {"Frigate": Vector2(100, 40), "Gunship": Vector2(125, 40)}, Vector2(115, -40))
	_scenario("2 all three classes", {"Frigate": Vector2(100, 40), "Gunship": Vector2(115, 45), "Destroyer": Vector2(132, 40)}, Vector2(115, -40))
	_scenario("3 different starting distances", {"Frigate": Vector2(115, -20), "Gunship": Vector2(100, 30), "Destroyer": Vector2(130, 70)}, Vector2(115, -45))
	_scenario("4 near an asteroid (click 1 u off its edge)", {"Frigate": Vector2(30, -5), "Gunship": Vector2(42, 0), "Destroyer": Vector2(56, -4)}, Vector2(40, -26))
	_scenario("5 beside a wall (click inside the closed box)", {"Frigate": Vector2(50, 10), "Gunship": Vector2(60, 5), "Destroyer": Vector2(74, 10)}, Vector2(60, 42))
	_insufficient()
	_redirect()
	_selection_change()
	_scenario("9 narrow passage (the gap)", {"Frigate": Vector2(-8, 62), "Gunship": Vector2(5, 66), "Destroyer": Vector2(-30, 60)}, Vector2(-1, 15))
	var total := 0
	for cost: Dictionary in _costs:
		total += cost.usec
	print("assignment cost over %d commands: mean %.0f us" % [_costs.size(), float(total) / _costs.size()])
	print("RESULT: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


# Places the ships at rest (unnamed ships parked far away), gives the group MOVE,
# flies until everyone has arrived plus SETTLE_TIME (or TIME_LIMIT), and reports.
func _scenario(label: String, starts: Dictionary, click: Vector2) -> Dictionary:
	_setup(starts, click)
	var ships := _ships(starts.keys())
	var destinations: Dictionary = _orders.assign(ships, click)
	_report_cost(label, destinations)
	_check(label, "assignment succeeds", not destinations.is_empty())
	if destinations.is_empty():
		return {}
	_check_destinations(label, destinations, click)
	_dispatch(destinations)
	return _fly(label, destinations, click, label.begins_with("3"))


func _setup(starts: Dictionary, click: Vector2) -> void:
	var parking := 0
	for ship_name in SHIPS:
		var point: Vector2
		var heading := 0.0
		if starts.has(ship_name):
			point = starts[ship_name]
			var travel: Vector2 = click - point
			heading = atan2(-travel.x, -travel.y)
		else:
			point = PARKING[parking]
			parking += 1
		_node(ship_name, "Locomotion").place(point, heading)
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()


func _dispatch(destinations: Dictionary) -> void:
	for ship: Node in destinations:
		(ship.get_node("RouteFollower")).order(destinations[ship])


# Separation, reachability and obstacle clearance of the assigned destinations.
func _check_destinations(label: String, destinations: Dictionary, click: Vector2) -> void:
	var ships := destinations.keys()
	var min_gap := INF
	for i in ships.size():
		for j in range(i + 1, ships.size()):
			var gap: float = (destinations[ships[i]] as Vector2).distance_to(destinations[ships[j]]) - _radius(ships[i]) - _radius(ships[j])
			min_gap = minf(min_gap, gap)
	if ships.size() > 1:
		_check(label, "destination footprints >= 1 u apart (min gap %.2f u)" % min_gap, min_gap >= 1.0 - 0.001)
	var reachable := true
	var clear := INF
	var enclosed := false
	for ship: Node in ships:
		var follower = ship.get_node("RouteFollower")
		var route: PackedVector2Array = _lab.get_node("StaticNavigation").plan(follower.planning_radius(), ship.get_node("Locomotion").planar_position, destinations[ship])
		reachable = reachable and route.size() >= 2 and route[route.size() - 1].distance_to(destinations[ship]) < 0.01
		clear = minf(clear, _surface_distance(destinations[ship]) - _radius(ship))
		enclosed = enclosed or ENCLOSURE.has_point(destinations[ship])
	_check(label, "every destination reachable from its ship", reachable)
	_check(label, "destination footprints clear of obstacles (min %.2f u)" % clear, clear >= 0.0)
	if label.begins_with("5"):
		_check(label, "no destination inside the closed box", not enclosed)


func _fly(label: String, destinations: Dictionary, click: Vector2, check_start: bool) -> Dictionary:
	var records := {}
	for ship: Node in destinations:
		var follower = ship.get_node("RouteFollower")
		records[ship] = {"arrived": -1.0, "waiting": 0.0, "moving_at_3s": false, "route": _length(follower.route),
			"start": ship.get_node("Locomotion").planar_position}
	var errors: Array[String] = []
	var t := 0.0
	var last_arrival := INF
	var min_gap := INF
	var settle_moves := 0.0
	var settle_avoid := false
	while t < TIME_LIMIT:
		var before := {}
		for ship: Node in destinations:
			var loco = ship.get_node("Locomotion")
			before[ship] = [loco.velocity, loco.angular_velocity, loco.heading, loco.arrived, loco.planar_position]
		_steps(1)
		t += DT
		_check_step(destinations, before, errors, t)
		min_gap = minf(min_gap, _min_gap(destinations))
		var all_arrived := true
		for ship: Node in destinations:
			var loco = ship.get_node("Locomotion")
			var record: Dictionary = records[ship]
			if loco.arrived and record.arrived < 0.0:
				record.arrived = t
			if record.arrived < 0.0:
				all_arrived = false
				if ship.get_node("Avoidance").state == ship.get_node("Avoidance").State.WAITING:
					record.waiting += DT
			elif record.arrived < t - DT * 0.5: # From the tick after arrival (avoidance ran before it).
				settle_moves = maxf(settle_moves, (loco.planar_position - (before[ship][4] as Vector2)).length())
				var avoidance = ship.get_node("Avoidance")
				settle_avoid = settle_avoid or avoidance.offset != Vector2.ZERO or avoidance.speed_cap < INF
			if check_start and absf(t - 3.0) < DT * 0.5:
				record.moving_at_3s = loco.velocity.length() > 0.5
		if all_arrived and last_arrival == INF:
			last_arrival = t
		if t > last_arrival + SETTLE_TIME:
			break
	var all_in := true
	var waiting := 0.0
	for ship: Node in destinations:
		var record: Dictionary = records[ship]
		all_in = all_in and record.arrived >= 0.0
		waiting += record.waiting
		print("    %-10s start->dest %6.1f u  click->dest %5.2f u  route %6.1f u  arrival %s  waiting %.1f s" % [ship.name,
			(record.start as Vector2).distance_to(destinations[ship]), (destinations[ship] as Vector2).distance_to(click), record.route,
			"%.1f s" % record.arrived if record.arrived >= 0.0 else "NO", record.waiting])
	var spread := 0.0
	for ship: Node in destinations:
		spread = maxf(spread, (destinations[ship] as Vector2).distance_to(click))
	print("    min footprint gap between the ordered ships %.2f u, destination spread (farthest from the click) %.2f u" % [min_gap, spread])
	_check(label, "every ship arrives", all_in)
	_check(label, "no ship contact, obstacle overlap or limit violation", errors.is_empty(), ", ".join(errors.slice(0, 3)))
	_check(label, "settled after arrival (max move %.4f u, avoidance idle)" % settle_moves, settle_moves < 0.001 and not settle_avoid)
	if not label.begins_with("9"):
		_check(label, "no waiting (%.1f s)" % waiting, waiting == 0.0)
	if check_start:
		var all_moving := true
		for ship: Node in destinations:
			all_moving = all_moving and records[ship].moving_at_3s
		_check(label, "every ship under way at 3 s (nobody waits to regroup)", all_moving)
	return records


# Per tick: limits, footprint against obstacles, ship footprints against each other.
func _check_step(destinations: Dictionary, before: Dictionary, errors: Array[String], t: float) -> void:
	for ship: Node in destinations:
		var loco = ship.get_node("Locomotion")
		var dv: Vector2 = loco.velocity - before[ship][0]
		if not (loco.arrived and not before[ship][3]) and _ellipse_size(loco, dv / DT, before[ship][2]) > 1.0 + SLACK:
			errors.append("%s acceleration limit at %.1f s" % [ship.name, t])
		if absf(loco.angular_velocity) > deg_to_rad(loco.max_turn_rate_deg) * (1.0 + SLACK) \
			or absf(loco.angular_velocity - before[ship][1]) > deg_to_rad(loco.turn_accel_deg) * DT * (1.0 + SLACK):
			errors.append("%s turn limit at %.1f s" % [ship.name, t])
		if _surface_distance(loco.planar_position) - _radius(ship) < 0.0:
			errors.append("%s OBSTACLE OVERLAP at %.1f s" % [ship.name, t])
	for i in SHIPS.size():
		for j in range(i + 1, SHIPS.size()):
			var a := _ship(SHIPS[i])
			var b := _ship(SHIPS[j])
			var gap: float = (a.get_node("Locomotion").planar_position as Vector2).distance_to(b.get_node("Locomotion").planar_position) - _radius(a) - _radius(b)
			if gap < 0.0:
				errors.append("CONTACT %s-%s at %.1f s" % [a.name, b.name, t])


# Smallest footprint gap between the ordered ships now.
func _min_gap(destinations: Dictionary) -> float:
	var ships := destinations.keys()
	var nearest := INF
	for i in ships.size():
		for j in range(i + 1, ships.size()):
			nearest = minf(nearest, (ships[i].get_node("Locomotion").planar_position as Vector2).distance_to(ships[j].get_node("Locomotion").planar_position)
				- _radius(ships[i]) - _radius(ships[j]))
	return nearest


# 6: a command with no room is refused as a whole; the existing orders stay.
func _insufficient() -> void:
	var label := "6 insufficient space (search radius 12 u, click inside the closed box)"
	var starts := {"Frigate": Vector2(100, 40), "Gunship": Vector2(125, 40), "Destroyer": Vector2(112, 60)}
	_setup(starts, Vector2(115, -40))
	var ships := _ships(SHIPS)
	_dispatch(_orders.assign(ships, Vector2(115, -40)))
	_steps(60)
	var before := {}
	for ship: Node in ships:
		before[ship] = [ship.get_node("Locomotion").destination, ship.get_node("RouteFollower").plans]
	_orders.search_radius = 12.0
	var ok: bool = _orders.command(ships, Vector2(60, 50))
	_report_cost(label, {} if not ok else {0: 0})
	_orders.search_radius = 40.0
	var kept := true
	for ship: Node in ships:
		kept = kept and ship.get_node("Locomotion").has_destination and ship.get_node("Locomotion").destination == before[ship][0] \
			and ship.get_node("RouteFollower").plans == before[ship][1]
	_check(label, "command refused", not ok)
	_check(label, "existing orders kept (same destinations, no new route)", kept)
	var notice := _lab.get_node("NoticeUI/Notice") as Label
	_lab.get_node("Selection").set_selection(ships)
	var camera := _lab.get_node("CameraRig/Camera3D") as Camera3D
	_lab.get_node("CameraRig").global_position = Vector3(60, 0, 50)
	_orders.search_radius = 12.0
	_lab._command(camera.unproject_position(Vector3(60, 0, 50)))
	_orders.search_radius = 40.0
	_check(label, "lab shows the notice", notice.text == _lab.GROUP_NOTICE and _lab._notice_left > 0.0)


# 7: three moving ships redirected by one command keep their momentum.
func _redirect() -> void:
	var label := "7 group redirect while moving"
	var starts := {"Frigate": Vector2(100, 40), "Gunship": Vector2(115, 45), "Destroyer": Vector2(132, 40)}
	_setup(starts, Vector2(115, -40))
	var ships := _ships(SHIPS)
	_dispatch(_orders.assign(ships, Vector2(115, -40)))
	_steps(240)
	var state := {}
	for ship: Node in ships:
		var loco = ship.get_node("Locomotion")
		state[ship] = [loco.velocity, loco.angular_velocity, ship.get_node("RouteFollower").plans]
	var destinations: Dictionary = _orders.assign(ships, Vector2(95, 10))
	_report_cost(label, destinations)
	_dispatch(destinations)
	var kept := true
	var replaced := true
	for ship: Node in ships:
		var loco = ship.get_node("Locomotion")
		kept = kept and loco.velocity == state[ship][0] and loco.angular_velocity == state[ship][1]
		replaced = replaced and loco.destination.distance_to(destinations[ship]) < 0.01 and ship.get_node("RouteFollower").plans == state[ship][2] + 1
	_check(label, "assignment succeeds", not destinations.is_empty())
	_check(label, "every ship redirected at once (one new route each)", replaced)
	_check(label, "velocity and turn rate kept", kept)
	_check_destinations(label, destinations, Vector2(95, 10))
	_fly(label, destinations, Vector2(95, 10), false)


# 8: removing a ship from the selection does not interrupt its order (dispatched
# through the lab's right-click with all three selected).
func _selection_change() -> void:
	var label := "8 selection change during a group move"
	var starts := {"Frigate": Vector2(100, 40), "Gunship": Vector2(115, 45), "Destroyer": Vector2(132, 40)}
	_setup(starts, Vector2(115, -40))
	var selection := _lab.get_node("Selection")
	var ships := _ships(SHIPS)
	selection.set_selection(ships)
	var rig := _lab.get_node("CameraRig") as Node3D
	rig.global_position = Vector3(115, 0, 0)
	rig.zoom_distance = 40.0
	rig._apply_zoom()
	var camera := _lab.get_node("CameraRig/Camera3D") as Camera3D
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	press.position = camera.unproject_position(Vector3(115, 0, -30))
	root.push_input(press, true)
	var destinations := {}
	for ship: Node in ships:
		if ship.get_node("Locomotion").has_destination:
			destinations[ship] = ship.get_node("Locomotion").destination
	_report_cost(label, destinations)
	_check(label, "right-click with three selected orders all three", destinations.size() == 3)
	_steps(120)
	var destroyer := _ship("Destroyer")
	selection.set_selection([_ship("Frigate"), _ship("Gunship")])
	_check(label, "Destroyer removed from the selection", selection.selected.size() == 2)
	_check(label, "its order continues (same destination)", destroyer.get_node("Locomotion").has_destination
		and destroyer.get_node("Locomotion").destination == destinations[destroyer])
	selection.set_selection([])
	_fly(label, destinations, Vector2(115, -30), false)


func _report_cost(label: String, destinations: Dictionary) -> void:
	var stats: Dictionary = _orders.last_stats
	_costs.append(stats)
	print("%s: %s, %d ships, %d candidates, %d fit queries, %d route queries, %d us, %d placement orders, departure conflicts %d -> %d" % [label,
		"assigned" if stats.success else "refused", destinations.size(), stats.candidates, stats.fit_queries, stats.route_queries, stats.usec,
		stats.orders, stats.conflicts_first, stats.conflicts])


func _steps(count: int) -> void:
	for i in count:
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower")._physics_process(DT)
			_node(ship_name, "Avoidance")._physics_process(DT)
		for ship_name in SHIPS:
			_node(ship_name, "Locomotion")._step(DT)


func _check(label: String, what: String, ok: bool, detail := "") -> void:
	if not ok:
		_failures += 1
	print("  %-72s %s" % [what, "PASS" if ok else "FAIL" + (": " + detail if detail != "" else "")])


func _length(route: PackedVector2Array) -> float:
	var total := 0.0
	for i in route.size() - 1:
		total += route[i].distance_to(route[i + 1])
	return total


func _radius(ship: Node) -> float:
	return ship.get_node("RouteFollower").ship_radius


func _ships(names: Array) -> Array:
	var result := []
	for ship_name in names:
		result.append(_ship(ship_name))
	return result


func _ship(ship_name: String) -> Node3D:
	return _lab.get_node("Ships/" + ship_name)


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
