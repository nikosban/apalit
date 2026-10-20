extends "res://game/weapons/weapon.gd"
## Combat (migrated from the prototype): articulated turret. The base stays on the mount; YawPivot turns
## about the mount's up axis within ±yaw_limit_deg at yaw_speed_deg; PitchPivot (inside
## the yaw pivot) elevates within [pitch_min_deg, pitch_max_deg] at pitch_speed_deg (the
## limits are the hardpoint's when the turret is installed on one, v0.3). The target direction is taken from the pitch pivot in the mount's
## frame; yaw and pitch are solved and stepped independently.
##
## Yaw is a bounded range (no wrap through the rear blind zone): a target crossing
## behind makes the turret travel the long way through the front. A target outside the
## mechanical coverage is not forced: the turret holds the limit on the side it is
## already on (no swinging between the two limits) and reports the blocked arc. Without
## a target it returns to neutral (yaw 0, pitch 0). Steps never exceed speed × delta and
## stop exactly on the wanted angle (no overshoot, so no oscillation).

const WeaponGeometry := preload("res://game/weapons/weapon_geometry.gd")

@export var base_diameter := 0.5 # u
@export var body_height := 0.25 # u
@export var barrel_length := 0.65 # u

var yaw := 0.0 # rad, current
var pitch := 0.0 # rad, current
var wanted_yaw := 0.0
var wanted_pitch := 0.0
var in_coverage := true
var yaw_pivot: Node3D
var pitch_pivot: Node3D


func _build() -> void:
	var parts := WeaponGeometry.build_turret(self, base_diameter, body_height, barrel_length)
	yaw_pivot = parts.yaw
	pitch_pivot = parts.pitch
	muzzle = parts.muzzle


## Mount-frame yaw and pitch (rad) that point the barrel from the pitch pivot at `point`.
func angles_to(point: Vector3) -> Vector2:
	var local := global_basis.inverse() * (point - pitch_pivot.global_position)
	var horizontal := Vector2(local.x, local.z).length()
	return Vector2(atan2(-local.x, -local.z), atan2(local.y, horizontal))


func _track(delta: float, target: Node3D) -> void:
	var limit := deg_to_rad(yaw_limit_deg())
	var low := deg_to_rad(pitch_min_deg())
	var high := deg_to_rad(pitch_max_deg())
	if target == null:
		wanted_yaw = 0.0
		wanted_pitch = 0.0
		in_coverage = true
		tracking = "Neutral" if is_zero_approx(yaw) and is_zero_approx(pitch) else "Returning to neutral"
	else:
		var angles := angles_to(aim_point if has_solution else target.global_position)
		var yaw_ok := absf(angles.x) <= limit
		var pitch_ok := angles.y >= low and angles.y <= high
		in_coverage = yaw_ok and pitch_ok
		if yaw_ok:
			wanted_yaw = angles.x
		else:
			var side := signf(yaw) if absf(yaw) > 0.000001 else signf(angles.x)
			wanted_yaw = side * limit
		wanted_pitch = clampf(angles.y, low, high)
		tracking = "Tracking" if in_coverage else "Holding at limit (blocked arc)"
	yaw += clampf(wanted_yaw - yaw, -deg_to_rad(config.yaw_speed_deg) * delta, deg_to_rad(config.yaw_speed_deg) * delta)
	pitch += clampf(wanted_pitch - pitch, -deg_to_rad(config.pitch_speed_deg) * delta, deg_to_rad(config.pitch_speed_deg) * delta)
	yaw = clampf(yaw, -limit, limit)
	pitch = clampf(pitch, low, high)
	yaw_pivot.rotation = Vector3(0.0, yaw, 0.0)
	pitch_pivot.rotation = Vector3(pitch, 0.0, 0.0)
	if target != null and in_coverage and absf(wanted_yaw - yaw) < 0.0001 and absf(wanted_pitch - pitch) < 0.0001:
		tracking = "On target"


func _in_coverage(_aim: Vector3) -> bool:
	return in_coverage


## v0.4 (read-only): `aim` within the traverse and elevation limits.
func _covers(aim: Vector3) -> bool:
	var angles := angles_to(aim)
	return absf(angles.x) <= deg_to_rad(yaw_limit_deg()) and angles.y >= deg_to_rad(pitch_min_deg()) and angles.y <= deg_to_rad(pitch_max_deg())


func _coverage_reason() -> String:
	return "Outside turret coverage (yaw ±%.0f°, pitch %.0f° to %.0f°)" % [yaw_limit_deg(), pitch_min_deg(), pitch_max_deg()]


func _alignment_reason(error: float) -> String:
	return "Tracking (%.1f° off)" % error
