extends "res://game/weapons/weapon_config.gd"
## Experiment (PDC saturation fire, not used by the game): a PDC configuration with the
## committed-prediction and tracer controls. Ballistics reuse the inherited fields
## (`weapon_range`, `cooldown` = 1 / rounds per second, `dispersion_max_deg` = per-round
## spread, `projectile_speed`, `projectile_lifetime`, `travel_factor`, magazine, stock).
## Rounds stay point projectiles (no collision radius); the tracer mesh is visual only.

@export_group("Prediction")
## s a committed firing solution is held before it is re-solved from the live threat.
@export_range(0.05, 3.0, 0.01, "suffix:s") var prediction_update_interval := 0.5
## Half-angle of the cone the shared aim error of one commitment is drawn from (uniform
## over its solid angle); every round of that commitment carries the same error.
@export_range(0.0, 10.0, 0.05, "suffix:°") var prediction_error_degrees := 1.5

@export_group("Visual")
## The tracer drawn for each round (size: width × width × length, along −Z). Its material is
## lit by emission only (black albedo, no specular): colour = `emission`, brightness =
## `emission_energy_multiplier` (above 1 clips toward white without glow), opacity = albedo
## alpha. Has no effect on hit detection.
@export var tracer_mesh: Mesh
