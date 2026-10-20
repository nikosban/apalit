extends "res://game/scenes/movement_lab.gd"
## Combat test fixture: the encounter arenas (encounter_arena.tscn and its E01–E05 /
## P01–P03 variants) on the production scene script. Everything a player uses (combat
## commands, tactics, profiles, time control, target selection, envelopes, strategic
## markers, grid, fog of war) is production movement_lab.gd; this adds only the fixture
## duties:
##   - scenario set-up: `scenarios.apply()` places the ships and sets their channels (the
##     prototype's encounters and behavior scenarios); the production Behavior nodes are
##     removed first, so a scenario's ships carry Behavior exactly where the prototype's
##     did (P01–P03 player ships, E05 with `behavior_layer`);
##   - keys (tests and manual inspection only): C toggles the player's sensor contact on
##     the hostile under the cursor, F5 reloads the encounter, 1–5 E01–E05, 6–8 P01–P03
##     (through the fixture lab, combat_lab.tscn).

const SCENARIO_KEY_LIST := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8]

signal encounter_requested(index: int)

@export var scenario_index := 0 # Applied in _ready (-1: the scene as authored).
@export var scenarios: Script = null # Scenario set (encounters.gd).
@export var encounter := false # An encounter scene (F5 reloads the encounter).
## The scenario gives its player ships a Behavior node (P01–P03 always; E05 when this is
## set, which the fixture lab does for play; the combat suites load E05 without it).
@export var behavior_layer := false

var scenario_name := ""
var conditions: Array[String] = [] # Scenario-specific conditions shown in the HUD.
var result_text := "" # Battle result shown in the HUD (E05 FleetBattle).

@onready var enemy_controller = $EnemyController


func _ready() -> void:
	for ship: Node in $Ships.get_children():
		var behavior := ship.get_node_or_null("Behavior")
		if behavior != null:
			ship.remove_child(behavior)
			behavior.free()
	super._ready()
	if scenario_index >= 0:
		scenario_name = scenarios.apply(self, scenario_index)
		_show_notice(scenario_name)
	ensure_behavior_view()


func _combat_key(code: Key, shift: bool = false) -> bool:
	match code:
		KEY_C:
			var picked: Node3D = _selection.pick_any(get_viewport().get_mouse_position())
			var combat = CombatShip.of(picked)
			if combat != null and combat.faction != PLAYER_FACTION:
				var seen: bool = contacts.toggle(PLAYER_FACTION, picked)
				_show_notice("Sensor contact %s: %s" % ["restored" if seen else "lost", DisplayName.of(picked)])
			return true
		KEY_F5:
			if encounter:
				encounter_requested.emit(scenario_index)
			return true
	var index := SCENARIO_KEY_LIST.find(code)
	if index >= 0 and not shift:
		encounter_requested.emit(index)
		return true
	return super._combat_key(code, shift)
