extends SceneTree
## Headless Stage 6 collision enforcement checks on the real lab scene (PlanarCollision
## queried from Locomotion._apply_motion()). Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/collision_test.gd
## Case 0 flies routed orders with avoidance on, once with and once without collision
## (identical trajectories required) and measures the cost. Cases 1-8 step only the
## RouteFollowers and Locomotions (avoidance off, so contacts really happen), with
## direct Locomotion MOVE orders, at 60 Hz in scene order (some also in reverse order).
## Every tick: no new penetration (ship-ship and ship-obstacle footprints, checked
## independently of PlanarCollision) or, for pairs starting overlapped, no deeper
## overlap; committed displacement = position change, never longer than proposed;
## stored velocity never faster than requested and never into a contact; contact
## normals unit length, from the blocker toward the ship; acceleration ellipse and turn
## limits on ticks without a constraining contact; turn rate never altered; the order
## kept until arrival. Reported: final state, contacts begun, time blocked,
## resolution-limit hits, direction reversals while in contact (jitter), and the
## collision cost per ship per tick.

const LAB := preload("res://game/scenes/movement_test.tscn")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer"]
const PARKING := [Vector2(-135, 135), Vector2(-135, -135), Vector2(-135, 0)]
const TOLERANCE := 1.0e-4 # u; positions are 32-bit floats (about 1e-5 u resolution near 100 u).
const SLACK := 1.0e-4

var _failures := 0
var _lab: Node
var _collision: Node
var _obstacles: Array[Dictionary] = []
var _costs: Array[int] = []
var _contact_costs: Array[int] = []


func _initialize() -> void:
	await process_frame
	_lab = LAB.instantiate()
	root.add_child(_lab)
	_collision = _lab.get_node("PlanarCollision")
	_read_obstacles()
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance"]:
			_node(ship_name, child).set_physics_process(false)
	for ship_name in SHIPS:
		while not _lab.get_node("StaticNavigation").is_ready(_node(ship_name, "RouteFollower").planning_radius()):
			await physics_frame
	var wired := true
	for ship_name in SHIPS:
		wired = wired and _loco(ship_name)._collision == _collision
	_check("setup", "every Locomotion uses the lab's PlanarCollision", wired)

	_case_free_flight()
	_case_idle()
	_case_head_on()
	_case_crossing()
	_case_wall()
	_case_diagonal()
	_case_converging()
	_case_redirect()
	_case_overlap()
	_observe_occupied_destination()

	_costs.sort()
	_contact_costs.sort()
	print("collision cost per ship per tick: all %d ship-ticks mean %.1f us, 99th percentile %d us, max %d us; ship-ticks with contacts %d, mean %.1f us, max %d us" % [
		_costs.size(), _mean(_costs), _costs[int(_costs.size() * 0.99)], _costs[-1],
		_contact_costs.size(), _mean(_contact_costs), _contact_costs[-1] if not _contact_costs.is_empty() else 0])
	print("RESULT: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


# 0: routed orders past obstacles (slalom, LargeRound, RotatedBlock), the ships apart,
# avoidance on: identical with and without collision.
func _case_free_flight() -> void:
	var label := "0 free flight past obstacles (collision on vs off)"
	var starts := {"Frigate": Vector2(-50, 62), "Gunship": Vector2(90, -20), "Destroyer": Vector2(-100, -40)}
	var targets := {"Frigate": Vector2(50, 62), "Gunship": Vector2(40, -80), "Destroyer": Vector2(-60, -100)}
	var paths := []
	for enforced in [true, false]:
		_setup(starts, targets)
		for ship_name in SHIPS:
			_node(ship_name, "RouteFollower").order(targets[ship_name])
			if not enforced:
				_loco(ship_name)._collision = null
		var path := PackedVector2Array()
		var contacts := 0
		for i in 60 * 40:
			_tick(SHIPS, true)
			for ship_name in SHIPS:
				path.append(_loco(ship_name).planar_position)
				contacts += _loco(ship_name).contacts.size()
				if enforced:
					_costs.append(_loco(ship_name).collision_usec)
		paths.append(path)
		if enforced:
			_check(label, "no contact while flying (%d contact entries)" % contacts, contacts == 0)
		for ship_name in SHIPS:
			_loco(ship_name)._collision = _collision
	_check(label, "trajectories identical with and without collision (%d samples)" % paths[0].size(), paths[0] == paths[1])


# 1: the Frigate flies through an idle Gunship's position.
func _case_idle() -> void:
	var label := "1 moving ship against an idle ship"
	var setup := func() -> void:
		_setup({"Frigate": Vector2(115, 30), "Gunship": Vector2(115, 0)}, {"Frigate": Vector2(115, -30)})
		_loco("Frigate").move_to(Vector2(115, -30))
	setup.call()
	var idle: Vector2 = _loco("Gunship").planar_position
	var run := _fly(label, ["Frigate"], 12.0, SHIPS)
	var gap := _gap("Frigate", "Gunship")
	_report(label, run)
	_check(label, "stops touching: gap %.4f u in [0, skin]" % gap, gap >= -TOLERANCE and gap <= _collision.contact_skin + 0.001)
	_check(label, "stored velocity zero (%.6f u/s)" % _loco("Frigate").velocity.length(), _loco("Frigate").velocity.length() < 0.001)
	_check(label, "contact normal from the Gunship toward the Frigate", _normal_toward("Frigate", Vector2(0, 1)))
	_check(label, "idle Gunship untouched", _loco("Gunship").planar_position == idle and _loco("Gunship").velocity == Vector2.ZERO)
	_replay(label, setup, ["Frigate"], 12.0, run)


# 2: Frigate and Gunship head-on on the same line.
func _case_head_on() -> void:
	var label := "2 two ships head-on"
	var setup := func() -> void:
		_setup({"Frigate": Vector2(115, 30), "Gunship": Vector2(115, -30)}, {"Frigate": Vector2(115, -30), "Gunship": Vector2(115, 30)})
		_loco("Frigate").move_to(Vector2(115, -30))
		_loco("Gunship").move_to(Vector2(115, 30))
	setup.call()
	var run := _fly(label, ["Frigate", "Gunship"], 14.0, SHIPS)
	_report(label, run)
	var gap := _gap("Frigate", "Gunship")
	_check(label, "both stop touching: gap %.4f u in [0, skin]" % gap, gap >= -TOLERANCE and gap <= _collision.contact_skin + 0.001)
	_check(label, "both stored velocities zero", _loco("Frigate").velocity.length() < 0.001 and _loco("Gunship").velocity.length() < 0.001)
	_replay(label, setup, ["Frigate", "Gunship"], 14.0, run)


# 3: Frigate eastbound, Gunship southbound, timed to meet near (115, 0).
func _case_crossing() -> void:
	var label := "3 two ships crossing"
	var setup := func() -> void:
		_setup({"Frigate": Vector2(80, 0), "Gunship": Vector2(115, 35)}, {"Frigate": Vector2(150, 0), "Gunship": Vector2(115, -35)})
		_loco("Frigate").move_to(Vector2(150, 0))
		_loco("Gunship").move_to(Vector2(115, -35))
	setup.call()
	var run := _fly(label, ["Frigate", "Gunship"], 30.0, SHIPS)
	_report(label, run)
	_replay(label, setup, ["Frigate", "Gunship"], 30.0, run)


# 4: the Frigate flies straight into the Wall's north face (z = -77).
func _case_wall() -> void:
	var label := "4 ship straight into a static obstacle"
	_setup({"Frigate": Vector2(-10, -60)}, {"Frigate": Vector2(-10, -100)})
	_loco("Frigate").move_to(Vector2(-10, -100))
	var run := _fly(label, ["Frigate"], 12.0, SHIPS)
	_report(label, run)
	var gap := _obstacle_gap("Frigate")
	_check(label, "stops at the wall: gap %.4f u in [0, skin]" % gap, gap >= -TOLERANCE and gap <= _collision.contact_skin + 0.001)
	_check(label, "stored velocity zero (%.6f u/s)" % _loco("Frigate").velocity.length(), _loco("Frigate").velocity.length() < 0.001)
	_check(label, "contact normal out of the wall face (0, 1)", _normal_toward("Frigate", Vector2(0, 1)))


# 5: diagonal into the Wall (glides along it), then the RotatedBlock's corner (30°
# block): head on along its diagonal (stops at the corner), across the diagonal just
# clear (no contact) and clipping it by 0.3 u (glides around the corner).
func _case_diagonal() -> void:
	var label := "5 ship diagonally along an obstacle"
	_setup({"Frigate": Vector2(-30, -60)}, {"Frigate": Vector2(-5, -100)})
	_loco("Frigate").move_to(Vector2(-5, -100))
	var glide := {"ticks": 0, "into": 0.0, "speed": 0.0}
	var watch := func() -> void:
		var frigate := _loco("Frigate")
		for contact: Dictionary in frigate.contacts:
			glide.ticks += 1
			glide.into = minf(glide.into, frigate.velocity.dot(contact.normal))
			glide.speed = maxf(glide.speed, frigate.velocity.length())
	var run := _fly(label, ["Frigate"], 20.0, SHIPS, watch)
	_report(label, run)
	_check(label, "glides in contact (%d ticks, fastest %.2f u/s), never into the face (min %.6f u/s)" % [glide.ticks, glide.speed, glide.into],
		glide.ticks > 0 and glide.speed > 0.5 and glide.into >= -TOLERANCE)
	_check(label, "ends pressed near x = -5, below the destination (x %.3f, still %.3f u/s along the face)" % [_loco("Frigate").planar_position.x, _loco("Frigate").velocity.length()],
		absf(_loco("Frigate").planar_position.x + 5.0) < 0.5)

	var block := _lab.get_node("Obstacles/RotatedBlock") as MeshInstance3D
	var x_axis := Vector2(block.global_basis.x.x, block.global_basis.x.z).normalized()
	var z_axis := Vector2(-x_axis.y, x_axis.x)
	var center := Vector2(block.global_position.x, block.global_position.z)
	var half := Vector2(8, 2)
	var corner := center + x_axis * half.x + z_axis * half.y
	var outward := (x_axis + z_axis).normalized()
	var side := Vector2(-outward.y, outward.x)
	var radius := 1.6
	# [name, start, target]
	var variants := [
		["head-on into the corner", corner + outward * 25.0, corner - outward * 25.0],
		["across it 0.05 u clear", corner + outward * (radius + 0.05) - side * 25.0, corner + outward * (radius + 0.05) + side * 25.0],
		["across it clipping 0.3 u", corner + outward * (radius - 0.3) - side * 25.0, corner + outward * (radius - 0.3) + side * 25.0]]
	for variant: Array in variants:
		var sub: String = "5 rotated corner, " + variant[0]
		_setup({"Frigate": variant[1]}, {"Frigate": variant[2]})
		_loco("Frigate").move_to(variant[2])
		var corner_run := _fly(sub, ["Frigate"], 20.0, SHIPS)
		_report(sub, corner_run)
		var loco := _loco("Frigate")
		if variant[0].begins_with("head-on"):
			_check(sub, "stops at the corner, normal along the diagonal", loco.velocity.length() < 0.001 and _normal_toward("Frigate", outward))
		elif variant[0].ends_with("clear"):
			_check(sub, "no contact, arrives", corner_run.contacts["Frigate"] == 0 and loco.arrived)
		else:
			_check(sub, "contact, slides around the corner and arrives", corner_run.contacts["Frigate"] > 0 and loco.arrived)


# 6: three ships converging on one point.
func _case_converging() -> void:
	var label := "6 three ships converging"
	var setup := func() -> void:
		var point := Vector2(115, 0)
		_setup({"Frigate": Vector2(115, 35), "Gunship": Vector2(85, -20), "Destroyer": Vector2(145, -20)}, {"Frigate": point, "Gunship": point, "Destroyer": point})
		for ship_name in SHIPS:
			_loco(ship_name).move_to(point)
	setup.call()
	var run := _fly(label, SHIPS, 40.0, SHIPS)
	_report(label, run)
	_check(label, "settled: last 2 s moves at most %.5f u per tick" % run.late_move, run.late_move < 0.001)
	_replay(label, setup, SHIPS, 40.0, run)


# 7: from case 1's end (Frigate pressed on the idle Gunship): away, along the contact,
# then back into it.
func _case_redirect() -> void:
	var label := "7 redirect while touching"
	var loco := _loco("Frigate")
	for variant: Array in [["away", Vector2(115, 40)], ["along the contact", Vector2(140, 5.0)], ["back into the Gunship", Vector2(115, -40)]]:
		var sub: String = "%s %s" % [label, variant[0]]
		_setup({"Frigate": Vector2(115, 30), "Gunship": Vector2(115, 0)}, {"Frigate": Vector2(115, -30)})
		loco.move_to(Vector2(115, -30))
		_fly(sub + " (approach)", ["Frigate"], 12.0, SHIPS)
		var velocity_before: Vector2 = loco.velocity
		var turn_before: float = loco.angular_velocity
		loco.move_to(variant[1])
		_check(sub, "MOVE keeps velocity and turn rate", loco.velocity == velocity_before and loco.angular_velocity == turn_before)
		var run := _fly(sub, ["Frigate"], 6.0, SHIPS)
		_report(sub, run)
		if variant[0] == "back into the Gunship":
			var gap := _gap("Frigate", "Gunship")
			_check(sub, "blocked again touching (gap %.4f u)" % gap, gap >= -TOLERANCE and gap <= _collision.contact_skin + 0.001)
		else:
			_check(sub, "leaves the contact (gap %.2f u)" % _gap("Frigate", "Gunship"), _gap("Frigate", "Gunship") > 1.0)


# 8: ships placed overlapping by 2 u: never deeper, no snapping, apart only by moving away.
func _case_overlap() -> void:
	var starts := {"Frigate": Vector2(115, 3), "Gunship": Vector2(115, 0)}
	for variant: Array in [["Frigate into the Gunship", {"Frigate": Vector2(115, -30)}], ["Frigate away", {"Frigate": Vector2(115, 30)}],
			["both into each other", {"Frigate": Vector2(115, -30), "Gunship": Vector2(115, 30)}]]:
		var label: String = "8 starting overlapped, " + variant[0]
		var orders: Dictionary = variant[1]
		_setup(starts, orders)
		for ship_name in orders:
			_loco(ship_name).move_to(orders[ship_name])
		var start_gap := _gap("Frigate", "Gunship")
		var run := _fly(label, orders.keys(), 10.0, SHIPS)
		_report(label, run)
		var gap := _gap("Frigate", "Gunship")
		if variant[0] == "Frigate away":
			_check(label, "separates by moving away (gap %.2f -> %.2f u)" % [start_gap, gap], gap > 0.0)
		else:
			_check(label, "overlap kept, not snapped apart (gap %.4f -> %.4f u)" % [start_gap, gap], absf(gap - start_gap) < 0.001)


# Observation (reported, not judged): routed orders with avoidance on where the
# Gunship's destination lies on the Frigate's route; avoidance does not keep them apart.
func _observe_occupied_destination() -> void:
	var label := "observation: destination on another's route"
	var starts := {"Frigate": Vector2(-50, 62), "Gunship": Vector2(-30, 105), "Destroyer": Vector2(60, 100)}
	var targets := {"Frigate": Vector2(50, 62), "Gunship": Vector2(30, 60), "Destroyer": Vector2(-45, 105)}
	_setup(starts, targets)
	for ship_name in SHIPS:
		_node(ship_name, "RouteFollower").order(targets[ship_name])
	var gap := INF
	var first := -1.0
	for i in 60 * 60:
		_tick(SHIPS, true)
		gap = minf(gap, _gap("Frigate", "Gunship"))
		if first < 0.0 and not _loco("Frigate").contacts.is_empty():
			first = (i + 1) * DT
	var states := []
	for ship_name in ["Frigate", "Gunship"]:
		var loco := _loco(ship_name)
		var avoidance := _node(ship_name, "Avoidance")
		states.append("%s %s at (%.2f, %.2f) %.2f u/s, avoidance %s, blocked %.1f s" % [ship_name, "arrived" if loco.arrived else "NOT arrived",
			loco.planar_position.x, loco.planar_position.y, loco.velocity.length(), avoidance.State.keys()[avoidance.state], loco.blocked_time])
	print("  %s: first contact %.2f s, min Frigate-Gunship gap %.4f u after 60 s; %s" % [label, first, gap, "; ".join(states)])


# Places named ships at rest (others parked far away), heading toward their targets.
func _setup(starts: Dictionary, targets: Dictionary) -> void:
	var parking := 0
	for ship_name in SHIPS:
		var point: Vector2
		var heading := 0.0
		if starts.has(ship_name):
			point = starts[ship_name]
			if targets.has(ship_name):
				var travel: Vector2 = targets[ship_name] - point
				heading = atan2(-travel.x, -travel.y)
		else:
			point = PARKING[parking]
			parking += 1
		_loco(ship_name).place(point, heading)
		var follower := _node(ship_name, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_node(ship_name, "Avoidance").reset()


# One tick: RouteFollowers (and Avoidance if on), then Locomotions in `order`.
func _tick(order: Array, avoidance := false) -> void:
	for ship_name in SHIPS:
		_node(ship_name, "RouteFollower")._physics_process(DT)
		if avoidance:
			_node(ship_name, "Avoidance")._physics_process(DT)
	for ship_name in order:
		_loco(ship_name)._step(DT)


# Flies `seconds` with the per-tick checks; returns the run's record.
func _fly(label: String, movers: Array, seconds: float, order: Array, per_tick := Callable()) -> Dictionary:
	var errors: Array[String] = []
	var record := {"contacts": {}, "blocked": {}, "limit": {}, "reversals": {}, "displacement": {}, "final": {}, "speed": {},
		"min_gap": INF, "late_move": 0.0, "ellipse_skipped": 0}
	var orders := {}
	var previous_motion := {}
	var gaps := _pair_gaps()
	var obstacle_gaps := {}
	for ship_name in SHIPS:
		orders[ship_name] = _loco(ship_name).destination
		record.displacement[ship_name] = 0.0
		record.reversals[ship_name] = 0
		obstacle_gaps[ship_name] = _obstacle_gap(ship_name)
	var ticks := int(round(seconds / DT))
	for i in ticks:
		var before := {}
		for ship_name in SHIPS:
			var loco := _loco(ship_name)
			before[ship_name] = [loco.planar_position, loco.velocity, loco.angular_velocity, loco.heading, loco.arrived]
		_tick(order)
		if per_tick.is_valid():
			per_tick.call()
		var t := (i + 1) * DT
		for ship_name in SHIPS:
			_check_ship(ship_name, before[ship_name], movers.has(ship_name), orders[ship_name], t, record, previous_motion, errors, i >= ticks - 120)
		var now := _pair_gaps()
		for pair: String in now:
			record.min_gap = minf(record.min_gap, now[pair])
			if gaps[pair] >= -TOLERANCE and now[pair] < -TOLERANCE:
				errors.append("PENETRATION %s %.6f u at %.2f s" % [pair, now[pair], t])
			elif gaps[pair] < -TOLERANCE and now[pair] < gaps[pair] - TOLERANCE:
				errors.append("DEEPER OVERLAP %s %.6f -> %.6f u at %.2f s" % [pair, gaps[pair], now[pair], t])
			gaps[pair] = now[pair]
		for ship_name in SHIPS:
			var gap := _obstacle_gap(ship_name)
			if obstacle_gaps[ship_name] >= -TOLERANCE and gap < -TOLERANCE:
				errors.append("OBSTACLE PENETRATION %s %.6f u at %.2f s" % [ship_name, gap, t])
			obstacle_gaps[ship_name] = gap
	for ship_name in SHIPS:
		var loco := _loco(ship_name)
		record.contacts[ship_name] = loco.collision_count
		record.blocked[ship_name] = loco.blocked_time
		record.limit[ship_name] = loco.contact_limit_count
		record.final[ship_name] = loco.planar_position
		record.speed[ship_name] = loco.velocity.length()
	_check(label, "no new penetration or deeper overlap, motion and velocity invariants, order kept", errors.is_empty(), ", ".join(errors.slice(0, 3)))
	return record


func _check_ship(ship_name: String, before: Array, mover: bool, destination: Vector2, t: float, record: Dictionary,
		previous_motion: Dictionary, errors: Array[String], late: bool) -> void:
	var loco := _loco(ship_name)
	var moved: Vector2 = loco.planar_position - before[0]
	record.displacement[ship_name] += moved.length()
	if late:
		record.late_move = maxf(record.late_move, moved.length())
	if (moved - loco.committed_motion).length() > TOLERANCE:
		errors.append("%s position change differs from committed motion at %.2f s" % [ship_name, t])
	if loco.committed_motion.length() > loco.proposed_motion.length() + TOLERANCE:
		errors.append("%s committed longer than proposed at %.2f s" % [ship_name, t])
	if loco.velocity.length() > loco.proposed_motion.length() / DT + TOLERANCE:
		errors.append("%s velocity faster than requested at %.2f s" % [ship_name, t])
	for contact: Dictionary in loco.contacts:
		var normal: Vector2 = contact.normal
		if absf(normal.length() - 1.0) > TOLERANCE:
			errors.append("%s contact normal not unit at %.2f s" % [ship_name, t])
		if contact.gap >= 0.0 and (loco.planar_position - contact.point).dot(normal) < -TOLERANCE:
			errors.append("%s contact normal points into the ship at %.2f s" % [ship_name, t])
		if loco.velocity.dot(normal) < -TOLERANCE:
			errors.append("%s velocity into a contact at %.2f s" % [ship_name, t])
		if not contact.swept and loco.committed_motion.dot(normal) < -TOLERANCE:
			errors.append("%s moved into an existing contact at %.2f s" % [ship_name, t])
	if loco.contacts.is_empty():
		var dv: Vector2 = loco.velocity - before[1]
		if not (loco.arrived and not before[4]) and _ellipse_size(loco, dv / DT, before[3]) > 1.0 + SLACK:
			errors.append("%s acceleration limit at %.2f s" % [ship_name, t])
	else:
		record.ellipse_skipped += 1
		if previous_motion.has(ship_name) and (previous_motion[ship_name] as Vector2).length() > TOLERANCE \
			and loco.committed_motion.length() > TOLERANCE and (previous_motion[ship_name] as Vector2).dot(loco.committed_motion) < 0.0:
			record.reversals[ship_name] += 1
	previous_motion[ship_name] = loco.committed_motion
	if absf(loco.angular_velocity) > deg_to_rad(loco.max_turn_rate_deg) * (1.0 + SLACK) \
		or absf(loco.angular_velocity - before[2]) > deg_to_rad(loco.turn_accel_deg) * DT * (1.0 + SLACK):
		errors.append("%s turn limit at %.2f s" % [ship_name, t])
	if mover and not loco.arrived and (not loco.has_destination or loco.destination != destination):
		errors.append("%s order lost at %.2f s" % [ship_name, t])
	if not mover and loco.planar_position != before[0]:
		errors.append("%s (not ordered) moved at %.2f s" % [ship_name, t])
	_costs.append(loco.collision_usec)
	if not loco.contacts.is_empty():
		_contact_costs.append(loco.collision_usec)


# Runs the same case again with the Locomotions stepped in reverse scene order and
# reports the differences.
func _replay(label: String, setup: Callable, movers: Array, seconds: float, first: Dictionary) -> Dictionary:
	setup.call()
	var reversed_order := SHIPS.duplicate()
	reversed_order.reverse()
	var run := _fly(label + " (reverse order)", movers, seconds, reversed_order)
	var worst := 0.0
	var parts := []
	for ship_name in movers:
		var shift: float = (run.final[ship_name] as Vector2).distance_to(first.final[ship_name])
		worst = maxf(worst, shift)
		parts.append("%s final %.4f u apart, contacts %d/%d, displacement %.3f/%.3f u" % [ship_name, shift,
			first.contacts[ship_name], run.contacts[ship_name], first.displacement[ship_name], run.displacement[ship_name]])
	print("    reverse order: " + "; ".join(parts))
	return run


func _report(label: String, run: Dictionary) -> void:
	var parts := []
	for ship_name in SHIPS:
		var final: Vector2 = run.final[ship_name]
		if final in PARKING:
			continue
		parts.append("%s at (%.3f, %.3f) %.3f u/s, contacts %d, blocked %.2f s, limit %d, reversals %d" % [ship_name, final.x, final.y,
			run.speed[ship_name], run.contacts[ship_name], run.blocked[ship_name], run.limit[ship_name], run.reversals[ship_name]])
	print("    %s: min gap %.4f u; %s" % [label, run.min_gap, "; ".join(parts)])


func _normal_toward(ship_name: String, direction: Vector2) -> bool:
	var contacts: Array = _loco(ship_name).contacts
	return not contacts.is_empty() and (contacts[0].normal as Vector2).dot(direction.normalized()) > 0.99


# Footprint gaps of every ship pair ("A-B" -> u).
func _pair_gaps() -> Dictionary:
	var gaps := {}
	for i in SHIPS.size():
		for j in range(i + 1, SHIPS.size()):
			gaps[SHIPS[i] + "-" + SHIPS[j]] = _gap(SHIPS[i], SHIPS[j])
	return gaps


func _gap(a: String, b: String) -> float:
	return _loco(a).planar_position.distance_to(_loco(b).planar_position) - _radius(a) - _radius(b)


func _obstacle_gap(ship_name: String) -> float:
	return _surface_distance(_loco(ship_name).planar_position) - _radius(ship_name)


func _radius(ship_name: String) -> float:
	return _node(ship_name, "RouteFollower").ship_radius


func _loco(ship_name: String) -> Node:
	return _node(ship_name, "Locomotion")


func _node(ship_name: String, child: String) -> Node:
	return _lab.get_node("Ships/%s/%s" % [ship_name, child])


func _check(label: String, what: String, ok: bool, detail := "") -> void:
	if not ok:
		_failures += 1
	print("  %-40s %-78s %s" % [label.left(40), what, "PASS" if ok else "FAIL" + (": " + detail if detail != "" else "")])


static func _mean(values: Array[int]) -> float:
	var total := 0
	for value in values:
		total += value
	return float(total) / maxf(1.0, values.size())


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


# Distance from a point to the nearest obstacle surface (negative inside).
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
