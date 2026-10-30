extends Resource
## Shared settings of every directional jet effect (directional_thruster_fx.gd), one
## resource: directional_thruster_settings.tres. Plasma colour, gradient, spread, fade and
## turbulence are in directional_exhaust_process.tres; emission colour and energy in
## plasma_directional.tres. Sizes are for the reference jet (nozzle_scale 1, the Miner's).

@export_group("Emission")
@export var continuous := true # A steady stream while active; off = the pulses below
@export_range(0.5, 30.0, 0.1, "suffix:Hz") var pulse_frequency := 2.5 # Fixed; thrust does not change it
@export_range(0.01, 0.5, 0.005, "suffix:s") var pulse_duration := 0.08 # Emission time of one pulse

@export_group("Exhaust")
@export_range(0.05, 2.0, 0.01, "suffix:s") var lifetime := 0.35
@export_range(1, 256) var amount := 64 # Particle slots; one pulse emits about amount x duration / lifetime
@export_range(0.0, 1.0) var low_thrust_density := 0.35 # Particle share as thrust nears 0
@export_range(0.0, 1.0) var low_thrust_brightness := 0.45 # Brightness share as thrust nears 0
