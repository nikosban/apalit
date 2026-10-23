extends Node
## Group MOVE: turns one clicked point into one destination per selected ship, once
## per command, and gives each ship a normal MOVE through its RouteFollower. Nothing
## persists after dispatch: no group controller, no steering, no reassignment while the
## ships travel; each ship then moves at its own speed with its own navigation and
## avoidance.
##
## Translation (2026-10-23): the group keeps its current shape. Every ship's target is
## its current position moved by the same displacement, from the centroid of the ships
## given to the clicked point (no rotation, scaling or reordering). A destination is
## valid when (cheapest checks first):
##   1. its footprint plus `separation_margin` + `destination_buffer` stays clear of the
##      points reserved in this command and of the occupancy of ships outside it
##      (parked: position; queued order: requested point; active order: destination);
##   2. the ship fits there (the point is on its planning radius' navigable area, which
##      also keeps it inside the sector);
##   3. a route from the ship's current position ends there (reachable);
##   4. the resolved route end passes check 1 too.
## Each round: every translated target is checked as it is, largest ship first (ties:
## scene order; the order only decides between two conflicting targets) and reserved
## when valid; then only the ships whose target was invalid are relocated, on rings
## around their own target (`candidate_spacing` apart, up to `search_radius`, nearest
## to the ship's current position first), clear of every reservation and with the
## approach check (_approach_clear: by approximate arrival order, a later ship's route
## does not pass an earlier ship's destination footprint). A ship that finds nothing is
## excluded for the rest of the command (no new order: it keeps its order and
## assignments) and its current occupancy becomes a constraint; the round is repeated
## for the others until none fails (at most one round per ship). Ships with a
## destination move; none: no order.
##
## Single-ship manual MOVE onto a stationary ship: resolve_occupied() places that one
## ship with the same candidate rings and checks 1-4, at most `resolve_margin` beyond
## the blocker's clearance.

const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const ShipAvoidance := preload("res://game/avoidance/ship_avoidance.gd")
const RESOLVE_TOLERANCE := 0.25 # u; navigation precision (the maps' cell size).

@export var search_radius := 40.0 # u around a ship's target searched when it is invalid (provisional experiment value).
@export var candidate_spacing := 1.0 # u between rings and between candidates on a ring (provisional).
@export var separation_margin := 1.0 # u between destination footprints (as avoidance; provisional).
@export var destination_buffer := 0.5 # u added to that margin between destinations, so they never sit
	# exactly on the avoidance separation boundary (provisional; avoidance limits unchanged).
@export var resolve_margin := 5.0 # u beyond a stationary ship's clearance a resolved single MOVE may lie (provisional).
@export var ships_path := NodePath("../Ships")
@export var navigation_path := NodePath("../StaticNavigation")

## Cost and outcome of the last assignment: candidates looked at, fit queries (closest
## point), route queries, microseconds; whether any ship got a destination; ships at
## their translated target, relocated, and without a destination; rounds.
var last_stats := {}

@onready var _ships := get_node(ships_path)
@onready var _navigation := get_node(navigation_path) as StaticNavigation


## Assigns and dispatches a group MOVE: the ships whose RouteFollower took their
## destination (ship -> Vector2); the others keep their orders. Empty: nothing ordered.
func command(ships: Array, point: Vector2) -> Dictionary:
	var ordered := {}
	var destinations := assign(ships, point)
	for ship: Node in destinations:
		if (ship.get_node("RouteFollower") as RouteFollower).order(destinations[ship]):
			ordered[ship] = destinations[ship]
	return ordered


## Destination per ship (ship -> Vector2) for the ships that can be placed, the whole
## assignment computed before anything is ordered; empty if no ship can be. Orders
## nothing and changes no ship (last_stats only).
func assign(ships: Array, point: Vector2) -> Dictionary:
	return _solve(ships, point)


## Whether a group MOVE to the point would order any ship (the command cursor's group
## check): the same solver as assign(), so the answer is the click's.
func can_assign(ships: Array, point: Vector2) -> bool:
	return not _solve(ships, point).is_empty()


# The translated assignment (see the header). Rounds repeat until no ship fails; a
# failed ship is excluded for good, so there are at most ships.size() + 1 rounds.
func _solve(ships: Array, point: Vector2) -> Dictionary:
	var start_usec := Time.get_ticks_usec()
	last_stats = {"candidates": 0, "fit_queries": 0, "route_queries": 0, "usec": 0, "success": false,
		"translated": 0, "relocated": 0, "unplaced": 0, "rounds": 0}
	var result := {}
	if ships.is_empty():
		return result
	var centroid := Vector2.ZERO
	for ship: Node in ships:
		centroid += (ship.get_node("Locomotion") as ShipLocomotion).planar_position
	var shift := point - centroid / ships.size()
	var ordered := ships.duplicate()
	ordered.sort_custom(_placed_before)
	var fixed := _occupied(ships)
	var excluded := []
	var placed := []
	var translated := 0
	while true:
		last_stats.rounds += 1
		var occupied := fixed.duplicate()
		placed = []
		var invalid := []
		for ship: Node in ordered:
			if excluded.has(ship):
				continue
			var found := _find(ship, _target(ship, shift), occupied, placed, 0.0, false)
			if found.is_empty():
				invalid.append(ship)
				continue
			placed.append(found)
			occupied.append([found.point, found.radius])
		translated = placed.size()
		var failed := []
		for ship: Node in invalid:
			var found := _find(ship, _target(ship, shift), occupied, placed, search_radius)
			if found.is_empty():
				failed.append(ship)
				continue
			placed.append(found)
			occupied.append([found.point, found.radius])
		if failed.is_empty():
			break
		for ship: Node in failed:
			excluded.append(ship)
			fixed.append(_occupancy(ship))
	for found: Dictionary in placed:
		result[found.ship] = found.point
	last_stats.translated = translated
	last_stats.relocated = placed.size() - translated
	last_stats.unplaced = excluded.size()
	last_stats.usec = Time.get_ticks_usec() - start_usec
	last_stats.success = not result.is_empty()
	return result


# The ship's current position moved by the command's displacement.
func _target(ship: Node, shift: Vector2) -> Vector2:
	return (ship.get_node("Locomotion") as ShipLocomotion).planar_position + shift


## Single-ship manual MOVE: the stationary ship (ShipAvoidance.is_stationary) whose
## clearance (both footprints + separation_margin + destination_buffer, as between
## destinations) the point lies deepest inside, and the nearest valid destination for
## the ship outside every occupied clearance (_find for this ship alone), at most
## resolve_margin beyond the blocker's clearance: {blocker, point}; {blocker} if there
## is none; {} if no stationary ship occupies the point.
func resolve_occupied(ship: Node, point: Vector2) -> Dictionary:
	var start_usec := Time.get_ticks_usec()
	var radius := (ship.get_node("RouteFollower") as RouteFollower).ship_radius
	var blocker: Node = null
	var depth := 0.0
	for other: Node in _ships.get_children():
		var locomotion := other.get_node_or_null("Locomotion") as ShipLocomotion
		if other == ship or locomotion == null or not ShipAvoidance.is_stationary(locomotion):
			continue
		var clearance := radius + (other.get_node("RouteFollower") as RouteFollower).ship_radius + separation_margin + destination_buffer
		var inside := clearance - point.distance_to(locomotion.planar_position)
		if inside > depth:
			depth = inside
			blocker = other
	if blocker == null:
		return {}
	last_stats = {"candidates": 0, "fit_queries": 0, "route_queries": 0, "usec": 0, "success": false,
		"translated": 0, "relocated": 0, "unplaced": 0, "rounds": 0}
	var found := _find(ship, point, _occupied([ship]), [], depth + resolve_margin)
	last_stats.usec = Time.get_ticks_usec() - start_usec
	last_stats.success = not found.is_empty()
	return {"blocker": blocker} if found.is_empty() else {"blocker": blocker, "point": found.point}


# What the ships outside `ships` hold: _occupancy() of each.
func _occupied(ships: Array) -> Array:
	var occupied := []
	for ship: Node in _ships.get_children():
		if not ships.has(ship):
			occupied.append(_occupancy(ship))
	return occupied


# What a ship holds: [point, ship radius] (parked: its position; queued order: the
# requested point; active order: its destination).
func _occupancy(ship: Node) -> Array:
	var locomotion := ship.get_node("Locomotion") as ShipLocomotion
	var follower := ship.get_node("RouteFollower") as RouteFollower
	var at := locomotion.planar_position # parked
	if follower.status == RouteFollower.RouteStatus.WAITING:
		at = follower.requested # queued order
	elif locomotion.has_destination:
		at = locomotion.destination # active order
	return [at, follower.ship_radius]


# Candidates on the rings around the point out to `limit` u (0: the point only); with
# `approach`, also the approach check against `assigned`.
func _find(ship: Node, point: Vector2, occupied: Array, assigned: Array, limit: float, approach := true) -> Dictionary:
	var follower := ship.get_node("RouteFollower") as RouteFollower
	var locomotion := ship.get_node("Locomotion") as ShipLocomotion
	var position := locomotion.planar_position
	var radius := follower.ship_radius
	var planning := follower.planning_radius()
	# The navigable area lies inside the sector square it is baked from, so a candidate
	# farther than the fit tolerance outside it can never fit: skipped before any query
	# (after the ring's sorting, so the order of the others is unchanged).
	var bound := _navigation.map_half_size + RESOLVE_TOLERANCE
	for k in int(limit / candidate_spacing) + 1:
		for candidate: Vector2 in _ring(point, k, position):
			last_stats.candidates += 1
			if absf(candidate.x) > bound or absf(candidate.y) > bound:
				continue
			if not _clear(candidate, radius, occupied):
				continue
			last_stats.fit_queries += 1
			if _navigation.closest_point(planning, candidate).distance_to(candidate) > RESOLVE_TOLERANCE:
				continue
			last_stats.route_queries += 1
			var route := _navigation.plan(planning, position, candidate)
			if route.size() < 2:
				continue
			var resolved := route[route.size() - 1]
			if resolved.distance_to(candidate) > RESOLVE_TOLERANCE or not _clear(resolved, radius, occupied):
				continue
			var found := {"ship": ship, "point": resolved, "radius": radius, "route": route,
				"eta": _length(route) / locomotion.max_speed}
			if not approach or _approach_clear(found, assigned):
				return found
	return {}


# Approach check against this command's other destinations, by approximate arrival
# order (route length / top speed): the route of the ship arriving later must keep
# both footprints plus the margin clear of the destination of the one arriving
# earlier (equal: both ways). Route-versus-footprint only; no trajectory simulation.
func _approach_clear(found: Dictionary, assigned: Array) -> bool:
	for other: Dictionary in assigned:
		var clearance: float = found.radius + other.radius + separation_margin + destination_buffer
		if other.eta <= found.eta and _route_distance(found.route, other.point) < clearance:
			return false
		if found.eta <= other.eta and _route_distance(other.route, found.point) < clearance:
			return false
	return true


static func _route_distance(route: PackedVector2Array, point: Vector2) -> float:
	var nearest := INF
	for i in route.size() - 1:
		nearest = minf(nearest, Geometry2D.get_closest_point_to_segment(point, route[i], route[i + 1]).distance_to(point))
	return nearest


static func _length(route: PackedVector2Array) -> float:
	var total := 0.0
	for i in route.size() - 1:
		total += route[i].distance_to(route[i + 1])
	return total


# Ring k around the point (k = 0: the point itself), nearest to `near` first.
func _ring(point: Vector2, k: int, near: Vector2) -> Array:
	if k == 0:
		return [point]
	var radius := k * candidate_spacing
	var count := int(ceil(TAU * radius / candidate_spacing))
	var ring := []
	for i in count:
		ring.append(point + Vector2.from_angle(TAU * i / count) * radius)
	ring.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.distance_squared_to(near) < b.distance_squared_to(near))
	return ring


func _clear(point: Vector2, radius: float, occupied: Array) -> bool:
	for entry: Array in occupied:
		if point.distance_to(entry[0]) < radius + entry[1] + separation_margin + destination_buffer:
			return false
	return true


# Largest footprint first; equal: earlier in the scene.
static func _placed_before(a: Node, b: Node) -> bool:
	var ra: float = (a.get_node("RouteFollower") as RouteFollower).ship_radius
	var rb: float = (b.get_node("RouteFollower") as RouteFollower).ship_radius
	if ra != rb:
		return ra > rb
	return a.get_index() < b.get_index()
