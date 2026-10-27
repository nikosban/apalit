extends "res://game/weapons/gatling.gd"
## Combat: Point Defense Cannon family (PDC-20 Kestrel and future variants; values in the
## variant's WeaponConfig, e.g. pdc20_kestrel.tres). The Gatling's mount, articulation,
## magazine, threat evaluation, engageability and firing paths are reused unchanged; every
## round is one physical tracer deviated within the configuration's `dispersion_max_deg`
## (Weapon.disperse, uniform over the cone's solid angle, drawn from this mount's own `rng`)
## in defense and offense alike. Each mount selects on its own: no reservation, assignment
## or coordination between mounts, so several may engage the same threat.
##
## Only the defensive order differs from the Gatling. Protection first: threats to the own
## ship, then to allies within the defensive radius (commands such as Guard never change
## this). Within a category: torpedoes before missiles, except a missile whose predicted
## impact is under MISSILE_OVERRIDE_TIME and earlier than the torpedo's; then the earliest
## predicted impact (a torpedo wins an exact tie with a missile), ordnance id breaking ties.
## Predicted impact times are the Gatling's threat_time().

const MISSILE_OVERRIDE_TIME := 1.5 # s


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
