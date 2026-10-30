@tool
extends Resource
## Shared hull-bar appearance. Runtime entries never write this resource.

@export var bar_size := Vector2(44, 4)
@export var world_offset := Vector3(0, 2.2, 0)
@export var background := Color(0, 0, 0, 0.6)
@export var border := Color(1, 1, 1, 0.5)
@export var border_width := 1.0
@export_range(0.0, 1.0) var faction_lightening := 0.2
@export var destroyed_color := Color(1, 0.6, 0.3)
@export var destroyed_font: Font
@export var destroyed_font_size := 12
