extends SceneTree
## Headless checks for the RouteFollower end-of-route correction, on the playable
## main scene (plain MOVE orders only; no mining, docking or transport running):
## a ship on a routed order displaced sideways near its destination by a parked
## ship must still arrive (no zero route speed cap short of it), with the route
## speed profile otherwise unchanged. Layouts: the twelve plain-MOVE layouts that
## stalled in the Stage 6 soaks (Miner1 from asteroid 19's working point to
## Station's west approach point, the Transporter or Miner2 parked near the end),
## and routed approaches around asteroid 19 for Miner1, the Transporter and the
## FF-01 past a parked Miner2 beside the final leg. A layout whose
## destination lies within avoidance's separation of the parked ship is
## unreachable: the ship must settle beside it (stopped, no shuttling), and once
## the parked ship has left it must complete its order (the Stage 6 soak stall). Physics is stepped manually at 60 Hz in
## the game's order (per ship RouteFollower then Avoidance, then Locomotion).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/route_end_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const DT := 1.0 / 60.0
const SHIPS := ["FF01", "Miner1", "Miner2", "Transporter"]
const PARK := {"FF01": Vector2(40, -5), "Miner1": Vector2(40, -20),
	"Miner2": Vector2(40, -32), "Transporter": Vector2(-80, 30)}
const SOAK_START := Vector2(-62.45, -7.0) # Miner1's working point at asteroid 19 (Stage 6 soak).
const SOAK_TARGET := Vector2(-62.1, -20.0) # Station's west approach point for a Miner.
const SOAK_BLOCKERS := [Vector2(-62.3, -16.0), Vector2(-62.0, -18.0), Vector2(-61.0, -19.0), Vector2(-63.5, -17.0), Vector2(-62.2, -14.0), Vector2(-60.5, -18.5)]
const ROUND_START := Vector2(-84, -7) # West of asteroid 19: the route bends around it.
const ROUND_TARGET := Vector2(-48, -8)
const TIME_LIMIT := 90.0 # s
const HOLD_LIMIT := 20.0 # s stopped short with an order = stalled

var _failures := 0
var _checks := 0
var _main: Node
var _navigation: Node


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	var ff01: Node3D = load("res://game/ships/ff01_unit.tscn").instantiate() # The large hull.
	ff01.name = "FF01"
	ff01.position = Vector3(14, 1.5, 0)
	_main.get_node("Ships").add_child(ff01)
	root.add_child(_main)
	_navigation = _main.get_node("StaticNavigation")
	_main.get_node("Survey").set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Transport", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.set_physics_process(false)
	for ship_name in SHIPS:
		while not _navigation.is_ready(_follower(ship_name).planning_radius()):
			await physics_frame

	print("layout                                                             outcome             time s  short u  cross u  progress/len   remain u  cap u/s  min cap>0.5u  contacts  gap u")
	var arrived := 0
	var reachable := 0
	var unreachable: Array[String] = []
	var settled := 0
	var resumed := 0
	var clear := true
	var no_early_zero := true
	for blocker_name in ["Transporter", "Miner2"]:
		for point: Vector2 in SOAK_BLOCKERS:
			var r := _run("Miner1", SOAK_START, PI, SOAK_TARGET, blocker_name, point)
			_tally(r)
			clear = clear and r.clear
			no_early_zero = no_early_zero and r.no_early_zero
			if r.reachable:
				reachable += 1
				arrived += 1 if r.arrived else 0
			else:
				unreachable.append(r.name)
				settled += 1 if r.settled else 0
				resumed += 1 if r.arrived_after_leave else 0
	var round_arrived := 0
	var round_reachable := 0
	for mover in ["Miner1", "Transporter", "FF01"]:
		var leg := (ROUND_TARGET - Vector2(-60, -8)).normalized()
		for along: float in [3.0, 5.0, 8.0]:
			for lateral: float in [-2.0, 0.0, 2.0]:
				var point: Vector2 = ROUND_TARGET - leg * along + leg.orthogonal() * lateral
				var r := _run(mover, ROUND_START, -PI / 2, ROUND_TARGET, "Miner2", point)
				_tally(r)
				clear = clear and r.clear
				no_early_zero = no_early_zero and r.no_early_zero
				if r.reachable:
					round_reachable += 1
					round_arrived += 1 if r.arrived else 0
				else:
					unreachable.append(r.name)
					settled += 1 if r.settled else 0
					resumed += 1 if r.arrived_after_leave else 0
	_check("1-3. the Stage 6 plain-MOVE layouts with a reachable destination: %d of %d arrive" % [arrived, reachable], reachable > 0 and arrived == reachable)
	_check("1-3. routed approaches past a parked ship near the destination: %d of %d arrive" % [round_arrived, round_reachable],
		round_reachable > 0 and round_arrived == round_reachable)
	_check("4. no zero route speed cap more than 0.5 u from a destination the ship can reach (clear line, nobody within separation; at most the one tick after the parked ship vanishes)", no_early_zero)
	_check("8. no footprint ever inside an obstacle or another ship's footprint", clear)
	_check("destination within the parked ship's separation (unreachable): the ship settles beside it in %d of %d layouts (no shuttling)" % [settled,
		unreachable.size()], settled == unreachable.size())
	_check("2, 3. the parked ship leaves: the waiting ship then completes its order in %d of %d layouts" % [resumed, unreachable.size()],
		resumed == unreachable.size())
	_test_unobstructed()
	_test_redirect()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _tally(r: Dictionary) -> void:
	print("%-66s %-19s %6.1f  %7.2f  %7.2f  %6.2f/%-6.2f %8.2f  %7.2f  %12s  %8d  %5.2f" % [r.name, r.outcome, r.time, r.short, r.cross,
		r.progress, r.length, r.remaining, r.cap, "%.2f" % r.min_cap if r.min_cap < INF else "-", r.contacts, r.min_gap])


# 5, 6: unobstructed routed arrivals: the route speed cap is the unchanged profile
# (restrictions read along the route) except where the ship is farther from its
# destination than the route distance left (never more than its distance off the route).
func _test_unobstructed() -> void:
	var worst := 0.0
	var all_arrived := true
	var names: Array[String] = []
	for mover in ["Transporter", "FF01", "Miner1"]:
		for leg: Array in [[ROUND_START, -PI / 2, ROUND_TARGET], [SOAK_START, PI, SOAK_TARGET], [Vector2(-75, 25), PI, Vector2(-20, -40)]]:
			if mover != "Miner1" and leg[0] == SOAK_START:
				continue
			_reset()
			_place(mover, leg[0], leg[1])
			_follower(mover).order(leg[2])
			var corners: int = _follower(mover).restrictions.size() - 1
			var ticks := 0
			while _locomotion(mover).has_destination and ticks < 60 * TIME_LIMIT:
				_step_route_followers()
				worst = maxf(worst, absf(_capped(_follower(mover).speed_cap) - _capped(_profile_cap(mover))))
				_step_rest()
				ticks += 1
			all_arrived = all_arrived and not _locomotion(mover).has_destination
			names.append("%s %.0f s (%d speed restrictions)" % [mover, ticks * DT, corners])
	_check("5, 6. unobstructed routed arrivals all complete; route speed cap equals the along-route profile (largest difference %.4f u/s)" % worst,
		all_arrived and worst < 0.01)
	print("    %s" % ", ".join(names))


# 7: mid-route redirect to a point just beyond a parked ship, then arrival.
func _test_redirect() -> void:
	_reset()
	_place("Miner2", Vector2(-55.0, -5.0), 0.0) # Beside the final leg, outside the destination's separation.
	_place("Transporter", ROUND_START, -PI / 2)
	_follower("Transporter").order(Vector2(-60, 20))
	for i in 60 * 4:
		_step_route_followers()
		_step_rest()
	_follower("Transporter").order(ROUND_TARGET)
	var ticks := 0
	while _locomotion("Transporter").has_destination and ticks < 60 * TIME_LIMIT:
		_step_route_followers()
		_step_rest()
		ticks += 1
	_check("7. mid-route redirect to a destination beside a parked ship arrives (%.1f s, %d contacts)" % [ticks * DT, _locomotion("Transporter").collision_count],
		not _locomotion("Transporter").has_destination and _locomotion("Transporter").planar_position.distance_to(ROUND_TARGET) < 0.1)


func _run(mover: String, start: Vector2, heading: float, target: Vector2, blocker: String, point: Vector2) -> Dictionary:
	_reset()
	_place(blocker, point, 0.0)
	_place(mover, start, heading)
	var follower := _follower(mover)
	var locomotion := _locomotion(mover)
	follower.order(target)
	var radius: float = follower.ship_radius
	var blocker_radius: float = _follower(blocker).ship_radius
	var r := {"name": "%s -> (%.1f, %.1f), %s parked at (%.1f, %.1f)" % [mover, target.x, target.y, blocker, point.x, point.y],
		# Reachable: the destination keeps avoidance's separation from the parked ship.
		"reachable": point.distance_to(target) >= radius + blocker_radius + _main.get_node("Ships/%s/Avoidance" % mover).separation_margin,
		"arrived": false, "outcome": "", "time": 0.0,
		"short": 0.0, "cross": 0.0, "progress": 0.0, "length": 0.0, "remaining": 0.0, "cap": 0.0, "min_cap": INF,
		"no_early_zero": true, "clear": true, "min_gap": INF, "contacts": 0, "arrived_after_leave": false, "after_leave": 0.0, "settled": false,
		"reversals": 0, "reverse_speed": 0.0, "reaccelerations": 0, "zero_ticks": 0}
	var stopped := 0.0
	var ticks := 0
	while locomotion.has_destination and ticks < 60 * TIME_LIMIT and stopped < HOLD_LIMIT:
		_step_route_followers()
		var away := locomotion.planar_position.distance_to(target)
		if follower.status == RouteFollower.RouteStatus.ROUTE and away > 0.5:
			r.min_cap = minf(r.min_cap, follower.speed_cap)
			if r.reachable and follower.speed_cap < 0.000001 and _navigation.segment_clear(locomotion.planar_position, target, follower.line_clearance()):
				r.no_early_zero = false
		_step_rest()
		ticks += 1
		stopped = stopped + DT if locomotion.velocity.length() < 0.01 else 0.0
		for ship_name in [mover, blocker]:
			r.min_gap = minf(r.min_gap, _navigation.surface_distance(_locomotion(ship_name).planar_position) - _follower(ship_name).ship_radius)
		r.min_gap = minf(r.min_gap, locomotion.planar_position.distance_to(_locomotion(blocker).planar_position) - radius - blocker_radius)
	r.clear = r.min_gap >= -0.001
	r.arrived = not locomotion.has_destination
	r.time = ticks * DT
	r.outcome = "arrived" if r.arrived else ("stopped" if stopped >= HOLD_LIMIT else "moving")
	if not r.reachable:
		r.name += " [unreachable]"
	r.contacts = locomotion.collision_count
	if not r.arrived:
		var position := locomotion.planar_position
		r.short = position.distance_to(target)
		var last := follower.route.size() - 1
		r.cross = Geometry2D.get_closest_point_to_segment(position, follower.route[follower.segment], follower.route[follower.segment + 1]).distance_to(position)
		r.progress = follower.progress
		r.length = follower.progress + 0.0 if last < 1 else _route_length(follower.route)
		r.remaining = follower.remaining
		r.cap = follower.speed_cap
	if not r.reachable and r.outcome == "stopped":
		r.settled = true
		# The parked ship leaves (removed to its parking spot): the order must complete.
		_place(blocker, PARK[blocker], 0.0)
		var after := 0
		var last_sign := 0.0
		var last_speed := locomotion.velocity.length()
		var slowing := false
		while locomotion.has_destination and after < 60 * 60:
			_step_route_followers()
			if follower.speed_cap < 0.000001 and locomotion.planar_position.distance_to(target) > 0.5 \
					and _navigation.segment_clear(locomotion.planar_position, target, follower.line_clearance()):
				r.zero_ticks += 1
			_step_rest()
			after += 1
			var rate := rad_to_deg(locomotion.angular_velocity)
			if absf(rate) > 1.0:
				r.reversals += 1 if last_sign != 0.0 and signf(rate) != last_sign else 0
				last_sign = signf(rate)
			r.reverse_speed = maxf(r.reverse_speed, -locomotion.local_velocity().x)
			var speed := locomotion.velocity.length()
			r.reaccelerations += 1 if slowing and speed > last_speed + 0.0001 else 0
			slowing = speed < last_speed - 0.0001
			last_speed = speed
		# One tick allowed: the route reads avoidance's offset from the tick before (the parked ship vanished at once).
		r.no_early_zero = r.no_early_zero and r.zero_ticks <= 1
		r.arrived_after_leave = not locomotion.has_destination and locomotion.planar_position.distance_to(target) < 0.1
		r.after_leave = after * DT
		r.outcome = "left: %s" % ("arrived %.0f s" % r.after_leave if r.arrived_after_leave else "STUCK")
		print("    after the parked ship left: %s: %s, turn-rate reversals %d, largest reverse speed %.2f u/s, re-accelerations %d, zero-cap ticks %d" % [r.name, r.outcome,
			r.reversals, r.reverse_speed, r.reaccelerations, r.zero_ticks])
	return r


# The route speed cap read purely along the route (the profile as planned): what
# RouteFollower gave before the correction.
func _profile_cap(ship_name: String) -> float:
	var follower := _follower(ship_name)
	if follower.status != RouteFollower.RouteStatus.ROUTE:
		return follower.speed_cap
	var brake: float = follower.turn_brake_share * _locomotion(ship_name).reverse_accel
	var cap := INF
	for k in range(follower._next_restriction, follower.restrictions.size()):
		var restriction: Vector3 = follower.restrictions[k]
		var reach := 2.0 * brake * maxf(0.0, restriction.x - follower.progress)
		cap = minf(cap, sqrt(restriction.z * restriction.z + reach))
		if reach >= _locomotion(ship_name).max_speed * _locomotion(ship_name).max_speed:
			break
	return cap


static func _capped(value: float) -> float:
	return minf(value, 100.0)


static func _route_length(route: PackedVector2Array) -> float:
	var length := 0.0
	for i in range(1, route.size()):
		length += route[i - 1].distance_to(route[i])
	return length


func _reset() -> void:
	for ship_name in SHIPS:
		var follower := _follower(ship_name)
		follower.status = RouteFollower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_main.get_node("Ships/%s/Avoidance" % ship_name).reset()
		_place(ship_name, PARK[ship_name], 0.0)


func _step_route_followers() -> void:
	for ship_name in SHIPS:
		_follower(ship_name)._physics_process(DT)
		_main.get_node("Ships/%s/Avoidance" % ship_name)._physics_process(DT)


func _step_rest() -> void:
	for ship_name in SHIPS:
		_locomotion(ship_name)._step(DT)


func _place(ship_name: String, point: Vector2, heading: float) -> void:
	_locomotion(ship_name).place(point, heading)


func _follower(ship_name: String) -> RouteFollower:
	return _main.get_node("Ships/%s/RouteFollower" % ship_name) as RouteFollower


func _locomotion(ship_name: String) -> ShipLocomotion:
	return _main.get_node("Ships/%s/Locomotion" % ship_name) as ShipLocomotion


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-110s %s" % [label, "PASS" if ok else "FAIL"])
