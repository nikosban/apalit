extends Node
## Combat test fixture (ported from the combat prototype's entry scene): builds an
## encounter arena and rebuilds it from its scene file on reset (F5) or an encounter key, so
## every encounter starts from the same authored state; the previous arena (ships,
## projectiles, effects, navigation maps) is freed with it. Encounters E01–E05 (keys 1–5)
## and the behavior scenarios P01–P03 (keys 6–8) each have their own scene (their asteroids
## differ). The prototype's v0.2 scenarios T01–T13 are not migrated.

const ENCOUNTERS := [
	preload("res://game/tests/combat/fixtures/e01_cannon.tscn"),
	preload("res://game/tests/combat/fixtures/e02_torpedo.tscn"),
	preload("res://game/tests/combat/fixtures/e03_escort.tscn"),
	preload("res://game/tests/combat/fixtures/e04_missile.tscn"),
	preload("res://game/tests/combat/fixtures/e05_fleet.tscn"),
	# Behavior scenarios (keys 6–8): P01–P03.
	preload("res://game/tests/combat/fixtures/p01_defensive.tscn"),
	preload("res://game/tests/combat/fixtures/p02_siege.tscn"),
	preload("res://game/tests/combat/fixtures/p03_guard.tscn"),
]

const E05_INDEX := 4

signal arena_loaded(arena: Node3D)

@export var encounter_index := 0

var arena: Node3D
var loads := 0


func _ready() -> void:
	load_encounter(encounter_index)


func load_encounter(index: int) -> void:
	encounter_index = index
	_replace(ENCOUNTERS[index].instantiate(), index)


func _replace(new_arena: Node3D, index: int) -> void:
	if arena != null:
		remove_child(arena)
		arena.queue_free()
		arena = null
	arena = new_arena
	arena.scenario_index = index
	arena.behavior_layer = arena.encounter and index == E05_INDEX # E05 is played with the Behavior layer.
	arena.encounter_requested.connect(func(requested: int) -> void: load_encounter.call_deferred(requested))
	add_child(arena)
	loads += 1
	arena_loaded.emit(arena)
