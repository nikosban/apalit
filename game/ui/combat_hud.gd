extends CanvasLayer
## Combat screen feedback (node `CombatHUD`, combat migration; the per-ship information is
## in the ship panel, not here):
##   - a hull bar over every ship the player may see (faction colour; "DESTROYED" over a
##     hulk; they fade out as the tactical markers fade in (1 - emphasis), so none at
##     full Tactical emphasis, where the markers carry the ships);
##   - top right, the simulation speed (TimeControl: "Speed: 1x", "PAUSED", ...) and, while
##     attack-target selection is open, its hint;
##   - during target selection, beside the cursor, the hostile under it with each selected
##     ship's weapons that can and cannot engage it and why (Weapon.assess());
##   - the scene's `result_text`, centred, when it has one (a scenario's battle result).
## The static texts are shared with the ship panel and the combat debug overlay.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const DisplayName := preload("res://game/ui/display_name.gd")
const BAR_SIZE := Vector2(44, 4) # px at 1080 lines
const TARGET_HINT := "Choose a target: click a hostile ship  |  Esc or right-click elsewhere cancels"

var _bars: Control
var _result: Label
var _speed: Label # Simulation speed (TimeControl) and the target-selection hint.
var _inspect: Label # Target eligibility at the cursor during target selection.

@onready var _arena := get_parent()


func _ready() -> void:
	layer = 1
	_bars = Control.new()
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bars.draw.connect(_draw_bars)
	add_child(_bars)
	_result = _label(Control.PRESET_CENTER, Vector2.ZERO, 24)
	_result.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_result.grow_vertical = Control.GROW_DIRECTION_BOTH
	_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed = _label(Control.PRESET_TOP_RIGHT, Vector2(-12, 12), 18)
	_speed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_inspect = _label(Control.PRESET_TOP_LEFT, Vector2.ZERO, 13)
	_inspect.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.08, 0.085, 0.09, 0.85)
	panel.border_color = Color(0.5, 0.52, 0.55, 0.8)
	panel.set_border_width_all(1)
	panel.set_content_margin_all(6)
	_inspect.add_theme_stylebox_override("normal", panel)
	_inspect.visible = false


func _label(preset: Control.LayoutPreset, offset: Vector2, size: int) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_and_offsets_preset(preset)
	label.position += offset
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	add_child(label)
	return label


func _process(_delta: float) -> void:
	_bars.queue_redraw()
	var result: Variant = _arena.get("result_text")
	_result.text = result if result is String else ""
	var time_control = _arena.get("time_control")
	if time_control != null:
		_speed.text = "Speed: %s%s" % [time_control.label(), "\n" + TARGET_HINT if _arena.target_selection else ""]
	_update_inspection(_arena.selection().selected)


# Target selection: the hostile under the cursor, with each selected ship's weapons that
# can and cannot engage it and why (Weapon.assess(), the firing authorization's checks).
func _update_inspection(selected: Array) -> void:
	_inspect.visible = false
	if not _arena.get("target_selection") or selected.is_empty():
		return
	var mouse: Vector2 = _arena.pointer if _arena.pointer.x >= 0.0 else _arena.get_viewport().get_mouse_position()
	var picked: Node3D = _arena.selection().pick_any(mouse)
	var target = CombatShip.of(picked)
	if target == null or not target.alive or target.faction == CombatShip.of(selected[0]).faction:
		return
	if _arena.has_method("player_sees") and not _arena.player_sees(picked):
		return
	_inspect.text = inspect_text(selected, picked)
	_inspect.reset_size()
	var area := _arena.get_viewport().get_visible_rect().size
	var at := mouse + Vector2(18, 18)
	if at.x + _inspect.size.x > area.x - 8.0:
		at.x = mouse.x - 18.0 - _inspect.size.x # flip to the cursor's left near the edge
	at.y = clampf(at.y, 8.0, maxf(8.0, area.y - _inspect.size.y - 8.0))
	_inspect.position = at
	_inspect.visible = true


## Target-selection readout (also used by tests): the target, then per selected ship its
## distance and every weapon as "+ can engage" or "- cannot engage: reason".
static func inspect_text(ships: Array, target: Node3D) -> String:
	var lines: Array[String] = ["Target: %s" % DisplayName.of(target)]
	for ship: Node3D in ships:
		var combat = CombatShip.of(ship)
		if combat == null or not combat.alive:
			continue
		var entries: Array[String] = []
		var capable := 0
		for weapon in combat.weapons:
			var result: Dictionary = weapon.assess(target)
			if result.capable:
				capable += 1
			entries.append("   %s %s: %s" % ["+" if result.capable else "-", weapon.config.display_name, result.reason])
		lines.append("%s  %.1f u  -  %d of %d weapons can engage" % [DisplayName.of(ship), combat.distance_to(target), capable, combat.weapons.size()])
		lines.append_array(entries)
	return "\n".join(lines)


## A ship's combat channels as text (tests, debugging): hull, movement, tactic and point
## defense, command (Behavior), target and its state, each weapon's state and
## ammunition, confirmed threats.
static func describe(ship: Node3D) -> String:
	var combat = CombatShip.of(ship)
	if combat == null:
		return ""
	var locomotion = ship.get_node("Locomotion")
	var follower = ship.get_node("RouteFollower")
	var lines: Array[String] = []
	lines.append("%s  [%s]  %s" % [DisplayName.of(ship), CombatShip.FACTION_NAMES[combat.faction], hull_text(combat)])
	var movement := "Idle"
	if follower.status == RouteFollower.RouteStatus.WAITING:
		movement = "Order queued"
	elif locomotion.has_destination:
		movement = "Moving to (%.0f, %.0f)" % [locomotion.destination.x, locomotion.destination.y]
	lines.append("Movement: %s" % movement)
	lines.append("Tactic: %s  |  Point defense: %s" % [combat.stance_name(), "authorized" if combat.point_defense_authorized else "off"])
	var behavior := ship.get_node_or_null("Behavior")
	if behavior != null:
		lines.append(behavior.describe())
	lines.append("Target: %s" % target_text(combat))
	lines.append_array(weapon_lines(combat))
	var threats: Array[String] = []
	for attacker: Variant in combat.threats:
		if is_instance_valid(attacker):
			threats.append("%s %.1f s" % [DisplayName.of(attacker), combat.threats[attacker] - CombatShip.now()])
	if not threats.is_empty():
		lines.append("Confirmed threats: %s" % ", ".join(threats))
	return "\n".join(lines)


static func hull_text(combat: Node) -> String:
	if not combat.alive:
		return "Hull: DESTROYED"
	return "Hull %d / %d" % [roundi(combat.health), roundi(combat.max_health)]


## The resolved target: "name (manual | auto) - state", plus a held manual target that is
## not the resolved one; "none".
static func target_text(combat: Node) -> String:
	var text := "none"
	if combat.target != null and is_instance_valid(combat.target):
		var kind := "manual" if combat.target == combat.manual_target else "auto"
		text = "%s (%s) - %s" % [DisplayName.of(combat.target), kind, combat.state_name()]
	if combat.manual_target != null and is_instance_valid(combat.manual_target) and combat.manual_target != combat.target:
		text += "  |  manual: %s (%s)" % [DisplayName.of(combat.manual_target), CombatShip.STATE_NAMES[combat.target_status(combat.manual_target)]]
	return text


## One line per installed weapon: state, ammunition, turret articulation.
static func weapon_lines(combat: Node) -> Array[String]:
	var lines: Array[String] = []
	for weapon in combat.weapons:
		lines.append("%s: %s  |  %s%s" % [weapon.config.display_name, weapon.reason, ammunition_text(weapon),
			"" if weapon.get("yaw_pivot") == null else "  [%s, yaw %.0f°, pitch %.0f°]" % [weapon.tracking, rad_to_deg(weapon.yaw), rad_to_deg(weapon.pitch)]])
	return lines


## Ammunition and reload state of one weapon.
static func ammunition_text(weapon: Node) -> String:
	var text := ""
	if weapon.config.magazine_size > 0:
		text = "magazine %d / %d, reserve %d" % [weapon.magazine, weapon.config.magazine_size, weapon.ammo]
		if weapon.reloading():
			text += ", reloading %.1f s" % weapon.reload_left
	else:
		text = "ammo %d / %d" % [weapon.ammo, weapon.capacity()]
		if weapon.cooldown_left > 0.0 and weapon.ammo > 0:
			text += ", reloading %.1f s" % weapon.cooldown_left
	if weapon.rounds_left() <= 0:
		text += ", EMPTY"
	return text


func _draw_bars() -> void:
	var camera := _arena.get_viewport().get_camera_3d()
	if camera == null:
		return
	var markers = _arena.get("markers")
	var alpha: float = 1.0 if markers == null else 1.0 - markers.emphasis()
	if alpha <= 0.0:
		return # The tactical markers carry the ships at full Tactical emphasis.
	for ship: Node3D in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat == null or combat.removed_from_play:
			continue
		if _arena.has_method("player_sees") and not _arena.player_sees(ship):
			continue
		var point: Vector3 = ship.global_position + Vector3(0, 2.2, 0)
		if camera.is_position_behind(point):
			continue
		var screen := camera.unproject_position(point)
		var origin := screen - Vector2(BAR_SIZE.x * 0.5, 0)
		if not combat.alive:
			_bars.draw_string(ThemeDB.fallback_font, origin, "DESTROYED", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 0.6, 0.3, alpha))
			continue
		var share: float = clampf(combat.health / combat.max_health, 0.0, 1.0) if combat.max_health > 0.0 else 0.0
		_bars.draw_rect(Rect2(origin, BAR_SIZE), Color(0, 0, 0, 0.6 * alpha))
		_bars.draw_rect(Rect2(origin, Vector2(BAR_SIZE.x * share, BAR_SIZE.y)), Color(CombatShip.FACTION_COLORS[combat.faction].lerp(Color.WHITE, 0.2), alpha))
		_bars.draw_rect(Rect2(origin, BAR_SIZE), Color(1, 1, 1, 0.5 * alpha), false, 1.0)
