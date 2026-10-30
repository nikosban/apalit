@tool
extends Node3D
## A main engine's exhaust: a stable emissive core streak on the nozzle (`Core`), a
## coherent plume body of velocity-stretched plasma (GPUParticles3D `Exhaust`), a short
## residual trail (GPUParticles3D `Trail`: slow particles that stay where they were emitted,
## so movement leaves a readable exhaust path) and an emissive nozzle glow (`Glow`). Both
## emitters use world-space particles. Place the node on the nozzle with its -Z along the
## exhaust. Runtime control: `thrust` 0..1 (0 = no exhaust, the faint idle glow only;
## plume length, density and brightness grow with it) and `powered` (false = no glow
## either). Shared look: `settings` (main_thruster_settings.tres) and the resources it
## names; per instance only `nozzle_scale` and `length_multiplier`. Nothing here writes
## to a shared resource: per-instance values go to node properties and instance uniforms.

@export_range(0.0, 1.0) var thrust := 0.0
@export var powered := true
@export_range(0.05, 10.0, 0.01, "or_greater") var nozzle_scale := 1.0 # Width; 1 = the Miner's engine (radius 0.2 u)
@export_range(0.1, 5.0, 0.01, "or_greater") var length_multiplier := 1.0
@export var settings: Resource = preload("res://game/presentation/effects/thrusters/main_thruster_settings.tres")

var _exhaust: GPUParticles3D
var _trail: GPUParticles3D
var _core: GeometryInstance3D
var _glow: GeometryInstance3D


func _process(_delta: float) -> void:
	# Looked up when missing, not once on ready: in the editor a reloaded tool script loses
	# its references, and an instance can predate a child added to the scene.
	if _exhaust == null or _trail == null or _core == null or _glow == null:
		_exhaust = get_node_or_null("Exhaust")
		_trail = get_node_or_null("Trail")
		_core = get_node_or_null("Core")
		_glow = get_node_or_null("Glow")
		if _exhaust == null or _trail == null or _core == null or _glow == null:
			return
	if settings == null:
		return
	_sync(_exhaust, settings.amount, settings.lifetime)
	_sync(_trail, settings.trail_amount, settings.trail_lifetime)
	var t := clampf(thrust, 0.0, 1.0)
	var length := length_multiplier * lerpf(settings.low_thrust_length, 1.0, t)
	for emitter: GPUParticles3D in [_exhaust, _trail]:
		emitter.emitting = t > 0.0
		emitter.set_instance_shader_parameter("size", nozzle_scale)
		if t > 0.0:
			# The node's scale carries the emission width and, along Z, the particle velocity
			# (plume length); the particle size comes from the instance uniform. Only new
			# particles take these, and the brightness is held when thrust stops, so the
			# exhaust already in space fades unchanged.
			emitter.scale = Vector3(nozzle_scale, nozzle_scale, nozzle_scale * length)
			emitter.amount_ratio = lerpf(settings.low_thrust_density, 1.0, t)
			emitter.set_instance_shader_parameter("intensity", lerpf(settings.low_thrust_brightness, 1.0, t))
	# The core: a streak from the nozzle along the exhaust, its +Y toward the nozzle (the
	# shader's bright head).
	_core.visible = t > 0.0
	if t > 0.0:
		var core_length: float = settings.core_length * nozzle_scale * length
		var width: float = settings.core_width * nozzle_scale
		_core.transform = Transform3D(Basis(Vector3(width, 0, 0), Vector3(0, 0, core_length), Vector3(0, -width, 0)), Vector3(0, 0, -core_length / 2.0))
		_core.set_instance_shader_parameter("intensity", lerpf(settings.low_thrust_brightness, 1.0, t))
	_glow.visible = powered
	_glow.scale = Vector3.ONE * nozzle_scale
	_glow.set_instance_shader_parameter("intensity", lerpf(settings.idle_glow, settings.active_glow, t))


## True while exhaust particles are being emitted.
func emitting() -> bool:
	return _exhaust != null and _exhaust.emitting


# Applied only on a change: setting amount or lifetime restarts the particles.
func _sync(emitter: GPUParticles3D, amount: int, lifetime: float) -> void:
	if emitter.amount != amount:
		emitter.amount = amount
	if not is_equal_approx(emitter.lifetime, lifetime):
		emitter.lifetime = lifetime
