extends Node
## Stage 5.3 group MOVE: turns one clicked point into one destination per selected
## ship, once per command, and gives each ship a normal MOVE through its
## RouteFollower. Nothing persists after dispatch: no group controller, no steering,
## no reassignment while the ships travel.
##
## Ships are placed largest first (ties: scene order). Each tries the clicked point,
## then rings around it (`candidate_spacing` apart, up to `search_radius`); within a
## ring, the candidate nearest to the ship's current position first. A candidate is
## accepted when, in this order (cheapest checks first):
##   1. its footprint plus `separation_margin` + `destination_buffer` stays clear of the destinations already
##      assigned in this command, of parked ships, and of the active destinations of
##      ships outside the command (ships in the command are being reassigned);
##   2. the ship fits there (the point is on its planning radius' navigable area);
##   3. a route from the ship's current position ends there (reachable);
##   4. the resolved route end passes check 1 too;
##   5. approach check against this command's destinations (_approach_clear): by
##      approximate arrival order, a later ship's route does not pass an earlier
##      ship's destination footprint. The route end becomes the destination.
## The command is atomic: if any ship finds no destination, no ship is ordered and
## existing orders stay.
##
## Departure preference: if that assignment has departure conflicts (two ships whose
## first `departure_length` of route come closer than their footprints plus the margin,
## and closer than they start), groups of up to `max_reordered_ships` are placed again
## in every other placement order (same rules), and the assignment with the fewest
## departure conflicts is kept; ties: fewer swaps of the ships' side-by-side order
## (across the group's travel), then the smaller total click distance, then the
## earlier order (largest first is first). A preference only, not a guarantee.
##
## Single-ship manual MOVE onto a stationary ship: resolve_occupied() places that one
## ship with the same candidate rings and checks 1-4 (no placement orders, no
## departure preference), at most `resolve_margin` beyond the blocker's clearance.

const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const ShipAvoidance := preload("res://game/avoidance/ship_avoidance.gd")
const RESOLVE_TOLERANCE := 0.25 # u; navigation precision (the maps' cell size).

@export var search_radius := 40.0 # u around the clicked point (provisional experiment value).
@export var candidate_spacing := 1.0 # u between rings and between candidates on a ring (provisional).
@export var separation_margin := 1.0 # u between destination footprints (as avoidance; provisional).
@export var destination_buffer := 0.5 # u added to that margin between destinations, so they never sit
	# exactly on the avoidance separation boundary (provisional; avoidance limits unchanged).
@export var departure_length := 15.0 # u of each route compared for departure conflicts (provisional).
@export var max_reordered_ships := 4 # Largest group placed in every order (4: 24 orders; provisional).
@export var resolve_margin := 5.0 # u beyond a stationary ship's clearance a resolved single MOVE may lie (provisional).
@export var ships_path := NodePath("../Ships")
@export var navigation_path := NodePath("../StaticNavigation")

## Cost of the last assignment: candidates looked at, fit queries (closest point),
## route queries, microseconds; whether it succeeded; placement orders tried and the
## departure conflicts of the first (largest first) and the chosen assignment.
var last_stats := {}

@onready var _ships := get_node(ships_path)
@onready var _navigation := get_node(navigation_path) as StaticNavigation


## Assigns and dispatches a group MOVE. False (nothing ordered) if any ship has no
## valid destination.
func command(ships: Array, point: Vector2) -> bool:
	var destinations := assign(ships, point)
	for ship: Node in destinations:
		(ship.get_node("RouteFollower") as RouteFollower).order(destinations[ship])
	return not destinations.is_empty()


## Destination per ship (ship -> Vector2), or empty if any ship has none.
func assign(ships: Array, point: Vector2) -> Dictionary:
	var start_usec := Time.get_ticks_usec()
	last_stats = {"candidates": 0, "fit_queries": 0, "route_queries": 0, "usec": 0, "success": false,
		"orders": 1, "conflicts_first": 0, "conflicts": 0}
	var ordered := ships.duplicate()
	ordered.sort_custom(_placed_before)
	var occupied := _occupied(ships)
	var assigned := _place(ordered, point, occupied)
	if not assigned.is_empty():
		var best := _score(assigned, point)
		last_stats.conflicts_first = best[0]
		if best[0] > 0 and ships.size() <= max_reordered_ships:
			for order: Array in _permutations(ordered).slice(1):
				last_stats.orders += 1
				var other := _place(order, point, occupied)
				if other.is_empty():
					continue
				var score := _score(other, point)
				if _better(score, best):
					best = score
					assigned = other
		last_stats.conflicts = best[0]
	var result := {}
	for found: Dictionary in assigned:
		result[found.ship] = found.point
	last_stats.usec = Time.get_ticks_usec() - start_usec
	last_stats.success = not result.is_empty()
	return result


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
		"orders": 0, "conflicts_first": 0, "conflicts": 0}
	var found := _find(ship, point, _occupied([ship]), [], depth + resolve_margin)
	last_stats.usec = Time.get_ticks_usec() - start_usec
	last_stats.success = not found.is_empty()
	return {"blocker": blocker} if found.is_empty() else {"blocker": blocker, "point": found.point}


# What the ships outside `ships` hold: [point, ship radius] each (parked: its
# position; queued order: the requested point; active order: its destination).
func _occupied(ships: Array) -> Array:
	var occupied := []
	for ship: Node in _ships.get_children():
		if ships.has(ship):
			continue
		var locomotion := ship.get_node("Locomotion") as ShipLocomotion
		var follower := ship.get_node("RouteFollower") as RouteFollower
		var at := locomotion.planar_position # parked
		if follower.status == RouteFollower.RouteStatus.WAITING:
			at = follower.requested # queued order
		elif locomotion.has_destination:
			at = locomotion.destination # active order
		occupied.append([at, follower.ship_radius])
	return occupied


# One placement in the given order: {ship, point, radius, route, eta} per ship, or
# empty if a ship finds no destination.
func _place(order: Array, point: Vector2, parked: Array) -> Array:
	var occupied := parked.duplicate()
	var assigned := []
	for ship: Node in order:
		var found := _find(ship, point, occupied, assigned, search_radius)
		if found.is_empty():
			return []
		assigned.append(found)
		occupied.append([found.point, found.radius])
	return assigned


# [departure conflicts, side-by-side order swaps, total click distance].
func _score(assigned: Array, point: Vector2) -> Array:
	var conflicts := 0
	var swaps := 0
	var spread := 0.0
	var centre := Vector2.ZERO
	for found: Dictionary in assigned:
		centre += (found.route as PackedVector2Array)[0]
		spread += (found.point as Vector2).distance_to(point)
	centre /= assigned.size()
	var travel := point - centre
	var across := Vector2(-travel.y, travel.x).normalized()
	for i in assigned.size():
		var a: Dictionary = assigned[i]
		var a_route: PackedVector2Array = a.route
		for j in range(i + 1, assigned.size()):
			var b: Dictionary = assigned[j]
			var b_route: PackedVector2Array = b.route
			var start_gap := a_route[0].distance_to(b_route[0])
			var nearest := _prefix_distance(_prefix(a_route), _prefix(b_route))
			if nearest < a.radius + b.radius + separation_margin and nearest < start_gap - RESOLVE_TOLERANCE:
				conflicts += 1
			if across != Vector2.ZERO and signf(across.dot(a_route[0] - b_route[0])) * signf(across.dot(a.point - b.point)) < 0.0:
				swaps += 1
	return [conflicts, swaps, spread]


static func _better(score: Array, best: Array) -> bool:
	if score[0] != best[0]:
		return score[0] < best[0]
	if score[1] != best[1]:
		return score[1] < best[1]
	return score[2] < best[2] - RESOLVE_TOLERANCE


# The first departure_length of a route.
func _prefix(route: PackedVector2Array) -> PackedVector2Array:
	var prefix := PackedVector2Array([route[0]])
	var left := departure_length
	for i in route.size() - 1:
		var length := route[i].distance_to(route[i + 1])
		if length >= left:
			prefix.append(route[i] + (route[i + 1] - route[i]) * (left / length))
			break
		prefix.append(route[i + 1])
		left -= length
	return prefix


static func _prefix_distance(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var nearest := INF
	for i in a.size() - 1:
		for j in b.size() - 1:
			var points := Geometry2D.get_closest_points_between_segments(a[i], a[i + 1], b[j], b[j + 1])
			nearest = minf(nearest, points[0].distance_to(points[1]))
	return nearest


# Every order of the ships, the given order first (lexicographic by position in it).
static func _permutations(ships: Array) -> Array:
	if ships.size() <= 1:
		return [ships.duplicate()]
	var result := []
	for i in ships.size():
		var rest := ships.duplicate()
		rest.remove_at(i)
		for tail: Array in _permutations(rest):
			result.append([ships[i]] + tail)
	return result


# Candidates on the rings around the point out to `limit` u.
func _find(ship: Node, point: Vector2, occupied: Array, assigned: Array, limit: float) -> Dictionary:
	var follower := ship.get_node("RouteFollower") as RouteFollower
	var locomotion := ship.get_node("Locomotion") as ShipLocomotion
	var position := locomotion.planar_position
	var radius := follower.ship_radius
	var planning := follower.planning_radius()
	for k in int(limit / candidate_spacing) + 1:
		for candidate: Vector2 in _ring(point, k, position):
			last_stats.candidates += 1
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
			if _approach_clear(found, assigned):
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
