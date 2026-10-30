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
const HudView := preload("res://game/ui/overlays/combat_hud/combat_hud_view.tscn")
const TARGET_HINT := "Choose a target: click a hostile ship  |  Esc or right-click elsewhere cancels"

var _view: Control
var _result: Label
var _speed: Label # Simulation speed (TimeControl) and the target-selection hint.
var _inspect: Label # Target eligibility at the cursor during target selection.

@onready var _arena := get_parent()


func _ready() -> void:
	layer = 1
	_view = HudView.instantiate()
	add_child(_view)
	_result = _view.get_node("Result")
	_speed = _view.get_node("Speed")
	_inspect = _view.get_node("Inspection")


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
	_draw_bars()
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
	var at: Vector2 = mouse + _view.cursor_offset
	if at.x + _inspect.size.x > area.x - _view.edge_margin:
		at.x = mouse.x - _view.cursor_offset.x - _inspect.size.x # flip to the cursor's left near the edge
	at.y = clampf(at.y, _view.edge_margin, maxf(_view.edge_margin, area.y - _inspect.size.y - _view.edge_margin))
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


# Controller owns all world queries and eligibility; view receives screen data only.
func _draw_bars() -> void:
	var entries: Array[Dictionary] = []
	var camera := _arena.get_viewport().get_camera_3d()
	var markers = _arena.get("markers")
	var alpha: float = 1.0 if markers == null else 1.0 - markers.emphasis()
	if camera != null and alpha > 0.0:
		for ship: Node3D in _arena.get_node("Ships").get_children():
			var combat = CombatShip.of(ship)
			if combat == null or combat.removed_from_play:
				continue
			if _arena.has_method("player_sees") and not _arena.player_sees(ship):
				continue
			var point: Vector3 = ship.global_position + _view.bar_style.world_offset
			if camera.is_position_behind(point):
				continue
			var share: float = clampf(combat.health / combat.max_health, 0.0, 1.0) if combat.max_health > 0.0 else 0.0
			entries.append({"position": camera.unproject_position(point), "share": share,
				"destroyed": not combat.alive, "alpha": alpha,
				"color": Color(CombatShip.FACTION_COLORS[combat.faction].lerp(Color.WHITE, _view.bar_style.faction_lightening), alpha)})
	_view.set_entries(entries)
