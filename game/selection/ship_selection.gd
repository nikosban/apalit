extends Node3D
## Stage 5 RTS selection (mouse). Owns only the selection set and its feedback; it
## never reads or writes movement state. Left-click picks the ship whose visible
## hull is hit first along the camera ray (each hull part's box, grown by a small
## tolerance); Shift-click toggles it; a click on empty ground clears the selection
## (kept with Shift). Dragging beyond the threshold, from anywhere, draws a screen
## rectangle that selects the ships whose centres project inside it (Shift adds).
## No physics bodies are used.
## Combat migration: only live ships of the player's faction are selectable (a hostile
## ship or a hulk is never selected; pick_any() still finds it, for targeting), and a ship
## the scene says the player cannot see (its `player_sees()`, fog of war) is never picked.
## A destroyed ship is dropped from the selection; a ship leaving the scene is
## unregistered (pick boxes and ring). Phase B, with the scene's tactical markers
## (`markers`): a click on an interactive marker picks its ship, elsewhere the hull pick
## applies (both resolve to the same ship node); the ring fades out as the markers'
## brackets fade in (1 - emphasis), so a selected ship stays marked at every zoom.
## Phase C: in Strategic View (the scene's `strategic`) only markers pick (the hidden
## hulls never do), and nothing picks during the Tactical / Strategic handoff.

const CombatShip := preload("res://game/combat/combat_ship.gd")

signal selection_changed

const DRAG_THRESHOLD := 5.0 # px; less movement between press and release is a click.
const PICK_TOLERANCE := 0.3 # u added around each visible hull part when picking (provisional).
const RING_PADDING := 0.5 # u between the hull's farthest point and the selection ring.
const RING_WIDTH := 0.15 # u
const RING_HEIGHT := 0.03
const RING_COLOR := Color(0.35, 0.9, 0.45)
const BOX_FILL := Color(0.35, 0.9, 0.45, 0.12)
const BOX_BORDER := Color(0.35, 0.9, 0.45, 0.8)

@export var ships_path := NodePath("../Ships")
@export var player_faction := 0

var selected: Array[Node3D] = []

var _parts := {} # ship -> Array of AABB, the visible hull parts in the ship's own frame
var _rings := {} # ship -> MeshInstance3D
var _ring_material: StandardMaterial3D
var _pressing := false
var _dragging := false
var _press_position := Vector2.ZERO
var _press_shift := false
var _box: Panel

@onready var _ships := get_node(ships_path)


func _ready() -> void:
	_ring_material = StandardMaterial3D.new()
	_ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA # Fades with the Tactical emphasis.
	_ring_material.albedo_color = RING_COLOR
	for ship: Node3D in _ships.get_children():
		register_ship(ship)
	var layer := CanvasLayer.new()
	_box = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = BOX_FILL
	style.border_color = BOX_BORDER
	style.set_border_width_all(1)
	_box.add_theme_stylebox_override("panel", style)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.visible = false
	layer.add_child(_box)
	add_child(layer)


## Reads a ship's visible hull parts (pick boxes) and creates its selection ring: for
## every ship at start, and (Phase 4) for a ship added under Ships during the game, in
## the same call that adds it. A ship already registered is left as it is.
func register_ship(ship: Node3D) -> void:
	if _parts.has(ship):
		return
	var parts: Array[AABB] = []
	var reach := 0.0
	var to_ship := ship.global_transform.affine_inverse()
	for mesh_instance in ship.find_children("*", "MeshInstance3D", true, false):
		var part: AABB = (to_ship * (mesh_instance as MeshInstance3D).global_transform) * (mesh_instance as MeshInstance3D).get_aabb()
		parts.append(part)
		for i in 8:
			var corner := part.get_endpoint(i)
			reach = maxf(reach, Vector2(corner.x, corner.z).length())
	_parts[ship] = parts
	var torus := TorusMesh.new()
	torus.outer_radius = reach + RING_PADDING
	torus.inner_radius = reach + RING_PADDING - RING_WIDTH
	var ring := MeshInstance3D.new()
	ring.mesh = torus
	ring.material_override = _ring_material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.scale = Vector3(1.0, 0.2, 1.0)
	ring.visible = false
	add_child(ring)
	_rings[ship] = ring


func _process(_delta: float) -> void:
	var markers = get_parent().get("markers")
	var ring_alpha: float = 1.0 if markers == null else 1.0 - markers.emphasis() # The markers' brackets take over.
	_ring_material.albedo_color = Color(RING_COLOR, ring_alpha)
	for key: Variant in _rings.keys():
		if not is_instance_valid(key): # Freed without being unregistered: its ring goes.
			(_rings[key] as Node).queue_free()
			_rings.erase(key)
			_parts.erase(key)
			continue
		var ship := key as Node3D
		var ring: MeshInstance3D = _rings[ship]
		ring.visible = selected.has(ship) and ring_alpha > 0.0
		if ring.visible:
			ring.global_position = Vector3(ship.global_position.x, RING_HEIGHT, ship.global_position.z)


## Whether the player may select this ship: live and of the player's faction (a ship
## without a Combat component counts as the player's).
func selectable(ship: Variant) -> bool:
	if not is_instance_valid(ship):
		return false
	var combat = CombatShip.of(ship)
	return combat == null or (combat.alive and combat.faction == player_faction)


## A ship that can no longer be selected (destroyed) leaves the selection.
func drop(ship: Node3D) -> void:
	if selected.has(ship):
		set_selection(selected.filter(func(other: Node3D) -> bool: return other != ship))


## A ship leaving the scene: it leaves the selection, its pick boxes and ring go.
func unregister_ship(ship: Node3D) -> void:
	drop(ship)
	if _rings.has(ship):
		(_rings[ship] as Node).queue_free()
		_rings.erase(ship)
	_parts.erase(ship)


## Ships currently registered (pick boxes).
func registered_count() -> int:
	return _parts.size()


# A left press not taken by the GUI (debug panel) starts a click or drag.
func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
		_pressing = true
		_dragging = false
		_press_position = button.position
		_press_shift = button.shift_pressed
		get_viewport().set_input_as_handled()


# Motion and release of a started press are read here, before the GUI, so a drag
# released over the debug panel still completes. Events are not consumed.
func _input(event: InputEvent) -> void:
	if not _pressing:
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		if not _dragging and motion.position.distance_to(_press_position) > DRAG_THRESHOLD:
			_dragging = true
		if _dragging:
			var rect := Rect2(_press_position, Vector2.ZERO).expand(motion.position)
			_box.position = rect.position
			_box.size = rect.size
			_box.visible = true
		return
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT or button.pressed:
		return
	_pressing = false
	_box.visible = false
	if _dragging or button.position.distance_to(_press_position) > DRAG_THRESHOLD:
		select_box(Rect2(_press_position, Vector2.ZERO).expand(button.position), _press_shift)
	else:
		_click(_press_position, _press_shift)


## Selectable ship whose visible hull the camera ray through a screen point hits first
## (nearest to the camera; equal distances: the earlier ship in the scene), or null (a
## hostile ship or a hulk in front gives none).
func pick(screen_position: Vector2) -> Node3D:
	var ship := pick_any(screen_position)
	return ship if ship != null and selectable(ship) else null


## Any ship under a screen point that the player can see: the ship of an interactive
## tactical marker under the point (TacticalMarkers.marker_at()), else the nearest hull
## hit. A hidden ship never shadows a visible one.
func pick_any(screen_position: Vector2) -> Node3D:
	var arena := get_parent()
	var strategic = arena.get("strategic")
	var abstract: bool = strategic != null and strategic.in_strategic()
	if abstract and strategic.transitioning():
		return null
	var markers = arena.get("markers")
	if markers != null:
		var marked: Node3D = markers.marker_at(screen_position)
		if marked != null or abstract:
			return marked
	var camera := get_viewport().get_camera_3d()
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var best: Node3D = null
	var best_distance := INF
	for ship: Node3D in _ships.get_children():
		if not _parts.has(ship) or (arena.has_method("player_sees") and not arena.player_sees(ship)):
			continue
		var to_ship := ship.global_transform.affine_inverse()
		var local_origin := to_ship * origin
		var local_direction := to_ship.basis * direction
		for part: AABB in _parts[ship]:
			var hit: Variant = part.grow(PICK_TOLERANCE).intersects_ray(local_origin, local_direction)
			if hit != null and local_origin.distance_to(hit) < best_distance:
				best_distance = local_origin.distance_to(hit)
				best = ship
	return best


## Ships whose centres project inside a screen rectangle; Shift adds to the selection.
func select_box(rect: Rect2, add: bool) -> void:
	var camera := get_viewport().get_camera_3d()
	var inside: Array[Node3D] = []
	if add:
		inside.assign(selected)
	for ship: Node3D in _ships.get_children():
		if camera.is_position_behind(ship.global_position) or inside.has(ship):
			continue
		if rect.has_point(camera.unproject_position(ship.global_position)):
			inside.append(ship)
	set_selection(inside)


## Drops a press in progress (no click or box completes from it; Phase C handoff).
func cancel_press() -> void:
	_pressing = false
	_dragging = false
	_box.visible = false


func set_selection(ships: Array) -> void:
	var ordered: Array[Node3D] = []
	for ship: Node3D in _ships.get_children():
		if ships.has(ship) and selectable(ship):
			ordered.append(ship)
	if ordered != selected:
		selected = ordered
		selection_changed.emit()


func _click(screen_position: Vector2, shift: bool) -> void:
	var ship := pick(screen_position)
	if ship == null:
		if not shift:
			set_selection([])
	elif not shift:
		set_selection([ship])
	elif selected.has(ship):
		var remaining := selected.duplicate()
		remaining.erase(ship)
		set_selection(remaining)
	else:
		set_selection(selected + [ship])
