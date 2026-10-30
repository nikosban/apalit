extends Node
## F6 authoring scene: production renderers and real scene data, no duplicate drawing.
## Save interaction_style.tres / marker_style.tres, then restart F6 to apply appearance.
const Arena := preload("res://main.tscn")
const Warship := preload("res://game/ships/ff01_unit.tscn")

@export_enum("All", "Selection ring / drag", "World highlight", "Object markers", "Tactical markers") var family := 0
@export var zoom_distance := 40.0
@export var sample_hover := true

var _arena: Node3D


func _ready() -> void:
	process_priority = 100 # Visibility controls run after the production presenters.
	_arena = Arena.instantiate()
	_arena.scenario_keys = false
	_arena.get_node("Asteroids").session_seed = 20261030
	var ship: Node3D = Warship.instantiate()
	ship.name = "FF01"
	ship.position = Vector3(0, 1.5, -8)
	_arena.get_node("Ships").add_child(ship)
	add_child(_arena)
	_arena.get_node("Ships/Transporter/Locomotion").place(Vector2(12, -8), 0.0)
	_freeze_physics(_arena)
	_arena.get_node("Selection").set_selection([_arena.get_node("Ships/Miner1"), ship])
	_zoom(zoom_distance)


func _freeze_physics(node: Node) -> void:
	node.set_physics_process(false)
	for child in node.get_children():
		_freeze_physics(child)


func _zoom(distance: float) -> void:
	var rig = _arena.get_node("CameraRig")
	rig.global_position = Vector3.ZERO
	rig.zoom_distance = distance
	rig._apply_zoom()


func _process(_delta: float) -> void:
	var selection = _arena.get_node("Selection")
	selection.visible = family == 0 or family == 1
	selection._box.self_modulate.a = 1.0 if family == 0 or family == 1 else 0.0
	var highlight = _arena.get_node("WorldHighlight")
	if sample_hover and get_viewport().gui_get_hovered_control() == null:
		var camera := get_viewport().get_camera_3d()
		highlight.update(camera.unproject_position(_arena.get_node("Ships/Transporter").global_position), true)
	for target in highlight.highlighted().keys():
		if family == 0 or family == 2:
			highlight._set_style(target, highlight.style_of(target))
		elif target.get_parent() == _arena.get_node("Asteroids"):
			highlight._set_asteroid(target, null)
		else:
			for mesh: MeshInstance3D in target.find_children("*", "MeshInstance3D", true, false):
				if not mesh.mesh is ImmediateMesh:
					mesh.material_overlay = null
	_arena.get_node("ObjectMarkers")._overlay.visible = family == 0 or family == 3
	_arena.markers.visible = family == 0 or family == 4


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_5:
			family = event.keycode - KEY_1
			if family > 0:
				_zoom(100.0 if family == 4 else 20.0)
		elif event.keycode >= KEY_6 and event.keycode <= KEY_9:
			_zoom([5.0, 40.0, 100.0, 150.0][event.keycode - KEY_6])
		elif event.keycode == KEY_0:
			_zoom(150.0)
			if _arena.strategic.is_active():
				_arena.strategic.exit()
			else:
				_arena.strategic.enter()
