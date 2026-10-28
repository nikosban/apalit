extends "res://game/weapons/weapon_config.gd"
## Combat: PDC family configuration (PDC-20 Kestrel: pdc20_kestrel.tres). The inherited
## fields hold the ballistics (`weapon_range`, `cooldown` = 1 / rounds per second,
## `dispersion_max_deg` = per-round dispersion, speed, lifetime, travel, magazine, stock);
## these add the point-defense raid sweep, its committed prediction and the tracer look
## (pdc.gd). Rounds stay zero-radius points; the tracer mesh is visual only.

@export_group("Prediction")
## s a committed firing solution is held before it is re-solved from the live threat.
@export_range(0.05, 3.0, 0.01, "suffix:s") var prediction_update_interval := 0.5
## Half-angle of the cone the shared aim error of one commitment is drawn from (uniform
## over its solid angle); every round fired on that commitment carries the same error.
@export_range(0.0, 10.0, 0.05, "suffix:°") var prediction_error_degrees := 1.5

@export_group("Raid sweep")
## Rounds fired at one threat before the mount moves on to the next.
@export_range(1, 60, 1) var rounds_per_target := 4
## s without firing after switching to another threat (the turret keeps turning).
@export_range(0.0, 2.0, 0.01, "suffix:s") var target_switch_delay := 0.0
## s between re-reads of the mount's threat list (new threats join the cycle at a re-read).
@export_range(0.05, 3.0, 0.01, "suffix:s") var raid_refresh_interval := 0.25

@export_group("Visual")
## The tracer drawn for each round (size: width × width × length, along −Z). Its material is
## lit by emission only (black albedo, no specular): colour = `emission`, brightness =
## `emission_energy_multiplier` (above 1 clips toward white without glow), opacity = albedo
## alpha. Shared resource (pdc20_kestrel_tracer.tres). Has no effect on hit detection.
@export var tracer_mesh: Mesh
