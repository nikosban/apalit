@tool
extends Control
## Authoring scene of the movement indicator (open movement_indicator_preview.tscn; F6 to
## run). It instances the production renderer (movement_indicator.tscn) with the shared
## style and feeds it synthetic orders through the same set_entries() as the gameplay
## scenes; no simulation runs.
##
## Global look: select View/Viewport/MovementIndicator and edit its `style`, or open
## movement_indicator_style.tres directly. That one resource is used by every gameplay
## scene; the editor view redraws at once, and F6 shows the saved values.
##
## Sample orders: each child of View/Viewport/Orders is one ship (`Ship`, its model) with a
## `Destination` marker, optionally a `Requested` marker (the connector) and `Via*`
## markers (route points, drawn in the Strategic pose). Move them in the editor to try
## other shapes. In the editor the rig camera shows its authored pose (zoom 15).
## Run time: 1 zoom 5 (Local), 2 zoom 40, 3 zoom 150 (Tactical), 4 Strategic scale
## (top-down, routes, cross-faded over `handoff_time`); the wheel, W/A/S/D, Q/E and
## middle drag move the production camera rig.

enum Pose { LOCAL_5, ZOOM_40, TACTICAL_150, STRATEGIC }
const POSE_ZOOM := [5.0, 40.0, 150.0]

@export var pose := Pose.ZOOM_40:
	set(value):
		pose = value
		if is_node_ready():
			_apply_pose()
## World gap between the symbol and its lines; the gameplay scenes' own value is
## `destination_gap_world` on their root (movement_lab.gd). Preview only.
@export var destination_gap_world := 0.25
@export var handoff_time := 0.45 # s, the route cross-fade at run time (as the Strategic handoff)

var _route_blend := 0.0

@onready var _rig = $View/Viewport/CameraRig
@onready var _strategic_camera: Camera3D = $View/Viewport/StrategicCamera
@onready var _indicator = $View/Viewport/MovementIndicator
@onready var _orders: Node3D = $View/Viewport/Orders


func _ready() -> void:
	_apply_pose()


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var index := [KEY_1, KEY_2, KEY_3, KEY_4].find(key.physical_keycode)
	if index >= 0:
		pose = index as Pose


func _process(delta: float) -> void:
	var target := 1.0 if pose == Pose.STRATEGIC else 0.0
	if Engine.is_editor_hint() or handoff_time <= 0.0:
		_route_blend = target
	else:
		_route_blend = move_toward(_route_blend, target, delta / handoff_time)
	_indicator.destination_gap_world = destination_gap_world
	_indicator.set_entries(_entries(), smoothstep(0.0, 1.0, _route_blend))


func _apply_pose() -> void:
	var strategic := pose == Pose.STRATEGIC
	_strategic_camera.current = strategic
	(_rig.get_node("Camera3D") as Camera3D).current = not strategic
	if not strategic and not Engine.is_editor_hint():
		_rig.max_zoom = POSE_ZOOM[Pose.TACTICAL_150]
		_rig.zoom_distance = POSE_ZOOM[pose]
		_rig._apply_zoom()


# The sample orders as renderer entries (world X/Z).
func _entries() -> Array:
	var entries := []
	for order: Node3D in _orders.get_children():
		var ship := order.get_node_or_null("Ship") as Node3D
		var destination := order.get_node_or_null("Destination") as Node3D
		if ship == null or destination == null:
			continue
		var entry := {"from": _planar(ship), "destination": _planar(destination)}
		var requested := order.get_node_or_null("Requested") as Node3D
		if requested != null:
			entry.requested = _planar(requested)
		var route := PackedVector2Array([entry.from])
		for child in order.get_children():
			if child.name.begins_with("Via"):
				route.append(_planar(child))
		if route.size() > 1:
			route.append(entry.destination)
			entry.route = route
		entries.append(entry)
	return entries


func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)
