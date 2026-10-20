extends HBoxContainer
## UX round (P7) segmented control: toggle buttons of which exactly one is selected (a
## ButtonGroup), theme type SegmentButton. Shows what it is given (select()) and reports
## the player's choice (selected_changed). A segment can be disabled with a tooltip
## (e.g. a not yet implemented choice).

signal selected_changed(index: int)

var selected := 0

var _group := ButtonGroup.new()
var _buttons: Array[Button] = []


## The segments' labels (rebuilds the buttons; the first is selected).
func setup(labels: Array) -> void:
	for button in _buttons:
		button.queue_free()
	_buttons.clear()
	for i in labels.size():
		var button := Button.new()
		button.text = labels[i]
		button.toggle_mode = true
		button.button_group = _group
		button.focus_mode = Control.FOCUS_NONE
		button.theme_type_variation = &"SegmentButton"
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggled.connect(func(on: bool) -> void:
			if on and selected != i:
				selected = i
				selected_changed.emit(i))
		add_child(button)
		_buttons.append(button)
	select(0)


## Selects a segment without emitting selected_changed.
func select(index: int) -> void:
	selected = index
	_buttons[index].set_pressed_no_signal(true)
	for i in _buttons.size():
		if i != index:
			_buttons[i].set_pressed_no_signal(false)


func set_segment_disabled(index: int, disabled: bool, tooltip := "") -> void:
	_buttons[index].disabled = disabled
	_buttons[index].tooltip_text = tooltip


func button(index: int) -> Button:
	return _buttons[index]
