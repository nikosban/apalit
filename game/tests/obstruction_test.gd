extends SceneTree
## Headless checks for ship obstruction by stationary ships, on the test arena
## (game/scenes/movement_test.tscn, unchanged): a Miner and a Transporter are
## added at run time, configured as in main.tscn (movement nodes only). Physics is
## stepped manually at 60 Hz in the game's order (per ship RouteFollower then
## Avoidance, then every Locomotion). Manual MOVE orders go through the lab's
## single-ship MOVE (movement_lab.gd `_move_single`), as a right-click does.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/obstruction_test.gd
## Scenarios (open area east of the obstacles, around (115, 0), unless stated):
##   1. MOVE onto or beside a stationary ship (directly underneath, offset, near the
##      separation boundary); a click on a moving ship; no valid destination.
##   2. Close approaches past an idle Miner (the previously failing distances).
##   3. The same approaches with the Miner moved away (reference).
##   4. Moving-ship encounters: crossing from either side, head-on, overtaking.
##   5. Two stationary ships with room between or around them (side by side,
##      staggered), and two across the arena's gap (impassable: hold short).
##   7. Direct moves ending beyond a stationary Miner (every hull, several
##      distances), and the same moves unobstructed (control).
##   6. A stationary Miner in the arena's gap (insufficient clearance), then leaving.
## Measured: outcome, time, along-travel reversals, largest reverse speed, longest
## stall (stopped with an order), contacts (collision count), smallest footprint
## gap, acceleration / turn-limit violations, passing-side flips. Every check is PASS/FAIL.

const LAB := preload("res://game/scenes/movement_test.tscn")
const MINER := preload("res://game/ships/miner.tscn")
const TRANSPORTER := preload("res://game/ships/transporter.tscn")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipAvoidance := preload("res://game/avoidance/ship_avoidance.gd")
const Scenarios := preload("res://game/scenes/avoidance_scenarios.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner", "Transporter"]
const PARK := {"Frigate": Vector2(-135, 135), "Gunship": Vector2(-135, 70), "Destroyer": Vector2(-135, 0),
	"Miner": Vector2(-135, -70), "Transporter": Vector2(-135, -135)}
const CENTER := Vector2(115, 0)
const TIME_LIMIT := 90.0 # s per run
const HOLD_LIMIT := 15.0 # s stopped with an order ends a run as WAITING
const STOPPED_SPEED := 0.01 # u/s
const REVERSE_SPEED := 0.05 # u/s along the travel direction counted for reversals
const SLACK := 1.0e-4

var _failures := 0
var _checks := 0
var _lab: Node
var _navigation: Node


func _initialize() -> void:
	await process_frame
	_lab = LAB.instantiate()
	root.add_child(_lab)
	_add_ship(MINER.instantiate(), "Miner", [5.0, 4.0, 3.0, 6.0, 3.0, 2.5, 120.0, 240.0], 1.6, 1)
	_add_ship(TRANSPORTER.instantiate(), "Transporter", [4.5, 2.5, 2.0, 3.0, 1.5, 1.2, 60.0, 90.0], 4.1, 2)
	_navigation = _lab.get_node("StaticNavigation")
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance"]:
			_node(ship_name, child).set_physics_process(false)
	for ship_name in SHIPS:
		while not _navigation.is_ready(_follower(ship_name).planning_radius()):
			await physics_frame
	print("run                                                                  outcome    time s  reversals  back u/s  stall s  contacts  gap u  limits  flips")
	_test_occupied()
	_test_close_approaches()
	_test_moving_encounters()
	_test_two_stationary()
	_test_insufficient()
	_test_far_side()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# A ship under Ships with the three movement nodes, set up before they enter the tree.
# profile: max speed forward / reverse / lateral, accel forward / reverse / lateral, turn rate, turn accel.
func _add_ship(ship: Node3D, ship_name: String, profile: Array, radius: float, size_class: int) -> void:
	ship.name = ship_name
	ship.position = Vector3(PARK[ship_name].x, 1.5, PARK[ship_name].y)
	_lab.get_node("Ships").add_child(ship)
	var locomotion := ShipLocomotion.new()
	locomotion.name = "Locomotion"
	locomotion.max_speed = profile[0]
	locomotion.max_reverse_speed = profile[1]
	locomotion.max_lateral_speed = profile[2]
	locomotion.forward_accel = profile[3]
	locomotion.reverse_accel = profile[4]
	locomotion.lateral_accel = profile[5]
	locomotion.max_turn_rate_deg = profile[6]
	locomotion.turn_accel_deg = profile[7]
	ship.add_child(locomotion)
	var follower := RouteFollower.new()
	follower.name = "RouteFollower"
	follower.ship_radius = radius
	follower.clearance_margin = 1.0
	ship.add_child(follower)
	var avoidance := ShipAvoidance.new()
	avoidance.name = "Avoidance"
	avoidance.size_class = size_class
	avoidance.separation_margin = 1.0
	ship.add_child(avoidance)


# 1. MOVE onto or beside a stationary ship.
func _test_occupied() -> void:
	var group := _lab.get_node("GroupOrders")
	var results := {true: [0, true], false: [0, true]} # far side of the blocker -> [count, all ok]
	for case: Array in [["Gunship", "Miner", Vector2(0, 0)], ["Gunship", "Miner", Vector2(2, 0)], ["Gunship", "Miner", Vector2(0, -6)],
			["Gunship", "Miner", Vector2(0, -6.4)], ["Gunship", "Miner", Vector2(4, 4)], ["Destroyer", "Miner", Vector2(0, 0)],
			["Transporter", "Miner", Vector2(0, 0)], ["Frigate", "Gunship", Vector2(0, 0)], ["Miner", "Gunship", Vector2(2, 0)],
			["Frigate", "Miner", Vector2(0, 0)]]:
		var mover: String = case[0]
		var blocker: String = case[1]
		var click: Vector2 = CENTER + case[2]
		_reset()
		_place(blocker, CENTER, 0.0)
		var start := CENTER + Vector2(0, 30)
		_place(mover, start, 0.0)
		var given: bool = _lab._move_single(_ship(mover), click)
		var destination := _locomotion(mover).destination
		var clearance: float = _follower(mover).ship_radius + _follower(blocker).ship_radius + group.separation_margin + group.destination_buffer
		var label := "1. %s MOVE to %s (%+.1f, %+.1f) from the blocker" % [mover, blocker, case[2].x, case[2].y]
		var r := _simulate(label, mover, start)
		var outside := destination.distance_to(CENTER) >= clearance - 0.01
		var within: bool = destination.distance_to(CENTER) <= clearance + group.resolve_margin + 0.01
		# A click on the mover's side of the blocker (or on it) resolves on that side.
		var far := (click - CENTER).dot(start - CENTER) < 0.0
		var near_side := far or (destination - CENTER).dot(start - CENTER) >= 0.0
		var ok: bool = given and outside and within and near_side and r.arrived and r.reversals == 0 and r.contacts == 0 and r.clear and r.limits == 0
		print("    -> destination (%.2f, %.2f), %.2f u from the blocker (clearance %.2f, limit %.2f), %.2f u from the click%s" % [destination.x, destination.y,
			destination.distance_to(CENTER), clearance, clearance + group.resolve_margin, destination.distance_to(click), ", far side" if far else ""])
		results[far][0] += 1
		results[far][1] = results[far][1] and ok
	_check("1. occupied destinations on or in front of the blocker (%d): resolved outside the stationary ship's clearance within the limit, on the mover's side; arrive with no reversal, contact or limit violation" % results[false][0], results[false][1])
	_check("1. occupied destinations just beyond the blocker (%d): resolved outside its clearance within the limit; arrive with no reversal, contact or limit violation" % results[true][0], results[true][1])

	# A click on a ship that is moving (with an order) is not resolved.
	_reset()
	_place("Miner", CENTER + Vector2(-20, 0), -PI / 2)
	_follower("Miner").order(CENTER + Vector2(20, 0))
	for i in 60 * 3:
		_step()
	_place("Gunship", CENTER + Vector2(0, 30), 0.0)
	var click := _locomotion("Miner").planar_position
	_lab._move_single(_ship("Gunship"), click)
	_check("1. a click on a moving ship keeps the clicked point (destination %.2f u from it)" % _locomotion("Gunship").destination.distance_to(click),
		_locomotion("Gunship").destination.distance_to(click) < 0.01)

	# No valid destination (a Miner inside the closed box): rejected, the current order kept.
	_reset()
	_place("Miner", Vector2(60, 50), 0.0)
	_place("Gunship", CENTER + Vector2(0, 30), 0.0)
	_follower("Gunship").order(CENTER + Vector2(0, -30))
	for i in 60:
		_step()
	var before := _locomotion("Gunship").destination
	var given: bool = _lab._move_single(_ship("Gunship"), Vector2(60, 50))
	_check("1. no valid destination: command rejected, current order kept (destination unchanged, still moving)",
		not given and _locomotion("Gunship").has_destination and _locomotion("Gunship").destination == before)


# 2, 3. Close approaches past an idle Miner, and the same with the Miner moved away.
func _test_close_approaches() -> void:
	var ok := true
	var reference_ok := true
	var stalls := 0
	var runs := 0
	var worst_added := 0.0
	for set: Array in [["Gunship", [7.0, 8.0, 9.0, 10.0]], ["Transporter", [7.7, 8.7, 9.7, 10.7, 12.7]],
			["Destroyer", [9.8, 11.8, 13.8, 16.8]], ["Frigate", [5.2, 7.2]]]:
		var mover: String = set[0]
		for distance: float in set[1]:
			for lateral: float in [0.0, 1.0, 2.0, 3.0, 4.0]:
				var start := CENTER + Vector2(lateral, distance)
				var target := CENTER + Vector2(lateral, -30)
				_reset()
				_place("Miner", CENTER, 0.0)
				_place(mover, start, 0.0)
				_follower(mover).order(target)
				var r := _simulate("2. %s from %.1f u, %.0f u off, past an idle Miner" % [mover, distance, lateral], mover, start)
				_reset()
				_place(mover, start, 0.0)
				_follower(mover).order(target)
				var alone := _simulate("", mover, start)
				reference_ok = reference_ok and alone.arrived
				runs += 1
				stalls += 0 if r.arrived else 1
				if r.arrived and alone.arrived:
					worst_added = maxf(worst_added, r.time - alone.time)
				ok = ok and r.arrived and r.contacts == 0 and r.clear and r.reversals == 0 and r.limits == 0
	_check("2. close approaches past an idle Miner: %d of %d arrive (largest added time %.1f s) with no contact, reversal or limit violation" % [runs - stalls, runs, worst_added], ok)
	_check("3. the same approaches with the Miner moved away all arrive", reference_ok)


# 4. Moving-ship encounters (avoidance roles unchanged): crossing either side, head-on, overtaking.
func _test_moving_encounters() -> void:
	var profiles := {}
	for ship_name in SHIPS:
		profiles[ship_name] = [_locomotion(ship_name).max_speed, _locomotion(ship_name).forward_accel]
	var ok := true
	for scenario: Dictionary in [Scenarios.crossing("Frigate", "Gunship", true, profiles), Scenarios.crossing("Frigate", "Gunship", false, profiles),
			Scenarios.crossing("Miner", "Gunship", true, profiles), Scenarios.head_on("Frigate", "Gunship", 0.0), Scenarios.head_on("Miner", "Transporter", 0.0),
			Scenarios.overtake("Frigate", "Gunship")]:
		_reset()
		for entry: Dictionary in scenario.movers:
			var travel: Vector2 = entry.target - entry.start
			_place(entry.ship, entry.start, atan2(-travel.x, -travel.y))
		for entry: Dictionary in scenario.movers:
			_follower(entry.ship).order(entry.target)
		var results := _simulate_all(scenario.name, scenario.movers)
		for r: Dictionary in results:
			ok = ok and r.arrived and r.contacts == 0 and r.clear and r.limits == 0
	_check("4. moving-ship encounters (crossing both sides, head-on, overtaking): every ship arrives, no contact or limit violation", ok)


# 5. Two stationary ships (an idle Miner and an idle Frigate). Passable (open space):
# 16 u apart (Gunship and Transporter fit between, the Destroyer must go around)
# and 4 u apart (everyone goes around; the two encounters start committed to opposite
# sides), from the centre line and 3 u off; a staggered pair. Impassable: the two
# ships across the arena's 10 u gap (walled on both sides): the mover holds short,
# then arrives once they leave. Passing-side flips: sign changes of the applied
# steering shift across the route (more than 0.5 u either side).
func _test_two_stationary() -> void:
	var ok := true
	var arrived := 0
	var runs := 0
	var layouts := []
	for spacing: float in [16.0, 4.0]:
		for lateral: float in [0.0, 3.0]:
			for mover in ["Gunship", "Transporter", "Destroyer"]:
				layouts.append(["%.0f u apart, from %.0f u off" % [spacing, lateral], mover, Vector2(-spacing * 0.5, 0), Vector2(spacing * 0.5, 0),
					Vector2(lateral, 12.0 if mover != "Destroyer" else 16.0), Vector2(lateral, -30)])
	for mover in ["Gunship", "Destroyer"]:
		layouts.append(["staggered (Miner 1 u left, Frigate 2 u right and 8 u on)", mover, Vector2(-1, 0), Vector2(2, -8),
			Vector2(0, 12.0 if mover != "Destroyer" else 16.0), Vector2(0, -30)])
	for layout: Array in layouts:
		var mover: String = layout[1]
		_reset()
		_place("Miner", CENTER + layout[2], 0.0)
		_place("Frigate", CENTER + layout[3], 0.0)
		var start: Vector2 = CENTER + layout[4]
		_place(mover, start, 0.0)
		_follower(mover).order(CENTER + layout[5])
		var r := _simulate("5. %s past two stationary ships %s" % [mover, layout[0]], mover, start)
		runs += 1
		arrived += 1 if r.arrived else 0
		ok = ok and r.arrived and r.contacts == 0 and r.clear and r.reversals == 0 and r.limits == 0 and r.flips == 0
	_check("5. two stationary ships with room between or around them: %d of %d arrive; no contact, reversal, limit violation or passing-side flip" % [arrived, runs], ok)

	# Impassable: Miner and Frigate across the gap (blocks at x -26..-6 and 4..24, y 37..43;
	# only ships up to the Gunship fit through it, so the Gunship is the mover).
	var held := true
	for points: Array in [[Vector2(-3.5, 40), Vector2(1.5, 40)], [Vector2(-4.0, 39), Vector2(2.0, 41)]]:
		var mover := "Gunship"
		_reset()
		_place("Miner", points[0], 0.0)
		_place("Frigate", points[1], 0.0)
		var start := Vector2(-1, 62)
		_place(mover, start, 0.0)
		_follower(mover).order(Vector2(-1, 15))
		var r := _simulate("5. %s through the gap held by two stationary ships at %s, %s (impassable)" % [mover, points[0], points[1]], mover, start)
		_place("Miner", PARK["Miner"], 0.0)
		_place("Frigate", PARK["Frigate"], 0.0)
		var after := _simulate("5. ... after both left", mover, start)
		held = held and r.outcome == "WAITING" and r.contacts == 0 and r.clear and r.reversals == 0 and r.flips == 0 and after.arrived and after.contacts == 0
	_check("5. two stationary ships across a gap too narrow to pass: the mover holds short (no contact, reversal or side flip), then arrives once they leave", held)


# 6. Insufficient clearance: a Miner parked in the arena's gap (10 u between the gap
# blocks): the Gunship holds short (order kept, no contact, no shuttling); once the
# Miner has left it completes its order.
func _test_insufficient() -> void:
	_reset()
	_place("Miner", Vector2(-1, 40), 0.0)
	var start := Vector2(-1, 62)
	_place("Gunship", start, 0.0)
	_follower("Gunship").order(Vector2(-1, 15))
	var r := _simulate("6. Gunship through the gap held by a Miner", "Gunship", start)
	var waited: bool = not r.arrived and r.outcome == "WAITING" and r.contacts == 0 and r.clear and r.reversals == 0 and r.limits == 0
	_place("Miner", PARK["Miner"], 0.0)
	var after := _simulate("6. ... after the Miner left", "Gunship", start)
	_check("6. insufficient clearance: the Gunship holds short with its order (no contact, no shuttling), then arrives once the Miner left",
		waited and after.arrived and after.contacts == 0 and after.clear)


# 7. Direct moves ending beyond a stationary Miner (the passing shift still applied
# near the destination), every hull, destinations 0.3 / 2 / 5 / 10 u beyond the
# Miner's clearance (both footprints + 1.5 u), from the centre line and 2 u off;
# the original case (a MOVE 6.4 u beyond, resolved 1 u on); every move also
# unobstructed (control). Per run: overshoot past the destination along the leg,
# backward travel along the leg, reverse speed, along-leg reversals,
# re-accelerations, and when the avoidance shift is released: lateral and along-leg
# distance left, speed, braking distance; the largest change of the desired speed in
# one tick, and that change at the release.
func _test_far_side() -> void:
	print("far side                                                    outcome  time s  over u  back u  back u/s  rev  reacc  rel lat u  rel along u  rel v  rel brake u  max dv  rel dv  contacts  gap u")
	var ok := true
	var control_ok := true
	var count := 0
	_reset()
	_place("Miner", CENTER, 0.0)
	_place("Gunship", CENTER + Vector2(0, 30), 0.0)
	_lab._move_single(_ship("Gunship"), CENTER + Vector2(0, -6.4))
	var original := _far_run("7. Gunship MOVE 6.4 u beyond the Miner (original case)", "Gunship")
	ok = ok and _far_ok(original)
	for mover in ["Gunship", "Frigate", "Transporter", "Destroyer"]:
		var clearance: float = _follower(mover).ship_radius + 1.6 + 1.5
		for extra: float in [0.3, 2.0, 5.0, 10.0]:
			for lateral: float in [0.0, 2.0]:
				var start := CENTER + Vector2(lateral, 30.0 if mover != "Destroyer" else 35.0)
				var target := CENTER + Vector2(lateral, -(clearance + extra))
				for obstructed: bool in [true, false]:
					_reset()
					if obstructed:
						_place("Miner", CENTER, 0.0)
					_place(mover, start, 0.0)
					_follower(mover).order(target)
					var r := _far_run("7. %s %.1f u beyond, %.0f u off%s" % [mover, clearance + extra, lateral, "" if obstructed else " (control)"], mover)
					if obstructed:
						ok = ok and _far_ok(r)
						count += 1
					else:
						control_ok = control_ok and r.arrived and r.reversals == 0 and r.over <= 0.05 and r.contacts == 0
	_check("7. direct moves ending beyond a stationary ship (%d + the original case): arrive without reversal, backward travel or overshoot over 0.5 u; no contact" % count, ok)
	_check("7. the same moves unobstructed (control): arrive without reversal or overshoot", control_ok)


func _far_ok(r: Dictionary) -> bool:
	return r.arrived and r.reversals == 0 and r.back < 0.05 and r.over <= 0.5 and r.contacts == 0 and r.clear and r.limits == 0


func _far_run(label: String, mover: String) -> Dictionary:
	var loco := _locomotion(mover)
	var follower := _follower(mover)
	var avoidance := _node(mover, "Avoidance") as ShipAvoidance
	var destination := loco.destination
	var dir := (destination - loco.planar_position).normalized()
	var side := Vector2(-dir.y, dir.x)
	var r := {"ship": mover, "dir": dir, "arrived": false, "time": 0.0, "over": 0.0, "back": 0.0, "back_speed": 0.0, "reversals": 0, "last": 0.0,
		"reaccel": 0, "peak": 0.0, "trough": 0.0, "falling": false, "rel_lat": 0.0, "rel_along": 0.0, "rel_v": 0.0, "rel_brake": 0.0,
		"max_dv": 0.0, "rel_dv": 0.0, "contacts": 0, "gap": INF, "clear": true, "limits": 0, "stopped": 0.0, "stall": 0.0, "flips": 0, "side": 0.0}
	var shifted := false
	var desired := 0.0
	var t := 0.0
	while t < TIME_LIMIT and loco.has_destination and r.stopped < HOLD_LIMIT:
		var before := [loco.velocity, loco.angular_velocity, loco.heading, loco.has_destination]
		_step()
		t += DT
		_measure(r, before)
		var position := loco.planar_position
		var along: float = loco.velocity.dot(dir)
		r.over = maxf(r.over, (position - destination).dot(dir))
		if along < 0.0:
			r.back += -along * DT
		r.back_speed = maxf(r.back_speed, -loco.local_velocity().x)
		var speed := loco.velocity.length()
		if r.falling:
			r.trough = minf(r.trough, speed)
			if speed > r.trough + 0.1:
				r.reaccel += 1
				r.falling = false
				r.peak = speed
		else:
			r.peak = maxf(r.peak, speed)
			if speed < r.peak - 0.1:
				r.falling = true
				r.trough = speed
		var desired_now := loco.desired_velocity.length()
		var dv := absf(desired_now - desired)
		r.max_dv = maxf(r.max_dv, dv)
		desired = desired_now
		var active := absf((avoidance.target - follower.aim_point).dot(side)) > 0.05
		if shifted and not active:
			r.rel_lat = absf((position - destination).dot(side))
			r.rel_along = (destination - position).dot(dir)
			r.rel_v = speed
			r.rel_brake = speed * speed / (2.0 * ShipLocomotion.BRAKE_MARGIN * loco.reverse_accel)
			r.rel_dv = dv
		shifted = active
		r.stopped = r.stopped + DT if speed < STOPPED_SPEED else 0.0
	r.arrived = not loco.has_destination and loco.planar_position.distance_to(destination) < 0.1
	r.time = t
	r.contacts = loco.collision_count
	r.clear = r.gap >= -0.001
	print("%-60s %-8s %6.1f  %6.2f  %6.2f  %8.2f  %3d  %5d  %9.2f  %11.2f  %5.2f  %11.2f  %6.3f  %6.3f  %8d  %5.2f" % [label, "arrived" if r.arrived else "NOT", r.time,
		r.over, r.back, r.back_speed, r.reversals, r.reaccel, r.rel_lat, r.rel_along, r.rel_v, r.rel_brake, r.max_dv, r.rel_dv, r.contacts, r.gap])
	return r


func _simulate(label: String, mover: String, start: Vector2) -> Dictionary:
	return _simulate_all(label, [{"ship": mover, "start": start}])[0]


# Steps until every mover arrived or held HOLD_LIMIT, or TIME_LIMIT; one result per mover.
func _simulate_all(label: String, movers: Array) -> Array:
	var records := []
	for entry: Dictionary in movers:
		var travel: Vector2 = _locomotion(entry.ship).destination - _locomotion(entry.ship).planar_position
		records.append({"ship": entry.ship, "dir": travel.normalized(), "arrived": false, "time": 0.0, "outcome": "MOVING", "reversals": 0,
			"back": 0.0, "stall": 0.0, "stopped": 0.0, "last": 0.0, "contacts": 0, "gap": INF, "clear": true, "limits": 0, "flips": 0, "side": 0.0})
	var t := 0.0
	while t < TIME_LIMIT:
		var before := {}
		for record: Dictionary in records:
			var loco := _locomotion(record.ship)
			before[record.ship] = [loco.velocity, loco.angular_velocity, loco.heading, loco.has_destination]
		_step()
		t += DT
		var done := true
		for record: Dictionary in records:
			var loco := _locomotion(record.ship)
			if record.arrived or record.outcome == "WAITING":
				continue
			_measure(record, before[record.ship])
			if not loco.has_destination:
				record.arrived = true
				record.time = t
				record.outcome = "arrived"
				continue
			record.stopped = record.stopped + DT if loco.velocity.length() < STOPPED_SPEED else 0.0
			record.stall = maxf(record.stall, record.stopped)
			if record.stopped >= HOLD_LIMIT:
				record.outcome = "WAITING"
				record.time = t
				continue
			done = false
		if done:
			break
	for record: Dictionary in records:
		if record.outcome == "MOVING":
			record.time = t
		record.contacts = _locomotion(record.ship).collision_count
		record.clear = record.gap >= -0.001
		if label != "":
			print("%-68s %-9s %6.1f  %9d  %8.2f  %7.1f  %8d  %5.2f  %6d  %5d" % [label + ("" if records.size() == 1 else " [%s]" % record.ship),
				record.outcome, record.time, record.reversals, record.back, record.stall, record.contacts, record.gap, record.limits, record.flips])
	return records


# Per tick: reversals of the travel along the order's direction, reverse speed,
# footprint gaps to ships and obstacles, acceleration ellipse and turn limits.
func _measure(record: Dictionary, before: Array) -> void:
	var loco := _locomotion(record.ship)
	var along: float = loco.velocity.dot(record.dir)
	if absf(along) > REVERSE_SPEED:
		if record.last != 0.0 and signf(along) != signf(record.last):
			record.reversals += 1
		record.last = along
	record.back = maxf(record.back, -loco.local_velocity().x)
	var avoidance := _node(record.ship, "Avoidance") as ShipAvoidance
	var across: float = (avoidance.target - _follower(record.ship).aim_point).dot(Vector2(-record.dir.y, record.dir.x))
	if absf(across) > 0.5:
		if record.side != 0.0 and signf(across) != record.side:
			record.flips += 1
		record.side = signf(across)
	var radius: float = _follower(record.ship).ship_radius
	record.gap = minf(record.gap, _navigation.surface_distance(loco.planar_position) - radius)
	for other in SHIPS:
		if other != record.ship:
			record.gap = minf(record.gap, loco.planar_position.distance_to(_locomotion(other).planar_position) - radius - _follower(other).ship_radius)
	var dv: Vector2 = loco.velocity - before[0]
	if before[3] and loco.has_destination and loco.contacts.is_empty() and _ellipse_size(loco, dv / DT, before[2]) > 1.0 + SLACK:
		record.limits += 1
	if absf(loco.angular_velocity) > deg_to_rad(loco.max_turn_rate_deg) * (1.0 + SLACK) \
			or absf(loco.angular_velocity - before[1]) > deg_to_rad(loco.turn_accel_deg) * DT * (1.0 + SLACK):
		record.limits += 1


func _ellipse_size(loco: ShipLocomotion, accel: Vector2, h: float) -> float:
	var f := accel.dot(Vector2(-sin(h), -cos(h)))
	var l := accel.dot(Vector2(cos(h), -sin(h)))
	var axis_limit: float = loco.forward_accel if f >= 0.0 else loco.reverse_accel
	return sqrt(pow(f / axis_limit, 2) + pow(l / loco.lateral_accel, 2))


func _step() -> void:
	for ship_name in SHIPS:
		_follower(ship_name)._physics_process(DT)
		_node(ship_name, "Avoidance")._physics_process(DT)
	for ship_name in SHIPS:
		_locomotion(ship_name)._step(DT)


func _reset() -> void:
	for ship_name in SHIPS:
		var follower := _follower(ship_name)
		follower.status = RouteFollower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()
		_place(ship_name, PARK[ship_name], 0.0)


func _place(ship_name: String, point: Vector2, heading: float) -> void:
	_locomotion(ship_name).place(point, heading)


func _ship(ship_name: String) -> Node3D:
	return _lab.get_node("Ships/" + ship_name) as Node3D


func _node(ship_name: String, child: String) -> Node:
	return _lab.get_node("Ships/%s/%s" % [ship_name, child])


func _follower(ship_name: String) -> RouteFollower:
	return _node(ship_name, "RouteFollower") as RouteFollower


func _locomotion(ship_name: String) -> ShipLocomotion:
	return _node(ship_name, "Locomotion") as ShipLocomotion


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-150s %s" % [label, "PASS" if ok else "FAIL"])
