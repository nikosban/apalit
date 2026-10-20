extends Node3D

@export var pitch_degrees := 45.0
@export var zoom_distance := 15.0
@export var min_zoom := 5.0
@export var max_zoom := 40.0
@export var zoom_step := 0.1
@export var pan_speed_factor := 1.5
@export var rotate_speed := 90.0
@export var drag_rotate_sensitivity := 0.3
@export var bounds := Rect2(-150.0, -150.0, 300.0, 300.0)

var _follow_target: Node3D = null

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_camera.rotation = Vector3(-deg_to_rad(pitch_degrees), 0.0, 0.0)
	_apply_zoom()


func _process(delta: float) -> void:
	# Combat migration: pan and rotation run in real time at every simulation speed (the
	# engine time scale divided out); the scene keeps the rig processing while paused.
	if Engine.time_scale > 0.0:
		delta /= Engine.time_scale
	var rotate_input := 0.0
	if Input.is_physical_key_pressed(KEY_Q):
		rotate_input += 1.0
	if Input.is_physical_key_pressed(KEY_E):
		rotate_input -= 1.0
	rotate_y(deg_to_rad(rotate_speed) * rotate_input * delta)

	var pan := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		pan.y += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		pan.y -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		pan.x += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		pan.x -= 1.0
	if pan != Vector2.ZERO:
		_follow_target = null
		pan = pan.normalized()
		var forward := Vector3(-global_basis.z.x, 0.0, -global_basis.z.z).normalized()
		var right := Vector3(global_basis.x.x, 0.0, global_basis.x.z).normalized()
		global_position += (right * pan.x + forward * pan.y) * pan_speed_factor * zoom_distance * delta
	elif is_instance_valid(_follow_target):
		_snap_to_target()
	global_position.x = clampf(global_position.x, bounds.position.x, bounds.end.x)
	global_position.z = clampf(global_position.z, bounds.position.y, bounds.end.y)


func follow(target: Node3D) -> void:
	_follow_target = target
	_snap_to_target()


func _snap_to_target() -> void:
	global_position.x = _follow_target.global_position.x
	global_position.z = _follow_target.global_position.z


func _unhandled_input(event: InputEvent) -> void:
	var button_event := event as InputEventMouseButton
	if button_event != null and button_event.pressed:
		if button_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_distance *= 1.0 - zoom_step
			_apply_zoom()
		elif button_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_distance *= 1.0 + zoom_step
			_apply_zoom()
		return
	var motion_event := event as InputEventMouseMotion
	if motion_event != null and motion_event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		rotate_y(deg_to_rad(-motion_event.relative.x * drag_rotate_sensitivity))


func _apply_zoom() -> void:
	zoom_distance = clampf(zoom_distance, min_zoom, max_zoom)
	var pitch := deg_to_rad(pitch_degrees)
	_camera.position = Vector3(0.0, sin(pitch), cos(pitch)) * zoom_distance
