extends Node
## Per-ship combat component (node `Combat`, from every ship archetype, after `Weapons`;
## physics priority 2, after Locomotion, Fuel and Docking). Migrated from the combat
## prototype (v0.5). Every ship has one: it owns the ship's hull (`health`, the only health
## owner), its faction and its targeting; a ship whose `Weapons` node has no hardpoints
## (Frigate, Miner, Transporter) takes damage and can be targeted but never fires. The same
## code runs for every faction; only commands differ (player input or scripted orders,
## both through CombatOrders).
##
## Channels: movement belongs to the existing systems (RouteFollower / GroupOrders,
## Locomotion); this node holds the targeting channel
## (`manual_target`, plus `auto_target` chosen by stance) and the engagement channel
## (`stance`). Setting one never changes another.
##
## Each tick (alive): prune invalid references, resolve the target (strict manual focus,
## v0.3: a manual target is the only offensive target under every stance, and weapons
## that cannot engage it wait; without one, a retained or newly chosen automatic target
## by stance, nearest first, combat id breaking ties), step the weapons (each checks the full firing
## authorization and fires visible projectiles), and, idle only, ask Locomotion.face() to
## align a fixed-axis weapon (the torpedo tube; never during a move).
##
## Threats (Defensive): a valid shot fired at an intended target registers its attacker
## on that ship and on its allies within `defensive_radius`, expiring after
## `threat_persistence` unless refreshed; destroyed, invalid or no longer hostile
## attackers are dropped.
##
## Destruction (health 0): at once weapons off, targets and threats cleared, other ships
## forget it, propulsion off and its movement and work components (route, avoidance, fuel,
## scanner, docking, mining, extraction, transport) stopped, `destroyed` emitted
## (selection drops it); it stays as an inert dark hulk (still a physical obstacle, it
## absorbs projectiles without damage) for `hulk_duration`, then is removed from Ships
## (its entries in other ships' avoidance are cleaned) and freed.

signal destroyed(ship: Node3D)
signal removing(ship: Node3D)
signal damaged(amount: float, projectile_id: int)
signal fired(weapon: Node, target: Node3D)
signal target_changed

enum Stance { HOLD_FIRE, DEFENSIVE, AGGRESSIVE }
enum TargetState { NONE, VALID, OUT_OF_RANGE, OUTSIDE_ARC, OBSCURED, CONTACT_LOST, DESTROYED, INVALID, NOT_HOSTILE, NOT_THREAT, HOLD_FIRE }

const STANCE_NAMES := ["Passive", "Defensive", "Aggressive"] # Behavior prototype: Hold Fire is shown as Passive (target state keeps "Hold Fire").
const STATE_NAMES := ["No target", "Valid", "Out of range", "Outside firing arc", "Temporarily obscured",
	"Sensor contact lost", "Destroyed", "Permanently invalid", "No longer hostile", "Not a confirmed threat", "Hold Fire"]
const FACTION_NAMES := ["Friendly", "Hostile"]
const FACTION_COLORS := [Color(0.25, 0.5, 1.0), Color(1.0, 0.25, 0.2)]
const TINT := 0.45 # Share of the faction colour mixed into the hull materials.
const HULK_COLOR := Color(0.06, 0.06, 0.065)
const TIE := 0.000001
const SimClock := preload("res://game/time/sim_clock.gd")
const STOPPED_ON_DESTRUCTION := ["RouteFollower", "Avoidance", "Fuel", "Scanner", "Docking", "Mining", "Extractor", "Transport"]

@export var faction := 0
@export var combat_id := 0 # Stable identifier (target selection tie-breaker).
@export var stance := Stance.DEFENSIVE
@export var rules: Resource = preload("res://game/combat/combat_rules.tres")
## DurabilityConfig (hull and armor); null = rules.hull_health and no armor. An invalid one
## is rejected as a whole and reported (durability_errors, push_error).
@export var durability: Resource = null
@export var ships_path := NodePath("../..")
@export var contacts_path := NodePath("../../../Contacts")
@export var projectiles_path := NodePath("../../../Projectiles")
@export var effects_path := NodePath("../../../Effects")
@export var asteroids_path := NodePath("../../../Asteroids")

var health := 100.0
var max_health := 100.0 # Resolved maximum hull (durability.max_hull or rules.hull_health).
var armor := 0.0 # Armor condition (global; reduced by armor damage, never repaired).
var max_armor := 0.0
var armor_resistance := 0.0
var durability_errors := PackedStringArray() # Why `durability` was rejected (empty = accepted or none).
var alive := true
var removed_from_play := false
var manual_target: Node3D = null
var auto_target: Node3D = null
var target: Node3D = null # Resolved this tick.
var target_state := TargetState.NONE
var threats := {} # attacker ship -> expiry time (s)
var hitboxes: Array[AABB] = [] # Visible hull parts (Model meshes) in the ship frame.
var weapons: Array = []
var incompatible: Array = [] # Weapons on hardpoints that do not accept them (disabled, not stepped).
var bounds_radius := 0.0 # u, ship origin to the farthest hull box corner.
var point_defense_authorized := true # Always (Gatlings defend under every stance, v0.3).
var events: Array[String] = [] # Target lifecycle log (HUD, tests).
var hulk_left := 0.0
## Behavior prototype v0.1 (set only by a ship's Behavior node; unused elsewhere):
## the target of an Attack command, which the stance always allows (Attack authorizes
## that one target even under Hold Fire); `defensive_priority` makes a Defensive ship rank
## its threats (_defensive_tier(): engageable now first, then attackers of itself, kept in
## `direct_threats`, before attackers of its allies) and leave a held one for a better one.
var attack_target: Node3D = null
var defensive_priority := false
var direct_threats := {} # attacker ship -> expiry time (s): attacks on this ship itself

var _last_position := Vector3.ZERO
var _velocity := Vector3.ZERO
var _was_observable := true
var _remove_queued := false

@onready var ship := get_parent() as Node3D
@onready var ships_node = get_node(ships_path)
@onready var contacts = get_node_or_null(contacts_path)
@onready var projectiles = get_node_or_null(projectiles_path)
@onready var effects = get_node_or_null(effects_path)
@onready var asteroids = get_node_or_null(asteroids_path)
@onready var locomotion = ship.get_node_or_null("Locomotion")


static func of(node: Variant):
	if node == null or not is_instance_valid(node):
		return null
	return (node as Node).get_node_or_null("Combat")


## Simulation time (v0.4: the scene's SimClock; frozen while paused, scaled by time speed).
static func now() -> float:
	return SimClock.now()


func _ready() -> void:
	process_physics_priority = 2
	_resolve_durability()
	_last_position = ship.global_position
	var to_ship := ship.global_transform.affine_inverse()
	for mesh_instance in _meshes("Model"):
		hitboxes.append((to_ship * mesh_instance.global_transform) * mesh_instance.get_aabb())
	for box in hitboxes:
		for i in 8:
			bounds_radius = maxf(bounds_radius, box.get_endpoint(i).length())
	var mounts := ship.get_node_or_null("Weapons")
	if mounts != null:
		for mount in mounts.get_children():
			if mount.has_method("step"):
				weapons.append(mount)
			elif mount.has_method("accepts"):
				var weapon = mount.weapon()
				if weapon == null:
					continue
				if mount.accepts(weapon.config):
					weapons.append(weapon)
				else:
					weapon.enabled = false
					weapon.reason = "Incompatible hardpoint"
					incompatible.append(weapon)
	_apply_look(FACTION_COLORS[faction], TINT)


func _physics_process(delta: float) -> void:
	if delta > 0.0:
		_velocity = (ship.global_position - _last_position) / delta
	_last_position = ship.global_position
	if not alive:
		if not removed_from_play and not _remove_queued:
			hulk_left -= delta
			if hulk_left <= 0.0:
				_remove_queued = true
				_remove.call_deferred()
		return
	_prune()
	_resolve()
	for weapon in weapons:
		weapon.step(delta)
	_request_facing()
	target_state = _summary()


# --- Queries ------------------------------------------------------------------------

## Planar velocity as a 3D vector (Locomotion's, else measured from the motion).
func velocity() -> Vector3:
	if locomotion != null:
		return Vector3(locomotion.velocity.x, 0.0, locomotion.velocity.y)
	return _velocity


func observable(other: Node3D) -> bool:
	return contacts == null or contacts.observable(faction, other)


## Ship-level eligibility of a target (independent of weapons and stance).
func target_status(other: Variant) -> TargetState:
	if other == null:
		return TargetState.NONE
	if not is_instance_valid(other) or not (other as Node).is_inside_tree():
		return TargetState.INVALID
	var combat = of(other)
	if combat == null or combat.removed_from_play:
		return TargetState.INVALID
	if not combat.alive:
		return TargetState.DESTROYED
	if combat.faction == faction:
		return TargetState.NOT_HOSTILE
	if not observable(other):
		return TargetState.CONTACT_LOST
	return TargetState.VALID


## Whether the stance authorizes offensive fire at `other`: VALID, HOLD_FIRE or NOT_THREAT.
func stance_allows(other: Node3D) -> TargetState:
	if other != null and other == attack_target:
		return TargetState.VALID
	match stance:
		Stance.HOLD_FIRE:
			return TargetState.HOLD_FIRE
		Stance.DEFENSIVE:
			return TargetState.VALID if is_threat(other) else TargetState.NOT_THREAT
	return TargetState.VALID


func is_threat(other: Node3D) -> bool:
	return threats.has(other) and threats[other] > now()


func is_hostile_to(other: Node3D) -> bool:
	var combat = of(other)
	return combat != null and combat.faction != faction


func distance_to(other: Node3D) -> float:
	return Vector2(ship.global_position.x, ship.global_position.z).distance_to(Vector2(other.global_position.x, other.global_position.z))


## Fraction (0–1) along from→to where the segment first enters this ship's hull, or -1.
func segment_fraction(from: Vector3, to: Vector3) -> float:
	var to_ship := ship.global_transform.affine_inverse()
	var a := to_ship * from
	var b := to_ship * to
	var length := a.distance_to(b)
	var best := -1.0
	for box in hitboxes:
		var hit: Variant
		if box.has_point(a):
			hit = a
		else:
			hit = box.intersects_segment(a, b)
		if hit != null:
			var fraction := 0.0 if length <= 0.0 else a.distance_to(hit) / length
			if best < 0.0 or fraction < best:
				best = fraction
	return best


func stance_name() -> String:
	return STANCE_NAMES[stance]


func state_name() -> String:
	return STATE_NAMES[target_state]


# --- Channel setters (CombatOrders is the only caller in the game) ---------------------

func set_stance(value: Stance) -> void:
	if stance == value:
		return
	stance = value
	if stance == Stance.HOLD_FIRE:
		auto_target = null


func assign_target(other: Node3D) -> bool:
	if not alive or other == ship or not is_hostile_to(other) or target_status(other) in [TargetState.INVALID, TargetState.DESTROYED]:
		return false
	manual_target = other
	_log("manual target %s" % other.name)
	return true


func clear_target() -> void:
	if manual_target != null:
		_log("manual target cleared (order)")
	manual_target = null


func add_threat(attacker: Node3D, direct := false) -> void:
	if alive and is_hostile_to(attacker):
		threats[attacker] = now() + rules.threat_persistence
		if direct:
			direct_threats[attacker] = threats[attacker]


## A valid shot by one of this ship's weapons at its intended target: registers the
## attack on the target and its allies within their defensive radius.
func on_fired(weapon: Node, at: Node3D) -> void:
	var attacked = of(at)
	if attacked != null:
		for other: Node in ships_node.get_children():
			var combat = of(other)
			if combat != null and combat.alive and combat.faction == attacked.faction \
					and (other == at or combat.distance_to(at) <= combat.rules.defensive_radius):
				combat.add_threat(ship, other == at)
	fired.emit(weapon, at)


## A projectile impact (hostile, valid). Returns whether damage was applied. `penetration`
## null = unconfigured (bypasses armor); `damaged` reports the hull damage actually applied.
func take_hit(amount: float, projectile_id: int, penetration: Variant = null, armor_damage := 0.0) -> bool:
	if not alive:
		return false
	var hit := resolve_hit(amount, penetration, armor_damage, armor, max_armor, armor_resistance)
	armor = hit.armor
	health = maxf(0.0, health - hit.hull_damage)
	damaged.emit(hit.hull_damage, projectile_id)
	if health <= 0.0:
		destroy()
	return true


## Armor resolution for one impact, from the pre-impact armor condition. `penetration` null =
## unconfigured (bypasses armor: the base damage); 0 or less = no hull damage. Returns
## {"hull_damage": float, "armor": float} (64-bit floats; armor clamped to [0, maximum]).
static func resolve_hit(base_damage: float, penetration: Variant, armor_damage: float,
		current_armor: float, maximum_armor: float, resistance: float) -> Dictionary:
	var maximum := maxf(0.0, maximum_armor)
	var condition := clampf(current_armor, 0.0, maximum)
	var hull_damage := maxf(0.0, base_damage)
	if penetration != null:
		var p := maxf(0.0, float(penetration))
		if p <= 0.0:
			hull_damage = 0.0
		else:
			var effective := resistance * condition / maximum if maximum > 0.0 else 0.0
			hull_damage = hull_damage * p / (p + maxf(0.0, effective))
	return {"hull_damage": hull_damage, "armor": maxf(0.0, condition - maxf(0.0, armor_damage))}


## Another ship was destroyed or removed: every reference to it goes at once.
func forget(other: Node3D) -> void:
	if manual_target == other:
		manual_target = null
		_log("manual target cleared (destroyed)")
	if auto_target == other:
		auto_target = null
	if target == other:
		target = null
		target_state = TargetState.NONE
	if attack_target == other:
		attack_target = null
	threats.erase(other)
	direct_threats.erase(other)


func destroy() -> void:
	if not alive:
		return
	alive = false
	health = 0.0
	manual_target = null
	auto_target = null
	target = null
	target_state = TargetState.NONE
	attack_target = null
	threats.clear()
	direct_threats.clear()
	for weapon in weapons:
		weapon.disable()
	if locomotion != null:
		locomotion.propulsion = false
	var docking := ship.get_node_or_null("Docking")
	if docking != null and docking.has_method("abandon"):
		docking.abandon() # Station reservation, queue, hold and exit corridor released.
	for component in STOPPED_ON_DESTRUCTION:
		var node := ship.get_node_or_null(component)
		if node != null:
			node.set_physics_process(false)
	for other: Node in ships_node.get_children():
		var combat = of(other)
		if combat != null and combat != self:
			combat.forget(ship)
	hulk_left = rules.hulk_duration
	_apply_look(HULK_COLOR, 1.0)
	if effects != null:
		effects.destruction(ship.global_position)
	destroyed.emit(ship)


# --- Internals ----------------------------------------------------------------------

# Hull and armor from `durability` when it is valid; otherwise (none, or rejected and
# reported) rules.hull_health and no armor. Armor condition starts at its maximum.
func _resolve_durability() -> void:
	max_health = rules.hull_health
	max_armor = 0.0
	armor_resistance = 0.0
	durability_errors = durability.errors() if durability != null else PackedStringArray()
	if durability != null and durability_errors.is_empty():
		max_health = durability.max_hull
		max_armor = durability.max_armor
		armor_resistance = durability.armor_resistance
	for error in durability_errors:
		push_error("%s: durability %s rejected: %s; using rules.hull_health and no armor" % [ship.name,
			durability.resource_path if durability.resource_path != "" else "(unsaved resource)", error])
	health = max_health
	armor = max_armor


func _prune() -> void:
	var manual_state := target_status(manual_target)
	if manual_target != null and manual_state in [TargetState.INVALID, TargetState.DESTROYED, TargetState.NOT_HOSTILE]:
		_log("manual target cleared (%s)" % STATE_NAMES[manual_state].to_lower())
		manual_target = null
	if manual_target != null:
		var seen := observable(manual_target)
		if seen != _was_observable:
			_log("contact %s: %s" % ["reacquired" if seen else "lost", manual_target.name])
		_was_observable = seen
	else:
		_was_observable = true
	if auto_target != null and not _auto_eligible(auto_target):
		auto_target = null
	for attacker: Variant in threats.keys():
		if threats[attacker] <= now() or target_status(attacker) in [TargetState.INVALID, TargetState.DESTROYED, TargetState.NOT_HOSTILE]:
			threats.erase(attacker)
	for attacker: Variant in direct_threats.keys():
		if not threats.has(attacker) or direct_threats[attacker] <= now():
			direct_threats.erase(attacker)
	if attack_target != null and target_status(attack_target) in [TargetState.INVALID, TargetState.DESTROYED, TargetState.NOT_HOSTILE]:
		attack_target = null
	# Behavior prototype: a held attacker gives way to an eligible threat of a better tier.
	if defensive_priority and stance == Stance.DEFENSIVE and auto_target != null:
		var held := _defensive_tier(auto_target)
		if held > 0 and threats.keys().any(func(other: Variant) -> bool: return other != auto_target and _auto_eligible(other) and _defensive_tier(other) < held):
			auto_target = null


func _direct(other: Node3D) -> bool:
	return direct_threats.has(other) and direct_threats[other] > now()


## Behavior prototype, Defensive target priority (lower first): an attacker some weapon can
## engage now (range, coverage, line of fire) before one it cannot; within each, an
## attacker of this ship itself before an attacker of an ally.
func _defensive_tier(other: Node3D) -> int:
	return (0 if _engageable_now(other) else 2) + (0 if _direct(other) else 1)


func _auto_eligible(other: Node3D) -> bool:
	if target_status(other) != TargetState.VALID:
		return false
	match stance:
		Stance.DEFENSIVE:
			return is_threat(other)
		Stance.AGGRESSIVE:
			return distance_to(other) <= acquisition_reach()
	return false


## v0.4: automatic acquisition reach (Aggressive): the longest authorization range among
## this ship's offensive weapons that can still fire (Weapon.offensive_reach(): enabled, with
## ammunition; a reload or a turret still turning does not shorten it). Contact is required
## separately (target_status), so the sensors limit what is actually acquired.
func acquisition_reach() -> float:
	var reach := 0.0
	for weapon in weapons:
		reach = maxf(reach, weapon.offensive_reach())
	return reach


## v0.4 acquisition preference: whether any offensive weapon could engage `other` from where
## things stand (Weapon.assess(): range, coverage, firing solution and a clear line; only
## alignment, a reload or the cooldown may remain). Used to choose a new automatic target,
## never to drop a held one.
func _engageable_now(other: Node3D) -> bool:
	for weapon in weapons:
		if weapon.offensive_reach() > 0.0 and weapon.assess(other).capable:
			return true
	return false


func _resolve() -> void:
	var previous := target
	match stance:
		Stance.HOLD_FIRE:
			auto_target = null
			target = manual_target
		Stance.DEFENSIVE:
			# Strict manual focus (v0.3): a manual target is never replaced by another
			# hostile; the weapons wait until it is a confirmed threat.
			if manual_target != null:
				auto_target = null
				target = manual_target
			else:
				if auto_target == null:
					auto_target = _nearest()
				target = auto_target if auto_target != null else manual_target
		Stance.AGGRESSIVE:
			if manual_target != null:
				target = manual_target
			else:
				if auto_target == null:
					auto_target = _nearest()
				target = auto_target
	if target != previous:
		target_changed.emit()


# Nearest eligible ship for an automatic target; equal distances: lower combat id.
# v0.4, Aggressive: a ship some offensive weapon could engage now (_engageable_now) comes
# before one only within reach (needing a turn, or obstructed); nearest within each.
func _nearest() -> Node3D:
	var best: Node3D = null
	var best_tier := 99
	var best_distance := INF
	var best_id := 0
	for other: Node in ships_node.get_children():
		var combat = of(other)
		if combat == null or other == ship or not _auto_eligible(other):
			continue
		var tier := 0 if stance != Stance.AGGRESSIVE or _engageable_now(other) else 1
		if defensive_priority and stance == Stance.DEFENSIVE:
			tier = _defensive_tier(other)
		var distance := distance_to(other)
		if tier < best_tier or (tier == best_tier and (distance < best_distance - TIE or (absf(distance - best_distance) <= TIE and combat.combat_id < best_id))):
			best = other
			best_tier = tier
			best_distance = distance
			best_id = combat.combat_id
	return best


# Idle only: turn the hull toward the fixed-axis weapon's aim point.
func _request_facing() -> void:
	if locomotion == null or not locomotion.has_method("face") or target == null:
		return
	if locomotion.has_destination or locomotion.guided:
		return
	if target_status(target) != TargetState.VALID or stance_allows(target) != TargetState.VALID:
		return
	for weapon in weapons:
		if weapon.get("fixed") == true and distance_to(target) <= weapon.config.weapon_range:
			var aim: Vector3 = weapon.aim_point if weapon.has_solution else target.global_position
			var offset := Vector2(aim.x - ship.global_position.x, aim.z - ship.global_position.z)
			if offset.length() > 0.01:
				locomotion.face(locomotion.bearing_heading(offset))
			return


func _summary() -> TargetState:
	var status := target_status(target)
	if status != TargetState.VALID:
		return status
	var allowed := stance_allows(target)
	if allowed != TargetState.VALID:
		return allowed
	var first := TargetState.NONE
	for weapon in weapons:
		if weapon.state == TargetState.VALID:
			return TargetState.VALID
		if first == TargetState.NONE:
			first = weapon.state
	return first


func _log(text: String) -> void:
	events.append("%.2f %s" % [now(), text])
	if events.size() > 40:
		events.remove_at(0)


# Faction tint (alive) or the dark hulk: per-instance material overrides on the hull and
# weapon meshes (shared hull materials are not changed).
func _apply_look(color: Color, share: float) -> void:
	for root_name in ["Model", "Weapons"]:
		for mesh_instance in _meshes(root_name):
			var source: Material = mesh_instance.get_meta("combat_base_material") if mesh_instance.has_meta("combat_base_material") else null
			if not mesh_instance.has_meta("combat_base_material"):
				source = mesh_instance.material_override
				if source == null and mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
					source = mesh_instance.get_active_material(0)
				mesh_instance.set_meta("combat_base_material", source)
			var base := source as StandardMaterial3D
			var material := StandardMaterial3D.new() if base == null else base.duplicate() as StandardMaterial3D
			material.albedo_color = material.albedo_color.lerp(color, share)
			if share >= 1.0:
				material.emission_enabled = false
				material.metallic = 0.0
				material.roughness = 1.0
			mesh_instance.material_override = material


# Meshes of a ship part (the node itself when it is a mesh, and all meshes under it).
func _meshes(part: String) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	var root := ship.get_node_or_null(part)
	if root is MeshInstance3D:
		found.append(root)
	if root != null:
		for mesh_instance in root.find_children("*", "MeshInstance3D", true, false):
			found.append(mesh_instance)
	return found


# After the hulk delay: other ships' avoidance entries for it are cleaned (production
# Avoidance keeps per-ship dictionaries), listeners clean up (selection, markers), then
# it leaves Ships and is freed.
func _remove() -> void:
	if removed_from_play:
		return
	removed_from_play = true
	removing.emit(ship)
	for other: Node in ships_node.get_children():
		if other == ship:
			continue
		var combat = of(other)
		if combat != null:
			combat.forget(ship)
		var avoidance := other.get_node_or_null("Avoidance")
		if avoidance != null:
			avoidance.forget(ship)
	if contacts != null:
		contacts.forget(ship)
	ships_node.remove_child(ship)
	ship.queue_free()
