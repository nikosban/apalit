extends Node
## Combat (migrated from the prototype v0.4): faction-shared sensor contacts (node
## `Sensors`, in main.tscn and the combat scenes; a scene without it has no fog of war and
## every ship is in contact unless removed on the contact board). Station meshes do not
## occlude sensors (only asteroids, unchanged).
##
## Every `update_interval` s of simulation time (SimClock), for each faction: a ship of the
## other faction is detected when any live ship of the faction is within `sensor_range`
## (planar) and the sensor line between their centres is clear of asteroids (the same
## asteroid circles weapons and navigation use: AsteroidField centre / radius). Contacts are
## faction-wide: one detecting ship gives the whole faction the live contact; it is lost
## only when no ship detects it. A lost contact keeps a last-known position (where it was
## at its last detection) for `memory` s of simulation time, then is forgotten. Paused, it
## does nothing (simulation node); at 0.25x / 2x everything follows simulation time.
##
## The ContactBoard reads `detected()` (contacts.sensors), so target eligibility, weapon
## authorization and ordnance guidance use sensor contact; the manual board still removes
## contacts on top (C key, scripted events). Sensor detection and weapon line of fire stay
## separate: weapons keep their own range, coverage and path checks.

const SimClock := preload("res://game/time/sim_clock.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")

@export var sensor_range := 100.0 # u, every ship (provisional, scene-specific)
@export var update_interval := 0.2 # s of simulation time between evaluations
@export var memory := 8.0 # s of simulation time a lost contact stays marked
@export var ships_path := NodePath("../Ships")
@export var asteroids_path := NodePath("../Asteroids")
@export var contacts_path := NodePath("../Contacts")

var updates := 0 # Evaluations made (diagnostics).
var line_checks := 0 # Sensor-line tests made in total.
var last_update_usec := 0 # Cost of the last evaluation.
var _next := 0.0
var _live := {0: {}, 1: {}} # faction -> {ship: last detected position}
var _lost := {0: {}, 1: {}} # faction -> {ship: {position, time}}
var _sources := {0: [], 1: []} # faction -> [Vector3 ship positions] at the last evaluation

@onready var _ships := get_node(ships_path)
@onready var _asteroids := get_node_or_null(asteroids_path)


func _ready() -> void:
	process_physics_priority = -50 # after the clock, before ships act on contact
	var contacts := get_node_or_null(contacts_path)
	if contacts != null:
		contacts.sensors = self


func _physics_process(_delta: float) -> void:
	var now := SimClock.now()
	if now + 0.000001 < _next and updates > 0:
		return
	_next = now + update_interval
	evaluate()


## Whether `faction` has live contact with `ship` (own ships always).
func detected(faction: int, ship: Node3D) -> bool:
	var combat = CombatShip.of(ship)
	if combat != null and combat.faction == faction:
		return true
	return _live.get(faction, {}).has(ship)


## Lost contacts still marked for `faction`: [{ship, position, age}] (simulation time).
func last_known(faction: int) -> Array:
	var now := SimClock.now()
	var list := []
	for ship: Variant in _lost.get(faction, {}):
		if is_instance_valid(ship):
			var entry: Dictionary = _lost[faction][ship]
			list.append({"ship": ship, "position": entry.position, "age": now - entry.time})
	return list


func is_lost(faction: int, ship: Node3D) -> bool:
	return _lost.get(faction, {}).has(ship)


## Whether `point` lies in `faction`'s sensor coverage as of the last evaluation (within
## range of one of its ships with a clear line).
func covered(faction: int, point: Vector3) -> bool:
	for source: Vector3 in _sources.get(faction, []):
		if _sees(source, point):
			return true
	return false


## The faction's sensor positions at the last evaluation (fog drawing).
func sources(faction: int) -> Array:
	return _sources.get(faction, [])


## One evaluation now (also called by tests).
func evaluate() -> void:
	var start := Time.get_ticks_usec()
	updates += 1
	var now := SimClock.now()
	var by_faction := {0: [], 1: []}
	var everyone := []
	for ship: Node3D in _ships.get_children():
		var combat = CombatShip.of(ship)
		if combat == null or combat.removed_from_play:
			continue
		everyone.append(ship)
		if combat.alive:
			by_faction[combat.faction].append(ship.global_position)
	for faction: int in [0, 1]:
		_sources[faction] = by_faction[faction]
		var live: Dictionary = _live[faction]
		var lost: Dictionary = _lost[faction]
		for ship: Node3D in everyone:
			if CombatShip.of(ship).faction == faction:
				continue
			var seen := false
			for source: Vector3 in by_faction[faction]:
				if _sees(source, ship.global_position):
					seen = true
					break
			if seen:
				live[ship] = ship.global_position
				lost.erase(ship)
			elif live.has(ship):
				lost[ship] = {"position": live[ship], "time": now}
				live.erase(ship)
		for ship: Variant in live.keys():
			if not is_instance_valid(ship) or not everyone.has(ship):
				live.erase(ship)
		for ship: Variant in lost.keys():
			if not is_instance_valid(ship) or not everyone.has(ship) or now - lost[ship].time >= memory - 0.000001:
				lost.erase(ship)
	last_update_usec = Time.get_ticks_usec() - start


func _sees(source: Vector3, point: Vector3) -> bool:
	var a := Vector2(source.x, source.z)
	var b := Vector2(point.x, point.z)
	if a.distance_to(b) > sensor_range:
		return false
	line_checks += 1
	if _asteroids == null or not _asteroids.has_method("ids"):
		return true
	for id: int in _asteroids.ids():
		var center: Vector3 = _asteroids.center(id)
		var c := Vector2(center.x, center.z)
		if Geometry2D.get_closest_point_to_segment(c, a, b).distance_to(c) <= _asteroids.radius(id):
			return false
	return true
