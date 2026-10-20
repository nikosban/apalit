extends Node3D
## Avoidance Debug drawing: every ship's footprint (bounding circle; red while it
## overlaps another ship's), and for the active ship its steering line to the
## avoidance target while passing (orange) and its predicted closest approach to
## the nearest-threatening ship in range (yellow: both predicted positions). The
## footprint is also the collision circle; the active ship's collision contacts are
## drawn as a small ring at the contact point and its normal (magenta). Visual only.

const ShipAvoidance := preload("res://game/avoidance/ship_avoidance.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const LINE_HEIGHT := 0.08
const RING_SEGMENTS := 48
const FOOTPRINT_COLOR := Color(0.75, 0.78, 0.8)
const CONTACT_COLOR := Color(1.0, 0.25, 0.2)
const TARGET_COLOR := Color(1.0, 0.55, 0.15)
const CLOSEST_COLOR := Color(1.0, 0.9, 0.2)
const COLLISION_COLOR := Color(1.0, 0.3, 0.9)
const NORMAL_LENGTH := 2.0 # u

@export var ships_path := NodePath("../Ships")

var avoidance: ShipAvoidance = null

var _footprints: MeshInstance3D
var _contacts: MeshInstance3D
var _target_line: MeshInstance3D
var _closest_line: MeshInstance3D
var _collision_lines: MeshInstance3D

@onready var _ships := get_node(ships_path)


func _ready() -> void:
	visible = false
	_footprints = _line_instance(FOOTPRINT_COLOR)
	_contacts = _line_instance(CONTACT_COLOR)
	_target_line = _line_instance(TARGET_COLOR)
	_closest_line = _line_instance(CLOSEST_COLOR)
	_collision_lines = _line_instance(COLLISION_COLOR)
	for instance in [_footprints, _contacts, _target_line, _closest_line, _collision_lines]:
		add_child(instance)


func _process(_delta: float) -> void:
	if not visible:
		return
	var normal := []
	var touching := []
	var ships := _ships.get_children()
	for ship: Node3D in ships:
		var radius: float = (ship.get_node("RouteFollower") as RouteFollower).ship_radius
		var center := Vector2(ship.global_position.x, ship.global_position.z)
		var overlapping := false
		for other: Node3D in ships:
			if other != ship and center.distance_to(Vector2(other.global_position.x, other.global_position.z)) < radius + (other.get_node("RouteFollower") as RouteFollower).ship_radius:
				overlapping = true
		_add_ring(touching if overlapping else normal, center, radius)
	_draw(_footprints, normal)
	_draw(_contacts, touching)
	var target_points := []
	var closest_points := []
	var collision_points := []
	if avoidance != null:
		var ship := avoidance.get_parent() as Node3D
		for contact: Dictionary in ship.get_node("Locomotion").contacts:
			_add_ring(collision_points, contact.point, 0.3)
			collision_points.append(_point(contact.point))
			collision_points.append(_point(contact.point + (contact.normal as Vector2) * NORMAL_LENGTH))
		if avoidance.state == ShipAvoidance.State.PASSING:
			target_points.append(Vector3(ship.global_position.x, LINE_HEIGHT, ship.global_position.z))
			target_points.append(_point(avoidance.target))
			_add_ring(target_points, avoidance.target, 0.4)
		if avoidance.closest_points.size() == 2:
			closest_points.append(_point(avoidance.closest_points[0]))
			closest_points.append(_point(avoidance.closest_points[1]))
			_add_ring(closest_points, avoidance.closest_points[0], 0.5)
			_add_ring(closest_points, avoidance.closest_points[1], 0.5)
	_draw(_target_line, target_points)
	_draw(_closest_line, closest_points)
	_draw(_collision_lines, collision_points)


# Array (not a packed array): appended in place.
func _add_ring(points: Array, center: Vector2, radius: float) -> void:
	for i in RING_SEGMENTS:
		points.append(_point(center + Vector2.from_angle(TAU * i / RING_SEGMENTS) * radius))
		points.append(_point(center + Vector2.from_angle(TAU * (i + 1) / RING_SEGMENTS) * radius))


static func _point(point: Vector2) -> Vector3:
	return Vector3(point.x, LINE_HEIGHT, point.y)


static func _draw(instance: MeshInstance3D, points: Array) -> void:
	var mesh := instance.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if points.is_empty():
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for point: Vector3 in points:
		mesh.surface_add_vertex(point)
	mesh.surface_end()


static func _line_instance(color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance
