extends Node3D
## Combat prototype v0.2: a static or scripted target for the turret pitch range only
## (never in planar combat). It is placed with place() or flies its waypoints in a loop at
## `speed` (straight lines, any height); its Combat node measures its velocity from the
## motion, so turrets lead it like a ship. Not a ship: no Locomotion, navigation or
## avoidance.

@export var speed := 4.0 # u/s along the waypoints
@export var waypoints := PackedVector3Array()

var _next := 0


func _ready() -> void:
	process_physics_priority = -2 # Moves before the turret's Combat (2) steps.


func place(point: Vector3) -> void:
	waypoints = PackedVector3Array()
	global_position = point


func fly(points: PackedVector3Array, new_speed: float) -> void:
	waypoints = points
	speed = new_speed
	_next = 0


func _physics_process(delta: float) -> void:
	if waypoints.is_empty():
		return
	var goal := waypoints[_next]
	var offset := goal - global_position
	var step := speed * delta
	if offset.length() <= step:
		global_position = goal
		_next = (_next + 1) % waypoints.size()
	else:
		global_position += offset.normalized() * step
