extends Node3D
## Authoring scene for the thruster effects (open thruster_fx_preview.tscn; F6 to run).
## In the editor: select an effect instance and set its `thrust` (and `nozzle_scale`,
## `length_multiplier`) to see it live; edit the shared look in the resources next to the
## scenes (main_thruster_settings.tres, directional_thruster_settings.tres, the
## *_exhaust_process.tres, plasma_*.tres and nozzle_glow.tres), which every ship uses.
## At run time the Turntable spins, to show the world-space exhaust trailing behind
## moving, turning emitters.

@export var turntable_speed := 90.0 # deg/s

@onready var _turntable: Node3D = $Turntable


func _process(delta: float) -> void:
	_turntable.rotate_y(deg_to_rad(turntable_speed) * delta)
