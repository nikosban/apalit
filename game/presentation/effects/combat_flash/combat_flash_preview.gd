@tool
extends Node3D
## Authoring scene of the combat flashes (open combat_flash_preview.tscn; F6 to run). Its
## `Effects` node is the production spawner (game/combat/combat_effects.gd), so every flash
## here comes from the same calls, offsets, colours, scene (combat_flash.tscn) and shared
## presets as in combat; no simulation runs. Every `interval` it fires each sample once
## (also in the editor), so each flash's whole lifetime and its disappearance are seen.
##
## Global look: select `Effects` and edit its presets, or open muzzle.tres, impact.tres,
## impact_soft.tres, burst.tres or destruction.tres directly. Those files are used by every
## gameplay scene; a change applies to the next flashes (in the editor at once).
##
## Samples: each Marker3D under `Samples` is one flash at its position (move them freely);
## SAMPLES below says which call it makes. Run time: 1 zoom 5 (Local), 2 zoom 40, 3 zoom
## 150 (Tactical); the wheel, W/A/S/D, Q/E and middle drag move the production camera rig.
## In the editor the rig camera shows its authored pose (zoom 15).

const ZOOMS := [5.0, 40.0, 150.0]
const BLUE := Color(0.25, 0.5, 1.0) # CombatShip.FACTION_COLORS
const RED := Color(1.0, 0.25, 0.2)
## Marker name -> [call, colour, size or radius] (Effects' public methods).
const SAMPLES := {
	"MuzzleBlueSmall": ["muzzle", BLUE, 0.6], "MuzzleBlue": ["muzzle", BLUE, 1.0], "MuzzleBlueLarge": ["muzzle", BLUE, 1.4],
	"MuzzleRedSmall": ["muzzle", RED, 0.6], "MuzzleRed": ["muzzle", RED, 1.0], "MuzzleRedLarge": ["muzzle", RED, 1.4],
	"Impact": ["impact", null, 1.6], "ImpactSoft": ["impact_soft", null, 1.0],
	"Burst": ["burst", Color(1.0, 0.8, 0.5), 0.5], "BurstInterception": ["burst", Color(1.0, 0.9, 0.6), 0.45],
	"Destruction": ["destruction", null, 1.0],
}

@export_range(0.1, 5.0, 0.05, "suffix:s") var interval := 1.2 # between replays (destruction lives 0.8 s)
@export var playing := true

var _clock := 0.0

@onready var _effects: Node3D = $Effects
@onready var _samples: Node3D = $Samples
@onready var _rig = $CameraRig


func _ready() -> void:
	_clock = interval # Fire at once.


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if Engine.is_editor_hint() or key == null or not key.pressed or key.echo:
		return
	var index := [KEY_1, KEY_2, KEY_3].find(key.physical_keycode)
	if index >= 0:
		_rig.max_zoom = ZOOMS[2]
		_rig.zoom_distance = ZOOMS[index]
		_rig._apply_zoom()


func _process(delta: float) -> void:
	if not playing:
		return
	_clock += delta
	if _clock < interval:
		return
	_clock = 0.0
	for marker: Node3D in _samples.get_children():
		var sample: Array = SAMPLES.get(String(marker.name), [])
		if sample.is_empty():
			continue
		var point := marker.global_position
		match sample[0]:
			"muzzle":
				_effects.muzzle_flash(point, -marker.global_basis.z, sample[1], sample[2])
			"impact", "impact_soft":
				_effects.impact(point, sample[0] == "impact", sample[2])
			"burst":
				_effects.burst(point, sample[1], sample[2])
			"destruction":
				_effects.destruction(point)
