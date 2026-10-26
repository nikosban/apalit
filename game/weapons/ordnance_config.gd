extends Resource
## Combat (migrated from the prototype v0.3): guided ordnance values (torpedo or missile; provisional).
##
## Torpedo: constant `speed` along its nose; straight for `arming_distance`, then the nose
## turns toward the guidance point at no more than `turn_rate_deg`.
## Missile: ejected along the launcher axis at `eject_speed` until `clearance` from the
## launch point and clear of its own hull; then it drifts while the nose turns at
## `orient_rate_deg` until within `powered_within_deg` of the wanted direction; then main
## thrust `acceleration` along the nose (speed capped at `max_speed`) while the nose turns
## at `turn_rate_deg`. Velocity is integrated (momentum kept): it never snaps to the nose.
## The nose steers toward the velocity change needed to fly the wanted direction at
## `max_speed`, except within `steering_deadband_deg` of it, where it steers along the
## wanted direction itself (no turning across a small error at the speed cap).
## Rocket: unguided, constant `speed` along its launch axis until `max_travel` / `lifetime`;
## no turning or avoidance (the turn, ejection and avoidance values are unused).

@export var kind := &"torpedo" # torpedo, missile, rocket
@export var speed := 12.0 # u/s (torpedo, rocket; constant)
@export var turn_rate_deg := 4.0 # °/s (torpedo; missile powered pursuit)
@export var arming_distance := 6.0 # u straight before guidance (torpedo)
@export var eject_speed := 5.0 # u/s (missile)
@export var clearance := 2.5 # u from the launch point (missile)
@export var hull_margin := 0.5 # u beyond its own hull boxes before turning (missile)
@export var orient_rate_deg := 180.0 # °/s (missile, orientation stage)
@export var powered_within_deg := 15.0 # (missile)
@export var acceleration := 60.0 # u/s² (missile)
@export var max_speed := 32.0 # u/s (missile)
@export var steering_deadband_deg := 0.0 # (missile; 0 = none)
@export var avoidance := true # missile: local obstacle avoidance
@export var avoid_lookahead := 0.8 # s of travel checked ahead (missile)
@export var avoid_margin := 1.0 # u added to obstacle radii (missile)
@export var flight_time := 9.0 # s from launch, then self-destruct (missile); 0 = none
@export var lifetime := 30.0 # s technical bound (torpedo)
@export var max_travel := 360.0 # u technical bound
@export var radius := 0.4 # u, interception sphere
@export var length := 0.9 # u, model
@export var body_radius := 0.09 # u, model
@export var trail_time := 1.2 # s of trail
@export var arrival_distance := 2.0 # u: a last known position counts as reached
# Presentation: the shared thruster effects (game/presentation/thrusters/) on the model.
@export var thruster_scale := 0.38 # main_thruster_fx nozzle_scale (1 = a 0.2 u nozzle)
@export var thruster_length := 1.0 # main_thruster_fx length_multiplier
@export var rcs_scale := 0.25 # directional_thruster_fx nozzle_scale, attitude thrusters (missile)
