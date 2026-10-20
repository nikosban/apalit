extends Node
## Phase 4 shipyard of its station (child node of a Station; the Shipyard station in
## main.tscn): one production slot that builds one Mining Ship or Transport Ship per
## order from ingots in the station's own storage, then deploys it at the station's
## `Deployment` marker (a Marker3D child of the station; its -Z is the new ship's bow).
##
## Lifecycle: IDLE -> WAITING (order accepted, ingredients missing) -> CONSTRUCTING (the
## whole recipe was consumed at once) -> deployed -> IDLE. When the deployment area is
## obstructed at completion the finished ship is held (AWAITING_DEPLOYMENT) and deployed
## once it clears. One order at a time, no queue. A waiting order consumes and reserves
## nothing (other users of the storage take stock as before) and can be cancelled;
## construction cannot. Ingots delivered during construction are only stored.
##
## Deployment: blocked while any ship's collision circle is closer to the marker than
## both footprints + DEPLOY_MARGIN (moving, docked or idle ships alike); nothing is
## moved or overridden. The ship is created from its complete unit scene with its
## transform set before it enters the tree, added under Ships, named on in its series
## (Miner3, Transporter2, ...), and announced through `ship_deployed` (registration in
## selection and the scene's command layer, in the same call) and `notice`. It starts
## idle with the existing initialization (full tank, no order or assignment).
## Physics priority 3, as the Refinery: after the ships' Docking (1) and the stations
## (2), so stock delivered or loaded in a tick is seen in that tick.

signal notice(text: String)
signal ship_deployed(ship: Node3D)

const DisplayName := preload("res://game/ui/display_name.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const EPSILON := 1e-6 # s; summed per-tick deltas complete on time.
const DEPLOY_MARGIN := 1.0 # u between footprints at the deployment point.

enum State { IDLE, WAITING, CONSTRUCTING, AWAITING_DEPLOYMENT }

const STATE_NAMES := ["Idle", "Waiting for Materials", "Constructing", "Awaiting Deployment"]

## Recipes (provisional prototype values, not final balance): ingots per ship and
## construction time in seconds.
const RECIPES := {
	&"mining_ship": {"name": "Mining Ship", "scene": preload("res://game/ships/miner_unit.tscn"), "series": "Miner",
		"ingots": {&"iron_ingot": 200, &"nickel_ingot": 100, &"silicon_ingot": 50}, "duration": 60.0},
	&"transport_ship": {"name": "Transport Ship", "scene": preload("res://game/ships/transporter_unit.tscn"), "series": "Transporter",
		"ingots": {&"iron_ingot": 300, &"titanium_ingot": 100, &"cobalt_ingot": 50}, "duration": 90.0},
}
const RECIPE_ORDER: Array[StringName] = [&"mining_ship", &"transport_ship"]

@export var ships_path := NodePath("../../../Ships")
@export var deployment_path := NodePath("../Deployment")

var state := State.IDLE
var recipe := &"" # The active order's recipe (&"" when idle).
var elapsed := 0.0 # s of construction done.
var last_completed := "" # Name of the last ship deployed.

var _finished: Node3D = null # The completed ship while it waits for a clear deployment area.

@onready var _ships := get_node(ships_path) as Node3D
@onready var _deployment := get_node(deployment_path) as Node3D


func _ready() -> void:
	process_physics_priority = 3 # After Docking (1) and the station (2).


func _exit_tree() -> void:
	if _finished != null:
		_finished.free() # Never deployed (the scene is closing).
		_finished = null


## The station whose storage the shipyard uses.
func station() -> Node3D:
	return get_parent() as Node3D


## Accepts an order only while idle; it starts at once when every ingredient is in
## storage, otherwise it waits. Returns whether it was accepted (refused: no change).
func order(id: StringName) -> bool:
	if state != State.IDLE or not RECIPES.has(id):
		return false
	recipe = id
	elapsed = 0.0
	state = State.WAITING
	_try_start()
	return true


## Cancels a waiting order (nothing was consumed). Refused in every other state.
func cancel() -> bool:
	if state != State.WAITING:
		return false
	recipe = &""
	state = State.IDLE
	return true


## Units of each ingredient still missing in storage for a recipe ({ingot: units > 0}).
func missing(id: StringName) -> Dictionary:
	var result := {}
	var ingots: Dictionary = RECIPES[id].ingots
	for ingot: StringName in ingots:
		var short: int = ingots[ingot] - _storage().quantity_of(ingot)
		if short > 0:
			result[ingot] = short
	return result


func duration() -> float:
	return RECIPES[recipe].duration if recipe != &"" else 0.0


## Share of the construction done (0-1); 0 unless constructing or finished.
func progress() -> float:
	if state == State.CONSTRUCTING or state == State.AWAITING_DEPLOYMENT:
		return clampf(elapsed / duration(), 0.0, 1.0)
	return 0.0


func remaining_time() -> float:
	return maxf(duration() - elapsed, 0.0) if state == State.CONSTRUCTING else 0.0


func state_name() -> String:
	return STATE_NAMES[state]


## Whether a ship of this radius could be deployed now: every ship's collision circle
## keeps both footprints + DEPLOY_MARGIN from the deployment point.
func deployment_clear(radius: float) -> bool:
	var point := _planar(_deployment.global_position)
	for ship: Node in _ships.get_children():
		var follower := ship.get_node_or_null("RouteFollower")
		var locomotion := ship.get_node_or_null("Locomotion")
		if follower == null or locomotion == null:
			continue
		if locomotion.planar_position.distance_to(point) < radius + follower.ship_radius + DEPLOY_MARGIN:
			return false
	return true


func _physics_process(delta: float) -> void:
	match state:
		State.WAITING:
			_try_start()
		State.CONSTRUCTING:
			elapsed += delta
			if elapsed >= duration() - EPSILON:
				elapsed = duration()
				_finished = RECIPES[recipe].scene.instantiate()
				state = State.AWAITING_DEPLOYMENT
				_try_deploy() # Clear: deployed in this tick.
		State.AWAITING_DEPLOYMENT:
			_try_deploy()


# Consumes the whole recipe at once when every ingredient is in storage; else nothing.
func _try_start() -> void:
	var storage := _storage()
	var ingots: Dictionary = RECIPES[recipe].ingots
	for ingot: StringName in ingots:
		if storage.quantity_of(ingot) < ingots[ingot]:
			return
	for ingot: StringName in ingots:
		storage.remove(ingot, ingots[ingot])
	elapsed = 0.0
	state = State.CONSTRUCTING


func _try_deploy() -> void:
	if not deployment_clear(_finished.get_node("RouteFollower").ship_radius):
		return
	var ship := _finished
	_finished = null
	ship.name = _next_name(RECIPES[recipe].series)
	# Position and heading (bow = the marker's -Z) set before the ship enters the tree,
	# where Locomotion reads them in _ready().
	var pose := Transform3D(Basis(Vector3.UP, _deployment.global_rotation.y), _deployment.global_position)
	ship.transform = _ships.global_transform.affine_inverse() * pose
	_ships.add_child(ship)
	last_completed = String(ship.name)
	recipe = &""
	elapsed = 0.0
	state = State.IDLE
	ship_deployed.emit(ship)
	notice.emit("%s: %s completed" % [DisplayName.of(station()), DisplayName.of(ship)])


# Next name in a series: "Miner" + (highest number in use + 1); a ship named exactly
# like the series counts as number 1 (Transporter -> Transporter2).
func _next_name(series: String) -> String:
	var highest := 0
	for ship: Node in _ships.get_children():
		var ship_name := String(ship.name)
		if ship_name == series:
			highest = maxi(highest, 1)
		elif ship_name.begins_with(series) and ship_name.substr(series.length()).is_valid_int():
			highest = maxi(highest, ship_name.substr(series.length()).to_int())
	return "%s%d" % [series, highest + 1]


func _storage() -> Inventory:
	return station().storage


static func _planar(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)
