extends Node3D
## Camera rig: one perspective camera looking at the rig's pivot on the ground (Y 0).
## The wheel sets a target distance; the rendered `zoom_distance` follows it smoothly
## (log space) and the pitch follows the rendered distance, so the camera tilts toward
## top-down as it zooms out. A wheel zoom keeps the ground point under the cursor in
## place while the pivot stays inside `bounds`; panning or rotating cancels that anchor.
## Writing `zoom_distance` and calling `_apply_zoom()` snaps at once (tests, resets).

const REFERENCE_MIN_ZOOM := 5.0 # zoom_level() 0 (main scene range)
const REFERENCE_MAX_ZOOM := 150.0 # zoom_level() 1
const MAX_WHEEL_FACTOR := 10.0 # notches one high-resolution wheel event may count for
const MIN_ANCHOR_RAY_DROP := 0.05 # anchor rays flatter than this (direction y) are ignored

@export var pitch_degrees := 45.0 # close range (normal) pitch
@export var tactical_pitch_degrees := 80.0 # pitch at and beyond pitch_end_distance
@export var pitch_start_distance := 20.0 # the pitch starts to steepen beyond this distance
@export var pitch_end_distance := 100.0 # and reaches the tactical pitch here
@export var zoom_distance := 15.0
@export var min_zoom := 5.0
@export var max_zoom := 40.0
@export var zoom_step := 0.1 # one notch: target × (1 + step) out, ÷ (1 + step) in
@export var zoom_smoothing_time := 0.25 # s for the rendered distance to cover 95% of a change
@export var pan_speed_factor := 1.5
@export var rotate_speed := 90.0
@export var drag_rotate_sensitivity := 0.3
@export var bounds := Rect2(-150.0, -150.0, 300.0, 300.0)

var zoom_target := 15.0 # requested distance; the rendered zoom_distance follows it

var _follow_target: Node3D = null
var _anchored := false
var _anchor_screen := Vector2.ZERO
var _anchor_world := Vector3.ZERO
var _applied_zoom := -1.0 # zoom_distance as last applied (a different value is an outside write)
var _applied_transform := Transform3D() # the rig as left by the last frame (a change cancels the anchor)

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_apply_zoom()


func _process(delta: float) -> void:
	# Combat migration: pan and rotation run in real time at every simulation speed (the
	# engine time scale divided out); the scene keeps the rig processing while paused.
	if Engine.time_scale > 0.0:
		delta /= Engine.time_scale
	if zoom_distance != _applied_zoom:
		_apply_zoom() # written from outside without a snap call: snap
	if global_transform != _applied_transform:
		_anchored = false # moved or rotated from outside
	var rotate_input := 0.0
	if Input.is_physical_key_pressed(KEY_Q):
		rotate_input += 1.0
	if Input.is_physical_key_pressed(KEY_E):
		rotate_input -= 1.0
	if rotate_input != 0.0:
		_anchored = false
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
		_anchored = false
		pan = pan.normalized()
		var forward := Vector3(-global_basis.z.x, 0.0, -global_basis.z.z).normalized()
		var right := Vector3(global_basis.x.x, 0.0, global_basis.x.z).normalized()
		global_position += (right * pan.x + forward * pan.y) * pan_speed_factor * zoom_distance * delta
	elif is_instance_valid(_follow_target):
		_anchored = false
		_snap_to_target()
	_smooth_zoom(delta)
	global_position.x = clampf(global_position.x, bounds.position.x, bounds.end.x)
	global_position.z = clampf(global_position.z, bounds.position.y, bounds.end.y)
	_applied_transform = global_transform


func follow(target: Node3D) -> void:
	_follow_target = target
	_snap_to_target()


func _snap_to_target() -> void:
	global_position.x = _follow_target.global_position.x
	global_position.z = _follow_target.global_position.z


func _unhandled_input(event: InputEvent) -> void:
	var button_event := event as InputEventMouseButton
	if button_event != null and button_event.pressed:
		if get_viewport().gui_get_hovered_control() != null:
			return # Over a UI panel: the wheel never zooms the camera.
		if button_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_wheel(-_notches(button_event), button_event.position)
		elif button_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_wheel(_notches(button_event), button_event.position)
		return
	var motion_event := event as InputEventMouseMotion
	if motion_event != null and motion_event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		_anchored = false
		rotate_y(deg_to_rad(-motion_event.relative.x * drag_rotate_sensitivity))


## Wheel notches of one event: its `factor` (high-resolution wheels and touchpads), one
## when the platform reports none or an unusable value.
func _notches(event: InputEventMouseButton) -> float:
	var factor := event.factor
	if not is_finite(factor) or factor <= 0.0:
		return 1.0
	return minf(factor, MAX_WHEEL_FACTOR)


## Changes the target by `notches` (positive: out) and anchors the ground point under
## the cursor, read from the camera as rendered now.
func _wheel(notches: float, screen_position: Vector2) -> void:
	zoom_target = clampf(zoom_target * pow(1.0 + zoom_step, notches), min_zoom, max_zoom)
	var hit: Variant = _ground_hit(screen_position)
	_anchored = hit != null
	if _anchored:
		_anchor_screen = screen_position
		_anchor_world = hit


## Moves the rendered distance toward the target (exponential, in log distance: no
## overshoot) and keeps the anchored ground point under its screen position.
func _smooth_zoom(delta: float) -> void:
	if zoom_distance == zoom_target:
		_anchored = false
		return
	var rate := -log(0.05) / maxf(zoom_smoothing_time, 0.001)
	var current := log(zoom_distance)
	var goal := log(zoom_target)
	current = lerpf(current, goal, 1.0 - exp(-rate * delta))
	zoom_distance = zoom_target if absf(goal - current) < 0.0001 else exp(current)
	_update_camera()
	if not _anchored:
		return
	var hit: Variant = _ground_hit(_anchor_screen)
	if hit == null:
		_anchored = false
		return
	var shift: Vector3 = _anchor_world - hit
	shift.y = 0.0
	if not shift.is_finite() or shift.length() > 2.0 * maxf(zoom_distance, min_zoom):
		_anchored = false # never jump the pivot
		return
	global_position += shift


## The point on the ground plane (Y 0) under a screen position, or null for no usable hit.
func _ground_hit(screen_position: Vector2) -> Variant:
	var origin := _camera.project_ray_origin(screen_position)
	var direction := _camera.project_ray_normal(screen_position)
	if not origin.is_finite() or not direction.is_finite() or direction.y > -MIN_ANCHOR_RAY_DROP:
		return null
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	if hit == null or not (hit as Vector3).is_finite():
		return null
	return hit


## Snap: applies `zoom_distance` at once (clamped), with its pitch; the target follows and
## any wheel anchor is dropped.
func _apply_zoom() -> void:
	zoom_distance = clampf(zoom_distance, min_zoom, max_zoom)
	zoom_target = zoom_distance
	_anchored = false
	_update_camera()


func _update_camera() -> void:
	var pitch := deg_to_rad(pitch_for(zoom_distance))
	_camera.rotation = Vector3(-pitch, 0.0, 0.0)
	_camera.position = Vector3(0.0, sin(pitch), cos(pitch)) * zoom_distance
	_applied_zoom = zoom_distance


## Camera pitch in degrees for a distance: `pitch_degrees` up to `pitch_start_distance`,
## `tactical_pitch_degrees` from `pitch_end_distance`, a smoothstep in log distance between.
func pitch_for(distance: float) -> float:
	var t := 0.0
	if pitch_end_distance > pitch_start_distance and pitch_start_distance > 0.0:
		t = clampf(log(maxf(distance, 0.001) / pitch_start_distance) / log(pitch_end_distance / pitch_start_distance), 0.0, 1.0)
	elif distance >= pitch_end_distance:
		t = 1.0
	return clampf(lerpf(pitch_degrees, tactical_pitch_degrees, smoothstep(0.0, 1.0, t)), 1.0, 90.0)


## Rendered zoom on the fixed reference scale (5–150, log): 0 close, 1 far. A scene's own
## limits clamp the camera but do not change what a value means.
func zoom_level() -> float:
	var d := clampf(zoom_distance, REFERENCE_MIN_ZOOM, REFERENCE_MAX_ZOOM)
	return log(d / REFERENCE_MIN_ZOOM) / log(REFERENCE_MAX_ZOOM / REFERENCE_MIN_ZOOM)
