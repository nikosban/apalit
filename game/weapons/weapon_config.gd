extends Resource
## Combat (migrated from the prototype): one weapon type's values (provisional testing defaults).
## Fixed weapons use `firing_cone_deg`; turrets use the yaw / pitch limits and speeds
## (a hardpoint, when the weapon is installed on one, supplies its own limits instead).
##
## v0.3: every weapon has a finite `ammunition` stock (no replenishment yet). Weapons
## without a magazine reload between shots (`cooldown`); magazine weapons (Gatlings) fire
## at `cooldown` intervals from a magazine of `magazine_size` rounds and refill it from the
## stock in `reload_time` when it is empty or when the weapon has been idle for
## `idle_reload_delay` with a partly used magazine. `weapon_range` is the maximum range
## (firing authorization); `effective_range` (0 = same as weapon_range) is where tracking
## starts to degrade: beyond it the lead is scaled down linearly to `lead_quality_at_max`
## at the maximum range (under-leading a moving target; never random).

@export var display_name := "Weapon"
@export var family := &"fixed" # fixed, cannon, gatling, torpedo, missile (hardpoint compatibility)
@export var size := 1 # 0 small, 1 medium, 2 large (hardpoint compatibility)
@export var damage := 10.0
@export var cooldown := 1.0 # s between shots (reload for weapons without a magazine)
@export var weapon_range := 45.0 # u; maximum range: authorization and acquisition
@export var effective_range := 0.0 # u; 0 = weapon_range (no degradation)
@export var lead_quality_at_max := 1.0 # lead factor at weapon_range (1 = full lead)
@export var travel_factor := 1.25 # maximum projectile travel = weapon_range × this (fired shots only)
@export var projectile_speed := 40.0 # u/s
@export var projectile_lifetime := 2.5 # s
@export var projectile_style := &"shell" # shell, tracer
@export var alignment_tolerance_deg := 3.0
@export var firing_cone_deg := 12.0 # fixed weapons: ± around the bow
@export var yaw_limit_deg := 160.0 # turrets: ± around the mount's forward
@export var pitch_min_deg := -15.0
@export var pitch_max_deg := 75.0
@export var yaw_speed_deg := 60.0 # °/s
@export var pitch_speed_deg := 40.0 # °/s
@export var ammunition := 200 # rounds in the stock at the start (magazine included)
@export var magazine_size := 0 # 0 = no magazine
@export var reload_time := 0.0 # s, magazine refill (empty or idle)
@export var idle_reload_delay := 0.25 # s without an actionable shot before an idle refill
@export var ordnance: Resource # Launchers: the guided ordnance's values (OrdnanceConfig).


func max_travel() -> float:
	return weapon_range * travel_factor


func effective() -> float:
	return weapon_range if effective_range <= 0.0 else minf(effective_range, weapon_range)


## Lead factor at `distance`: 1 up to the effective range, then linearly down to
## `lead_quality_at_max` at the maximum range.
func lead_quality(distance: float) -> float:
	var start := effective()
	if distance <= start or weapon_range <= start:
		return 1.0
	return lerpf(1.0, lead_quality_at_max, clampf((distance - start) / (weapon_range - start), 0.0, 1.0))
