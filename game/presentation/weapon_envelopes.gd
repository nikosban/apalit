extends Node3D
## Combat (migrated from the prototype v0.4): weapon envelopes (node `WeaponEnvelopes`, added by the arena,
## always processing). Shown only on request: while Alt is held, or while attack-target
## selection is open. One selected ship: each weapon's envelope; several: one compact
## outline per ship (its longest range). Neutral greys only; families differ by line style,
## weight and geometry, never by colour. Every value comes from the weapon itself (its
## configuration, hardpoint limits and current mount transform), so the drawing is what
## the firing authorization uses:
##   Cannon (articulated):  effective range solid and heavier, maximum range dashed, both
##                          only across the traverse (± yaw limit; the blind arc is left
##                          open), traverse edges, asteroid shadows (line of fire) dotted.
##   Gatling:               maximum range thin solid across the traverse, traverse edges.
##   Torpedo tube:          launch cone to the maximum range in long dashes, the tube's
##                          actual axis solid, asteroid shadows dotted (it needs a clear line).
##   Missile cells:         authorization range as a full dotted circle (no firing cone; the
##                          missiles steer and avoid obstacles), a square at the launcher.
##   Fixed cannon:          firing cone like the torpedo's, solid maximum range.
## Line widths are in screen pixels (constant at every zoom).

const CombatShip := preload("res://game/combat/combat_ship.gd")
const DisplayName := preload("res://game/ui/display_name.gd")
const SEGMENT_PX := 6.0 # Arc tessellation, in screen pixels.
const HEIGHT := 0.08
const GREY := Color(0.86, 0.87, 0.88)

var visible_ships: Array = [] # Ships drawn in the last update (tests).
var drawn_weapons := 0 # Weapons drawn in the last update (tests).
var force_visible := false # Tests: as if Alt were held.

var _mesh := ImmediateMesh.new()
var _instance: MeshInstance3D
var _labels: Array[Label3D] = []
var _used_labels := 0
var _camera: Camera3D
var _px := 0.05 # World units per screen pixel near the drawing (updated per ship).

@onready var _arena := get_parent()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_instance = MeshInstance3D.new()
	_instance.mesh = _mesh
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 1
	_instance.material_override = material
	add_child(_instance)


## Whether envelopes are requested now (Alt held, or target selection open).
func requested() -> bool:
	return force_visible or Input.is_key_pressed(KEY_ALT) or _arena.target_selection


func _process(_delta: float) -> void:
	_mesh.clear_surfaces()
	_used_labels = 0
	visible_ships = []
	drawn_weapons = 0
	_camera = get_viewport().get_camera_3d()
	var selected: Array = _arena.selection().selected
	if _camera != null and requested() and not selected.is_empty():
		var quads := []
		if selected.size() == 1:
			_ship_envelopes(quads, selected[0])
		else:
			for ship: Node3D in selected:
				_ship_outline(quads, ship)
		_flush(quads)
	for i in range(_used_labels, _labels.size()):
		_labels[i].visible = false


func _ship_envelopes(quads: Array, ship: Node3D) -> void:
	var combat = CombatShip.of(ship)
	if combat == null or not combat.alive:
		return
	visible_ships.append(ship)
	for weapon in combat.weapons:
		drawn_weapons += 1
		var family := String(weapon.config.family)
		var mount: Vector3 = _flat(weapon.muzzle.global_position if family in ["torpedo", "missile", "fixed"] else weapon.global_position)
		_px = _pixel_size(mount)
		var bow: Vector3 = weapon.global_basis * Vector3.FORWARD
		var heading := atan2(-bow.x, -bow.z)
		var max_range: float = weapon.config.weapon_range
		match family:
			"cannon":
				var limit := deg_to_rad(weapon.yaw_limit_deg())
				_arc(quads, mount, weapon.config.effective(), heading - limit, heading + limit, 2.2, 0.85, 0.0)
				_arc(quads, mount, max_range, heading - limit, heading + limit, 1.4, 0.7, 10.0)
				_edges(quads, mount, heading, limit, max_range, 1.0, 0.45)
				_shadows(quads, weapon, mount, max_range, heading, limit)
				_label(mount + _dir(heading) * max_range, "Cannon  %.0f / %.0f u  elev %.0f…%.0f°" % [weapon.config.effective(), max_range, weapon.pitch_min_deg(), weapon.pitch_max_deg()])
			"gatling":
				var limit := deg_to_rad(weapon.yaw_limit_deg())
				_arc(quads, mount, max_range, heading - limit, heading + limit, 1.0, 0.6, 0.0)
				_edges(quads, mount, heading, limit, max_range, 0.8, 0.35)
				_label(mount + _dir(heading) * max_range, "Gatling %.0f u  PD always%s" % [max_range, "" if combat.stance != CombatShip.Stance.HOLD_FIRE else ", offense held"])
			"torpedo":
				var cone := deg_to_rad(weapon.cone_deg())
				_arc(quads, mount, max_range, heading - cone, heading + cone, 1.4, 0.7, 22.0)
				_edges(quads, mount, heading, cone, max_range, 1.0, 0.5, 22.0)
				_line(quads, mount, mount + _dir(heading) * minf(12.0, max_range), 2.2, 0.9)
				_shadows(quads, weapon, mount, max_range, heading, cone)
				_label(mount + _dir(heading) * max_range, "Torpedo  %.0f u  cone ±%.0f°" % [max_range, weapon.cone_deg()])
			"missile":
				_arc(quads, mount, max_range, -PI, PI, 1.2, 0.6, 3.0)
				_square(quads, mount, 7.0, 1.6, 0.9)
				_label(mount + _dir(heading + PI * 0.5) * max_range, "Missiles  %.0f u  any bearing" % max_range)
			_:
				var cone := deg_to_rad(weapon.cone_deg())
				_arc(quads, mount, max_range, heading - cone, heading + cone, 1.4, 0.7, 0.0)
				_edges(quads, mount, heading, cone, max_range, 1.0, 0.5)
				_shadows(quads, weapon, mount, max_range, heading, cone)
				_label(mount + _dir(heading) * max_range, "%s  %.0f u  cone ±%.0f°" % [weapon.config.display_name, max_range, weapon.cone_deg()])


# Several ships selected: one dashed outline at each ship's longest weapon range.
func _ship_outline(quads: Array, ship: Node3D) -> void:
	var combat = CombatShip.of(ship)
	if combat == null or not combat.alive:
		return
	visible_ships.append(ship)
	var longest := 0.0
	for weapon in combat.weapons:
		if weapon.rounds_left() > 0:
			longest = maxf(longest, weapon.config.weapon_range)
	if longest <= 0.0:
		return
	var center := _flat(ship.global_position)
	_px = _pixel_size(center)
	_arc(quads, center, longest, -PI, PI, 1.2, 0.5, 10.0)
	_label(center + _dir(PI * 0.25) * longest, "%s  %.0f u" % [DisplayName.of(ship), longest])


# Asteroids inside a line-of-fire weapon's coverage: the two tangent rays bounding the
# shadow the asteroid casts from the mount, dotted, from the asteroid to the range edge.
func _shadows(quads: Array, weapon: Node, mount: Vector3, max_range: float, heading: float, half: float) -> void:
	var asteroids: Node = weapon.combat.asteroids
	if asteroids == null or not asteroids.has_method("ids"):
		return
	for id: int in asteroids.ids():
		var center: Vector3 = asteroids.center(id)
		var radius: float = asteroids.radius(id)
		var offset := Vector2(center.x - mount.x, center.z - mount.z)
		var distance := offset.length()
		if distance <= radius or distance - radius > max_range:
			continue
		var bearing := atan2(-offset.x, -offset.y)
		if absf(wrapf(bearing - heading, -PI, PI)) > half + asin(minf(1.0, radius / distance)):
			continue
		var spread := asin(minf(1.0, radius / distance))
		var tangent := sqrt(maxf(0.0, distance * distance - radius * radius))
		for side in [-1.0, 1.0]:
			var a: float = bearing + side * spread
			if absf(wrapf(a - heading, -PI, PI)) > half:
				continue
			_line(quads, mount + _dir(a) * tangent, mount + _dir(a) * max_range, 1.0, 0.4, 2.5)


func _edges(quads: Array, center: Vector3, heading: float, half: float, radius: float, width: float, alpha: float, dash: float = 0.0) -> void:
	if half >= PI - 0.001:
		return
	for side in [-1.0, 1.0]:
		_line(quads, center, center + _dir(heading + side * half) * radius, width, alpha, dash)


# An arc on the ground (angles in the overlay heading convention), solid or dashed (dash
# and gap length in screen pixels).
func _arc(quads: Array, center: Vector3, radius: float, from: float, to: float, width: float, alpha: float, dash: float) -> void:
	if radius <= 0.0:
		return
	if to - from > TAU:
		to = from + TAU
	var steps := maxi(8, ceili((to - from) * radius / (SEGMENT_PX * _px)))
	var length := 0.0
	var dash_world := dash * _px
	for i in steps:
		var a := lerpf(from, to, float(i) / steps)
		var b := lerpf(from, to, float(i + 1) / steps)
		var p := center + _dir(a) * radius
		var q := center + _dir(b) * radius
		var on := dash <= 0.0 or fmod(length, dash_world * 2.0) < dash_world
		length += p.distance_to(q)
		if on:
			_quad(quads, p, q, width, alpha)


func _line(quads: Array, a: Vector3, b: Vector3, width: float, alpha: float, dash: float = 0.0) -> void:
	if dash <= 0.0:
		_quad(quads, a, b, width, alpha)
		return
	var dash_world := dash * _px
	var total := a.distance_to(b)
	var t := 0.0
	while t < total:
		var end := minf(t + dash_world, total)
		_quad(quads, a.lerp(b, t / total), a.lerp(b, end / total), width, alpha)
		t += dash_world * 2.0


func _square(quads: Array, center: Vector3, size_px: float, width: float, alpha: float) -> void:
	var h := size_px * _px * 0.5
	var corners := [center + Vector3(-h, 0, -h), center + Vector3(h, 0, -h), center + Vector3(h, 0, h), center + Vector3(-h, 0, h)]
	for i in 4:
		_quad(quads, corners[i], corners[(i + 1) % 4], width, alpha)


func _quad(quads: Array, a: Vector3, b: Vector3, width_px: float, alpha: float) -> void:
	var along := b - a
	if along.length_squared() < 0.0000001:
		return
	var side := Vector3(-along.z, 0.0, along.x).normalized() * width_px * _px * 0.5
	quads.append([a - side, a + side, b + side, b - side, Color(GREY, alpha)])


func _flush(quads: Array) -> void:
	if quads.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for q: Array in quads:
		for index in [0, 1, 2, 0, 2, 3]:
			_mesh.surface_set_color(q[4])
			_mesh.surface_add_vertex(q[index])
	_mesh.surface_end()


func _label(point: Vector3, text: String) -> void:
	if _used_labels >= _labels.size():
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = 0.0012
		label.font_size = 18
		label.outline_size = 4
		label.modulate = Color(GREY, 0.85)
		label.outline_modulate = Color(0, 0, 0, 0.7)
		label.no_depth_test = true
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(label)
		_labels.append(label)
	var label := _labels[_used_labels]
	_used_labels += 1
	label.visible = true
	label.text = text
	label.global_position = point + Vector3(0, 0.3, 0)


# World units per screen pixel at a point (perspective camera).
func _pixel_size(point: Vector3) -> float:
	var height := get_viewport().get_visible_rect().size.y
	return _camera.global_position.distance_to(point) * 2.0 * tan(deg_to_rad(_camera.fov) * 0.5) / maxf(height, 1.0)


func _dir(angle: float) -> Vector3:
	return Vector3(-sin(angle), 0.0, -cos(angle))


func _flat(point: Vector3) -> Vector3:
	return Vector3(point.x, HEIGHT, point.z)

