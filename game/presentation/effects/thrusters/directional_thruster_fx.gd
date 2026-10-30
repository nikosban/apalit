@tool
extends Node3D
## A directional jet's exhaust (GPUParticles3D `Exhaust`, world-space particles) while
## `thrust` > 0: a steady stream (settings `continuous`) or short, separate pulses repeating
## at the shared fixed frequency. A pulse is a short emission window of the running
## emitter, never a restart, so the particles of earlier pulses live out their lifetime.
## Thrust 0: no new particles, no glow, nothing drawn but the residual particles. Place the
## node on the jet's outer face with its -Z along the exhaust. Runtime control: `thrust`
## 0..1 (density and brightness, not the frequency). Shared look: `settings`
## (directional_thruster_settings.tres) and the resources it names; per instance only
## `nozzle_scale` and `length_multiplier`.

@export_range(0.0, 1.0) var thrust := 0.0
@export_range(0.05, 10.0, 0.01, "or_greater") var nozzle_scale := 1.0 # 1 = the Miner's jet (box 0.14 u)
@export_range(0.1, 5.0, 0.01, "or_greater") var length_multiplier := 1.0
@export var settings: Resource = preload("res://game/presentation/effects/thrusters/directional_thruster_settings.tres")

var _clock := 0.0 # s into the current pulse period; 0 while inactive, so an activation pulses at once

var _exhaust: GPUParticles3D


func _process(delta: float) -> void:
	# Looked up when missing, not once on ready: in the editor a reloaded tool script loses
	# its references.
	if _exhaust == null:
		_exhaust = get_node_or_null("Exhaust")
		if _exhaust == null:
			return
	if settings == null:
		return
	# Applied only on a change: setting amount or lifetime restarts the particles.
	if _exhaust.amount != settings.amount:
		_exhaust.amount = settings.amount
	if not is_equal_approx(_exhaust.lifetime, settings.lifetime):
		_exhaust.lifetime = settings.lifetime
	var t := clampf(thrust, 0.0, 1.0)
	_exhaust.set_instance_shader_parameter("size", nozzle_scale)
	if t <= 0.0:
		_exhaust.emitting = false
		_clock = 0.0
		return
	_exhaust.emitting = settings.continuous or _clock < settings.pulse_duration
	_clock = fmod(_clock + delta, 1.0 / settings.pulse_frequency)
	_exhaust.scale = Vector3(nozzle_scale, nozzle_scale, nozzle_scale * length_multiplier)
	_exhaust.amount_ratio = lerpf(settings.low_thrust_density, 1.0, t)
	_exhaust.set_instance_shader_parameter("intensity", lerpf(settings.low_thrust_brightness, 1.0, t))


## True while emitting (streaming, or within a pulse).
func emitting() -> bool:
	return _exhaust != null and _exhaust.emitting
