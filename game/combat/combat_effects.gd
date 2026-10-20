extends Node3D
## Combat (migrated from the prototype): restrained functional effects (node `Effects`): muzzle flash,
## impact flash, destruction flash and (v0.3) small bursts, each a short-lived unshaded sphere that grows and
## fades, created here (never under a ship, so selection pick boxes never include them).

const MUZZLE := {"radius": 0.12, "grow": 1.6, "life": 0.09}
const IMPACT := {"radius": 0.18, "grow": 3.0, "life": 0.25}
const IMPACT_SOFT := {"radius": 0.12, "grow": 2.0, "life": 0.18}
const DESTRUCTION := {"radius": 1.0, "grow": 4.0, "life": 0.8}

var _live: Array[Dictionary] = []
static var _sphere: SphereMesh


func muzzle_flash(point: Vector3, direction: Vector3, color: Color, size: float = 1.0) -> void:
	_spawn(point + direction * 0.08 * size, color.lerp(Color(1, 0.95, 0.7), 0.6), MUZZLE, size)


func impact(point: Vector3, damaging: bool, size: float = 1.0) -> void:
	_spawn(point, Color(1.0, 0.65, 0.25) if damaging else Color(0.7, 0.75, 0.8), IMPACT if damaging else IMPACT_SOFT, size)


## Small flash of a given colour and starting radius (interceptions, self-destruction, v0.3).
func burst(point: Vector3, color: Color, radius: float) -> void:
	_spawn(point, color, {"radius": radius, "grow": 2.2, "life": 0.3})


func destruction(point: Vector3) -> void:
	_spawn(point + Vector3(0, 0.5, 0), Color(1.0, 0.5, 0.15), DESTRUCTION)


func active_count() -> int:
	return _live.size()


func _spawn(point: Vector3, color: Color, kind: Dictionary, size: float = 1.0) -> void:
	if _sphere == null:
		_sphere = SphereMesh.new()
		_sphere.radius = 1.0
		_sphere.height = 2.0
		_sphere.radial_segments = 12
		_sphere.rings = 6
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	var node := MeshInstance3D.new()
	node.mesh = _sphere
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	node.global_position = point
	node.scale = Vector3.ONE * kind.radius * size
	_live.append({"node": node, "material": material, "age": 0.0, "kind": kind, "color": color, "size": size})


func _process(delta: float) -> void:
	for entry in _live.duplicate():
		entry.age += delta
		var kind: Dictionary = entry.kind
		var share: float = entry.age / kind.life
		if share >= 1.0:
			(entry.node as Node).queue_free()
			_live.erase(entry)
			continue
		(entry.node as Node3D).scale = Vector3.ONE * kind.radius * entry.size * lerpf(1.0, kind.grow, share)
		var color: Color = entry.color
		color.a = 1.0 - share
		(entry.material as StandardMaterial3D).albedo_color = color
