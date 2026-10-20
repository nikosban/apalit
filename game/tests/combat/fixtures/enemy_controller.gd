extends Node
## Combat prototype v0.2: scenario script runner (node `EnemyController`, physics
## priority −2, before every ship). It runs a scenario's scripted command decisions at
## fixed times or once a condition holds, and patrols (next waypoint whenever the ship
## is idle). Every ship order goes through CombatOrders, so scripted ships use the same
## command interfaces, firing authorization, avoidance, collision, target validation and
## cooldowns as player ships. A few steps are labelled test events (contact loss, a
## faction change, a forced destruction): scenario conditions, not enemy decisions.
## The scenario clock starts once the navigation maps are ready for every ship (orders
## given before the first map synchronization would query an empty map); v0.4: it is
## read from the scene's SimClock, not accumulated separately.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const SimClock := preload("res://game/time/sim_clock.gd")

var time := 0.0 # Scenario time: SimClock time since the scenario started.
var _start := 0.0
var started := false
var log: Array[String] = []
var _steps: Array[Dictionary] = [] # {at, label, action, done}
var _triggers: Array[Dictionary] = [] # {label, condition, action, done}
var _patrols: Array[Dictionary] = [] # {ship, points, next}

@onready var _orders = get_parent().get_node("CombatOrders")
@onready var _navigation = get_parent().get_node_or_null("StaticNavigation")
@onready var _ships = get_parent().get_node("Ships")


func _ready() -> void:
	process_physics_priority = -2


func at(seconds: float, label: String, action: Callable) -> void:
	_steps.append({"at": seconds, "label": label, "action": action, "done": false})


func when(label: String, condition: Callable, action: Callable) -> void:
	_triggers.append({"label": label, "condition": condition, "action": action, "done": false})


func patrol(ship: Node3D, points: Array) -> void:
	_patrols.append({"ship": ship, "points": points, "next": 0})


func _physics_process(delta: float) -> void:
	if not started:
		started = _navigation_ready()
		if not started:
			return
		# The scenario clock is the simulation clock from the tick before this one (v0.4:
		# one clock; this tick counts, as before).
		_start = SimClock.now() - delta
	time = SimClock.now() - _start
	for step in _steps:
		if not step.done and time >= step.at - 0.000001:
			step.done = true
			_run(step.label, step.action)
	for trigger in _triggers:
		if not trigger.done and trigger.condition.call():
			trigger.done = true
			_run(trigger.label, trigger.action)
	for entry in _patrols:
		var ship: Variant = entry.ship
		var combat = CombatShip.of(ship)
		if combat == null or not combat.alive:
			continue
		var locomotion = ship.get_node("Locomotion")
		var follower = ship.get_node("RouteFollower")
		if not locomotion.has_destination and follower.status != RouteFollower.RouteStatus.WAITING:
			var point: Vector2 = entry.points[entry.next]
			entry.next = (entry.next + 1) % entry.points.size()
			_orders.move([ship], point)


func _navigation_ready() -> bool:
	if _navigation == null:
		return true
	for ship: Node in _ships.get_children():
		var follower = ship.get_node_or_null("RouteFollower")
		if follower != null and not _navigation.is_ready(follower.planning_radius()):
			return false
	return true


func _run(label: String, action: Callable) -> void:
	log.append("%.2f %s" % [time, label])
	action.call()
