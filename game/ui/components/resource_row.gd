extends HBoxContainer
## UX round (P7) resource row of the transport editor: icon and name, the units aboard
## (read-only), the requested amount (typed text counts at once), Units / % and Clear.
## It shows what it is given (show_request(), show_onboard()) and reports the player's
## edits (edited, cleared) to its owner's draft; it never changes a transport itself.

signal edited(amount: int, as_percent: bool)
signal cleared

const Inventory := preload("res://game/cargo/inventory.gd")
const ResourceIcons := preload("res://game/ui/resource_icons.gd")

var resource := &""

var _showing := false # Values are being shown: no edit signal from them.
var _capacity := 1000

@onready var _icon: TextureRect = $Icon
@onready var _name: Label = $Name
@onready var _onboard: Label = $Onboard
@onready var _amount: SpinBox = $Amount
@onready var _mode = $Mode # SegmentedControl: Units, %
@onready var _clear: Button = $Clear


func _ready() -> void:
	_mode.setup(["Units", "%"])
	_amount.value_changed.connect(func(_value: float) -> void: _emit_edit())
	_mode.selected_changed.connect(func(_index: int) -> void:
		if _mode.selected == 1 and _amount.value > 100:
			_showing = true
			_amount.max_value = 100 # Switching to % keeps the number, capped at 100.
			_showing = false
		_set_limit()
		_emit_edit())
	_clear.pressed.connect(func() -> void: cleared.emit())


func setup(new_resource: StringName, capacity: int) -> void:
	resource = new_resource
	_capacity = capacity
	_icon.texture = ResourceIcons.icon(resource)
	_name.text = Inventory.display_name(resource)
	tooltip_text = _name.text


## Shows a requested amount and its mode without emitting `edited`.
func show_request(amount: int, as_percent: bool) -> void:
	_showing = true
	_mode.select(1 if as_percent else 0)
	_set_limit()
	_amount.set_value_no_signal(amount)
	_amount.get_line_edit().text = str(amount)
	_showing = false


func show_onboard(units: int) -> void:
	_onboard.text = str(units)


func _set_limit() -> void:
	_amount.max_value = 100 if _mode.selected == 1 else _capacity


func _emit_edit() -> void:
	if not _showing:
		edited.emit(int(_amount.value), _mode.selected == 1)
