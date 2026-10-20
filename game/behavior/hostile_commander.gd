extends Node
## Minimal hostile commander (node `HostileCommander`, combat migration): gives one
## faction's armed ships their objectives and commands through CombatOrders, the same
## interface the player's input uses. It never moves, aims or fires a ship, plans no
## route and reads nothing about other factions: each ship carries the orders out with
## its own Behavior (Commands, Tactics, Weapon Profiles) on the production movement
## systems, exactly as a player ship would. Not a strategic AI: no formations,
## reinforcements or plans beyond the configured objectives.
##
## Configuration (per scene):
##   faction      the faction it commands (1: hostile);
##   tactic       given once to every ship it commands (-1: keep the ship's own);
##   profile      requested weapon profile for every ship that supports it (-1: keep);
##   escorted / escorts   ship names: each escort Guards the escorted ship while it lives;
##   objectives   Attack-Move route points, in order, looping.
## Every DECISION_INTERVAL s of simulation time, each live ship of the faction with a
## Behavior node and no command gets: Guard of its escorted ship (escorts), else an
## Attack-Move to its next objective. A ship given a command keeps it until it ends (its
## Behavior decides; Attack-Move engages on the way under Aggressive).

const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const DECISION_INTERVAL := 2.0 # s

@export var faction := 1
@export var tactic := -1
@export var profile := -1
@export var escorted := ""
@export var escorts := PackedStringArray()
@export var objectives := PackedVector2Array()
@export var ships_path := NodePath("../Ships")
@export var orders_path := NodePath("../CombatOrders")

var log: Array[String] = []
var _next_objective := {} # ship -> index into objectives
var _configured := {} # ship -> true once tactic and profile are given
var _clock := 0.0

@onready var _ships := get_node(ships_path)
@onready var _orders := get_node(orders_path)
@onready var _navigation := get_node_or_null("../StaticNavigation")


func _physics_process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.000001:
		return
	_clock += DECISION_INTERVAL
	for ship: Node in _ships.get_children():
		var combat = CombatShip.of(ship)
		var behavior = Behavior.of(ship)
		if combat == null or behavior == null or not combat.alive or combat.faction != faction:
			continue
		if _navigation != null and not _navigation.is_ready(ship.get_node("RouteFollower").planning_radius()):
			continue # Orders wait for the ship's navigation map (its first synchronization).
		if not _configured.has(ship):
			_configured[ship] = true
			if tactic >= 0:
				_orders.set_stance([ship], tactic)
			if profile >= 0:
				_orders.set_profile([ship], profile)
		if behavior.command != Behavior.Command.NONE:
			continue
		var protected: Node3D = _ships.get_node_or_null(escorted) if escorted != "" else null
		if escorts.has(String(ship.name)) and protected != null and CombatShip.of(protected) != null and CombatShip.of(protected).alive:
			if _orders.guard([ship], protected) > 0:
				_note("%s: guard %s" % [ship.name, protected.name])
			continue
		if objectives.is_empty():
			continue
		var index: int = _next_objective.get(ship, 0)
		var point: Vector2 = objectives[index % objectives.size()]
		if _orders.attack_move([ship], point) > 0:
			_next_objective[ship] = index + 1
			_note("%s: attack-move to (%.0f, %.0f)" % [ship.name, point.x, point.y])


func _note(text: String) -> void:
	log.append("%.1f %s" % [CombatShip.now(), text])
	if log.size() > 200:
		log.remove_at(0)
