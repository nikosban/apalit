extends "res://game/ui/combat_hud.gd"
## Combat test fixture HUD: the production combat HUD plus, for watching the encounters,
## the scenario name and conditions (top centre), the selected ship's combat text
## (bottom left; production shows it in the ship panel) and the fixture's controls.

const CONTROLS := "Left-click select  |  Right-click ground: move  |  Right-click hostile: target\nT choose target (slows time)  |  Hold Alt: weapon ranges  |  G grid\nSpace pause  |  - / = speed  |  F1 Passive  F2 Defensive  F3 Aggressive\nBackspace clear target  |  C toggle contact (hostile under cursor)\nCtrl+right-click hostile Attack / friendly Guard / ground Attack-Move  |  Shift+right-click waypoint  |  X cancel  |  P weapon profile\nF10 debug"

var _info: Label
var _controls: Label
var _title: Label


func _ready() -> void:
	super._ready()
	_info = _label(Control.PRESET_BOTTOM_LEFT, Vector2(12, -12), 14)
	_info.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_controls = _label(Control.PRESET_BOTTOM_RIGHT, Vector2(-12, -12), 12)
	_controls.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_controls.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_controls.text = CONTROLS
	_title = _label(Control.PRESET_CENTER_TOP, Vector2(0, 96), 14)
	_title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _process(delta: float) -> void:
	super._process(delta)
	_title.text = _arena.scenario_name + ("\nScenario conditions:\n" + "\n".join(_arena.conditions) if not _arena.conditions.is_empty() else "")
	var selected: Array = _arena.selection().selected
	_info.text = describe(selected[0]) if selected.size() == 1 else ("%d ships selected" % selected.size() if selected.size() > 1 else "")
