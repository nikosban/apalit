@tool
extends Node3D
## Experiment (PDC saturation fire): authoring scene for the PDC tracer look (open
## pdc_tracer_preview.tscn; it fires in the editor viewport, F6 to run). `config` defaults to
## the production Kestrel (pdc20_kestrel.tres); its tracer is pdc20_kestrel_tracer.tres. Visual only: no
## projectile system, collisions, missiles or interception (saturation_eval.gd measures
## those).
##
## A Kestrel placeholder mount fires continuously at the Target marker with `config`'s
## values, read live: rate (`cooldown`), `projectile_speed`, lifetime and maximum travel
## (`weapon_range` × `travel_factor`), per-round `dispersion_max_deg`, and a shared aim
## error within `prediction_error_degrees` re-drawn every `prediction_update_interval`
## (the burst groups). The firing rhythm is an approximation of pdc_saturation.gd for
## viewing. Every round draws `config.tracer_mesh`, so edits to its size, emission colour
## and strength, and albedo alpha (opacity) show at once on all rounds in flight.

const WeaponGeometry := preload("res://game/weapons/weapon_geometry.gd")
const Weapon := preload("res://game/weapons/weapon.gd")
# The Kestrel's placeholder geometry (pdc20_kestrel.tscn).
const BASE_DIAMETER := 0.36
const BODY_HEIGHT := 0.16
const BARREL_LENGTH := 0.5
const SPIN_SPEED := 24.0 # rad/s, as the Gatling's barrel cluster

@export var config: Resource = preload("res://game/weapons/pdc20_kestrel.tres")
@export_range(5.0, 120.0, 0.5, "suffix:u") var target_distance := 75.0
@export var firing := true
## Sideways speed of the Target (0 = stationary); the mount leads it.
@export_range(0.0, 40.0, 0.5, "suffix:u/s") var target_sweep_speed := 0.0
@export_range(0.0, 60.0, 0.5, "suffix:u") var target_sweep_width := 20.0

var _rounds: Array[Dictionary] = [] # {node, velocity, age, traveled}
var _rng := RandomNumberGenerator.new()
var _cooldown := 0.0
var _commit_age := INF
var _error := Quaternion.IDENTITY # Shared aim error of the current commitment.
var _sweep_time := 0.0
var _yaw: Node3D
var _pitch: Node3D
var _muzzle: Node3D
var _spinner: Node3D

@onready var _target: Node3D = $Target


func _ready() -> void:
	_rng.randomize()
	# Built at run time and in the editor; no owner, so never saved into the scene.
	var parts := WeaponGeometry.build_gatling($Mount, BASE_DIAMETER, BODY_HEIGHT, BARREL_LENGTH)
	_yaw = parts.yaw
	_pitch = parts.pitch
	_muzzle = parts.muzzle
	_spinner = parts.spinner


func _process(delta: float) -> void:
	if _muzzle == null:
		return
	_sweep_time += delta
	var side := 0.0
	var side_speed := 0.0
	if target_sweep_speed > 0.0 and target_sweep_width > 0.0:
		var omega := target_sweep_speed / (target_sweep_width * 0.5)
		side = sin(_sweep_time * omega) * target_sweep_width * 0.5
		side_speed = cos(_sweep_time * omega) * target_sweep_speed
	_target.position = Vector3(side, $Mount.position.y, -target_distance)
	_advance(delta)
	if not firing or config == null or config.tracer_mesh == null:
		return
	# Lead the moving Target, turned by this commitment's shared error.
	var origin := _pitch.global_position
	var velocity := Vector3(side_speed, 0.0, 0.0)
	var time := Weapon.intercept_time(origin, _target.global_position, velocity, config.projectile_speed)
	var aim := _target.global_position + velocity * maxf(time, 0.0)
	_commit_age += delta
	if _commit_age >= config.prediction_update_interval:
		_commit_age = 0.0
		var axis := (aim - origin).normalized()
		_error = Quaternion(axis, Weapon.disperse(axis, config.prediction_error_degrees, _rng).normalized())
	var direction := _error * (aim - origin)
	var local := global_basis.inverse() * direction
	_yaw.rotation.y = atan2(-local.x, -local.z)
	_pitch.rotation.x = atan2(local.y, Vector2(local.x, local.z).length())
	_spinner.rotation.z = wrapf(_spinner.rotation.z + SPIN_SPEED * delta, -PI, PI)
	_cooldown -= delta
	while _cooldown <= 0.0:
		_cooldown += maxf(config.cooldown, 0.005)
		_fire()


func _fire() -> void:
	var forward := -_muzzle.global_basis.z.normalized()
	var velocity: Vector3 = Weapon.disperse(forward, config.dispersion_max_deg, _rng) * config.projectile_speed
	var node := MeshInstance3D.new()
	node.mesh = config.tracer_mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	node.global_transform = Transform3D(Basis.looking_at(velocity.normalized(), Vector3.UP), _muzzle.global_position)
	_rounds.append({"node": node, "velocity": velocity, "age": 0.0, "traveled": 0.0})


func _advance(delta: float) -> void:
	var max_travel: float = config.weapon_range * config.travel_factor if config != null else 0.0
	for entry: Dictionary in _rounds.duplicate():
		var node: MeshInstance3D = entry.node
		var step: Vector3 = entry.velocity * delta
		entry.age += delta
		entry.traveled += step.length()
		node.global_position += step
		if config == null or entry.age >= config.projectile_lifetime or entry.traveled >= max_travel:
			_rounds.erase(entry)
			node.queue_free()
		elif node.mesh != config.tracer_mesh:
			node.mesh = config.tracer_mesh
