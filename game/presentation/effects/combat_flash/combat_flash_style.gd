@tool
extends Resource
## Shared look of one combat flash variant (combat_flash.gd): muzzle.tres, impact.tres,
## impact_soft.tres, burst.tres, destruction.tres, used by game/combat/combat_effects.gd
## and the preview (combat_flash_preview.tscn). A flash is an unshaded sphere that grows
## linearly from `radius` to `radius` × `growth` and fades linearly to transparent over
## `lifetime`. A flash reads its style once when it starts, so a change reaches every new
## flash; flashes already playing keep the values they started with. Every change emits
## `changed`.

## Starting radius (u) at size 1. Callers scale it per flash (burst: the caller's radius).
@export_range(0.01, 10.0, 0.01, "or_greater", "suffix:u") var radius := 0.12:
	set(value):
		radius = value
		emit_changed()
## Radius at the end of the lifetime, as a multiple of the starting radius.
@export_range(0.1, 10.0, 0.05, "or_greater", "suffix:×") var growth := 1.6:
	set(value):
		growth = value
		emit_changed()
@export_range(0.01, 5.0, 0.01, "or_greater", "suffix:s") var lifetime := 0.09:
	set(value):
		lifetime = value
		emit_changed()

@export_group("Color")
## Used when the caller gives no colour (impacts, destruction); muzzle flashes and bursts
## use the caller's colour (the firing faction's, the interception's).
@export var color := Color(1, 1, 1):
	set(value):
		color = value
		emit_changed()
## The colour (caller's or `color`) is blended towards this by `blend` (muzzle flash: 0.6).
@export var blend_color := Color(1, 0.95, 0.7):
	set(value):
		blend_color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var blend := 0.0:
	set(value):
		blend = value
		emit_changed()


## The flash colour for a caller's colour (null: the style's own `color`).
func tint(caller_color: Variant = null) -> Color:
	var base: Color = color if caller_color == null else caller_color
	return base.lerp(blend_color, blend)
