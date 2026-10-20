extends Node
## Phase 2 Stage 2 cargo hold of its ship (child node): owns the ship's raw cargo
## Inventory with the configured capacity.

const Inventory := preload("res://game/cargo/inventory.gd")

@export var capacity := 1000 # Abstract resource units (provisional).

var inventory := Inventory.new()


func _ready() -> void:
	inventory.capacity = capacity
