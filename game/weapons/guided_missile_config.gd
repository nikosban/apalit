extends "res://game/weapons/weapon_config.gd"
## Guided cruise-missile family: shared weapon/flight resources, resource-driven cell
## layout and committed salvos. Runtime ammunition, scheduling and target memory belong
## to each launcher, never this resource. Flight uses the shared OrdnanceConfig.

@export var cells := 4
@export var cell_columns := 2
@export var cell_size := Vector3(1.0, 0.3, 1.4) # Housing width, height, depth (u).
@export var launch_rotation_degrees := Vector3(90.0, 0.0, 0.0) # Muzzle -Z -> mount +Y.
@export var salvo_size := 4
@export var salvo_interval := 0.2 # s of simulation time.
