@tool
extends Node3D
## Combat (migrated from the prototype): restrained functional effects (node `Effects`): muzzle flash,
## impact flash, destruction flash and (v0.3) small bursts, each a short-lived unshaded sphere that grows and
## fades: one combat_flash.tscn per flash with a shared preset, created here (never under a ship, so selection
## pick boxes never include them). The look and timing live in the presets (edit them once for every scene);
## positions, offsets and caller colours and sizes stay here. `@tool` only for the flash preview
## (game/presentation/effects/combat_flash/combat_flash_preview.tscn); nothing runs here on its own.

const FLASH := preload("res://game/presentation/effects/combat_flash/combat_flash.tscn")

@export var muzzle_style: Resource = preload("res://game/presentation/effects/combat_flash/muzzle.tres")
@export var impact_style: Resource = preload("res://game/presentation/effects/combat_flash/impact.tres")
@export var impact_soft_style: Resource = preload("res://game/presentation/effects/combat_flash/impact_soft.tres")
@export var burst_style: Resource = preload("res://game/presentation/effects/combat_flash/burst.tres")
@export var destruction_style: Resource = preload("res://game/presentation/effects/combat_flash/destruction.tres")

var _live: Array[Node] = []


func muzzle_flash(point: Vector3, direction: Vector3, color: Color, size: float = 1.0) -> void:
	_spawn(muzzle_style, point + direction * 0.08 * size, size, color)


func impact(point: Vector3, damaging: bool, size: float = 1.0) -> void:
	_spawn(impact_style if damaging else impact_soft_style, point, size)


## Small flash of a given colour and starting radius (interceptions, self-destruction, v0.3).
func burst(point: Vector3, color: Color, radius: float) -> void:
	_spawn(burst_style, point, radius, color)


func destruction(point: Vector3) -> void:
	_spawn(destruction_style, point + Vector3(0, 0.5, 0))


func active_count() -> int:
	return _live.size()


func _spawn(style: Resource, point: Vector3, size: float = 1.0, color: Variant = null) -> void:
	var flash := FLASH.instantiate()
	add_child(flash)
	flash.play(style, point, size, color)
	_live.append(flash)
	flash.expired.connect(_live.erase.bind(flash))
