extends Node3D
## Combat (migrated from the prototype v0.3): a weapon hardpoint (node under the ship's `Weapons`). Its
## transform is the measured mounting transform on the hull (mount −Z = its neutral
## direction); the installed weapon is its only child, at identity. It defines the
## physical limits for whatever is installed: size, the weapon families it accepts, the
## traverse (± yaw around its forward) and elevation range for articulated weapons, and
## the planar launch cone for fixed-axis weapons (torpedo tubes, fixed cannons).
## Installation is a scene edit for v0.3 (fixed loadouts); `accepts()` is the check a
## future shipyard would use. An incompatible weapon is disabled by the ship's Combat.

@export_enum("Small", "Medium", "Large") var size := 1
@export var families := PackedStringArray(["cannon"])
@export var yaw_limit_deg := 160.0
@export var pitch_min_deg := -15.0
@export var pitch_max_deg := 60.0
@export var cone_deg := 15.0


## Whether a weapon of this configuration fits (family listed, size not larger).
func accepts(config: Resource) -> bool:
	return config != null and families.has(String(config.family)) and config.size <= size


func weapon() -> Node:
	for child in get_children():
		if child.has_method("step"):
			return child
	return null
