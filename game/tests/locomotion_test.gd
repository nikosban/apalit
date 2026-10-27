extends SceneTree
## Headless Stage 2 locomotion checks, using the ship profiles from movement_test.tscn.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/locomotion_test.gd
## Optional: -- --locomotion=<script path> runs the same scenarios with another
## locomotion script (before/after comparisons).
## Technical rules are PASS/FAIL; movement behaviour is reported only:
##   angle = peak angle between heading and actual velocity (speed >= 0.5 u/s),
##   drift = seconds with |lateral velocity| > 20% of max_speed.

const DEFAULT_LOCOMOTION := "res://game/locomotion/ship_locomotion.gd"
const LAB := preload("res://game/scenes/movement_test.tscn")
const DT := 1.0 / 60.0
const TIME_LIMIT := 180.0 # s per scenario
const SLACK := 1.0e-4 # relative slack on limit checks
const HOVER_HEIGHT := 1.5
const ANGLE_MIN_SPEED := 0.5 # u/s
const DRIFT_SHARE := 0.2 # of max_speed
const SHIPS := ["Miner", "Transporter", "FF01"]
const PROFILE := ["max_speed", "max_reverse_speed", "max_lateral_speed", "forward_accel", "reverse_accel",
	"lateral_accel", "max_turn_rate_deg", "turn_accel_deg"]
# Ship starts at the origin facing -Z. "redirect" is relative to the position at the trigger.
const SCENARIOS := [
	{"name": "straight 60 u", "target": Vector2(0, -60)},
	{"name": "sideways 60 u", "target": Vector2(60, 0)},
	{"name": "90 deg at speed", "target": Vector2(0, -300), "when": "speed", "redirect": Vector2(40, 0)},
	{"name": "180 deg at speed", "target": Vector2(0, -300), "when": "speed", "redirect": Vector2(0, 40)},
	{"name": "redirect braking", "target": Vector2(0, -40), "when": "braking", "redirect": Vector2(15, -25)},
	{"name": "1 u forward", "target": Vector2(0, -1)},
	{"name": "5 u forward", "target": Vector2(0, -5)},
	{"name": "1 u sideways", "target": Vector2(1, 0)},
	{"name": "5 u sideways", "target": Vector2(5, 0)},
	{"name": "1 u behind", "target": Vector2(0, 1)},
	{"name": "5 u behind", "target": Vector2(0, 5)},
]

var _failures := 0
var _script: GDScript
var _mode_names: Array
var _arrive_speed: float


func _initialize() -> void:
	await process_frame # The root is not inside the tree during _initialize().
	var path := DEFAULT_LOCOMOTION
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--locomotion="):
			path = argument.trim_prefix("--locomotion=")
	_script = load(path)
	var constants := _script.get_script_constant_map()
	_mode_names = (constants.HeadingMode as Dictionary).keys()
	_arrive_speed = constants.ARRIVE_SPEED
	var lab := LAB.instantiate()
	print("locomotion: ", path)
	print("ship       scenario          mode   time s  final err  overshoot  angle deg  drift s  max lat  rotation deg  checks")
	for ship_name in SHIPS:
		var source := lab.get_node("Ships/%s/Locomotion" % ship_name)
		for scenario in SCENARIOS:
			_run(ship_name, source, scenario)
	lab.free()
	print("RESULT: %s (%d technical failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


func _run(ship_name: String, source: Node, scenario: Dictionary) -> void:
	var ship := Node3D.new()
	ship.position = Vector3(0.0, HOVER_HEIGHT, 0.0)
	var loco: Node = _script.new()
	for property in PROFILE:
		if property in loco:
			loco.set(property, source.get(property))
	ship.add_child(loco)
	root.add_child(ship)
	loco.set_physics_process(false)

	var max_rate := deg_to_rad(loco.max_turn_rate_deg)
	var turn_accel := deg_to_rad(loco.turn_accel_deg)
	var errors: Array[String] = []
	var destination: Vector2 = scenario.target
	loco.move_to(destination)
	var redirected := not scenario.has("redirect")
	var approach := destination.normalized()
	var command_time := 0.0
	var t := 0.0
	var previous_speed := 0.0
	var overshoot := 0.0
	var max_lateral := 0.0
	var peak_angle := 0.0
	var drift_time := 0.0
	var rotation := 0.0
	var mode: String = _mode_names[loco.heading_mode]

	while t < TIME_LIMIT:
		if not redirected and _triggered(loco, scenario.when, previous_speed):
			var velocity_before: Vector2 = loco.velocity
			var angular_before: float = loco.angular_velocity
			destination = loco.planar_position + scenario.redirect
			loco.move_to(destination)
			if loco.velocity != velocity_before or loco.angular_velocity != angular_before:
				errors.append("momentum not preserved on redirect")
			approach = (destination - loco.planar_position).normalized()
			mode = _mode_names[loco.heading_mode]
			command_time = t
			redirected = true
		previous_speed = loco.velocity.length()

		var v0: Vector2 = loco.velocity
		var w0: float = loco.angular_velocity
		var h0: float = loco.heading
		var was_arrived: bool = loco.arrived
		loco._step(DT)
		t += DT

		var dv: Vector2 = loco.velocity - v0
		if loco.arrived and not was_arrived:
			# Arrival settling exception: velocity zeroed; the jump must stay within
			# the arrival speed plus one tick of maximum acceleration.
			if dv.length() > _arrive_speed + loco.forward_accel * DT:
				errors.append("settle jump %.4f u/s" % dv.length())
		elif _ellipse_size(loco, dv / DT, h0) > 1.0 + SLACK:
			errors.append("acceleration limit exceeded at %.2f s" % t)
		if absf(loco.angular_velocity) > max_rate * (1.0 + SLACK):
			errors.append("turn rate limit exceeded at %.2f s" % t)
		if absf(loco.angular_velocity - w0) > turn_accel * DT * (1.0 + SLACK):
			errors.append("turn acceleration limit exceeded at %.2f s" % t)
		if not is_equal_approx(ship.global_position.y, HOVER_HEIGHT):
			errors.append("Y changed at %.2f s" % t)
		if not (loco.planar_position.is_finite() and loco.velocity.is_finite() and is_finite(loco.heading) and is_finite(loco.angular_velocity)):
			errors.append("non-finite state at %.2f s" % t)
			break

		rotation += absf(wrapf(loco.heading - h0, -PI, PI))
		var local: Vector2 = loco.local_velocity()
		max_lateral = maxf(max_lateral, absf(local.y))
		if loco.velocity.length() >= ANGLE_MIN_SPEED:
			peak_angle = maxf(peak_angle, absf(local.angle()))
		if absf(local.y) > DRIFT_SHARE * loco.max_speed:
			drift_time += DT
		if redirected:
			overshoot = maxf(overshoot, (loco.planar_position - destination).dot(approach))
			if loco.arrived:
				break

	if not loco.arrived:
		errors.append("no arrival within %.0f s" % TIME_LIMIT)
	_failures += errors.size()
	var checks := "PASS" if errors.is_empty() else "FAIL: " + ", ".join(errors.slice(0, 3)) + (" (+%d)" % (errors.size() - 3) if errors.size() > 3 else "")
	print("%-10s %-17s %-5s %7.2f  %9.4f  %9.4f  %9.1f  %7.2f  %7.2f  %12.1f  %s" % [
		ship_name, scenario.name, mode, t - command_time, loco.distance_to_destination(), overshoot,
		rad_to_deg(peak_angle), drift_time, max_lateral, rad_to_deg(rotation), checks])
	ship.free()


func _triggered(loco: Node, when: String, previous_speed: float) -> bool:
	var speed: float = loco.velocity.length()
	if when == "speed":
		return speed >= 0.8 * loco.max_speed
	return speed > 0.2 * loco.max_speed and speed < previous_speed - 1.0e-6 # braking


# Size of an acceleration relative to the limit ellipse in the frame of heading h (1 = on the limit).
func _ellipse_size(loco: Node, accel: Vector2, h: float) -> float:
	var forward := Vector2(-sin(h), -cos(h))
	var right := Vector2(cos(h), -sin(h))
	var f := accel.dot(forward)
	var l := accel.dot(right)
	var axis_limit: float = loco.forward_accel if f >= 0.0 else loco.reverse_accel
	return sqrt(pow(f / axis_limit, 2) + pow(l / loco.lateral_accel, 2))
