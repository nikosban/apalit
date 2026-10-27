extends SceneTree
## Headless checks of Locomotion's guided mode (Phase 2.5 station-controlled docking,
## stage 1: the mode exists but nothing in the game uses it yet) on the test arena.
## Ships are stepped at 60 Hz in the game's order (per ship RouteFollower then
## Avoidance, then Locomotion). Every check is PASS/FAIL.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/guided_locomotion_test.gd
## Check 10 calls move_to() during guidance on purpose: one "ignored during guided
## movement" error line on stderr is expected.

const LAB := preload("res://game/scenes/movement_test.tscn")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Miner", "Transporter", "FF01"]
const PARK := {"Miner": Vector2(-135, 135), "Transporter": Vector2(-135, -135), "FF01": Vector2(-135, 0)}
const OPEN := Vector2(40, 100) # Open arena space, clear of the test obstacles.
const SPEED := 1.5 # Station limits used throughout (the prototype's).
const ACCEL := 1.0
const TURN_RATE := 30.0
const TURN_ACCEL := 30.0
const SLACK := 1.0001

var _lab: Node
var _failures := 0
var _checks := 0


func _initialize() -> void:
	await process_frame
	_lab = LAB.instantiate()
	root.add_child(_lab)
	for s in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance"]:
			_n(s, child).set_physics_process(false)
	for s in SHIPS:
		while not _lab.get_node("StaticNavigation").is_ready(_n(s, "RouteFollower").planning_radius()):
			await physics_frame
	_test_default()
	_test_turns()
	_test_moves()
	_test_authority()
	_test_collision()
	_test_propulsion()
	_test_place()
	_test_order_guard()
	_test_remaining_points()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# 1. Off by default.
func _test_default() -> void:
	_reset()
	var off := true
	for s in SHIPS:
		off = off and not _lo(s).guided and _lo(s).guided_order_errors == 0 and _lo(s).remaining_points() == PackedVector2Array([_lo(s).planar_position])
	_n("Miner", "RouteFollower").order(OPEN + Vector2(0, -20))
	_steps(1)
	_check("1. not guided by default; an ordinary order still gives a destination and moves the ship", off and _lo("Miner").has_destination
		and _lo("Miner").velocity.length() > 0.0)


# 2 and 4. Turn in place: within the capped turn rate and turn acceleration, no overshoot, ends at rest.
func _test_turns() -> void:
	var rows: Array[String] = []
	var ok := true
	for s in SHIPS:
		_reset()
		_place(s, OPEN, 0.0)
		var lo := _lo(s)
		var target := deg_to_rad(150.0)
		lo.guide([{"turn": target}], SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
		var rate_cap := minf(TURN_RATE, lo.max_turn_rate_deg)
		var accel_cap := minf(TURN_ACCEL, lo.turn_accel_deg)
		var max_rate := 0.0
		var max_accel := 0.0
		var flipped := false
		var moved := false
		var before := lo.angular_velocity
		var ticks := 0
		while lo.guided and ticks < 60 * 30:
			_steps(1)
			ticks += 1
			max_rate = maxf(max_rate, absf(rad_to_deg(lo.angular_velocity)))
			max_accel = maxf(max_accel, absf(rad_to_deg(lo.angular_velocity - before)) / DT)
			before = lo.angular_velocity
			flipped = flipped or wrapf(target - lo.heading, -PI, PI) < -0.0001
			moved = moved or lo.planar_position.distance_to(OPEN) > 0.000001
		var error := absf(wrapf(target - lo.heading, -PI, PI))
		var row_ok := not lo.guided and error < 0.0001 and lo.angular_velocity == 0.0 and max_rate <= rate_cap * SLACK and max_accel <= accel_cap * SLACK \
			and not flipped and not moved
		ok = ok and row_ok
		rows.append("%s %.1f s, rate %.1f/%.0f °/s, accel %.1f/%.0f °/s²" % [s, ticks * DT, max_rate, rate_cap, max_accel, accel_cap])
	_check("2, 4. turn 150° in place: exact final heading, at rest, no overshoot, no translation, rate and acceleration within the station limits capped by the ship's own (%s)" % "; ".join(rows), ok)


# 3. Straight moves forward and in reverse with the heading held.
func _test_moves() -> void:
	var rows: Array[String] = []
	var ok := true
	for s in SHIPS:
		for reverse in [false, true]:
			_reset()
			_place(s, OPEN, 0.0)
			var lo := _lo(s)
			var length := 3.0 if reverse else 12.0
			var target := OPEN + (Vector2(0, length) if reverse else Vector2(0, -length)) # Bow is -Z: forward is -Y on the plane.
			lo.guide([{"move": target, "reverse": reverse}], SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
			var top := minf(SPEED, lo.max_reverse_speed if reverse else lo.max_speed)
			var speed_up := minf(ACCEL, lo.reverse_accel if reverse else lo.forward_accel)
			var slow_down := minf(ACCEL, lo.forward_accel if reverse else lo.reverse_accel)
			var max_speed := 0.0
			var accel_ok := true
			var closer := true
			var heading_held := true
			var previous := 0.0
			var distance := OPEN.distance_to(target)
			var ticks := 0
			while lo.guided and ticks < 60 * 60:
				_steps(1)
				ticks += 1
				var speed := lo.velocity.length()
				max_speed = maxf(max_speed, speed)
				var change := (speed - previous) / DT
				accel_ok = accel_ok and (change <= speed_up * SLACK + 0.000001) and (-change <= slow_down * SLACK + 0.000001)
				previous = speed
				var now := lo.planar_position.distance_to(target)
				closer = closer and now <= distance + 0.000001
				distance = now
				heading_held = heading_held and absf(lo.heading) < 0.000001
			var row_ok := not lo.guided and distance < 0.001 and lo.velocity == Vector2.ZERO and max_speed <= top * SLACK and accel_ok and closer and heading_held
			ok = ok and row_ok
			rows.append("%s %s %.1f s top %.2f/%.2f" % [s, "back" if reverse else "fwd", ticks * DT, max_speed, top])
	_check("3. straight moves (12 u forward, 3 u reverse): arrive within 0.001 u at rest, never farther from the point, heading unchanged, speed and acceleration within the capped limits (%s)" % "; ".join(rows), ok)


# 5 and 6. A stale ordinary order, RouteFollower and avoidance (also another ship
# passing close, and avoid() input given directly) change nothing of the guided
# trajectory; the stale order does not resume when guidance ends.
func _test_authority() -> void:
	var legs := [{"turn": deg_to_rad(-90.0)}, {"move": OPEN + Vector2(10, 0), "reverse": false}] # Turn to face +X, then 10 u along +X.
	_reset()
	_place("Miner", OPEN, 0.0)
	_lo("Miner").guide(legs, SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
	var reference := _fly("Miner", false)
	_reset()
	_place("Miner", OPEN, 0.0)
	_place("Transporter", OPEN + Vector2(5, 14), 0.0) # Passes across the guided path toward -Z.
	_n("Transporter", "RouteFollower").order(OPEN + Vector2(5, -30))
	_n("Miner", "RouteFollower").order(OPEN + Vector2(-30, -30)) # Stale intent, given the same tick.
	var status: int = _n("Miner", "RouteFollower").status
	_lo("Miner").guide(legs, SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
	var disturbed := _fly("Miner", true)
	var same: bool = reference.trace.size() == disturbed.trace.size()
	for i in mini(reference.trace.size(), disturbed.trace.size()):
		same = same and reference.trace[i].is_equal_approx(disturbed.trace[i])
	_check("5. a same-tick ordinary order (RouteFollower status %s), a ship passing within %.1f u and direct avoid() input leave the guided trajectory identical tick by tick (%d ticks); no effective steering (Locomotion steering off, own avoidance neutral)" % [
		_n("Miner", "RouteFollower").RouteStatus.keys()[status], disturbed.closest, reference.ticks], same and disturbed.neutral and disturbed.closest < 6.0)
	var at := _lo("Miner").planar_position
	var heading := _lo("Miner").heading
	var still := true
	for i in 600:
		_steps(1)
		still = still and _lo("Miner").planar_position.distance_to(at) < 0.000001 and absf(_lo("Miner").heading - heading) < 0.000001 \
			and not _lo("Miner").has_destination
	_check("6. after guidance: the stale order does not resume, no movement or rotation for 10 s (also: heading target was the old order's bearing)", still)


func _fly(s: String, disturb: bool) -> Dictionary:
	var trace: Array[Vector3] = []
	var neutral := true
	var closest := INF
	while _lo(s).guided and trace.size() < 60 * 60:
		if disturb:
			for ship in SHIPS:
				_n(ship, "RouteFollower")._physics_process(DT)
				_n(ship, "Avoidance")._physics_process(DT)
			_lo(s).avoid(Vector2(3, 3), 0.1) # Direct avoidance input: must be ignored.
			for ship in SHIPS:
				_lo(ship)._step(DT)
			var avoidance := _n(s, "Avoidance")
			neutral = neutral and not _lo(s)._steering and not _lo(s).has_destination and avoidance.offset == Vector2.ZERO and avoidance.speed_cap == INF
			closest = minf(closest, _lo(s).planar_position.distance_to(_lo("Transporter").planar_position) - 1.6 - 3.4)
		else:
			_steps(1)
		trace.append(Vector3(_lo(s).planar_position.x, _lo(s).planar_position.y, _lo(s).heading))
	return {"trace": trace, "ticks": trace.size(), "neutral": neutral, "closest": closest}


# 7. Collision enforcement still applies to guided motion; nothing recovers.
func _test_collision() -> void:
	_reset()
	_place("Miner", OPEN, 0.0)
	_place("Transporter", OPEN + Vector2(0, -8), 0.0) # On the guided path (circles touch at 5.0 u).
	_lo("Miner").guide([{"move": OPEN + Vector2(0, -12), "reverse": false}], SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
	var closest := INF
	for i in 60 * 20:
		_steps(1)
		closest = minf(closest, _lo("Miner").planar_position.distance_to(_lo("Transporter").planar_position))
	_check("7. guided move toward a parked ship: stops at the contact (closest centres %.3f u, contact at 5.0), never inside, %d contact(s), leg not completed (no recovery)" % [closest, _lo("Miner").collision_count],
		closest >= 5.0 - 0.001 and _lo("Miner").collision_count >= 1 and _lo("Miner").guided)


# 8. Without propulsion the guided ship holds still; it goes on once restored; the
# committed motion (what Fuel charges) is exactly the guided travel.
func _test_propulsion() -> void:
	_reset()
	_place("Miner", OPEN, 0.0)
	var lo := _lo("Miner")
	var target := OPEN + Vector2(0, -12)
	lo.guide([{"move": target, "reverse": false}], SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
	var travelled := 0.0
	var committed_ok := true
	var previous := lo.planar_position
	_steps(120)
	travelled += lo.planar_position.distance_to(OPEN)
	previous = lo.planar_position
	lo.propulsion = false
	var held := true
	for i in 60:
		_steps(1)
		held = held and lo.planar_position == previous and lo.velocity == Vector2.ZERO and lo.angular_velocity == 0.0 and lo.committed_motion == Vector2.ZERO
	lo.propulsion = true
	var accel_ok := true
	var speed := 0.0
	while lo.guided:
		_steps(1)
		committed_ok = committed_ok and lo.committed_motion.is_equal_approx(lo.planar_position - previous) \
			and lo.committed_motion.is_equal_approx(lo.desired_velocity * DT)
		travelled += lo.committed_motion.length()
		accel_ok = accel_ok and absf(lo.velocity.length() - speed) / DT <= ACCEL * SLACK + 0.000001
		speed = lo.velocity.length()
		previous = lo.planar_position
	_check("8. propulsion off mid-leg: no translation, rotation or committed motion; restored: resumes within the acceleration limit and arrives; committed motion = guided travel (%.4f of 12 u)" % travelled,
		held and committed_ok and accel_ok and lo.planar_position.distance_to(target) < 0.001 and absf(travelled - 12.0) < 0.001)


# 9. place() cancels guidance.
func _test_place() -> void:
	_reset()
	_place("Miner", OPEN, 0.0)
	_lo("Miner").guide([{"move": OPEN + Vector2(0, -12), "reverse": false}], SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
	_steps(30)
	_place("Miner", OPEN, 0.0)
	_steps(30)
	_check("9. place() cancels guidance (not guided, no legs, stays put)", not _lo("Miner").guided and _lo("Miner").remaining_points().size() == 1
		and _lo("Miner").planar_position == OPEN)


# 10. move_to() during guidance is refused and counted (the safety net; callers must never do it).
func _test_order_guard() -> void:
	var legs := [{"move": OPEN + Vector2(0, -12), "reverse": false}]
	_reset()
	_place("Miner", OPEN, 0.0)
	_lo("Miner").guide(legs, SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
	var reference := _fly("Miner", false)
	_reset()
	_place("Miner", OPEN, 0.0)
	_lo("Miner").guide(legs, SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
	_steps(20)
	var follower := _n("Miner", "RouteFollower")
	var before := [follower.status, follower.requested, follower.route, follower.plans]
	var taken: bool = follower.order(OPEN + Vector2(30, 0)) # Stage 2b: refused by RouteFollower itself.
	var unchanged: bool = [follower.status, follower.requested, follower.route, follower.plans] == before and follower.guided_refusals == 1
	_lo("Miner").move_to(OPEN + Vector2(30, 0)) # The Locomotion safety net, reached directly.
	var rest := _fly("Miner", false)
	var same: bool = reference.ticks == rest.ticks + 20 and reference.trace[reference.ticks - 1].is_equal_approx(rest.trace[rest.ticks - 1])
	_check("10. during guidance: RouteFollower.order() refused with its route and command state unchanged (taken: %s); a direct move_to() ignored and counted (%d); guided trajectory unchanged, no destination afterwards" % [taken, _lo("Miner").guided_order_errors],
		not taken and unchanged and _lo("Miner").guided_order_errors == 1 and same and not _lo("Miner").has_destination)


# 11. remaining_points().
func _test_remaining_points() -> void:
	_reset()
	_place("Miner", OPEN, 0.0)
	var lo := _lo("Miner")
	var a := OPEN + Vector2(0, -6)
	var b := OPEN + Vector2(0, -3)
	var before := lo.remaining_points()
	lo.guide([{"move": a, "reverse": false}, {"turn": deg_to_rad(90.0)}, {"move": b, "reverse": false}], SPEED, ACCEL, TURN_RATE, TURN_ACCEL)
	var start := lo.remaining_points()
	while lo.guided and lo.guided_leg == 0:
		_steps(1)
	var middle := lo.remaining_points()
	while lo.guided:
		_steps(1)
	var after := lo.remaining_points()
	_check("11. remaining_points(): position only when not guided, then position + the move legs still to fly", before == PackedVector2Array([OPEN])
		and start == PackedVector2Array([OPEN, a, b]) and middle.size() == 2 and middle[1] == b and after == PackedVector2Array([lo.planar_position]))


func _reset() -> void:
	for s in SHIPS:
		var follower := _n(s, "RouteFollower")
		follower.status = follower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		_n(s, "Avoidance").reset()
		_place(s, PARK[s], 0.0)
		_lo(s).propulsion = true
		_lo(s).guided_order_errors = 0
		_n(s, "RouteFollower").guided_refusals = 0
		_lo(s).collision_count = 0


func _steps(count: int) -> void:
	for i in count:
		for s in SHIPS:
			_n(s, "RouteFollower")._physics_process(DT)
			_n(s, "Avoidance")._physics_process(DT)
		for s in SHIPS:
			_lo(s)._step(DT)


func _place(s: String, point: Vector2, heading: float) -> void:
	_lo(s).place(point, heading)


func _n(s: String, child: String) -> Node:
	return _lab.get_node("Ships/%s/%s" % [s, child])


func _lo(s: String) -> ShipLocomotion:
	return _n(s, "Locomotion") as ShipLocomotion


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-150s %s" % [label, "PASS" if ok else "FAIL"])
