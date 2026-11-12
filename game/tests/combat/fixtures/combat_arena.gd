extends "res://game/scenes/movement_lab.gd"
## Combat test fixture: the encounter arena (encounter_arena.tscn and its E05 variant) on
## the production scene script. Everything a player uses (combat commands, tactics,
## profiles, time control, target selection, envelopes, strategic markers, grid, fog of
## war) is shared production code; this adds only the fixture duties:
##   - scenario set-up: `scenarios.apply()` places the ships and sets their channels; the
##     production Behavior nodes are removed first, so a scenario's ships carry Behavior
##     only where the scenario gives it (E05 with `behavior_layer`);
##   - key (tests and manual inspection only): C toggles the player's sensor contact on
##     the hostile under the cursor.

@export var scenario_index := 0 # Applied in _ready (-1: the scene as authored).
@export var scenarios: Script = null # Scenario set (encounters.gd).
## The scenario gives its player ships a Behavior node (E05 when this is set; the combat
## suites load E05 without it unless they test the Behavior layer).
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
	var hud := player.get_node("CombatHUD")
	hud.configure_result(func() -> String: return result_text)
	hud.configure_scenario(_scenario_title)
	if scenario_index >= 0:
		scenario_name = scenarios.apply(self, scenario_index)
		_show_notice(scenario_name)
	ensure_behavior_view()


func _scenario_title() -> String:
	return scenario_name + ("\nScenario conditions:\n" + "\n".join(conditions) if not conditions.is_empty() else "")


func _development_key(code: Key, shift: bool = false) -> bool:
	match code:
		KEY_C:
			get_viewport().set_input_as_handled()
			var picked: Node3D = player.selection.pick_any(get_viewport().get_mouse_position())
			var combat = CombatShip.of(picked)
			if combat != null and combat.faction != PLAYER_FACTION:
				var seen: bool = contacts.toggle(PLAYER_FACTION, picked)
				_show_notice("Sensor contact %s: %s" % ["restored" if seen else "lost", DisplayName.of(picked)])
			return true
	return super._development_key(code, shift)
