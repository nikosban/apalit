extends Node3D
## Arena-independent player input and presentation. The arena supplies world services and
## receives resolved orders through callables.

const ShipSelection := preload("res://game/player/selection/ship_selection.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const DisplayName := preload("res://game/ui/display_name.gd")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")

enum CommandKind { DOCK, MINE, MOVE, GROUP_MOVE, GROUP, TARGET }

const NOTICE_TIME := 2.0
const GROUP_NOTICE := "Not enough space for the group - no orders given"

signal target_selection_changed

## World gap between trajectory lines and the destination symbol.
@export var destination_gap_world := 0.25

var ships: Node
var stations: Node
var orders: Node
var time_control: Node
var strategic: Node
var markers: CanvasLayer
var player_sees: Callable

var target_selection := false
var pointer := Vector2(-1, -1)
var _asteroids: AsteroidField
var _sector_half_size: float
var _submit_intent: Callable
var _can_submit_intent: Callable
var _held_move: Callable
var _development_key: Callable
var _notice_left := 0.0

@onready var camera_rig = $CameraRig
@onready var selection := $Selection as ShipSelection
@onready var station_panel := get_node_or_null("StationPanel")
@onready var _notice: Label = $NoticeUI/Notice
@onready var _indicator = $MovementIndicator


func configure(world_ships: Node, world_stations: Node, asteroids: AsteroidField, survey: Node,
		combat_orders: Node, clock_control: Node, strategic_view: Node, tactical_markers: CanvasLayer,
		half_size: float, visibility: Callable, submit: Callable, availability: Callable,
		held_destination: Callable, development_key: Callable) -> void:
	ships = world_ships
	stations = world_stations
	_asteroids = asteroids
	orders = combat_orders
	time_control = clock_control
	strategic = strategic_view
	markers = tactical_markers
	_sector_half_size = half_size
	player_sees = visibility
	_submit_intent = submit
	_can_submit_intent = availability
	_held_move = held_destination
	_development_key = development_key

	camera_rig.bounds = Rect2(-half_size, -half_size, 2.0 * half_size, 2.0 * half_size)
	selection.configure(ships, strategic, markers, player_sees)
	selection.selection_changed.connect(_on_selection_changed)
	var hover := get_node_or_null("AsteroidHover")
	if hover != null:
		hover.configure(_asteroids, survey, selection, stations, strategic)
	var ship_panel := get_node_or_null("ShipPanel")
	if ship_panel != null:
		ship_panel.configure_orders(orders)
	var cursor := get_node_or_null("CommandCursor")
	if cursor != null:
		cursor.configure(self)
	var hud := get_node_or_null("CombatHUD")
	if hud != null:
		hud.configure(self)


func register_ship(ship: Node3D) -> void:
	selection.register_ship(ship)


func ship_destroyed(ship: Node3D) -> void:
	selection.drop(ship)


func ship_removed(ship: Node3D) -> void:
	selection.unregister_ship(ship)


func cancel_presses() -> void:
	selection.cancel_press()
	if station_panel != null:
		station_panel.cancel_press()


func _on_selection_changed() -> void:
	if target_selection and selection.selected.is_empty():
		cancel_target_selection()


# Strategic handoffs can consume events before the GUI. A press already in progress
# can finish over the GUI. New ordinary world presses start in _unhandled_input.
func _input(event: InputEvent) -> void:
	if ships == null:
		return
	if strategic != null:
		strategic.handle_input(event)
		if get_viewport().is_input_handled():
			return
	if station_panel != null:
		station_panel.finish_press(event)
	selection.continue_press(event)
	var motion := event as InputEventMouseMotion
	if motion != null:
		pointer = motion.position
	_targeting_input(event)


func _unhandled_input(event: InputEvent) -> void:
	if ships == null:
		return
	if strategic != null:
		strategic.handle_world_input(event)
		if get_viewport().is_input_handled():
			return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if _development_key.call(key.physical_keycode, key.shift_pressed):
			return
		if orders != null and _combat_key(key.physical_keycode):
			get_viewport().set_input_as_handled()
		return
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	if button.button_index == MOUSE_BUTTON_LEFT:
		if station_panel != null:
			station_panel.begin_press(event)
		selection.begin_press(event)
	elif button.button_index == MOUSE_BUTTON_RIGHT:
		if orders != null and (button.ctrl_pressed or button.shift_pressed) and _behavior_selected():
			_behavior_command(button.position, button.shift_pressed)
			get_viewport().set_input_as_handled()
		elif _command(button.position):
			get_viewport().set_input_as_handled()


func _command(screen_position: Vector2) -> bool:
	var recipients := selection.selected.duplicate()
	var intent := resolve_command(screen_position, recipients)
	if intent.is_empty():
		return false
	var accepted: bool = _submit_intent.call(recipients, intent)
	return accepted or intent.kind == CommandKind.TARGET


func command_available(recipients: Array, intent: Dictionary) -> bool:
	return _can_submit_intent.call(recipients, intent)


## UX round (P8): the command a right-click at a screen point would give the selected
## ships, read-only (the click and the command cursor use the same resolution): one
## ship: {kind DOCK, station} over a station (ships with Docking), {kind MINE, asteroid}
## over an asteroid (miners), else {kind MOVE, point} on the ground; several ships:
## {kind GROUP, point}; {} for none (nothing selected, off the ground).
func resolve_command(screen_position: Vector2, ships: Array) -> Dictionary:
	if ships.is_empty():
		return {}
	if orders != null:
		var picked: Node3D = selection.pick_any(screen_position)
		var combat = CombatShip.of(picked)
		if combat != null and combat.faction != selection.player_faction and combat.alive:
			return {"kind": CommandKind.TARGET, "ship": picked}
	# Phase C: the active camera (Strategic or the rig's); in Strategic, stations and
	# asteroids are reached through their markers, never through hidden geometry.
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var abstract: bool = strategic != null and strategic.in_strategic()
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	if ships.size() == 1:
		var station: Node3D = strategic.station_at(screen_position) if abstract else _station_at(origin, direction)
		if station != null and ships[0].has_node("Docking"):
			return {"kind": CommandKind.DOCK, "station": station}
	if ships.size() == 1 and ships[0].has_node("Mining") and _asteroids != null:
		var asteroid: int = strategic.asteroid_at(screen_position) if abstract else _asteroids.pick(origin, direction)
		if asteroid >= 0:
			return {"kind": CommandKind.MINE, "asteroid": asteroid}
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	if hit == null:
		return {}
	var point := Vector2(hit.x, hit.z)
	var half := _sector_half_size
	if absf(point.x) > half or absf(point.y) > half:
		return {}
	return {"kind": CommandKind.MOVE if ships.size() == 1 else CommandKind.GROUP, "point": point}


func _station_at(origin: Vector3, direction: Vector3) -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	if stations == null:
		return null
	for station in stations.get_children():
		var distance: float = station.pick(origin, direction)
		if distance < best_distance:
			best_distance = distance
			best = station
	return best


func _process(delta: float) -> void:
	if ships == null:
		return
	# Notices and markers are UI: real time at every simulation speed (the engine time
	# scale divided out; paused it is 1).
	if Engine.time_scale > 0.0:
		delta /= Engine.time_scale
	_notice_left -= delta
	_notice.visible = _notice_left > 0.0
	_indicator.destination_gap_world = destination_gap_world
	var handoff: float = strategic.progress if strategic != null else 0.0
	var entries := []
	for ship: Node3D in ships.get_children():
		var held: Variant = _held_move.call(ship)
		if not selection.selected.has(ship):
			continue
		var follower := ship.get_node("RouteFollower") as RouteFollower
		var locomotion := ship.get_node("Locomotion") as ShipLocomotion
		var ship_point := Vector2(ship.global_position.x, ship.global_position.z)
		if held != null:
			# A held MOVE: the requested (group: assigned) point, resolved once control ends.
			entries.append({"ship": ship, "from": ship_point, "destination": held})
			continue
		var destination: Vector2
		if follower.status == RouteFollower.RouteStatus.WAITING:
			destination = follower.requested
		elif locomotion.has_destination:
			destination = locomotion.destination
		else:
			continue
		var entry := {"ship": ship, "from": ship_point, "destination": destination}
		if follower.requested.distance_to(destination) > 0.0001:
			entry.requested = follower.requested
		if handoff > 0.0:
			# Strategic View: the planned route still to fly, cross-faded in with the handoff.
			for line: Dictionary in strategic.order_lines(ship):
				if line.kind == "route" and (line.points[line.points.size() - 1] as Vector2).distance_to(destination) < 0.01:
					entry.route = line.points
		entries.append(entry)
	_indicator.set_entries(entries, smoothstep(0.0, 1.0, handoff))


func show_notice(text: String) -> void:
	_notice.text = text
	_notice_left = NOTICE_TIME


## While attack-target selection is open, mouse presses are read here, before Selection
## (which would otherwise take the left click): a click on a hostile assigns it to the
## selected ships; a right-click elsewhere cancels; a left click elsewhere changes nothing.
func _targeting_input(event: InputEvent) -> void:
	if not target_selection:
		return
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or not mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return
	var picked: Node3D = selection.pick_any(mouse.position)
	var combat = CombatShip.of(picked)
	if combat != null and combat.faction != selection.player_faction and combat.alive:
		_submit_intent.call(selection.selected.duplicate(), {"kind": CommandKind.TARGET, "ship": picked})
		_end_target_selection()
	elif mouse.button_index == MOUSE_BUTTON_RIGHT:
		cancel_target_selection()
	get_viewport().set_input_as_handled()


## Opens attack-target selection for the selected ships (0.25x unless paused). Returns
## whether it is open; opening it again changes nothing.
func begin_target_selection() -> bool:
	if time_control == null:
		return false
	if selection.selected.is_empty():
		show_notice("Select ships before choosing a target")
		return false
	if not target_selection:
		target_selection = true
		time_control.begin_targeting()
		target_selection_changed.emit()
	return true


func cancel_target_selection() -> void:
	if target_selection:
		show_notice("Target selection canceled")
	_end_target_selection()


func _end_target_selection() -> void:
	if not target_selection:
		return
	target_selection = false
	time_control.end_targeting()
	target_selection_changed.emit()


## Player bindings available in arenas with combat and time control.
func _combat_key(code: Key) -> bool:
	var selected: Array = selection.selected
	match code:
		KEY_F1, KEY_F2, KEY_F3:
			var stance := [KEY_F1, KEY_F2, KEY_F3].find(code)
			if orders.set_stance(selected, stance) > 0:
				show_notice("Tactic: %s" % CombatShip.STANCE_NAMES[stance])
		KEY_BACKSPACE:
			if orders.clear_target(selected) > 0:
				show_notice("Target cleared")
		KEY_SPACE:
			time_control.toggle_pause()
		KEY_MINUS, KEY_KP_SUBTRACT:
			time_control.step_speed(-1)
		KEY_EQUAL, KEY_KP_ADD:
			time_control.step_speed(1)
		KEY_T:
			begin_target_selection()
		KEY_ESCAPE:
			if not target_selection:
				return false
			cancel_target_selection()
		KEY_X:
			if not _behavior_selected():
				return false
			if orders.cancel(selected) > 0:
				show_notice("Orders canceled")
		_:
			return false
	return true


## Whether every selected ship has a Behavior node (armed warships).
func _behavior_selected() -> bool:
	var selected: Array = selection.selected
	return not selected.is_empty() and selected.all(func(each: Node) -> bool: return is_instance_valid(each) and each.has_node("Behavior"))


# Ctrl + right-click: a hostile under the cursor -> Attack; a friendly ship -> Guard it;
# the ground -> Attack-Move. Shift + right-click on the ground: add a waypoint.
func _behavior_command(screen_position: Vector2, waypoint: bool) -> void:
	var picked: Node3D = selection.pick_any(screen_position)
	var combat = CombatShip.of(picked)
	var selected: Array = selection.selected.duplicate()
	if waypoint or combat == null or not combat.alive or not player_sees.call(picked):
		# The same resolution as a right-click (a station or, for a miner, an asteroid
		# gives no point); over a hostile, the ground under it.
		var command := resolve_command(screen_position, selected)
		if command.get("kind", -1) == CommandKind.TARGET:
			var camera := get_viewport().get_camera_3d() # Strategic or the rig's (Phase C).
			var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(camera.project_ray_origin(screen_position), camera.project_ray_normal(screen_position))
			command = {} if hit == null else {"point": Vector2(hit.x, hit.z)}
		if not command.has("point"):
			return
		var point: Vector2 = command.point
		var count: int = orders.waypoint(selected, point, true) if waypoint else orders.attack_move(selected, point)
		if count == 0:
			show_notice(GROUP_NOTICE if selected.size() > 1 else "No route found")
		else:
			show_notice("%s (%.0f, %.0f) (%d ship%s)" % ["Waypoint" if waypoint else "Attack-Move", point.x, point.y, count, "" if count == 1 else "s"])
		return
	if combat.faction != selection.player_faction:
		var count: int = orders.attack(selected, picked)
		show_notice("Attack: %s (%d ship%s)" % [DisplayName.of(picked), count, "" if count == 1 else "s"])
	else:
		var count: int = orders.guard(selected, picked)
		show_notice("Guard: %s (%d ship%s)" % [DisplayName.of(picked), count, "" if count == 1 else "s"])
