extends Resource
## Shared settings of every main engine effect (main_thruster_fx.gd), one resource:
## main_thruster_settings.tres. Plasma colour, gradient, spread and fade are in
## main_exhaust_process.tres (plume body) and main_trail_process.tres (trail); emission
## colour, energy and streak shape in plasma_main.tres, plasma_core.tres and
## nozzle_glow.tres. Sizes are for the reference nozzle (nozzle_scale 1, the Miner's).

@export_group("Plume body")
@export_range(0.05, 2.0, 0.01, "suffix:s") var lifetime := 0.32
@export_range(1, 512) var amount := 96 # Particles alive at full thrust
@export_range(0.0, 1.0) var low_thrust_length := 0.4 # Plume length share as thrust nears 0
@export_range(0.0, 1.0) var low_thrust_density := 0.5 # Particle share as thrust nears 0
@export_range(0.0, 1.0) var low_thrust_brightness := 0.6 # Brightness share as thrust nears 0

@export_group("Core")
@export_range(0.0, 3.0, 0.01, "suffix:u") var core_length := 0.55 # At full thrust
@export_range(0.0, 1.0, 0.01, "suffix:u") var core_width := 0.24

@export_group("Trail")
@export_range(0.05, 3.0, 0.01, "suffix:s") var trail_lifetime := 0.55
@export_range(1, 512) var trail_amount := 48

@export_group("Nozzle glow")
@export_range(0.0, 2.0) var idle_glow := 0.25 # Glow brightness at thrust 0 (IDLE)
@export_range(0.0, 2.0) var active_glow := 0.8 # Glow brightness at full thrust
