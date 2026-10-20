extends Node
## Phase 2 Stage 1 scanner equipment of its ship (child node; equipment
## configuration, not ship class). activate(): an immediate Scan Area centred on the
## ship's current position, handed to the fleet Survey; the ship's own cooldown
## starts at activation. Reads the ship's position only: never orders or moves it.

enum Kind { GENERIC, MINING }

const Survey := preload("res://game/survey/survey.gd")

@export var kind := Kind.GENERIC # GENERIC: resource family; MINING: also composition and reserves.
@export var radius := 50.0 # u (provisional)
@export var cooldown := 3.0 # s (provisional)
@export var survey_path := NodePath("../../../Survey")

var cooldown_left := 0.0

@onready var _ship := get_parent() as Node3D
@onready var _survey := get_node(survey_path) as Survey


func _physics_process(delta: float) -> void:
	cooldown_left = maxf(0.0, cooldown_left - delta)


func kind_name() -> String:
	return "Mining Scanner" if kind == Kind.MINING else "Generic Scanner"


## Scan Area. False (nothing happens) while cooling down.
func activate() -> bool:
	if cooldown_left > 0.0:
		return false
	cooldown_left = cooldown
	var level := Survey.Level.ANALYZED if kind == Kind.MINING else Survey.Level.IDENTIFIED
	_survey.start_scan(Vector2(_ship.global_position.x, _ship.global_position.z), radius, level)
	return true
