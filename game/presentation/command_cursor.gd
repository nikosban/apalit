extends Node
## UX round (P8) command cursor: the mouse cursor shows what a right-click would do with
## the current selection, from the scene's own command resolution and refusal checks
## (movement_lab.gd resolve_command() / command_available(), the code the click runs):
## Move, Mine, Dock, or Unavailable when that command would be refused (no route, no
## working or docking position, no free position beside a stationary ship, Dock at the
## station the ship is already docking at, ...); the normal arrow with nothing selected,
## nowhere to order (off the ground) or over the GUI. Built-in OS cursor shapes as
## placeholders. The checks plan routes, so a result is kept per target (the station,
## the asteroid, or a 2 u ground cell) and checked again every REFRESH s; a group's
## assignment is the costliest and is checked only once the cursor rests for GROUP_REST s
## on a cell (Move is shown meanwhile). A MOVE onto an asteroid still resolves outside
## its footprint (RouteFollower), so the Move cursor over an asteroid is not a promise
## to stop inside it. Combat migration: over a visible hostile ship, Target (a right-click
## assigns it to the selected ships); the timings run in real time at every simulation speed.

enum Cursor { NONE, MOVE, MINE, DOCK, UNAVAILABLE, TARGET }

const SHAPES := {Cursor.NONE: Input.CURSOR_ARROW, Cursor.MOVE: Input.CURSOR_CROSS, Cursor.MINE: Input.CURSOR_POINTING_HAND,
	Cursor.DOCK: Input.CURSOR_CAN_DROP, Cursor.UNAVAILABLE: Input.CURSOR_FORBIDDEN, Cursor.TARGET: Input.CURSOR_MOVE}
const CELL := 2.0 # u: ground cells sharing one MOVE check
const REFRESH := 0.5 # s between checks of the same target
const GROUP_REST := 0.25 # s the cursor rests on a cell before a group's assignment is checked

@export var lab_path := NodePath("..")

var cursor := Cursor.NONE
var checks := 0 # Validations run (for checks of the caching).

var _key: Variant = null
var _available := false
var _checked := false
var _age := 0.0
var _shape := -1

@onready var _lab := get_node(lab_path)


func _process(delta: float) -> void:
	if Engine.time_scale > 0.0:
		delta /= Engine.time_scale # UI: real time.
	var viewport := get_viewport()
	update(viewport.get_mouse_position(), viewport.gui_get_hovered_control() == null, delta)
	var shape: int = SHAPES[cursor]
	if shape != _shape:
		_shape = shape
		Input.set_default_cursor_shape(shape)


## The cursor for a screen point (free: not over the GUI), `delta` s after the last call.
func update(mouse: Vector2, free: bool, delta: float) -> Cursor:
	var command: Dictionary = _lab.resolve_command(mouse) if free else {}
	if command.is_empty():
		_key = null
		cursor = Cursor.NONE
		return cursor
	var key := _key_of(command)
	if key != _key:
		_key = key
		_checked = false
		_age = 0.0
	else:
		_age += delta
	var group: bool = command.kind == _lab.CommandKind.GROUP
	if (not _checked and (not group or _age >= GROUP_REST)) or (_checked and _age >= REFRESH):
		_available = _lab.command_available(command)
		_checked = true
		_age = 0.0
		checks += 1
	if not _checked:
		cursor = Cursor.MOVE # A group's assignment not checked yet (the cursor is moving).
	elif not _available:
		cursor = Cursor.UNAVAILABLE
	else:
		match command.kind:
			_lab.CommandKind.DOCK:
				cursor = Cursor.DOCK
			_lab.CommandKind.MINE:
				cursor = Cursor.MINE
			_lab.CommandKind.TARGET:
				cursor = Cursor.TARGET
			_:
				cursor = Cursor.MOVE
	return cursor


# The selection, the command and its target (stations and asteroids by identity, ground
# points by 2 u cell).
func _key_of(command: Dictionary) -> Array:
	var key: Array = [_lab._selection.selected.map(func(ship: Node3D) -> int: return ship.get_instance_id()), command.kind]
	if command.has("ship"):
		key.append(command.ship.get_instance_id())
	elif command.has("station"):
		key.append(command.station.get_instance_id())
	elif command.has("asteroid"):
		key.append(command.asteroid)
	else:
		key.append((command.point as Vector2).snapped(Vector2(CELL, CELL)))
	return key
