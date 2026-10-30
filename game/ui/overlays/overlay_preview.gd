@tool
extends Node
## One authoring scene; every visual below is a production scene instance.
const CombatShip := preload("res://game/combat/combat_ship.gd")

@export_enum("All", "HUD", "Hover tooltip", "Notice") var family := 0
@export_range(0.0, 1.0) var health_fraction := 0.6
@export_range(0.0, 1.0) var bar_alpha := 1.0
@export_multiline var inspection_text := "Target: HostileFF01\nFF01  45.0 u  -  1 of 2 weapons can engage\n   + NC-90 Bastion: Ready\n   - GCM-4 Wayfarer: No ammunition"
@export_multiline var hover_text := "Asteroid Minerals\nIron 40%\nNickel 30%\nSilicon 30%\nRemaining reserves: 3500 units"
@export var notice_text := "Destination occupied by Miner1 - moved beside it"
@export var result_text := "Scenario result"

@onready var _hud = $HUD/CombatHudView
@onready var _hover: PanelContainer = $Hover/HoverTooltip
@onready var _notice: Label = $NoticeUI/Notice


func _process(_delta: float) -> void:
	if not is_node_ready():
		return
	var area := get_viewport().get_visible_rect().size
	_hud.visible = family == 0 or family == 1
	var entries: Array[Dictionary] = []
	for i in 3:
		entries.append({"position": Vector2(area.x * (0.35 + i * 0.15), area.y * 0.35),
			"share": health_fraction, "alpha": bar_alpha, "destroyed": i == 2,
			"color": Color(CombatShip.FACTION_COLORS[i % 2].lerp(Color.WHITE, _hud.bar_style.faction_lightening), bar_alpha)})
	_hud.set_entries(entries)
	_hud.get_node("Result").text = result_text
	_hud.get_node("Speed").text = "Speed: 1x"
	var inspection: Label = _hud.get_node("Inspection")
	inspection.text = inspection_text
	inspection.position = area * Vector2(0.08, 0.65)
	inspection.visible = true
	_hover.visible = family == 0 or family == 2
	_hover.get_node("Label").text = hover_text
	_hover.reset_size()
	_hover.position = area * Vector2(0.68, 0.6)
	_notice.text = notice_text
	_notice.visible = family == 0 or family == 3


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_4:
			family = event.keycode - KEY_1
			get_viewport().set_input_as_handled()
