extends Node
## The one authority over simulation speed for the whole game (node `TimeControl`, added
## by the scene's combat layer, always processing; migrated from the combat prototype
## v0.4). Nothing else writes Engine.time_scale or SceneTree.paused. Every simulation
## system (ships, combat, sensors, mining, refining, the Shipyard, fuel, transport,
## docking, the survey) runs on physics time, so pause and speed apply to all of them.
##
## States: Paused (SceneTree.paused; the simulation nodes are PAUSABLE, input, camera and
## UI are not), Targeting (0.25x while attack-target selection is open), and the manual
## speed (0.25x / 1x / 2x, stepped with - and =). Explicit pause wins over targeting;
## targeting does not stack (entering it again changes nothing); a manual speed chosen
## during targeting is the one restored when targeting ends. While paused the engine
## time scale is 1, so always-processing UI runs in real time. Leaving the tree (reset,
## another encounter) restores 1x, unpaused.

signal changed

const SPEEDS := [0.25, 1.0, 2.0]
const TARGETING_SPEED := 0.25

var speed := 1.0 # Manual speed, restored after targeting.
var paused := false # Explicit pause.
var targeting := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_apply()


func _exit_tree() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0


## The simulation speed now: 0 paused, else 0.25 targeting, else the manual speed.
func scale() -> float:
	if paused:
		return 0.0
	return TARGETING_SPEED if targeting else speed


func set_paused(value: bool) -> void:
	if paused == value:
		return
	paused = value
	_apply()


func toggle_pause() -> void:
	set_paused(not paused)


## Steps the manual speed (-1 slower, +1 faster) within SPEEDS. Returns whether it changed.
func step_speed(direction: int) -> bool:
	var index := clampi(SPEEDS.find(speed) + direction, 0, SPEEDS.size() - 1)
	if SPEEDS[index] == speed:
		return false
	speed = SPEEDS[index]
	_apply()
	return true


func begin_targeting() -> void:
	if targeting:
		return
	targeting = true
	_apply()


func end_targeting() -> void:
	if not targeting:
		return
	targeting = false
	_apply()


func label() -> String:
	if paused:
		return "PAUSED" + ("  |  target selection" if targeting else "")
	if targeting:
		return "%sx  target selection" % _format(TARGETING_SPEED)
	return "%sx" % _format(speed)


func _format(value: float) -> String:
	return "%.2f" % value if value < 1.0 else "%d" % int(value)


func _apply() -> void:
	get_tree().paused = paused
	Engine.time_scale = 1.0 if paused else (TARGETING_SPEED if targeting else speed)
	changed.emit()
