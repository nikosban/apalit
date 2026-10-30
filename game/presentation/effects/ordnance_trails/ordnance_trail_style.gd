extends Resource
## Shared ribbon appearance. Save the .tres and restart F6/game to apply.
## Sampling, age, lifetime and reveal rules belong to the production renderers.

@export_group("Widths (world units)")
@export_range(0.0, 2.0, 0.001, "or_greater") var torpedo_width := 0.14
@export_range(0.0, 2.0, 0.001, "or_greater") var missile_width := 0.1
@export_range(0.0, 2.0, 0.001, "or_greater") var fallback_width := 0.1

@export_group("Colors (RGB; opacity is separate)")
@export var torpedo_color := Color(1.0, 0.78, 0.5)
@export var missile_color := Color(0.85, 0.92, 1.0)
@export var fallback_color := Color.WHITE

@export_group("Ribbon shape")
@export_range(0.0, 1.0) var opacity := 0.75
@export_range(0.0, 1.0) var tail_width_ratio := 0.25


func width_for(kind: StringName) -> float:
	match kind:
		&"torpedo": return torpedo_width
		&"missile": return missile_width
	return fallback_width


func color_for(kind: StringName) -> Color:
	match kind:
		&"torpedo": return torpedo_color
		&"missile": return missile_color
	return fallback_color
