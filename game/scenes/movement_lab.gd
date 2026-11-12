extends Node3D
## Assembles the arena's simulation, Command, Player and world presentation.

const DisplayName := preload("res://game/ui/display_name.gd")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Docking := preload("res://game/stations/docking.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const ShipAvoidance := preload("res://game/avoidance/ship_avoidance.gd")
const PlayerController := preload("res://game/player/player.gd")
const CommandController := preload("res://game/command/command.gd")
const GroupOrders := preload("res://game/orders/group_orders.gd")
const Shipyard := preload("res://game/shipyard/shipyard.gd")
const AvoidanceScenarios := preload("res://game/scenes/avoidance_scenarios.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const TimeControl := preload("res://game/time/time_control.gd")
const FogView := preload("res://game/presentation/fog_view.gd")
const WeaponEnvelopes := preload("res://game/presentation/weapon_envelopes.gd")
const TacticalMarkers := preload("res://game/presentation/tactical_markers.gd")
const TacticalGrid := preload("res://game/presentation/tactical_grid.gd")
const StrategicView := preload("res://game/presentation/strategic_view.gd")
const SectorEnvironment := preload("res://game/presentation/sector_environment.gd")
const BehaviorView := preload("res://game/presentation/behavior_view.gd")
const SensorGridOverlay := preload("res://game/presentation/sensor_grid/sensor_grid_overlay.tscn")
const PLAYER_FACTION := 0
## Children that keep processing while paused (input, camera, UI, presentation); every
## other child is simulation and pauses.
const ALWAYS_NODES := ["Player", "DebugUI", "NavigationDebug", "AvoidanceDebug",
	"TimeControl", "WeaponEnvelopes", "TacticalMarkers", "TacticalGrid", "FogView",
	"CombatOverlay", "BehaviorView", "WorldHighlight", "ObjectMarkers", "StrategicView",
	"SectorEnvironment", "SensorGridOverlay"]
const SCENARIO_KEYS := [KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0, KEY_MINUS]
const SCENARIO_ZOOM := 40.0
const GROUND_HALF_SIZE := 150.0 # Sector half-size without a StaticNavigation (sector_half_size()).

signal notice_requested(text: String)

@export var scenario_keys := true # Keys 4-9, 0, - set up the avoidance scenarios (test arena only).
## Prototype (Sector Showcase round, not a balance decision): share of each ship's fuel
## consumption charged for movement inside this sector (Fuel). 1 keeps the Test Arena's
## behaviour; a scene can set e.g. 0.1, so fuel mainly limits future inter-sector travel.
@export var local_fuel_scale := 1.0
## The tactical grid is withdrawn from play (no grid node, no G toggle, no rendering
## cost); TacticalGrid is kept for a later return. True restores it in a scene.
@export var tactical_grid_available := false
## Environment rendering (SectorEnvironment, StrategicView): the sky, 0 A flat background
## (Test Arena), 1 B the panorama (Combat Test), 2 C for comparison (F8 cycles);
## development switches, each independent, for troubleshooting: designed environment
## lighting with B (F7), Strategic formation depth and sky-safe Strategic fog (F6), god
## rays (F9). Every scene keeps them off; Combat Test uses B only.
@export var environment_experiment := 0
@export var lighting_experiment_d := false
@export var strategic_experiment_e := false
@export var god_rays_enabled := false
var _registered := {} # ship -> true: registered ships (register_ship())
# Combat layer (scenes with CombatOrders).
var debug_visible := false # Combat debug overlay (F10).
var time_control: Node = null
var envelopes: Node3D = null # Weapon envelopes (Alt, target selection).
var markers: CanvasLayer = null # Tactical markers (Phase B).
var strategic: Node3D = null # Strategic View (Phase C prototype).
var environment: Node3D = null # Sector lighting, dust and debris (environmental prototype).
var grid: MeshInstance3D = null # Tactical grid (G); null while it is withdrawn.
var sensors: Node = null # The scene's Sensors, else null (no fog: every ship seen).
var fog_view: MeshInstance3D = null
var sensor_grid: MeshInstance3D = null # Sensor grid overlay of the first selected ship (with Sensors).
var fog_reveal := false # DEBUG override: show every ship despite the fog (tests only).

@onready var player := $Player as PlayerController
@onready var command := $Command as CommandController
@onready var _group_orders := $GroupOrders as GroupOrders
@onready var _debug_ui := $DebugUI
@onready var _navigation_debug := $NavigationDebug
@onready var _avoidance_debug := $AvoidanceDebug
@onready var _asteroids := get_node_or_null("Asteroids") as AsteroidField # Absent in the test arena.
@onready var orders = get_node_or_null("CombatOrders") # Combat layer; absent in the test arena.
@onready var contacts = get_node_or_null("Contacts")
@onready var projectiles = get_node_or_null("Projectiles")
@onready var effects = get_node_or_null("Effects")


func _ready() -> void:
	command.configure(_group_orders, $StaticNavigation as StaticNavigation, _asteroids, sector_half_size)
	if orders != null:
		orders.configure_move(command.issue_move)
		_setup_combat_layer()
	var stations := get_node_or_null("Stations")
	player.configure($Ships, stations, _asteroids, get_node_or_null("Survey"), orders,
		time_control, strategic, markers, sector_half_size(), player_sees, command, _development_key)
	command.notice_requested.connect(player.show_notice)
	notice_requested.connect(player.show_notice)
	for ship: Node3D in $Ships.get_children():
		register_ship(ship)
	if stations != null:
		for station in stations.get_children():
			var shipyard := station.get_node_or_null("Shipyard") as Shipyard
			if shipyard != null:
				shipyard.notice.connect(_show_notice)
				shipyard.ship_deployed.connect(_on_ship_deployed)
	player.selection.selection_changed.connect(_on_selection_changed)
	_on_selection_changed()
	if orders != null:
		ensure_behavior_view()


## Half-size of the square sector, centred on the origin: the scene's navigable map
## (StaticNavigation.map_half_size; 150 in the Test Arena). MOVE validity, the camera's
## pan bounds, the tactical grid and Strategic View all follow it.
func sector_half_size() -> float:
	var navigation := get_node_or_null("StaticNavigation")
	return navigation.map_half_size if navigation != null else GROUND_HALF_SIZE


## Adds the Behavior ground lines once some ship has a Behavior node.
func ensure_behavior_view() -> void:
	if has_node("BehaviorView") or not $Ships.get_children().any(func(each: Node) -> bool: return each.has_node("Behavior")):
		return
	var view := BehaviorView.new()
	view.name = "BehaviorView"
	view.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(view)


# Combat layer: process modes (simulation pauses, input / camera / UI do not), the time
# authority, envelopes, sector environment, tactical markers, grid and (with Sensors) the
# fog of war and the sensor grid overlay.
func _setup_combat_layer() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for child in get_children():
		child.process_mode = Node.PROCESS_MODE_ALWAYS if ALWAYS_NODES.has(String(child.name)) else Node.PROCESS_MODE_PAUSABLE
	time_control = TimeControl.new()
	time_control.name = "TimeControl"
	add_child(time_control)
	envelopes = WeaponEnvelopes.new()
	envelopes.name = "WeaponEnvelopes"
	envelopes.player = player
	add_child(envelopes)
	environment = SectorEnvironment.new()
	environment.name = "SectorEnvironment"
	add_child(environment)
	strategic = StrategicView.new() # Before the markers: its under-layer draws beneath theirs.
	strategic.name = "StrategicView"
	strategic.configure_player(player.camera_rig, player.selection, player.cancel_presses, player.resolve_command)
	add_child(strategic)
	markers = TacticalMarkers.new()
	markers.name = "TacticalMarkers"
	markers.camera_rig = player.camera_rig
	add_child(markers)
	if tactical_grid_available:
		grid = TacticalGrid.new()
		grid.name = "TacticalGrid"
		grid.camera_rig = player.camera_rig
		add_child(grid)
	sensors = get_node_or_null("Sensors")
	if sensors != null:
		fog_view = FogView.new()
		fog_view.name = "FogView"
		add_child(fog_view)
		sensor_grid = SensorGridOverlay.instantiate()
		sensor_grid.name = "SensorGridOverlay"
		add_child(sensor_grid)


## Connects a ship's notices and adds it to the ships whose orders the movement indicator
## shows (while selected): for every ship at start, and (Phase 4) for a ship added under
## Ships during the game. A ship already registered is left as it is.
func register_ship(ship: Node3D) -> void:
	if _registered.has(ship):
		return
	for node in [ship.get_node("RouteFollower"), _mining_of(ship), _docking_of(ship), ship.get_node_or_null("Fuel"), _transport_of(ship)]:
		if node != null and not node.notice.is_connected(_show_notice):
			node.notice.connect(_show_notice)
	_registered[ship] = true
	# Forward synchronously until the ship and world lifecycle owns registration.
	if is_instance_valid(player):
		player.register_ship(ship)
	# Combat migration: a destroyed ship leaves the selection at once; when its hulk is
	# removed its pick boxes, ring and movement indicator go.
	var combat = CombatShip.of(ship)
	if combat != null:
		combat.destroyed.connect(_on_destroyed)
		combat.removing.connect(_on_removing)


func _on_destroyed(destroyed_ship: Node3D) -> void:
	if is_instance_valid(player):
		player.ship_destroyed(destroyed_ship)
	command.forget_ship(destroyed_ship)
	_show_notice("%s destroyed" % DisplayName.of(destroyed_ship))


func _on_removing(removed_ship: Node3D) -> void:
	if is_instance_valid(player):
		player.ship_removed(removed_ship)
	_registered.erase(removed_ship)


# A shipyard deployed a ship: selection and commands know it before the next frame.
func _on_ship_deployed(ship: Node3D) -> void:
	register_ship(ship)


func _map_ready(ship: Node) -> bool:
	return ($StaticNavigation as StaticNavigation).is_ready((ship.get_node("RouteFollower") as RouteFollower).planning_radius())


func _mining_of(ship: Node) -> MiningOperation:
	return ship.get_node_or_null("Mining") as MiningOperation


func _docking_of(ship: Node) -> Docking:
	return ship.get_node_or_null("Docking") as Docking


func _transport_of(ship: Node) -> TransportOperation:
	return ship.get_node_or_null("Transport") as TransportOperation


# Debug panel and drawings follow the selection when exactly one ship is selected.
func _on_selection_changed() -> void:
	var ships := player.selection.selected
	var ship: Node3D = ships[0] if ships.size() == 1 else null
	_debug_ui.selected_count = ships.size()
	_debug_ui.target = ship.get_node("Locomotion") as ShipLocomotion if ship != null else null
	_debug_ui.follower = ship.get_node("RouteFollower") as RouteFollower if ship != null else null
	_debug_ui.avoidance = ship.get_node("Avoidance") as ShipAvoidance if ship != null else null
	_debug_ui.target_name = String(ship.name) if ship != null else ""
	_navigation_debug.follower = _debug_ui.follower
	_avoidance_debug.avoidance = _debug_ui.avoidance


# Debug scenario setup: every ship is placed at rest (movers facing their targets,
# unnamed ships at the far parking points), counters reset, then the movers get
# their orders through their RouteFollowers and are selected.
func _start_scenario(index: int) -> void:
	var ships := $Ships.get_children()
	var profiles := {}
	for ship in ships:
		var locomotion := ship.get_node("Locomotion") as ShipLocomotion
		profiles[ship.name] = [locomotion.max_speed, locomotion.forward_accel]
	var scenario: Dictionary = AvoidanceScenarios.lab_presets(profiles)[index]
	var placements := {}
	for entry: Dictionary in scenario.parked:
		placements[entry.ship] = [entry.point, 0.0]
	for entry: Dictionary in scenario.movers:
		var travel: Vector2 = entry.target - entry.start
		placements[entry.ship] = [entry.start, atan2(-travel.x, -travel.y)]
	var parking := 0
	for ship in ships:
		var placement: Array = placements.get(ship.name, [])
		if placement.is_empty():
			placement = [AvoidanceScenarios.PARKING[parking], 0.0]
			parking += 1
		(ship.get_node("Locomotion") as ShipLocomotion).place(placement[0], placement[1])
		var follower := ship.get_node("RouteFollower") as RouteFollower
		follower.status = RouteFollower.RouteStatus.NONE
		follower.route = PackedVector2Array()
		(ship.get_node("Avoidance") as ShipAvoidance).reset()
	var movers := []
	for entry: Dictionary in scenario.movers:
		var ship := get_node("Ships/" + entry.ship)
		(ship.get_node("RouteFollower") as RouteFollower).order(entry.target)
		movers.append(ship)
	var center: Vector2 = scenario.center
	player.camera_rig.global_position = Vector3(center.x, 0.0, center.y)
	player.camera_rig.zoom_distance = SCENARIO_ZOOM
	player.camera_rig._apply_zoom()
	player.selection.set_selection(movers)
	_show_notice("Scenario %d: %s" % [index + 1, scenario.name])


func _show_notice(text: String) -> void:
	notice_requested.emit(text)


# --- Combat layer (combat migration) ---------------------------------------------------

func ship(ship_name: String) -> Node3D:
	return $Ships.get_node_or_null(ship_name)


func selection() -> Node:
	return player.selection


## Whether the player may see this ship now (its model, marker, bar, label, hover,
## picking and inspection). Own ships always; without Sensors in the scene every ship;
## with Sensors, a hostile ship only while the player's faction detects it. `fog_reveal`
## is the explicitly labelled debug override (tests; never the default).
func player_sees(other: Node3D) -> bool:
	if sensors == null or fog_reveal:
		return true
	return sensors.detected(PLAYER_FACTION, other)


## Whether the ship's 3D presentation (model, propulsion effects) is drawn now: while the
## player may see it, at every zoom (Phase B: the tactical markers are drawn over the
## models, never instead of them).
func model_shown(other: Node3D) -> bool:
	return player_sees(other)


## Whether the player knows of this ship at all (live, or a lost contact still marked).
func player_knows(other: Node3D) -> bool:
	return player_sees(other) or (sensors != null and sensors.is_lost(PLAYER_FACTION, other))


## Drawn by TacticalMarkers at every zoom: the last-known position of each lost contact
## (a static dashed grey diamond and its age; nothing about the ship's current state).
func draw_contact_memory(canvas: Control, camera: Camera3D, width: float) -> void:
	if sensors == null or fog_reveal:
		return
	var scale: float = markers.scale_factor()
	for entry: Dictionary in sensors.last_known(PLAYER_FACTION):
		var point: Vector3 = entry.position
		if camera.is_position_behind(point):
			continue
		var center := camera.unproject_position(point)
		var d := 13.0 * scale
		var corners := [center + Vector2(0, -d), center + Vector2(d, 0), center + Vector2(0, d), center + Vector2(-d, 0), center + Vector2(0, -d)]
		for i in 4:
			canvas.draw_dashed_line(corners[i], corners[i + 1], Color(0.75, 0.76, 0.78, 0.85), width, 3.0 * scale)
		canvas.draw_string(ThemeDB.fallback_font, center + Vector2(-4, 5) * scale, "?", HORIZONTAL_ALIGNMENT_LEFT, -1, int(14 * scale), Color(0.8, 0.8, 0.82, 0.9))
		canvas.draw_string(ThemeDB.fallback_font, center + Vector2(d + 4 * scale, 4 * scale), "last seen %.0f s" % entry.age, HORIZONTAL_ALIGNMENT_LEFT, -1, int(11 * scale), Color(0.75, 0.76, 0.78, 0.8))



## The narrow internal movement request of a ship's Behavior (autonomous positioning: an
## engagement position, a guard position, a waypoint leg, a stop): one RouteFollower
## order to the point, moved beside a stationary ship occupying it (as a single MOVE).
## Unlike a command it cancels no assignment, shows no notice or marker change and is not
## announced as a command. Refused (false, nothing changes) while the station has the ship
## (docking in any state but Not docked / Unable to Dock), with no free point beside an
## occupying ship, or without a route. Before the navigation map is ready the order is
## queued by RouteFollower (as any order then), unchecked.
## Stage 6B.2: `through` (queued Waypoints after `point`) is passed on to the
## RouteFollower order to be flown through; its last point (the stop) is moved beside an
## occupying stationary ship as `point` is, or left for a later leg request without a
## free point there.
func autonomous_move(ship: Node3D, point: Vector2, through := PackedVector2Array()) -> bool:
	var docking := _docking_of(ship)
	if docking != null and (docking.under_control() or not (docking.state in [Docking.State.NONE, Docking.State.UNABLE])):
		return false
	var follower := ship.get_node("RouteFollower") as RouteFollower
	if not _map_ready(ship):
		return follower.order(point, through) # Queued by RouteFollower until the map is ready (as a command).
	var occupied := _group_orders.resolve_occupied(ship, point)
	if not occupied.is_empty():
		if not occupied.has("point"):
			return false
		point = occupied.point
	if not through.is_empty():
		through = through.duplicate()
		var last := _group_orders.resolve_occupied(ship, through[through.size() - 1])
		if last.has("point"):
			through[through.size() - 1] = last.point
		elif not last.is_empty():
			through.remove_at(through.size() - 1)
	var position := (ship.get_node("Locomotion") as ShipLocomotion).planar_position
	if ($StaticNavigation as StaticNavigation).plan(follower.planning_radius(), position, point).size() < 2:
		return false
	return follower.order(point, through)


## One destination per ship around `point`: the point itself for one ship, GroupOrders'
## assignment for several (only the ships that can be placed; {} when none can).
func group_destinations(ships: Array, point: Vector2) -> Dictionary:
	if ships.size() == 1:
		return {ships[0]: point}
	if ships.is_empty():
		return {}
	return _group_orders.assign(ships, point)


# Development bindings keep their arena-specific actions and precedence over player keys.
func _development_key(code: Key, _shift: bool = false) -> bool:
	if scenario_keys and SCENARIO_KEYS.has(code):
		_start_scenario(SCENARIO_KEYS.find(code))
		return true
	if orders == null:
		return false
	match code:
		KEY_F10:
			debug_visible = not debug_visible
		KEY_F8:
			if environment == null:
				return false
			environment.set_sky_mode((environment.sky_mode + 1) % 3)
			_show_notice("Environment %s" % environment.SKY_MODE_NAMES[environment.sky_mode])
		KEY_F7:
			if environment == null:
				return false
			environment.set_environment_lighting(not environment.lighting_d)
			_show_notice("Environment lighting (with B) %s" % ("on" if environment.lighting_d else "off"))
		KEY_F6:
			if strategic == null:
				return false
			strategic.set_environment_depth(not strategic.e_enabled)
			_show_notice("Strategic depth %s" % ("on" if strategic.e_enabled else "off"))
		KEY_F9:
			if environment == null:
				return false
			environment.set_god_rays(environment.god_rays == null)
			_show_notice("God rays %s" % ("on" if environment.god_rays != null else "off"))
		KEY_G:
			if grid == null:
				return false # Withdrawn: the key does nothing.
			grid.visible = not grid.visible
			_show_notice("Tactical grid %s" % ("on" if grid.visible else "off"))
		_:
			return false
	get_viewport().set_input_as_handled()
	return true
