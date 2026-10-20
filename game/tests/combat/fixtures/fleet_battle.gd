extends Node
## Combat prototype v0.3, E05 only: battle result and pacing record (node `FleetBattle` in
## encounters/e05_fleet.tscn; physics priority 4, after the projectiles). It only
## observes. Times are the scenario clock (EnemyController.time).
##   Result: once every ship of one faction is destroyed (alive false; hulks count as
##   destroyed), the battle ends once: VICTORY when the hostile fleet is gone, DEFEAT when
##   the player's is, DRAW when both go in the same tick. `result` lists the elapsed time
##   and each surviving ship with its hull; the arena shows it (`result_text`, HUD).
##   Pacing: first shot or launch, first guided launch, first impact on a ship (damage),
##   first kill, every kill, and the end.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const DisplayName := preload("res://game/ui/display_name.gd")
const PLAYER := 0
const HOSTILE := 1

var finished := false
var winner := -1 # PLAYER, HOSTILE, or 2 for a draw
var elapsed := 0.0
var survivors: Array[Dictionary] = [] # {name, faction, hull}
var pacing := {"first_shot": -1.0, "first_launch": -1.0, "first_impact": -1.0, "first_kill": -1.0, "end": -1.0}
var kills: Array[Dictionary] = [] # {time, ship, faction}
var result := ""

@onready var _arena := get_parent()
@onready var _controller = _arena.get_node("EnemyController")


func _ready() -> void:
	process_physics_priority = 4
	for ship: Node in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat == null:
			continue
		combat.fired.connect(func(_weapon: Node, _target: Node3D) -> void: _mark("first_shot"))
		combat.damaged.connect(func(_amount: float, _id: int) -> void: _mark("first_impact"))
		combat.destroyed.connect(_on_destroyed)
	_arena.get_node("Projectiles").ordnance_launched.connect(func(_node: Node3D) -> void: _mark("first_launch"))


func _physics_process(_delta: float) -> void:
	if finished or not _controller.started:
		return
	var alive := [0, 0]
	for ship: Node in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat != null and combat.alive:
			alive[combat.faction] += 1
	if alive[PLAYER] > 0 and alive[HOSTILE] > 0:
		return
	finished = true
	elapsed = _controller.time
	pacing.end = elapsed
	winner = 2 if alive[PLAYER] == 0 and alive[HOSTILE] == 0 else (PLAYER if alive[PLAYER] > 0 else HOSTILE)
	var lines: Array[String] = []
	for ship: Node in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat != null and combat.alive:
			survivors.append({"name": String(ship.name), "faction": combat.faction, "hull": combat.health})
			lines.append("%s  hull %d / %d" % [DisplayName.of(ship), roundi(combat.health), roundi(combat.rules.hull_health)])
	var title: String = ["VICTORY - hostile fleet destroyed", "DEFEAT - your fleet was destroyed", "DRAW - both fleets destroyed"][winner]
	result = "%s\nElapsed %d:%02d\n%s" % [title, floori(elapsed / 60.0), int(elapsed) % 60, "Survivors:\n" + "\n".join(lines) if not lines.is_empty() else "No survivors"]
	_arena.result_text = result


func _on_destroyed(ship: Node3D) -> void:
	_mark("first_kill")
	kills.append({"time": _controller.time, "ship": String(ship.name), "faction": CombatShip.of(ship).faction})


func _mark(key: String) -> void:
	if pacing[key] < 0.0 and _controller.started:
		pacing[key] = _controller.time
