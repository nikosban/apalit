extends PanelContainer
## UX round (P6) panel shell: the frame of the selection panels, on the right side of
## the screen above its bottom edge, at a fixed width. A header (Layout/Header) stays at
## the top and an optional footer (Layout/Footer, hidden unless used) at the bottom; the
## body (Layout/Scroll/Body) scrolls inside the shell once it is taller than the screen
## allows, so content never resizes the shell beyond its bounds. Its owner fills them
## and only shows or hides the shell. The shell takes the mouse over its whole area
## (clicks and wheel there do not reach the world; the wheel scrolls). P7: `right_offset`
## places a secondary panel (the transport editor) beside another one.

@export var width := 340.0 # px
@export var margin := 16.0 # px from the screen's right and bottom edges
@export var right_offset := 0.0 # px further from the right edge (a panel beside another)
@export var top_reserve := 96.0 # px kept free above the shell (notices)

@onready var _scroll: ScrollContainer = $Layout/Scroll
@onready var _body: Control = $Layout/Scroll/Body


func _process(_delta: float) -> void:
	if visible:
		fit()


## Sizes the shell to its content within the screen, anchored bottom right.
func fit() -> void:
	var chrome := get_combined_minimum_size().y - _scroll.custom_minimum_size.y # Header, footer, frame and spacing.
	var room := maxf(get_viewport_rect().size.y - margin - top_reserve, chrome)
	var height := minf(chrome + _body.get_combined_minimum_size().y, room)
	_scroll.custom_minimum_size.y = height - chrome
	offset_right = -margin - right_offset
	offset_left = -margin - right_offset - width
	offset_bottom = -margin
	offset_top = -margin - height
