extends Node3D
## Phase 2 Stage 2 mining presentation (temporary): a flickering beam from each
## extracting miner's mining equipment (bow) to the nearest point of its asteroid
## (UX round: only while it extracts, i.e. faces the asteroid).
## Reads the mining operations only.

const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const BEAM_COLOR := Color(1.0, 0.72, 0.3)
const BEAM_WIDTH := 0.18 # u
const BOW := Vector3(0.0, 0.0, -1.2) # Front face of the Miner's mining equipment, ship frame.

@export var ships_path := NodePath("../Ships")
@export var field_path := NodePath("../Asteroids")

var beam_count := 0 # Beams drawn this frame.

var _mesh := ImmediateMesh.new()
var _time := 0.0

@onready var _ships := get_node(ships_path)
@onready var _field := get_node(field_path) as AsteroidField


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var beams := MeshInstance3D.new()
	beams.mesh = _mesh
	beams.material_override = material
	beams.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beams)


func _process(delta: float) -> void:
	_time += delta
	_mesh.clear_surfaces()
	var segments := []
	for ship: Node3D in _ships.get_children():
		var mining := ship.get_node_or_null("Mining") as MiningOperation
		if mining == null or not mining.extracting: # UX round: only while facing the asteroid and extracting.
			continue
		var start := ship.global_transform * BOW
		var center := _field.center(mining.target)
		segments.append([start, center + (start - center).normalized() * _field.radius(mining.target)])
	beam_count = segments.size()
	if segments.is_empty():
		return
	var color := Color(BEAM_COLOR, 0.55 + 0.35 * sin(_time * 18.0))
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for segment: Array in segments:
		var a: Vector3 = segment[0]
		var b: Vector3 = segment[1]
		var side := (b - a).cross(Vector3.UP).normalized() * BEAM_WIDTH * 0.5
		for offset: Vector3 in [side, Vector3.UP * BEAM_WIDTH * 0.5]:
			for point: Vector3 in [a - offset, a + offset, b + offset, a - offset, b + offset, b - offset]:
				_mesh.surface_set_color(color)
				_mesh.surface_add_vertex(point)
	_mesh.surface_end()
