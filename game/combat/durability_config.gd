extends Resource
## Combat: a ship's durability (hull and one global armor condition), assigned to a Combat
## component's `durability`. A Combat component without one keeps `rules.hull_health` and
## has no armor. Armor condition starts at `max_armor`. A configuration with any invalid
## value is rejected as a whole (Combat reports it and keeps the no-durability behavior).

@export var max_hull := 150.0 # Hull at spawn and the displayed maximum (finite, > 0).
@export var max_armor := 0.0 # Armor condition at spawn and its maximum (finite, >= 0; 0 = no armor).
@export var armor_resistance := 0.0 # Effective armor at full condition (finite, >= 0).


## Why this configuration is invalid (empty when it is valid).
func errors() -> PackedStringArray:
	var found := PackedStringArray()
	if not is_finite(max_hull) or max_hull <= 0.0:
		found.append("max_hull must be finite and > 0 (is %s)" % str(max_hull))
	if not is_finite(max_armor) or max_armor < 0.0:
		found.append("max_armor must be finite and >= 0 (is %s)" % str(max_armor))
	if not is_finite(armor_resistance) or armor_resistance < 0.0:
		found.append("armor_resistance must be finite and >= 0 (is %s)" % str(armor_resistance))
	return found
