@tool
extends Control
## Presentation only: projected screen positions, fractions, colors and alpha.
## No ship, camera or arena references; one drawing surface for every entry.

const HullBarStyle := preload("res://game/ui/overlays/combat_hud/hull_bar_style.gd")
@export var bar_style: HullBarStyle = preload("res://game/ui/overlays/combat_hud/hull_bar_style.tres")
@export var cursor_offset := Vector2(18, 18)
@export var edge_margin := 8.0

var _entries: Array[Dictionary] = []


func set_entries(entries: Array[Dictionary]) -> void:
	_entries = entries
	queue_redraw()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		queue_redraw()


func _draw() -> void:
	for entry: Dictionary in _entries:
		var origin: Vector2 = entry.position - Vector2(bar_style.bar_size.x * 0.5, 0)
		var alpha: float = entry.alpha
		if entry.destroyed:
			var font: Font = bar_style.destroyed_font if bar_style.destroyed_font != null else ThemeDB.fallback_font
			draw_string(font, origin, "DESTROYED", HORIZONTAL_ALIGNMENT_LEFT, -1,
				bar_style.destroyed_font_size, Color(bar_style.destroyed_color, bar_style.destroyed_color.a * alpha))
			continue
		draw_rect(Rect2(origin, bar_style.bar_size), Color(bar_style.background, bar_style.background.a * alpha))
		draw_rect(Rect2(origin, Vector2(bar_style.bar_size.x * entry.share, bar_style.bar_size.y)), entry.color)
		draw_rect(Rect2(origin, bar_style.bar_size), Color(bar_style.border, bar_style.border.a * alpha), false, bar_style.border_width)
