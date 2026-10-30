extends Resource
## Shared fallback bars only. Weapon-supplied meshes retain their own appearance.
## Save the .tres and restart F6/game to apply. Faction colors belong to CombatShip.

@export_group("Bar dimensions (world units)")
@export var shell_size := Vector3(0.07, 0.07, 0.55)
@export var tracer_size := Vector3(0.045, 0.045, 1.6)

@export_group("Faction tint treatment")
@export_range(0.0, 1.0) var shell_white_mix := 0.55
@export_range(0.0, 1.0) var other_white_mix := 0.35
@export var tracer_warm_color := Color(1.0, 0.85, 0.45)
@export_range(0.0, 1.0) var tracer_warm_mix := 0.45


func size_for(style: StringName) -> Vector3:
	return tracer_size if style == &"tracer" else shell_size


func tint_for(faction_color: Color, style: StringName) -> Color:
	var color := faction_color.lerp(Color.WHITE, shell_white_mix if style == &"shell" else other_white_mix)
	return color.lerp(tracer_warm_color, tracer_warm_mix) if style == &"tracer" else color
