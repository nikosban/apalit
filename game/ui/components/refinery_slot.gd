extends VBoxContainer
## UX round (P5) refinery slot row: title, mineral choice (with resource icons),
## Enabled switch, status line and progress bar of the current unit. It only shows what
## it is given (show_config(), show_state()) and reports the player's choices
## (mineral_chosen, enabled_toggled); the Refinery stays the only owner of the slot's
## state. Each instance keeps its own controls.

signal mineral_chosen(mineral: StringName) # &"" for none.
signal enabled_toggled(on: bool)

enum Tone { NORMAL, MUTED, WARNING }

const Inventory := preload("res://game/cargo/inventory.gd")
const ResourceIcons := preload("res://game/ui/resource_icons.gd")
const NO_MINERAL := "No mineral"
const TONE_TYPES := [&"", &"MutedLabel", &"WarningLabel"]

@export var title := "Slot"

var _minerals: Array[StringName] = []

@onready var _title: Label = $Header/Label
@onready var _mineral: OptionButton = $Header/Mineral
@onready var _enabled: CheckButton = $Header/Enabled
@onready var _status: Label = $Status
@onready var _progress: ProgressBar = $Progress


func _ready() -> void:
	_title.text = title
	_mineral.item_selected.connect(func(item: int) -> void:
		var id := _mineral.get_item_id(item)
		mineral_chosen.emit(_minerals[id - 1] if id > 0 else &""))
	_enabled.toggled.connect(func(on: bool) -> void: enabled_toggled.emit(on))


## The minerals offered (item id = index + 1; 0 = none).
func setup(minerals: Array[StringName]) -> void:
	_minerals = minerals
	_mineral.clear()
	_mineral.add_item(NO_MINERAL, 0)
	for k in minerals.size():
		_mineral.add_icon_item(ResourceIcons.icon(minerals[k]), Inventory.display_name(minerals[k]), k + 1)


## Shows the slot's configuration without emitting the player signals.
func show_config(mineral: StringName, enabled: bool) -> void:
	_mineral.select(_mineral.get_item_index(_minerals.find(mineral) + 1))
	_enabled.set_pressed_no_signal(enabled)


## Shows the slot's current status line, progress of the unit (0..1) and its tone.
func show_state(text: String, progress: float, tone: Tone) -> void:
	_status.text = text
	_status.theme_type_variation = TONE_TYPES[tone]
	_progress.value = progress
