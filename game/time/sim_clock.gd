extends Node
## Combat (migrated from the prototype v0.4): the simulation clock (node `SimClock`, first child of every combat
## scene). The one source of simulation time: it adds up the physics delta, so it stops
## while the tree is paused and follows Engine.time_scale (0.25x: a quarter of real time,
## 2x: twice). Physics priority -100: it advances before anything reads it in a tick.
## The clock in the tree is found through `now()` (CombatShip.now() reads it); a combat
## scene restarts it at 0 when it is built.

static var _current: Node = null
static var _warned := false

var time := 0.0 # s of simulation time since this scene entered the tree.


static func now() -> float:
	if _current == null or not is_instance_valid(_current):
		if not _warned:
			_warned = true
			push_error("SimClock: no simulation clock in the tree")
		return 0.0
	return _current.time


static func current() -> Node:
	return _current if _current != null and is_instance_valid(_current) else null


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	process_physics_priority = -100
	_current = self


func _exit_tree() -> void:
	if _current == self:
		_current = null


func _physics_process(delta: float) -> void:
	time += delta
