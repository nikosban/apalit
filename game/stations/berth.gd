@tool
extends Node3D
## Phase 2.5 station docking stage 2a: one berth of a station, authored in the scene
## editor. Passive: production docking does not use it yet (stage 2b).
## The node's origin is the hub-side edge centre of the berth's parking rectangle and
## its +Z the berth's outward axis; `slot_size` = (length along the axis, width).
## Marker3D children, all on the X/Z plane:
## - ParkStop: the stop line a parked ship's collision circle touches; its -Z is the
##   final heading (bow toward the station);
## - Handover: the berth mouth; the handover point lies outside it on the axis by the
##   ship's radius + `handover_margin`;
## - ExitBack: the line a straight back-out clears by the radius + `exit_margin`;
## - ExitA / ExitB: the departure end points (sides +1 / -1), fixed, authored for the
##   largest supported ship.
## Only the ship's radius shifts the authored points, along the axis. The queries are
## read-only. In the editor the rectangle is drawn (a preview child that is never
## saved and never created in the game).

const PREVIEW_COLOR := Color(0.95, 0.85, 0.2)

@export var slot_size := Vector2(14.4, 13.4): # u: length along the axis, width.
	set(value):
		slot_size = value
		_update_preview()
@export var handover_margin := 1.0 # u between the rectangle and a ship's circle at the handover point.
@export var exit_margin := 1.0 # u between ExitBack and a backing-out ship's circle.

var _preview: MeshInstance3D


func _ready() -> void:
	_update_preview()


## Outward axis on the plane.
func axis() -> Vector2:
	return Vector2(global_basis.z.x, global_basis.z.z).normalized()


## Gap between a point and the parking rectangle (negative inside).
func rect_gap(point: Vector2) -> float:
	var relative := point - _planar(global_position)
	var along := relative.dot(axis()) - slot_size.x * 0.5
	var lateral := relative.dot(Vector2(-axis().y, axis().x))
	var d := Vector2(absf(along), absf(lateral)) - slot_size * 0.5
	return Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() + minf(maxf(d.x, d.y), 0.0)


## A collision circle at `point` overlaps the rectangle.
func overlaps(point: Vector2, radius: float) -> bool:
	return rect_gap(point) < radius


## The rectangle's corners (planar).
func corners() -> PackedVector2Array:
	var start := _planar(global_position)
	var along := axis() * slot_size.x
	var side := Vector2(-axis().y, axis().x) * slot_size.y * 0.5
	return PackedVector2Array([start + side, start + along + side, start + along - side, start - side])


func park_point(ship_radius: float) -> Vector2:
	return _marker("ParkStop") + axis() * ship_radius


## Final heading (Locomotion convention, bow = -Z of ParkStop).
func park_heading() -> float:
	return (get_node("ParkStop") as Node3D).global_rotation.y


func handover_point(ship_radius: float) -> Vector2:
	return _marker("Handover") + axis() * (ship_radius + handover_margin)


## Guided legs from the handover point: turn to the final heading, straight in.
func entry_legs(ship_radius: float) -> Array:
	return [{"turn": park_heading()}, {"move": park_point(ship_radius), "reverse": false}]


## Guided legs out of the berth to side +1 (ExitA) or -1 (ExitB): straight back past
## ExitBack, turn toward the exit point, forward to it.
func exit_legs(ship_radius: float, side: int) -> Array:
	var back := _marker("ExitBack") + axis() * (ship_radius + exit_margin)
	var exit := _marker("ExitA" if side > 0 else "ExitB")
	var direction := exit - back
	return [{"move": back, "reverse": true}, {"turn": atan2(-direction.x, -direction.y)}, {"move": exit, "reverse": false}]


func _marker(marker: String) -> Vector2:
	return _planar((get_node(marker) as Node3D).global_position)


# Editor only: the rectangle as lines at the berth's height.
func _update_preview() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _preview == null:
		_preview = MeshInstance3D.new()
		_preview.mesh = ImmediateMesh.new()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = PREVIEW_COLOR
		_preview.material_override = material
		add_child(_preview) # No owner: never saved with the scene.
	var mesh := _preview.mesh as ImmediateMesh
	mesh.clear_surfaces()
	var half := slot_size.y * 0.5
	var points := [Vector3(half, 0, 0), Vector3(half, 0, slot_size.x), Vector3(-half, 0, slot_size.x), Vector3(-half, 0, 0)]
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for k in 4:
		mesh.surface_add_vertex(points[k])
		mesh.surface_add_vertex(points[(k + 1) % 4])
	mesh.surface_end()


static func _planar(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)
