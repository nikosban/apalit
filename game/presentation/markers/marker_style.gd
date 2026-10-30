extends Resource
## Marker-only drawing settings. Shared interaction colors live in interaction_style.
## Geometry, picking, survey/faction palettes and contact-memory styling stay elsewhere.
## Save edits and restart F6/project; each renderer uses a deep ready-time snapshot.

@export_group("Object markers")
@export var object_outline: Color
@export var object_stroke: float
@export_group("Tactical markers")
@export var target_color: Color
@export var hulk_color: Color
@export var station_color: Color
@export var class_bar_color: Color
@export var line_width: float
@export var frame_extra_width: float
@export var fill_alpha: float
@export var asteroid_alpha: float
@export var line_alpha: float
@export var selection_alpha: float
@export var tint_lightening: float
@export var ship_fill_darkening: float
@export var station_fill_darkening: float
