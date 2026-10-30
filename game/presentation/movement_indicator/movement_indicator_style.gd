@tool
extends Resource
## Shared look of the movement indicator (movement_indicator.gd), one resource:
## movement_indicator_style.tres, used by every gameplay scene and the preview. Sizes are
## physical screen px, the same at every zoom and window size; the symbol lies on the
## ground, so its sizes are its width across the screen (its height foreshortens). The
## world gap between the symbol and the lines is not here: it is the scene's
## `destination_gap_world`. Every change emits `changed`, so the renderers using this
## resource redraw (also in the editor).

@export var color := Color(0.5137255, 0.5411765, 0.5686275): # #838A91: line, arc and circle
	set(value):
		color = value
		emit_changed()

@export_group("Line")
@export_range(0.5, 8.0, 0.1, "suffix:px") var line_width_px := 2.0: # Trajectory, route and request connector
	set(value):
		line_width_px = value
		emit_changed()

@export_group("Marker")
@export_range(4.0, 96.0, 0.5, "suffix:px") var marker_diameter_px := 28.0: # Circle across the screen, at the stroke centre
	set(value):
		marker_diameter_px = value
		emit_changed()
@export_range(0.5, 8.0, 0.1, "suffix:px") var marker_stroke_px := 2.0: # Circle and arc stroke
	set(value):
		marker_stroke_px = value
		emit_changed()

@export_group("Arc")
## Diameter of the circle the detached arc is part of (it bulges towards the incoming line).
@export_range(4.0, 160.0, 0.5, "suffix:px") var arc_size_px := 28.0:
	set(value):
		arc_size_px = value
		emit_changed()
## Gap between the circle's stroke and the arc's stroke, along the incoming line.
@export_range(0.0, 48.0, 0.5, "suffix:px") var arc_offset_px := 8.0:
	set(value):
		arc_offset_px = value
		emit_changed()
@export_range(10.0, 180.0, 1.0, "suffix:°") var arc_sweep_degrees := 90.0:
	set(value):
		arc_sweep_degrees = value
		emit_changed()
