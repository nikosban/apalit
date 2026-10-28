extends "res://game/weapons/gatling.gd"
## Experiment (PDC saturation fire, not used by the game): a PDC mount that, in point
## defense, fires at a committed prediction instead of re-solving from the live threat
## every tick. Configured by a PdcSaturationConfig (pdc_saturation_config.gd).
##
## Commitment: when a threat is engaged, and again every `prediction_update_interval`,
## the mount records the threat's observed position and velocity (a dead-reckoned
## straight track) and draws one aim error within `prediction_error_degrees`. Until the
## next commitment it leads the dead-reckoned track (the shared intercept solution), not
## the threat itself, and every round carries the same error plus its own dispersion
## (`dispersion_max_deg`). Commitments follow each other directly (no firing gap); the
## turret only re-slews by the size of the correction. A threat that accelerates or turns
## leaves the committed track: the rounds go where it was predicted to be.
##
## With `committed_prediction` off (the comparison control) the mount behaves like the
## pre-raid-sweep PDC (per-tick solution, one threat until destroyed), with the same
## configuration and tracer. Extends the Gatling directly and keeps that PDC's defensive
## order below, so the production PDC (pdc.gd, raid sweep) never changes these variants.
## Engageability, alignment, magazine and interception are the Gatling's; rounds are the
## projectile system's point rounds drawn with the configuration's tracer mesh.

const MISSILE_OVERRIDE_TIME := 1.5 # s

## Off: per-tick live solution (the control), on: committed prediction.
@export var committed_prediction := true

var commits := 0 # Commitments made (debug / evaluation).
var _committed_target: Node3D = null
var _commit_age := 0.0
var _track_position := Vector3.ZERO
var _track_velocity := Vector3.ZERO
var _error_cos := 1.0
var _error_phi := 0.0


func step(delta: float) -> void:
	_commit_age += delta
	super.step(delta)
	if mode != "defense":
		_committed_target = null


func _solve(target: Node3D) -> bool:
	if mode != "defense" or not committed_prediction:
		return super._solve(target)
	if target != _committed_target or _commit_age >= config.prediction_update_interval - 0.000001:
		_commit(target)
	var valid := _solve_for(_track_position + _track_velocity * _commit_age, _track_velocity)
	var origin := muzzle.global_position
	aim_point = origin + _deviate(aim_point - origin)
	return valid


func _commit(target: Node3D) -> void:
	_committed_target = target
	_commit_age = 0.0
	_track_position = target.global_position
	_track_velocity = velocity_of(target)
	_error_cos = rng.randf_range(cos(deg_to_rad(config.prediction_error_degrees)), 1.0)
	_error_phi = rng.randf() * TAU
	commits += 1


# `direction` turned by this commitment's error (the angles of Weapon.disperse, drawn once).
func _deviate(direction: Vector3) -> Vector3:
	var axis := direction.normalized()
	var sin_theta := sqrt(maxf(0.0, 1.0 - _error_cos * _error_cos))
	var u := axis.cross(Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT).normalized()
	var v := axis.cross(u)
	return (axis * _error_cos + (u * cos(_error_phi) + v * sin(_error_phi)) * sin_theta) * direction.length()


func _round_mesh() -> Mesh:
	return config.tracer_mesh


# The pre-raid-sweep PDC's defensive order (protection, torpedoes before missiles except a
# missile under MISSILE_OVERRIDE_TIME, earliest impact, id).
func _defense_before(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return a[0] < b[0]
	var bucket_a := _priority_bucket(a)
	var bucket_b := _priority_bucket(b)
	if bucket_a != bucket_b:
		return bucket_a < bucket_b
	if a[1] != b[1]:
		return a[1] < b[1]
	var torpedo_a: bool = a[3].kind == &"torpedo"
	var torpedo_b: bool = b[3].kind == &"torpedo"
	if torpedo_a != torpedo_b:
		return torpedo_a
	return a[2] < b[2]


static func _priority_bucket(entry: Array) -> int:
	return 0 if entry[3].kind == &"torpedo" or entry[1] < MISSILE_OVERRIDE_TIME else 1
