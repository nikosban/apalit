extends Node3D
## Navigation Debug drawing for the active ship: navigable-area boundary of its
## planning radius, its route, and its lookahead aim point. Visual only.

const RouteFollower := preload("res://game/navigation/route_follower.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const LINE_HEIGHT := 0.05
const BOUNDARY_COLOR := Color(0.85, 0.4, 0.3)
const ROUTE_COLOR := Color(0.3, 0.9, 1.0)

@export var navigation_path := NodePath("../StaticNavigation")

var follower: RouteFollower = null

var _boundary_radius := -1.0
var _boundary: MeshInstance3D
var _route: MeshInstance3D
var _aim: MeshInstance3D

@onready var _navigation := get_node(navigation_path) as StaticNavigation


func _ready() -> void:
	visible = false
	_boundary = _line_instance(BOUNDARY_COLOR)
	_route = _line_instance(ROUTE_COLOR)
	_aim = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	_aim.mesh = sphere
	_aim.material_override = _route.material_override
	_aim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_boundary)
	add_child(_route)
	add_child(_aim)


func _process(_delta: float) -> void:
	if not visible:
		return
	_boundary.visible = follower != null
	_route.visible = follower != null
	_aim.visible = follower != null and follower.status == RouteFollower.RouteStatus.ROUTE
	if follower == null:
		return
	if follower.planning_radius() != _boundary_radius:
		_boundary_radius = follower.planning_radius()
		_draw_boundary(_navigation.boundary_segments(_boundary_radius))
	_draw_route()
	_aim.global_position = Vector3(follower.aim_point.x, LINE_HEIGHT, follower.aim_point.y)


func _draw_boundary(segments: PackedVector2Array) -> void:
	var mesh := _boundary.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if segments.is_empty():
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for point in segments:
		mesh.surface_add_vertex(Vector3(point.x, LINE_HEIGHT, point.y))
	mesh.surface_end()


# Route from its current segment on, plus the ship-to-aim line while following.
func _draw_route() -> void:
	var mesh := _route.mesh as ImmediateMesh
	mesh.clear_surfaces()
	var route := follower.route
	var showing := follower.status == RouteFollower.RouteStatus.ROUTE or follower.status == RouteFollower.RouteStatus.DIRECT
	if not showing or route.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(follower.segment, route.size() - 1):
		mesh.surface_add_vertex(Vector3(route[i].x, LINE_HEIGHT, route[i].y))
		mesh.surface_add_vertex(Vector3(route[i + 1].x, LINE_HEIGHT, route[i + 1].y))
	if follower.status == RouteFollower.RouteStatus.ROUTE:
		var ship := follower.get_parent() as Node3D
		mesh.surface_add_vertex(Vector3(ship.global_position.x, LINE_HEIGHT, ship.global_position.z))
		mesh.surface_add_vertex(Vector3(follower.aim_point.x, LINE_HEIGHT, follower.aim_point.y))
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
