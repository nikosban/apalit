extends Node
## Phase 2 Stage 2 mining equipment of its ship (child node): extraction rate and
## working range, and the extraction step itself. Rates are integrated over time
## (fractions carried between ticks), so the extracted total does not depend on
## the physics rate. Never more than the asteroid's reserves or the free cargo;
## the asteroid's reserves fall by exactly what the cargo gains. Phase 3: the units
## arrive as the asteroid's raw resources in its fixed proportions
## (AsteroidField.extract()).

const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const Inventory := preload("res://game/cargo/inventory.gd")

@export var extraction_rate := 20.0 # Units per second (provisional).
@export var working_range := 4.5 # u from the ship's centre to the asteroid's surface (provisional).
@export var field_path := NodePath("../../../Asteroids")

var _carry := 0.0 # Fraction of a unit carried to the next tick.

@onready var _ship := get_parent() as Node3D
@onready var _field := get_node(field_path) as AsteroidField


func in_range(asteroid: int) -> bool:
	return _field.surface_distance(asteroid, Vector2(_ship.global_position.x, _ship.global_position.z)) <= working_range


func reset() -> void:
	_carry = 0.0


## One extraction step from an asteroid into a cargo inventory; returns the units moved.
func extract(asteroid: int, inventory: Inventory, delta: float) -> int:
	_carry += extraction_rate * delta
	var whole := floori(_carry)
	_carry -= whole
	var units := _field.extract(asteroid, mini(whole, inventory.free_space()))
	var moved := 0
	for resource: StringName in units:
		moved += inventory.add(resource, units[resource]) # Phase 3: each raw resource on its own.
	return moved
