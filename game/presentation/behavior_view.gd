extends MeshInstance3D
## Behavior (migrated from the behavior prototype v0.1): ground lines for every player ship with a Behavior node (P01–
## P03; added by the arena when one exists). Drawing only.
##   Defensive without a command: the defended area (DEFENSE_RADIUS around the anchor).
##   Guard: a line to the chosen guard position and a ring there.
##   A movement request of the layer under way: a line to the requested point.
##   Attack investigating: a ring at the target's last known position.
##   Waypoint Move: the remaining legs. Attack-Move: its destination (and, during an
##   encounter, the line back to it).

const Behavior := preload("res://game/behavior/ship_behavior.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const PLAYER := 0
const HEIGHT := 0.06
const AREA := Color(0.35, 0.75, 0.85, 0.7)
const GUARD := Color(0.4, 0.9, 0.45, 0.9)
const REQUEST := Color(0.95, 0.75, 0.3, 0.8)
const LAST_KNOWN := Color(0.75, 0.76, 0.78, 0.85)
const WAYPOINT := Color(0.55, 0.7, 1.0, 0.85)
const ATTACK_MOVE := Color(1.0, 0.45, 0.35, 0.85)

var _mesh := ImmediateMesh.new()

@onready var _arena := get_parent()


func _ready() -> void:
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = material


func _process(_delta: float) -> void:
	_mesh.clear_surfaces()
	var lines: Array = [] # [from, to, color]
	for ship: Node in _arena.get_node("Ships").get_children():
		var behavior = Behavior.of(ship)
		var combat = CombatShip.of(ship)
		if behavior == null or combat == null or not combat.alive or combat.faction != PLAYER:
			continue
		var here := Vector2(ship.global_position.x, ship.global_position.z)
		if behavior.command == Behavior.Command.NONE and combat.stance == CombatShip.Stance.DEFENSIVE and behavior.has_anchor:
			_circle(lines, behavior.anchor, Behavior.DEFENSE_RADIUS, AREA)
		if behavior.command == Behavior.Command.GUARD and behavior.guard_slot >= 0 and is_instance_valid(behavior.guard_target):
			var slot: Vector2 = behavior.slot_point(behavior.guard_slot)
			lines.append([here, slot, GUARD])
			_circle(lines, slot, 1.2, GUARD)
		if behavior.has_station and behavior._moving():
			lines.append([here, behavior.station, REQUEST])
		if behavior.command == Behavior.Command.ATTACK and behavior.investigating:
			_circle(lines, behavior.last_known, 2.0, LAST_KNOWN)
		if behavior.command == Behavior.Command.WAYPOINTS:
			var previous := here
			for point: Vector2 in behavior.waypoints:
				lines.append([previous, point, WAYPOINT])
				_circle(lines, point, 1.0, WAYPOINT)
				previous = point
		if behavior.command == Behavior.Command.ATTACK_MOVE:
			_circle(lines, behavior.destination, 1.5, ATTACK_MOVE)
			if is_instance_valid(behavior.encounter):
				lines.append([here, behavior.destination, ATTACK_MOVE])
	if lines.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for line: Array in lines:
		_mesh.surface_set_color(line[2])
		_mesh.surface_add_vertex(Vector3(line[0].x, HEIGHT, line[0].y))
		_mesh.surface_add_vertex(Vector3(line[1].x, HEIGHT, line[1].y))
	_mesh.surface_end()


func _circle(lines: Array, centre: Vector2, radius: float, color: Color) -> void:
	var steps := 40
	for i in steps:
		var a := centre + Vector2.RIGHT.rotated(TAU * i / steps) * radius
		var b := centre + Vector2.RIGHT.rotated(TAU * (i + 1) / steps) * radius
		lines.append([a, b, color])
