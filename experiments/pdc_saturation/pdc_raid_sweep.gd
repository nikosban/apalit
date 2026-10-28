extends "res://experiments/pdc_saturation/pdc_saturation.gd"
## Experiment (PDC saturation fire, not used by the game): `raid_sweep` point-defense
## targeting. Instead of firing at one threat until it is destroyed, the mount fires a
## micro-burst of `rounds_per_target` rounds at a threat, then moves on to the next eligible
## threat, cycling through the survivors. Aiming is the committed prediction of
## pdc_saturation.gd (a new commitment, with its own shared error, on every switch).
##
## The prototype the production PDC (pdc.gd) was integrated from; unlike production it
## commits the prediction at selection, not at the start of firing. Per mount, no
## coordination between mounts. The raid list is this mount's own defensive candidates
## (gatling.gd _defense_candidates(), the PDC order), re-read every `raid_refresh_interval`. After a burst the
## mount takes the next engageable threat after the one it just served in that list,
## wrapping to the most urgent one, so a threat is not picked twice in a row while another
## is eligible. With a single eligible threat it keeps firing at it. A threat that dies or
## stops being engageable mid-burst ends the burst. `target_switch_delay` holds fire after a
## switch (the turret keeps turning). Turret speed, arcs, alignment, magazine and the
## physical rounds are the PDC's unchanged.

@export_group("Raid sweep")
## Rounds fired at one threat before moving on.
@export_range(1, 60, 1) var rounds_per_target := 4
## s without firing after switching to another threat.
@export_range(0.0, 2.0, 0.01, "suffix:s") var target_switch_delay := 0.0
## s between re-reads of the raid list (new threats join the cycle at a re-read).
@export_range(0.05, 3.0, 0.01, "suffix:s") var raid_refresh_interval := 0.25

var switches := 0 # Switches to a different threat (evaluation).
var _raid: Array = [] # [category, time, ordnance id, ordnance] in defensive order
var _raid_age := INF
var _sweep_id := -1 # Ordnance id of the current burst's threat (ids outlive freed nodes).
var _burst_left := 0
var _switch_wait := 0.0


func step(delta: float) -> void:
	_raid_age += delta
	_switch_wait = maxf(0.0, _switch_wait - delta)
	super.step(delta)


func _choose_defense() -> void:
	if _raid_age >= raid_refresh_interval - 0.000001:
		_raid = _defense_candidates()
		_raid_age = 0.0
	var current := _index(_sweep_id)
	if _burst_left > 0 and current >= 0 and _eligible(_raid[current][3]):
		_engage(_raid[current])
		return
	# Next eligible threat after the one just served (wrapping; from the most urgent when it
	# is gone from the list); the same one only when it is the only one left.
	for k in _raid.size():
		var entry: Array = _raid[(current + 1 + k) % _raid.size()]
		if entry[2] != _sweep_id and _eligible(entry[3]):
			_begin(entry)
			return
	if current >= 0 and _eligible(_raid[current][3]):
		_begin(_raid[current])


func _index(id: int) -> int:
	for i in _raid.size():
		if _raid[i][2] == id:
			return i
	return -1


func _begin(entry: Array) -> void:
	if entry[2] != _sweep_id:
		switches += 1
		if _sweep_id >= 0:
			_switch_wait = target_switch_delay
	_sweep_id = entry[2]
	_burst_left = rounds_per_target
	_engage(entry)


func _engage(entry: Array) -> void:
	defense_target = entry[3]
	defense_category = entry[0]
	defense_time = entry[1]


# Untyped: list entries may hold ordnance that has since been freed.
func _eligible(node: Variant) -> bool:
	return is_instance_valid(node) and node.live and engageable(node)


func _fire(target: Node3D) -> void:
	if mode == "defense" and _switch_wait > 0.0:
		return
	super._fire(target)
	if mode == "defense":
		_burst_left -= 1
