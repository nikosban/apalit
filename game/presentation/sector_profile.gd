extends Resource
## Environmental lighting prototype: a sector's environmental appearance (the light of
## the system's central star as it reaches the sector, and how the sector's space reads).
## Presentation only. Several sectors may share one profile; the prototype has one warm
## profile (`warm_sector.tres`). The star's direction is not part of it: the scene's
## DirectionalLight3D stands for it. Colours are sRGB.

@export_group("Stellar light")
@export var key_color := Color(1, 0.9, 0.78) # DirectionalLight3D colour
@export var key_energy := 1.15
@export var ambient_color := Color(0.42, 0.5, 0.66) # Cool fill on shaded surfaces
@export var ambient_energy := 0.4
@export var background_color := Color(0.03, 0.035, 0.048)
@export var ground_color := Color(0.045, 0.047, 0.055) # The arena ground's albedo

@export_group("Strategic shadows")
@export var shadow_color := Color(0.02, 0.025, 0.045) # Tinted attenuation, not black
@export var shadow_strength := 0.5

@export_group("Fog of war")
@export var fog_color := Color(0.045, 0.055, 0.075) # Cool, desaturated
@export var fog_strength := 0.6 # Local / Tactical
@export var strategic_fog_strength := 0.45

@export_group("Dust and debris")
@export var dust_color := Color(0.78, 0.64, 0.5) # Lit by the star
@export var dust_strength := 0.045 # Alpha of one dust cloud (Local)
@export var strategic_dust_strength := 0.16
@export var debris_color := Color(0.33, 0.31, 0.29)
