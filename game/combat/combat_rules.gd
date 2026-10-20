extends Resource
## Combat (migrated from the prototype v0.2): ship-level combat values (provisional testing defaults).

@export var hull_health := 150.0 # v0.5: 1.5x the v0.2 100, chosen in the E05 survivability playtest (prototype baseline)
@export var defensive_radius := 30.0 # u; allies of an attacked ship within this may respond (Defensive).
@export var threat_persistence := 10.0 # s; a threat record expires unless refreshed by another valid attack.
@export var hulk_duration := 2.0 # s a destroyed ship stays visible (inert) before it is removed.
