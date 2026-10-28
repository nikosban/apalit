extends Node3D
## Combat (migrated from the prototype): everything in flight (node `Projectiles`, physics priority 3, after
## every ship's Combat).
##
## Rounds (v0.2): small emissive bars (cannon shells, Gatling tracers) travelling from the
## muzzle at constant velocity; every tick its segment (previous → next position) is
## swept against every ship's visible hull boxes (the firing ship excepted for its own
## rounds), the asteroid spheres and, v0.3, every hostile guided ordnance's interception
## sphere (relative motion over the same tick, so a fast round cannot pass through a
## moving missile), nearest hit first. Hit:
##   - a live hostile ship: damage applied once (take_hit), impact flash;
##   - a friendly ship or a hulk: stopped (absorbed), impact flash, no damage;
##   - an asteroid: stopped, impact flash;
##   - hostile ordnance (v0.3): both destroyed (outcome "intercept" / "intercepted"), a
##     small flash, no damage to anything.
## A round is removed on its first hit, or at its lifetime or maximum travel (only shots
## already fired legally travel that far; authorization uses weapon range).
##
## Guided ordnance (v0.3): torpedoes and missiles (ordnance.gd), stepped here first each
## tick, then swept (previous → current position) against hull boxes (never its own
## ship's), and asteroid spheres. A hit on a live hostile ship applies its damage once;
## friendly ships and hulks stop it without damage; an asteroid stops it. It ends at its
## technical limit ("expired") or, for missiles, at its flight time ("self_destruct").
## It is interceptable from its first tick (ejection included) by hostile rounds only.
## Rockets (unguided ordnance of kind rocket) are interceptable only by hostile rounds
## spawned with `intercepts_rockets` (Gatling-family rounds: PDCs and legacy Gatlings);
## other rounds (cannon shells) pass through them. Torpedoes and missiles are unaffected.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const Ordnance := preload("res://game/combat/ordnance.gd")
const CombatObstacles := preload("res://game/combat/combat_obstacles.gd")
const STYLES := {&"shell": Vector3(0.07, 0.07, 0.55), &"tracer": Vector3(0.045, 0.045, 1.6)}
const BAR_SIZE := Vector3(0.07, 0.07, 0.55)

signal impact(record: Dictionary)
signal spawned_projectile(record: Dictionary)
signal ordnance_launched(ordnance: Node3D)
signal ordnance_finished(record: Dictionary)

@export var ships_path := NodePath("../Ships")
@export var asteroids_path := NodePath("../Asteroids")
@export var effects_path := NodePath("../Effects")
@export var contacts_path := NodePath("../Contacts")
@export var trails_path := NodePath("../OrdnanceTrails")

var active: Array[Dictionary] = []
var ordnance: Array = [] # Live guided ordnance nodes.
var spawned := 0
var launched := 0
var impacts := 0
var expired := 0
var damage_events := {} # projectile / ordnance id -> damage applications (must stay 1)
var records: Array[Dictionary] = [] # Finished rounds (tests): {id, outcome, ship, point, traveled, age, ...}
var ordnance_records: Array[Dictionary] = [] # Finished ordnance (tests).
var _next_id := 1
static var _meshes := {}

@onready var _ships := get_node(ships_path)
@onready var _asteroids = get_node_or_null(asteroids_path)
@onready var _effects = get_node_or_null(effects_path)
@onready var _contacts = get_node_or_null(contacts_path)
@onready var _trails = get_node_or_null(trails_path)


func _ready() -> void:
	process_physics_priority = 3


## `penetration` null = unconfigured (bypasses armor); both armor values only reach ship hulls.
## `intercepts_rockets`: the round can also destroy hostile rockets. `mesh`: drawn instead of
## the style's bar (visual only; hits stay the zero-radius segment sweep).
func spawn(owner_ship: Node3D, faction: int, origin: Vector3, velocity: Vector3, damage: float, max_travel: float, lifetime: float, target: Node3D, style: StringName = &"shell",
		penetration: Variant = null, armor_damage := 0.0, intercepts_rockets := false, mesh: Mesh = null) -> int:
	var id := _next_id
	_next_id += 1
	var node := MeshInstance3D.new()
	node.name = "Projectile%d" % id
	node.mesh = mesh if mesh != null else _bar(faction, style)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	var direction := velocity.normalized()
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	node.global_transform = Transform3D(Basis.looking_at(direction, up), origin)
	var record := {"id": id, "node": node, "owner_id": owner_ship.get_instance_id(), "owner_name": String(owner_ship.name),
		"faction": faction, "position": origin, "origin": origin, "velocity": velocity, "damage": damage,
		"penetration": penetration, "armor_damage": armor_damage, "intercepts_rockets": intercepts_rockets,
		"max_travel": max_travel, "lifetime": lifetime, "traveled": 0.0, "age": 0.0, "style": style,
		"target_name": String(target.name) if target != null and is_instance_valid(target) else ""}
	active.append(record)
	spawned += 1
	spawned_projectile.emit(record)
	return id


## Launches guided ordnance from `origin` (the launcher's muzzle transform; −Z = launch
## axis) at `target`, with the launcher's configuration (damage, ordnance values).
func launch(owner_ship: Node3D, faction: int, origin: Transform3D, weapon_config: Resource, target: Node3D, remembered_target: Dictionary = {}) -> int:
	var id := _next_id
	_next_id += 1
	var node: Node3D = Ordnance.new()
	node.setup(id, owner_ship, faction, weapon_config, target, _contacts, remembered_target)
	add_child(node)
	node.begin(origin)
	ordnance.append(node)
	launched += 1
	ordnance_launched.emit(node)
	return id


func _physics_process(delta: float) -> void:
	for node in ordnance.duplicate():
		_advance_ordnance(node, delta)
	for record in active.duplicate():
		_advance(record, delta)


func _advance_ordnance(node: Node3D, delta: float) -> void:
	var age_before: float = node.age
	node.step(delta, self)
	var hit := _first_hit(node.owner_id, node.prev_position, node.global_position, -1)
	if node.strict_flight_expiration:
		# Flight was clipped at the operational deadline. Sweep that final segment, but
		# admit only hits strictly before the deadline (including when delta crosses it).
		var hit_age: float = age_before + (node.age - age_before) * hit.get("fraction", 1.0)
		if hit_age >= node.config.flight_time:
			hit = {}
		elif not hit.is_empty():
			node.age = hit_age
			node.traveled -= node.prev_position.distance_to(node.global_position)
			node.traveled += node.prev_position.distance_to(hit.point)
			node.global_position = hit.point
	if not hit.is_empty():
		var outcome := "asteroid"
		var ship_name := ""
		if hit.kind == "ship":
			var ship: Node3D = hit.ship
			ship_name = String(ship.name)
			var combat = CombatShip.of(ship)
			if combat.alive and combat.faction != node.faction:
				if combat.take_hit(node.damage, node.id, node.penetration, node.armor_damage):
					damage_events[node.id] = damage_events.get(node.id, 0) + 1
				outcome = "damage"
			else:
				outcome = "absorbed" if combat.alive else "wreck"
		elif hit.kind == "station":
			ship_name = String(hit.station.name) if hit.station != null else String(hit.part.name)
			outcome = _station_impact(hit.station, node.faction, node.damage, node.id)
		if _effects != null:
			_effects.impact(hit.point, outcome == "damage", 1.6 if outcome == "damage" else 1.0)
		_finish_ordnance(node, outcome, ship_name, hit.point, "")
		return
	if node.finished != "":
		if _effects != null:
			_effects.burst(node.global_position, Color(1.0, 0.8, 0.5), 0.5)
		_finish_ordnance(node, node.finished, "", node.global_position, "")


func _finish_ordnance(node: Node3D, outcome: String, ship_name: String, point: Vector3, by: String) -> void:
	ordnance.erase(node)
	node.live = false
	if _trails != null:
		_trails.release(node)
	var done := {"id": node.id, "kind": String(node.kind), "outcome": outcome, "ship": ship_name, "point": point,
		"origin": node.launch_point, "age": node.age, "traveled": node.traveled, "owner_name": node.owner_name,
		"target_name": node.target_name, "intercepted_by": by, "phase": node.phase}
	if node.strict_flight_expiration:
		done["target_id"] = node.target_id
	ordnance_records.append(done)
	if ordnance_records.size() > 500:
		ordnance_records.remove_at(0)
	remove_child(node)
	node.queue_free()
	ordnance_finished.emit(done)


func _advance(record: Dictionary, delta: float) -> void:
	var from: Vector3 = record.position
	var velocity: Vector3 = record.velocity
	var step := minf(velocity.length() * delta, record.max_travel - record.traveled)
	var to := from + velocity.normalized() * step
	var hit := _first_hit(record.owner_id, from, to, record.faction, record.intercepts_rockets)
	if not hit.is_empty():
		record.traveled += from.distance_to(hit.point)
		record.age += delta
		_hit(record, hit)
		return
	record.position = to
	record.traveled += step
	record.age += delta
	(record.node as Node3D).global_position = to
	if record.age >= record.lifetime - 0.000001 or record.traveled >= record.max_travel - 0.000001:
		expired += 1
		_finish(record, "expired", "", to)


# Nearest hull, asteroid or (rounds of `faction` >= 0) hostile ordnance along from→to
# (rockets only with `rockets`): {kind, ship | asteroid | ordnance, point, fraction}, or {}.
func _first_hit(owner_id: int, from: Vector3, to: Vector3, faction: int, rockets := false) -> Dictionary:
	var best := {}
	var best_fraction := INF
	for other: Node in _ships.get_children():
		if other.get_instance_id() == owner_id:
			continue
		var combat = CombatShip.of(other)
		if combat == null or combat.removed_from_play:
			continue
		var fraction: float = combat.segment_fraction(from, to)
		if fraction >= 0.0 and fraction < best_fraction:
			best_fraction = fraction
			best = {"kind": "ship", "ship": other, "fraction": fraction}
	if _asteroids != null and _asteroids.has_method("ids"):
		for id: int in _asteroids.ids():
			var fraction := _sphere_fraction(from, to, _asteroids.center(id), _asteroids.radius(id))
			if fraction >= 0.0 and fraction < best_fraction:
				best_fraction = fraction
				best = {"kind": "asteroid", "asteroid": id, "fraction": fraction}
	# Production world: station parts stop rounds and ordnance (combat_obstacles.gd).
	var station_hit := CombatObstacles.first_hit(get_tree(), from, to)
	if not station_hit.is_empty() and station_hit.fraction < best_fraction:
		best_fraction = station_hit.fraction
		best = {"kind": "station", "station": station_hit.station, "part": station_hit.part, "fraction": station_hit.fraction}
	if faction >= 0:
		for node in ordnance:
			if not node.live or node.faction == faction or (node.kind == &"rocket" and not rockets):
				continue
			# Relative motion over the tick: the round's segment seen from the ordnance.
			var fraction := _sphere_fraction(from - node.prev_position, to - node.global_position, Vector3.ZERO, node.config.radius)
			if fraction >= 0.0 and fraction < best_fraction:
				best_fraction = fraction
				best = {"kind": "ordnance", "ordnance": node, "fraction": fraction}
	if not best.is_empty():
		best.point = from.lerp(to, best_fraction)
	return best


static func _sphere_fraction(a: Vector3, b: Vector3, center: Vector3, radius: float) -> float:
	var d := b - a
	var f := a - center
	var aa := d.dot(d)
	var c := f.dot(f) - radius * radius
	if c <= 0.0:
		return 0.0
	if aa < 0.0000001:
		return -1.0
	var bb := 2.0 * f.dot(d)
	var disc := bb * bb - 4.0 * aa * c
	if disc < 0.0:
		return -1.0
	var t := (-bb - sqrt(disc)) / (2.0 * aa)
	return t if t >= 0.0 and t <= 1.0 else -1.0


func _hit(record: Dictionary, hit: Dictionary) -> void:
	impacts += 1
	var outcome := "asteroid"
	var ship_name := ""
	var point: Vector3 = hit.point
	if hit.kind == "ship":
		var ship: Node3D = hit.ship
		ship_name = String(ship.name)
		var combat = CombatShip.of(ship)
		if combat.alive and combat.faction != record.faction:
			if combat.take_hit(record.damage, record.id, record.penetration, record.armor_damage):
				damage_events[record.id] = damage_events.get(record.id, 0) + 1
			outcome = "damage"
		else:
			outcome = "absorbed" if combat.alive else "wreck"
	elif hit.kind == "station":
		ship_name = String(hit.station.name) if hit.station != null else String(hit.part.name)
		outcome = _station_impact(hit.station, record.faction, record.damage, record.id)
	elif hit.kind == "ordnance":
		var target: Node3D = hit.ordnance
		outcome = "intercept"
		ship_name = String(target.name)
		if _effects != null:
			_effects.burst(point, Color(1.0, 0.9, 0.6), 0.45)
		_finish_ordnance(target, "intercepted", "", target.global_position, record.owner_name)
	if _effects != null and outcome != "intercept":
		_effects.impact(point, outcome == "damage")
	_finish(record, outcome, ship_name, point)


# A round or ordnance stopped by a station: "station" (no damage) unless the station has a
# compatible hull component of another faction, which takes the damage once ("damage").
func _station_impact(station: Node3D, faction: int, damage: float, id: int) -> String:
	var hull := CombatObstacles.hull_of(station)
	if hull == null or hull.get("faction") == faction:
		return "station"
	if hull.take_hit(damage, id):
		damage_events[id] = damage_events.get(id, 0) + 1
		return "damage"
	return "station"


func _finish(record: Dictionary, outcome: String, ship_name: String, point: Vector3) -> void:
	active.erase(record)
	(record.node as Node).queue_free()
	var done := {"id": record.id, "outcome": outcome, "ship": ship_name, "point": point, "origin": record.origin,
		"traveled": record.traveled, "age": record.age, "owner_name": record.owner_name, "target_name": record.target_name,
		"max_travel": record.max_travel, "style": record.style}
	records.append(done)
	if records.size() > 4000:
		records.remove_at(0)
	impact.emit(done)


func _bar(faction: int, style: StringName) -> BoxMesh:
	var key := "%d_%s" % [faction, style]
	if not _meshes.has(key):
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var color: Color = CombatShip.FACTION_COLORS[faction].lerp(Color.WHITE, 0.55 if style == &"shell" else 0.35)
		if style == &"tracer":
			color = color.lerp(Color(1.0, 0.85, 0.45), 0.45)
		material.albedo_color = color
		var box := BoxMesh.new()
		box.size = STYLES.get(style, BAR_SIZE)
		box.material = material
		_meshes[key] = box
	return _meshes[key]
