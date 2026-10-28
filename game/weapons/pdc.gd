extends "res://game/weapons/gatling.gd"
## Combat: Point Defense Cannon family (PDC-20 Kestrel and future variants; values in the
## variant's PdcConfig, pdc_config.gd, e.g. pdc20_kestrel.tres). The Gatling's mount,
## articulation, magazine, threat evaluation, engageability and offensive path are reused
## unchanged; every round is one physical zero-radius tracer deviated within the
## configuration's `dispersion_max_deg` (Weapon.disperse, uniform over the cone's solid angle,
## drawn from this mount's own `rng`) in defense and offense alike, drawn with the
## configuration's `tracer_mesh` (visual only). Missed rounds fly on to their lifetime or
## maximum travel.
##
## Defensive order (the Gatling's threat evaluation): protection first, threats to the own
## ship, then to allies within the defensive radius (commands such as Guard never change
## this). Within a category: torpedoes before missiles, except a missile whose predicted
## impact is under MISSILE_OVERRIDE_TIME and earlier than the torpedo's; then the earliest
## predicted impact (a torpedo wins an exact tie with a missile), ordnance id breaking ties.
##
## Raid sweep: instead of firing at one threat until it is destroyed, the mount fires a
## micro-burst of `rounds_per_target` rounds at a threat, then takes the next engageable
## threat after it in its own defensive list (re-read every `raid_refresh_interval`), wrapping
## to the most urgent one, without waiting to see whether the burst hit. A threat is not
## picked twice in a row while another is engageable; with a single engageable threat the
## mount keeps firing at it. A threat that dies or stops being engageable mid-burst ends the
## burst. `target_switch_delay` holds fire after a switch (the turret keeps turning). Each
## mount decides on its own: no reservation, assignment or coordination between mounts.
##
## Committed prediction (defense only): while the turret turns onto a newly selected threat
## it follows the live solution; once the barrel is within the alignment tolerance of it
## (the start of actual firing) the mount records the threat's position and velocity (a
## dead-reckoned straight track) and draws one aim error within `prediction_error_degrees`.
## Until it is re-committed (every `prediction_update_interval`, or on the next threat) it
## leads that track, not the threat, and every round carries the same error plus its own
## dispersion. A threat that accelerates or turns leaves the committed track. Offense keeps
## the per-tick solution.

const MISSILE_OVERRIDE_TIME := 1.5 # s

var switches := 0 # Selections of a different threat (debug / tests).
var commits := 0 # Committed predictions (debug / tests).
var _raid: Array = [] # This mount's defensive candidates, [category, time, ordnance id, ordnance].
var _raid_age := INF
var _sweep_id := -1 # Ordnance id of the current burst's threat (ids outlive freed nodes).
var _burst_left := 0
var _switch_wait := 0.0
var _committed_target: Node3D = null
var _commit_age := INF
var _track_position := Vector3.ZERO
var _track_velocity := Vector3.ZERO
var _error_cos := 1.0
var _error_phi := 0.0


func step(delta: float) -> void:
	_raid_age += delta
	_commit_age += delta
	_switch_wait = maxf(0.0, _switch_wait - delta)
	super.step(delta)
	if mode != "defense":
		_committed_target = null


func _round_mesh() -> Mesh:
	return config.tracer_mesh


func _fire(target: Node3D) -> void:
	if mode == "defense" and _switch_wait > 0.0:
		return
	super._fire(target)
	if mode == "defense":
		_burst_left -= 1


# --- Raid sweep ----------------------------------------------------------------------------

func _choose_defense() -> void:
	if _raid_age >= config.raid_refresh_interval - 0.000001:
		_raid = _defense_candidates()
		_raid_age = 0.0
	var current := _raid_index(_sweep_id)
	if _burst_left > 0 and current >= 0 and _sweep_eligible(_raid[current][3]):
		_engage(_raid[current])
		return
	# Next engageable threat after the one just served (wrapping; from the most urgent when it
	# is gone from the list); the same one only when it is the only one left.
	for k in _raid.size():
		var entry: Array = _raid[(current + 1 + k) % _raid.size()]
		if entry[2] != _sweep_id and _sweep_eligible(entry[3]):
			_begin_burst(entry)
			return
	if current >= 0 and _sweep_eligible(_raid[current][3]):
		_begin_burst(_raid[current])


func _raid_index(id: int) -> int:
	for i in _raid.size():
		if _raid[i][2] == id:
			return i
	return -1


func _begin_burst(entry: Array) -> void:
	if entry[2] != _sweep_id:
		switches += 1
		if _sweep_id >= 0:
			_switch_wait = config.target_switch_delay
	_sweep_id = entry[2]
	_burst_left = config.rounds_per_target
	_engage(entry)


func _engage(entry: Array) -> void:
	defense_target = entry[3]
	defense_category = entry[0]
	defense_time = entry[1]


# Untyped: list entries may hold ordnance that has since been freed.
func _sweep_eligible(node: Variant) -> bool:
	return is_instance_valid(node) and node.live and engageable(node)


# --- Committed prediction ------------------------------------------------------------------

func _solve(target: Node3D) -> bool:
	var live := super._solve(target)
	if mode != "defense":
		return live
	if target != _committed_target:
		# Turning onto a new threat: follow the live solution until the barrel is ready to fire.
		if not live or _alignment_error(muzzle.global_position, aim_point) > config.alignment_tolerance_deg:
			return live
		_commit(target)
	elif _commit_age >= config.prediction_update_interval - 0.000001:
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


# --- Defensive order -----------------------------------------------------------------------

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


# 0: torpedoes and missiles inside the override time (ordered by impact time, so such a
# missile goes first only when it arrives earlier than the torpedo); 1: other missiles.
static func _priority_bucket(entry: Array) -> int:
	return 0 if entry[3].kind == &"torpedo" or entry[1] < MISSILE_OVERRIDE_TIME else 1
