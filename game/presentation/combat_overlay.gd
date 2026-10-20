extends Node3D
## Combat (migrated from the prototype v0.2): world-space combat indicators (node `CombatOverlay`).
## Always: for the selected ships, a line to the current target and a ring around it
## (green: weapons can fire, amber: engaged but a check fails, grey: no authorization or
## no contact). Debug (F10, `debug_visible` on the scene):
## for every live ship the fixed weapon's firing cone and range, the turret's coverage
## and range, the barrel axis, a line to its target and a label with each weapon's
## state, reason, tracking and cooldown.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const CombatHud := preload("res://game/ui/combat_hud.gd")
const HEIGHT := 0.06
const SEGMENTS := 48
const COLORS := {"ok": Color(0.35, 0.95, 0.45), "wait": Color(1.0, 0.75, 0.25), "off": Color(0.55, 0.55, 0.6),
	"lock": Color(0.3, 0.9, 1.0), "cone": Color(1.0, 0.85, 0.3, 0.9), "turret": Color(0.6, 0.75, 1.0, 0.9)}

var _mesh := ImmediateMesh.new()
var _labels := {} # ship instance id -> Label3D

@onready var _arena := get_parent()


func _ready() -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = _mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	instance.material_override = material
	add_child(instance)


func _process(_delta: float) -> void:
	_mesh.clear_surfaces()
	var lines := []
	var debug: bool = _arena.debug_visible
	var seen := {}
	for ship: Node3D in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat == null or not combat.alive:
			continue
		if _arena.has_method("player_sees") and not _arena.player_sees(ship):
			continue # v0.4 fog of war: nothing drawn for a ship the player cannot see.
		var selected: bool = _arena.selection().selected.has(ship)
		if selected or debug:
			_target_lines(lines, ship, combat)
		if debug:
			_debug_arcs(lines, ship, combat)
			seen[ship.get_instance_id()] = true
			_label_for(ship, combat)
	for id: int in _labels.keys():
		if not seen.has(id):
			(_labels[id] as Node).queue_free()
			_labels.erase(id)
	if lines.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for entry: Array in lines:
		_mesh.surface_set_color(entry[2])
		_mesh.surface_add_vertex(entry[0])
		_mesh.surface_set_color(entry[2])
		_mesh.surface_add_vertex(entry[1])
	_mesh.surface_end()


func _target_lines(lines: Array, ship: Node3D, combat: Variant) -> void:
	var target: Variant = combat.target
	if target == null or not is_instance_valid(target):
		return
	if _arena.has_method("player_sees") and not _arena.player_sees(target):
		return # v0.4: no line to a target the player cannot see (its marker shows where it was).
	var color: Color = COLORS.off
	if combat.target_status(target) == CombatShip.TargetState.VALID and combat.stance_allows(target) == CombatShip.TargetState.VALID:
		color = COLORS.ok if combat.target_state == CombatShip.TargetState.VALID else COLORS.wait
	_line(lines, _flat(ship.global_position), _flat(target.global_position), color)
	var radius: float = target.get_node("RouteFollower").ship_radius + 0.6 if target.has_node("RouteFollower") else 3.0
	_circle(lines, _flat(target.global_position), radius, color, -PI, PI)


func _debug_arcs(lines: Array, ship: Node3D, combat: Variant) -> void:
	for weapon in combat.weapons:
		var origin := _flat(weapon.muzzle.global_position)
		var bow: Vector3 = weapon.global_basis * Vector3.FORWARD
		var heading := atan2(-bow.x, -bow.z)
		if weapon.fixed:
			var cone := deg_to_rad(weapon.cone_deg())
			_wedge(lines, origin, heading, cone, weapon.config.weapon_range, COLORS.cone)
		elif weapon.get("yaw_pivot") != null:
			var limit := deg_to_rad(weapon.yaw_limit_deg())
			_wedge(lines, _flat(weapon.global_position), heading, limit, weapon.config.weapon_range, COLORS.turret)
			var barrel: Vector3 = weapon.forward()
			_line(lines, weapon.muzzle.global_position, weapon.muzzle.global_position + barrel * 4.0, COLORS.turret)


func _label_for(ship: Node3D, combat: Variant) -> void:
	var id := ship.get_instance_id()
	if not _labels.has(id):
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 28
		label.pixel_size = 0.01
		label.outline_size = 6
		label.no_depth_test = true
		add_child(label)
		_labels[id] = label
	var text: Array[String] = ["%s: %s" % [combat.stance_name(), combat.state_name()]]
	for weapon in combat.weapons:
		var tracking: String = "" if weapon.get("yaw_pivot") == null else " [%s]" % weapon.tracking
		text.append("%s: %s%s | %s" % [weapon.config.display_name, weapon.reason, tracking, CombatHud.ammunition_text(weapon)])
	var label: Label3D = _labels[id]
	label.text = "\n".join(text)
	label.global_position = ship.global_position + Vector3(0, 4.0, 0)


func _wedge(lines: Array, origin: Vector3, heading: float, half: float, radius: float, color: Color) -> void:
	for side in [-1.0, 1.0]:
		var angle: float = heading + side * half
		_line(lines, origin, origin + Vector3(-sin(angle), 0, -cos(angle)) * radius, color)
	_circle(lines, origin, radius, color, heading - half, heading + half)


func _circle(lines: Array, center: Vector3, radius: float, color: Color, from: float, to: float) -> void:
	var steps := maxi(4, int(SEGMENTS * (to - from) / TAU))
	for i in steps:
		var a := lerpf(from, to, float(i) / steps)
		var b := lerpf(from, to, float(i + 1) / steps)
		_line(lines, center + Vector3(-sin(a), 0, -cos(a)) * radius, center + Vector3(-sin(b), 0, -cos(b)) * radius, color)


func _line(lines: Array, a: Vector3, b: Vector3, color: Color) -> void:
	lines.append([a, b, color])


func _flat(point: Vector3) -> Vector3:
	return Vector3(point.x, HEIGHT, point.z)
