extends Node
## F6: the production Combat Test arena, Projectiles and OrdnanceTrails, with controlled
## samples instead of autonomous combat. Save shared style edits, then restart F6/game.
## Both factions: shell, fallback tracer, unknown style and the unchanged Kestrel mesh;
## torpedo, Wayfarer and Barrage flights use the real launch/flight/trail code.
## 1/2/3 zoom 5/40/150; wheel/pan/rotate, Space and -/= use production controls.

const Arena := preload("res://game/scenes/combat_test.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const WeaponConfig := preload("res://game/weapons/weapon_config.gd")
const OrdnanceConfig := preload("res://game/weapons/ordnance_config.gd")
const Wayfarer := preload("res://game/weapons/gcm4_wayfarer.tres")
const Barrage := preload("res://game/weapons/rl8_barrage.tres")
const Tracer := preload("res://game/weapons/pdc20_kestrel_tracer.tres")
const SITE := Vector3(-240, 1.5, -240)

@export var playing := true
@export_range(0.1, 3.0, 0.05, "suffix:s") var round_interval := 0.5
@export_range(10.0, 30.0, 0.5, "suffix:s") var ordnance_interval := 12.0
@export var zoom_distance := 40.0

var _arena: Node3D
var _round_clock := 0.0
var _ordnance_clock := 0.0
var _owners: Array[Node3D] = []
var _configs: Array[Resource] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	process_physics_priority = 4 # Samples are released after the production projectile step.
	_arena = Arena.instantiate()
	_arena.scenario_keys = false
	_arena.get_node("Asteroids").session_seed = 7007
	add_child(_arena)
	for ship: Node3D in _arena.get_node("Ships").get_children():
		ship.get_node("Behavior").set_physics_process(false)
		var combat = CombatShip.of(ship)
		combat.stance = CombatShip.Stance.HOLD_FIRE
		for weapon in combat.weapons:
			weapon.enabled = false
		var faction: int = combat.faction
		ship.get_node("Locomotion").place(Vector2(SITE.x + (-30.0 if faction == 0 else 30.0), SITE.z), -PI * 0.5 if faction == 0 else PI * 0.5)
		_owners.append(ship)
	_arena.sensors.evaluate()
	var torpedo := WeaponConfig.new()
	torpedo.ordnance = OrdnanceConfig.new()
	torpedo.ordnance.lifetime = 6.0 # Preview sample only; no ship carries torpedoes.
	torpedo.damage = 0.0
	_configs = [torpedo, Wayfarer.duplicate(true), Barrage.duplicate(true)]
	for config in _configs:
		config.damage = 0.0 # Samples may cross a hull; do not destroy the preview's owners.
	_zoom(zoom_distance)
	_round_clock = round_interval
	_ordnance_clock = ordnance_interval


func _physics_process(delta: float) -> void:
	if not playing:
		return
	_round_clock += delta
	_ordnance_clock += delta
	if _round_clock >= round_interval:
		_round_clock = 0.0
		_rounds()
	if _ordnance_clock >= ordnance_interval:
		_ordnance_clock = 0.0
		_launches()


func _rounds() -> void:
	for owner_ship in _owners:
		var faction: int = CombatShip.of(owner_ship).faction
		var sign_x := 1.0 if faction == 0 else -1.0
		for i in 4:
			var point := SITE + Vector3(-15.0 * sign_x, 1.0, -8.0 + i * 2.0)
			var style: StringName = [&"shell", &"tracer", &"unknown", &"tracer"][i]
			_arena.projectiles.spawn(owner_ship, faction, point, Vector3.RIGHT * sign_x * 20.0,
				0.0, 60.0, 3.0, null, style, null, 0.0, false, Tracer if i == 3 else null)


func _launches() -> void:
	for owner_ship in _owners:
		var faction: int = CombatShip.of(owner_ship).faction
		var target := _owners[1 - faction]
		var sign_x := 1.0 if faction == 0 else -1.0
		for i in _configs.size():
			var point := SITE + Vector3(-20.0 * sign_x, 0.0, 4.0 + i * 4.0)
			var origin := Transform3D(Basis.looking_at(Vector3.RIGHT * sign_x), point)
			var remembered := {"locked_point": SITE + Vector3(40.0 * sign_x, 0.0, 4.0 + i * 4.0)} if i == 2 else {}
			_arena.projectiles.launch(owner_ship, faction, origin, _configs[i], target, remembered)


func _zoom(distance: float) -> void:
	var rig = _arena.get_node("CameraRig")
	rig.position = Vector3(SITE.x, 0, SITE.z)
	rig.zoom_distance = distance
	rig._apply_zoom()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var index := [KEY_1, KEY_2, KEY_3].find(event.physical_keycode)
		if index >= 0:
			_zoom([5.0, 40.0, 150.0][index])
