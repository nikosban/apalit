extends Resource
## Shared interaction appearance. Save edits, then restart preview/game to apply.
## Renderers deep-copy this resource at ready; late registrations use that snapshot.

@export_group("Interaction colors")
@export var selected_color: Color
@export var selection_indicator_color: Color
@export var highlight_hover_color: Color
@export var object_hover_color: Color
@export_group("World highlight")
@export var hover_fill_alpha: float
@export var selected_fill_alpha: float
@export var hover_outline_alpha: float
@export var selected_outline_alpha: float
@export var hover_outline_pixels: float
@export var selected_outline_pixels: float
@export_group("Selection ring")
@export var ring_padding: float
@export var ring_width: float
@export var ring_height: float
@export var ring_flattening: float
@export_group("Drag rectangle")
@export var drag_box: StyleBoxFlat
