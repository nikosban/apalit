@tool
extends MeshInstance3D
## Combat flash (combat_flash.tscn): the one renderer of every combat flash (muzzle, impact,
## burst, destruction), instanced by game/combat/combat_effects.gd under the scene's
## `Effects` node (never under a ship, so selection pick boxes never include it) and by the
## preview. play() starts it with a shared style (combat_flash_style.gd) and per-flash
## position, colour and size; it then grows and fades on its own, emits `expired` at the
## end of the style's lifetime and frees itself. It processes in idle frames and inherits
## its parent's process mode, so it stops with the simulation pause.
##
## The sphere mesh is shared by every flash; the material is local to the scene, so each
## flash writes only its own copy and never the shared style or another flash.

signal expired

var _radius := 0.0
var _growth := 1.0
var _lifetime := 1.0
var _color := Color.WHITE
var _age := 0.0


## Starts the flash at `point` (global; the flash must be in the tree). `size` scales the
## style's radius; `color` replaces the style's own colour (null keeps it).
func play(style: Resource, point: Vector3, size: float = 1.0, color: Variant = null) -> void:
	_radius = style.radius * size
	_growth = style.growth
	_lifetime = style.lifetime
	_color = style.tint(color)
	_age = 0.0
	global_position = point
	_apply(0.0)
	set_process(true)


func age() -> float:
	return _age


func current_color() -> Color:
	return (material_override as StandardMaterial3D).albedo_color


func _ready() -> void:
	set_process(false) # Until play().


func _process(delta: float) -> void:
	_age += delta
	var share := _age / _lifetime
	if share >= 1.0:
		set_process(false)
		expired.emit()
		queue_free()
		return
	_apply(share)


func _apply(share: float) -> void:
	scale = Vector3.ONE * _radius * lerpf(1.0, _growth, share)
	var tint := _color
	tint.a = 1.0 - share
	(material_override as StandardMaterial3D).albedo_color = tint
