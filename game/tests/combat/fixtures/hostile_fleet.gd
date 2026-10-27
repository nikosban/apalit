extends Node
## Combat fixture, E05 only: the hostile fleet's scenario controller (node `HostileFleet`
## in e05_fleet.tscn; physics priority −2, before every ship). The fleet is three FF-01s:
## the lead (LEAD, at the wedge's point) and two escorts.
## It is not a general AI. Every command goes through CombatOrders (set_stance,
## assign_target, move); it never moves a ship, aims or fires itself. Once the scenario
## clock runs (EnemyController.started), every DECISION_INTERVAL:
##   1 focus: one manual target for the whole fleet (strict focus): the live player ship
##     nearest to the fleet's centre (lower combat id on a tie), kept until it is
##     destroyed, then chosen again from the survivors;
##   2 stations: each hostile ship gets a point on a ring around the focus target at its
##     useful range (LONG_RANGE while it has guided missiles left, otherwise ESCORT_RANGE:
##     just beyond the cannon's effective range, well outside the point-defense guns),
##     on the fleet's side of the target (the axis target → lead, or → the fleet's
##     centre without it); escorts abreast at ± ESCORT_SPREAD so they stay inside the
##     lead's defensive radius. A station whose line of fire to the target crosses an
##     asteroid (or that lies in one, or off the map) is rotated around the target in
##     ROTATION_STEP steps, nearest first, until it is clear;
##   3 approach together: while the lead is farther from its station than an escort's
##     run to its own takes (time at top speed, APPROACH_SLACK), that escort, if it is still
##     beyond its range band and has had no station order yet, holds back,
##     so the fleet arrives together with its escorts inside point-defense range;
##   4 orders: a ship is ordered to its station when it is idle but out of its range band
##     or with its line of fire blocked (repositioning), or while moving when its station
##     has shifted by more than RESTATION. A refused move tries the next clear station.
## After losses the survivors re-form on the same rules; it keeps fighting until no player
## ship is left.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const HOSTILE := 1
const AGGRESSIVE := 2
const DECISION_INTERVAL := 0.5 # s
const LEAD := "HostileFF01A"
const LONG_RANGE := 70.0 # u
const ESCORT_RANGE := 50.0 # u
const ESCORT_SPREAD := 10.0 # u
const BAND_IN := 12.0 # u closer than the range still counts as in range
const BAND_OUT := 8.0 # u farther
const RESTATION := 12.0 # u
const APPROACH_SLACK := 2.0 # s an escort may set off before its run matches the lead's
const ROTATION_STEP := 15.0 # °
const MAX_ROTATION := 120.0 # °
const MAP_LIMIT := 135.0 # u from the centre on each axis
const ROCK_CLEARANCE := 3.0 # u between a station's footprint and an asteroid
const SIGHT_MARGIN := 0.5 # u added to asteroid radii for the line of fire

var focus: Node3D = null
var decisions := 0
var repositions := 0 # Orders given because the line of fire was blocked.
var log: Array[String] = []
var _clock := 0.0
var _ordered := {} # ship -> station ordered (Vector2)

@onready var _arena := get_parent()
@onready var _orders = _arena.get_node("CombatOrders")
@onready var _controller = _arena.get_node("EnemyController")
@onready var _asteroids = _arena.get_node("Asteroids")


func _ready() -> void:
	process_physics_priority = -2


func _physics_process(delta: float) -> void:
	if not _controller.started:
		return
	_clock -= delta
	if _clock > 0.000001:
		return
	_clock += DECISION_INTERVAL
	var fleet := ships_of(HOSTILE)
	var enemies := ships_of(1 - HOSTILE)
	if fleet.is_empty() or enemies.is_empty():
		return
	decisions += 1
	if decisions == 1:
		_orders.set_stance(fleet, AGGRESSIVE)
	if focus == null or not is_instance_valid(focus) or not CombatShip.of(focus).alive:
		focus = _nearest(enemies, _centre(fleet))
		_orders.assign_target(fleet, focus)
		_log("focus %s" % focus.name)
	var target := _planar(focus)
	var anchor := _centre(fleet)
	for ship: Node3D in fleet:
		if _is_lead(ship):
			anchor = _planar(ship)
	var axis := (anchor - target).normalized() if anchor.distance_to(target) > 0.01 else Vector2.RIGHT
	# Approach together: the lead's time to its station (0 without a lead).
	var lead_time := 0.0
	for ship: Node3D in fleet:
		if _is_lead(ship):
			lead_time = maxf(0.0, _planar(ship).distance_to(target) - useful_range(ship)) / _top_speed(ship)
	var spread := ESCORT_SPREAD
	for ship: Node3D in fleet:
		var lateral := 0.0
		if not _is_lead(ship):
			lateral = spread
			spread = -spread
			var run := maxf(0.0, _planar(ship).distance_to(target) - ESCORT_RANGE) / _top_speed(ship)
			var beyond: bool = _planar(ship).distance_to(target) > ESCORT_RANGE + BAND_OUT
			if beyond and run < lead_time - APPROACH_SLACK and not _ordered.has(ship):
				continue # Holds back until its run takes as long as the lead's.
		_station(ship, target, axis, lateral)


## Live ships of a faction, in scene order.
func ships_of(faction: int) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for ship: Node in _arena.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		if combat != null and combat.alive and combat.faction == faction:
			found.append(ship)
	return found


## The useful range the controller keeps for a ship: LONG_RANGE while it has guided
## missiles left, otherwise ESCORT_RANGE (its cannon).
static func useful_range(ship: Node3D) -> float:
	for weapon in CombatShip.of(ship).weapons:
		if weapon.config.family == &"missile" and weapon.rounds_left() > 0:
			return LONG_RANGE
	return ESCORT_RANGE


static func _top_speed(ship: Node3D) -> float:
	var top: float = ship.get_node("Locomotion").max_speed
	return maxf(0.1, top)


static func _is_lead(ship: Node3D) -> bool:
	return String(ship.name) == LEAD


## Whether the straight line between two planar points clears every asteroid.
func line_clear(a: Vector2, b: Vector2) -> bool:
	for id: int in _asteroids.ids():
		var c: Vector3 = _asteroids.center(id)
		var centre := Vector2(c.x, c.z)
		if Geometry2D.get_closest_point_to_segment(centre, a, b).distance_to(centre) <= _asteroids.radius(id) + SIGHT_MARGIN:
			return false
	return true


func _station(ship: Node3D, target: Vector2, axis: Vector2, lateral: float) -> void:
	var keep := useful_range(ship)
	var here := _planar(ship)
	var radius: float = ship.get_node("RouteFollower").ship_radius
	var candidates := _candidates(target, axis * keep + axis.orthogonal() * lateral, radius)
	if candidates.is_empty():
		return
	var distance := here.distance_to(target)
	var sight := line_clear(here, target)
	var in_band := distance >= keep - BAND_IN and distance <= keep + BAND_OUT
	var locomotion = ship.get_node("Locomotion")
	var moving: bool = locomotion.has_destination or ship.get_node("RouteFollower").status == RouteFollower.RouteStatus.WAITING
	var last: Variant = _ordered.get(ship)
	var reason := ""
	if moving:
		if last != null and (last as Vector2).distance_to(candidates[0]) > RESTATION:
			reason = "station moved"
	elif not sight:
		reason = "line of fire blocked"
	elif not in_band:
		reason = "range %.0f u" % distance
	if reason == "":
		return
	for point: Vector2 in candidates:
		if not moving and point.distance_to(here) < 2.0:
			continue
		if _orders.move([ship], point):
			_ordered[ship] = point
			if not sight:
				repositions += 1
			_log("%s -> (%.0f, %.0f): %s" % [ship.name, point.x, point.y, reason])
			return


# Clear stations around the target at offset `offset` rotated by 0, ±step, ±2·step …
# (nearest rotation first): on the map, outside every asteroid, clear line of fire.
func _candidates(target: Vector2, offset: Vector2, radius: float) -> Array[Vector2]:
	var found: Array[Vector2] = []
	var steps := int(MAX_ROTATION / ROTATION_STEP)
	for i in steps * 2 + 1:
		var k := ceili(i * 0.5) * (1 if i % 2 == 1 else -1)
		var point := target + offset.rotated(deg_to_rad(ROTATION_STEP * k))
		if absf(point.x) > MAP_LIMIT or absf(point.y) > MAP_LIMIT:
			continue
		var inside := false
		for id: int in _asteroids.ids():
			var c: Vector3 = _asteroids.center(id)
			if point.distance_to(Vector2(c.x, c.z)) < _asteroids.radius(id) + radius + ROCK_CLEARANCE:
				inside = true
				break
		if not inside and line_clear(point, target):
			found.append(point)
	return found


func _nearest(ships: Array[Node3D], point: Vector2) -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for ship: Node3D in ships:
		var distance := _planar(ship).distance_to(point)
		var tie: bool = absf(distance - best_distance) <= 0.000001 and CombatShip.of(ship).combat_id < CombatShip.of(best).combat_id
		if distance < best_distance - 0.000001 or tie:
			best = ship
			best_distance = distance
	return best


func _centre(ships: Array[Node3D]) -> Vector2:
	var sum := Vector2.ZERO
	for ship: Node3D in ships:
		sum += _planar(ship)
	return sum / ships.size()


static func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)


func _log(text: String) -> void:
	log.append("%.1f %s" % [_controller.time, text])
