extends SceneTree
## Combat prototype v0.2, T06 (pitch half) on the isolated turret_pitch_range.tscn: one
## turret on a static platform, one target dummy placed or flown at other elevations
## (planar ship combat is not involved). Run with a fixed physics step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/turret_pitch_test.gd
## Expected angles are computed here from the pitch pivot's world position, independently
## of the turret code. Every shot is checked: from the muzzle, along the barrel, aligned
## within tolerance, inside the mechanical limits.

const RANGE := preload("res://game/tests/combat/fixtures/turret_pitch_range.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const DT := 1.0 / 60.0
const DISTANCE := 20.0

var _scene: Node3D
var _turret: Node3D
var _dummy: Node3D
var _checks := 0
var _failures := 0
var _shots: Array[float] = [] # times
var _bad_shots := 0
var _time := 0.0


func _initialize() -> void:
	await process_frame
	_scene = RANGE.instantiate()
	root.add_child(_scene)
	await physics_frame
	_turret = _scene.get_node("Ships/Platform/Weapons/Turret")
	_dummy = _scene.get_node("Ships/Dummy")
	CombatShip.of(_dummy).health = 1000000.0
	_turret.shot.connect(_on_shot)
	var orders = _scene.get_node("CombatOrders")
	orders.set_stance([_scene.get_node("Ships/Platform")], 2)
	orders.assign_target([_scene.get_node("Ships/Platform")], _dummy)
	await _elevations()
	await _limits()
	await _wrap()
	await _independence()
	await _sweep()
	_check("every shot from the muzzle, along the barrel, aligned and inside the limits (%d shots, %d bad)" % [_shots.size(), _bad_shots], _bad_shots == 0 and _shots.size() > 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-112s %s" % [text, "PASS" if ok else "FAIL"])


func _on_shot(weapon: Node, _id: int, _target: Node3D, origin: Transform3D) -> void:
	_shots.append(_time)
	var muzzle: Transform3D = weapon.muzzle.global_transform
	var axis := -muzzle.basis.z
	var ok := origin.origin.distance_to(muzzle.origin) < 0.0001 and (-origin.basis.z).angle_to(axis) < 0.0001
	ok = ok and rad_to_deg(axis.angle_to(weapon.aim_point - muzzle.origin)) <= weapon.config.alignment_tolerance_deg + 0.0001
	ok = ok and absf(rad_to_deg(weapon.yaw)) <= 160.0001 and rad_to_deg(weapon.pitch) >= -15.0001 and rad_to_deg(weapon.pitch) <= 75.0001
	if not ok:
		_bad_shots += 1


func _step(seconds: float) -> void:
	for i in roundi(seconds / DT):
		await physics_frame
		_time += DT


# Dummy at elevation `elevation_deg` and azimuth `azimuth_deg` (yaw convention: positive =
# left of the mount's forward −Z), DISTANCE from the pitch pivot at its neutral position.
func _put(azimuth_deg: float, elevation_deg: float) -> Vector3:
	var pivot := _neutral_pivot()
	var e := deg_to_rad(elevation_deg)
	var a := deg_to_rad(azimuth_deg)
	var point := pivot + Vector3(-sin(a) * cos(e), sin(e), -cos(a) * cos(e)) * DISTANCE
	_dummy.place(point)
	return point


func _neutral_pivot() -> Vector3:
	var mount: Node3D = _turret
	return mount.global_transform * Vector3(0, 0.08 + 0.15, 0) # pedestal + 0.6 × body height


# Independent expected angles from the current pitch pivot position.
func _expected(point: Vector3) -> Vector2:
	var local: Vector3 = _turret.global_basis.inverse() * (point - _turret.pitch_pivot.global_position)
	return Vector2(rad_to_deg(atan2(-local.x, -local.z)), rad_to_deg(atan2(local.y, Vector2(local.x, local.z).length())))


func _elevations() -> void:
	for elevation in [0.0, 30.0, 60.0, 74.0, -10.0]:
		var point := _put(0.0, elevation)
		var before := _shots.size()
		await _step(3.5)
		var steady := 0.0
		var last: float = _turret.pitch
		for i in 60:
			await _step(DT)
			steady = maxf(steady, absf(_turret.pitch - last))
			last = _turret.pitch
		var want := _expected(point)
		_check("elevation %+.0f deg: pitch %.3f deg (expected %.3f), yaw %.3f deg, '%s', %d shots" % [elevation, rad_to_deg(_turret.pitch), want.y, rad_to_deg(_turret.yaw), _turret.tracking, _shots.size() - before],
			absf(rad_to_deg(_turret.pitch) - want.y) < 0.05 and absf(rad_to_deg(_turret.yaw)) < 0.05 and _shots.size() > before)
		_check("elevation %+.0f deg: no oscillation once on target (largest pitch change over 1 s %.6f deg)" % [elevation, rad_to_deg(steady)], rad_to_deg(steady) < 0.000001)


func _limits() -> void:
	for case in [[85.0, 75.0], [-25.0, -15.0]]:
		_put(0.0, case[0])
		await _step(3.0)
		var before := _shots.size()
		await _step(2.0)
		_check("target at %+.0f deg: pitch held at its limit %.3f deg (expected %.0f), no shots, reason '%s'" % [case[0], rad_to_deg(_turret.pitch), case[1], _turret.reason],
			absf(rad_to_deg(_turret.pitch) - case[1]) < 0.0001 and _shots.size() == before and _turret.reason.begins_with("Outside turret coverage"))


func _wrap() -> void:
	_put(90.0, 10.0)
	await _step(4.0)
	_check("yaw 90 deg reached (%.2f)" % rad_to_deg(_turret.yaw), absf(rad_to_deg(_turret.yaw) - _expected(_dummy.global_position).x) < 0.05)
	_put(170.0, 10.0)
	await _step(3.0)
	_check("target in the rear blind arc (170 deg): turret holds +160 and reports it ('%s', %.2f)" % [_turret.tracking, rad_to_deg(_turret.yaw)],
		absf(rad_to_deg(_turret.yaw) - 160.0) < 0.0001 and _turret.tracking.begins_with("Holding"))
	_put(-170.0, 10.0) # crossing the wrap boundary behind the mount
	var swing := 0.0
	for i in 180:
		await _step(DT)
		swing = maxf(swing, absf(rad_to_deg(_turret.yaw) - 160.0))
	_check("crossing behind (-170 deg): no swing to the other limit (largest move %.4f deg)" % swing, swing < 0.0001)
	_put(-150.0, 10.0) # back in coverage on the other side: the long way through the front
	var monotonic := true
	var largest := 0.0
	var previous: float = _turret.yaw
	for i in 420:
		await _step(DT)
		monotonic = monotonic and _turret.yaw <= previous + 0.0000001
		largest = maxf(largest, absf(_turret.yaw - previous))
		previous = _turret.yaw
	_check("re-entering at -150 deg: yaw travelled monotonically through the front to %.2f deg" % rad_to_deg(_turret.yaw),
		monotonic and absf(rad_to_deg(_turret.yaw) - _expected(_dummy.global_position).x) < 0.05)
	_check("no snapping: largest yaw step %.4f deg <= %.4f" % [rad_to_deg(largest), 60.0 * DT], rad_to_deg(largest) <= 60.0 * DT + 0.0001)


func _independence() -> void:
	_put(40.0, 0.0)
	await _step(4.0)
	var yaw_before: float = _turret.yaw
	var yaw_drift := 0.0
	_put(40.0, 45.0) # elevation only
	for i in 180:
		await _step(DT)
		yaw_drift = maxf(yaw_drift, absf(_turret.yaw - yaw_before))
	_check("elevation-only change: yaw unchanged (largest drift %.4f deg)" % rad_to_deg(yaw_drift), rad_to_deg(yaw_drift) < 0.3)
	var pitch_before: float = _turret.pitch
	var pitch_drift := 0.0
	_put(-40.0, 45.0) # azimuth only
	for i in 180:
		await _step(DT)
		pitch_drift = maxf(pitch_drift, absf(_turret.pitch - pitch_before))
	_check("azimuth-only change: pitch held (largest drift %.4f deg, pivot offset only)" % rad_to_deg(pitch_drift), rad_to_deg(pitch_drift) < 0.5)


func _sweep() -> void:
	var pivot := _neutral_pivot()
	var points := PackedVector3Array()
	for i in 16:
		var a := TAU * i / 16.0
		var e := deg_to_rad(5.0 + 50.0 * (0.5 + 0.5 * sin(a * 2.0)))
		points.append(pivot + Vector3(-sin(a) * cos(e), sin(e), -cos(a) * cos(e)) * 18.0)
	_dummy.fly(points, 6.0)
	var before := _shots.size()
	var worst_yaw_step := 0.0
	var worst_pitch_step := 0.0
	var outside := 0
	var last := Vector2(_turret.yaw, _turret.pitch)
	for i in 2400:
		await _step(DT)
		worst_yaw_step = maxf(worst_yaw_step, absf(_turret.yaw - last.x))
		worst_pitch_step = maxf(worst_pitch_step, absf(_turret.pitch - last.y))
		last = Vector2(_turret.yaw, _turret.pitch)
		if absf(rad_to_deg(_turret.yaw)) > 160.0001 or rad_to_deg(_turret.pitch) < -15.0001 or rad_to_deg(_turret.pitch) > 75.0001:
			outside += 1
	var hits: int = _scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.outcome == "damage").size()
	_check("moving target across yaw and pitch: %d shots, %d hits; never beyond the limits (%d ticks)" % [_shots.size() - before, hits, outside],
		_shots.size() > before and hits > 0 and outside == 0)
	_check("speeds respected while tracking (yaw %.3f <= %.3f, pitch %.3f <= %.3f deg per tick)" % [rad_to_deg(worst_yaw_step), 60.0 * DT, rad_to_deg(worst_pitch_step), 40.0 * DT],
		rad_to_deg(worst_yaw_step) <= 60.0 * DT + 0.0001 and rad_to_deg(worst_pitch_step) <= 40.0 * DT + 0.0001)
