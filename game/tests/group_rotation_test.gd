extends SceneTree
## Headless checks for the direct-move prediction horizon in ShipAvoidance, on the
## playable main scene. Avoidance predicts its own ship from its route position along
## the leg; on a direct move that prediction must stop where the leg ends (the route
## distance left from the route position), not after the straight distance from the
## ship's actual position, which runs past the destination once a pass has displaced
## the ship. Before the correction a ship held beside its destination kept a pass
## against an idle ship parked beyond it (an encounter only that phantom extension
## saw) and shuttled and spun there indefinitely (group MOVE investigation,
## 2026-10-18).
##   1-3. Placed ships, one avoidance step: an idle ship beyond the destination, clear
##        of the remaining leg, is no encounter; one within separation of the remaining
##        leg (mid-leg and at its end) still is.
##   4.   Group MOVE of the five starting ships to (18.2, 7.0): the Frigate keeps no
##        pass against an idle ship its remaining leg clears; everyone arrives.
##   5.   Group MOVE to (23.5, 4.0): Miner1 likewise; arrival is not required (this
##        layout can end in the known mutual give-way stall, reported, not checked).
## Cumulative turning and progress are printed for 4 and 5. Physics is stepped manually
## at 60 Hz in the game's order (RouteFollower and Avoidance per ship, then Locomotion).
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/group_rotation_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2", "Transporter"]
const GROUP := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2"]
const TIME_LIMIT := 90.0 # s
const PASS := 1 # ShipAvoidance.Response.PASS

var _failures := 0
var _checks := 0
var _main: Node
var _starts := {}


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_main.get_node("Survey").set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	for ship_name in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Transport", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [ship_name, child])
			if node != null:
				node.set_physics_process(false)
		_starts[ship_name] = [_locomotion(ship_name).planar_position, _locomotion(ship_name).heading]
	for ship_name in SHIPS:
		while not _main.get_node("StaticNavigation").is_ready(_follower(ship_name).planning_radius()):
			await physics_frame

	_test_placed()
	_test_group(4, Vector2(18.2, 7.0), "Frigate", true)
	_test_group(5, Vector2(23.5, 4.0), "Miner1", false)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# 1-3: the Frigate on a direct move from (0, 60) to (10, 60), moved off its leg; the
# Destroyer (separation 8.8 u) idle nearby; one RouteFollower + Avoidance step.
func _test_placed() -> void:
	var origin := Vector2(0.0, 60.0)
	var cases := [
		# [label, Frigate position, Destroyer position, encounter expected]
		["1. beyond the destination, clear of the remaining leg (phantom before the correction)", Vector2(10, 6), Vector2(19, 2), false],
		["2. within separation of the remaining leg, mid-leg", Vector2(6, 6), Vector2(14, 3), true],
		["3. within separation of the remaining leg's end, beyond the destination", Vector2(7, 6), Vector2(16, 2), true],
	]
	for c: Array in cases:
		_reset()
		var mover := _locomotion("Frigate")
		mover.place(origin, -PI / 2)
		_follower("Frigate").order(origin + Vector2(10, 0))
		_place("Destroyer", origin + (c[2] as Vector2), 0.0)
		mover.planar_position = origin + (c[1] as Vector2) # Test-only: off the leg, the leg kept.
		_follower("Frigate")._physics_process(DT)
		var avoidance := _avoidance("Frigate")
		avoidance._physics_process(DT)
		var destroyer := _main.get_node("Ships/Destroyer")
		var from := Geometry2D.get_closest_point_to_segment(mover.planar_position, _follower("Frigate").route[0], _follower("Frigate").route[1])
		var to_leg := Geometry2D.get_closest_point_to_segment(_locomotion("Destroyer").planar_position, from, mover.destination).distance_to(_locomotion("Destroyer").planar_position)
		var found: bool = avoidance.encounters.has(destroyer)
		_check("%s: leg left %.2f u, straight distance %.2f u, Destroyer %.2f u from the leg left (separation 8.80): encounter %s (expected %s)" % [c[0],
			from.distance_to(mover.destination), mover.planar_position.distance_to(mover.destination), to_leg, found, c[3]],
			_follower("Frigate").status == RouteFollower.RouteStatus.DIRECT and found == c[3])


# 4, 5: a group MOVE of the five starting ships from the spawn, stepped until every
# order ends or the time limit. Per tick for `watched`: a pass against an idle ship
# whose distance from the leg left (route position -> destination) is at least the
# separation is a phantom pass. Prints cumulative turning, distance travelled and
# progress toward the destination for the whole run and after every other ship stopped.
func _test_group(number: int, point: Vector2, watched: String, require_arrival: bool) -> void:
	_reset()
	var ships := []
	for ship_name in GROUP:
		ships.append(_main.get_node("Ships/" + ship_name))
	var destinations: Dictionary = _main.get_node("GroupOrders").assign(ships, point)
	if destinations.is_empty():
		_check("%d. group MOVE to (%.1f, %.1f) assigned" % [number, point.x, point.y], false)
		return
	for ship in destinations:
		(ship.get_node("RouteFollower") as RouteFollower).order(destinations[ship])
	var locomotion := _locomotion(watched)
	var follower := _follower(watched)
	var avoidance := _avoidance(watched)
	var destination: Vector2 = destinations[_main.get_node("Ships/" + watched)]
	var phantom_ticks := 0
	var turning := 0.0
	var travelled := 0.0
	var start_distance := locomotion.planar_position.distance_to(destination)
	var window := [] # [turning, travelled, distance to destination] once per second, for the last 30 s.
	var ticks := 0
	while ticks < 60 * TIME_LIMIT:
		var busy := false
		for ship_name in GROUP:
			busy = busy or _locomotion(ship_name).has_destination
		if not busy:
			break
		var heading := locomotion.heading
		var position := locomotion.planar_position
		for ship_name in SHIPS:
			_follower(ship_name)._physics_process(DT)
			_avoidance(ship_name)._physics_process(DT)
		if locomotion.has_destination and follower.status == RouteFollower.RouteStatus.DIRECT:
			var from := Geometry2D.get_closest_point_to_segment(locomotion.planar_position, follower.route[0], follower.route[1])
			for other: Node in avoidance.encounters:
				var encounter: Dictionary = avoidance.encounters[other]
				var other_locomotion := other.get_node("Locomotion") as ShipLocomotion
				var separation: float = follower.ship_radius + (other.get_node("RouteFollower") as RouteFollower).ship_radius + avoidance.separation_margin
				var to_leg := Geometry2D.get_closest_point_to_segment(other_locomotion.planar_position, from, follower.route[1]).distance_to(other_locomotion.planar_position)
				if encounter.response == PASS and not other_locomotion.has_destination and to_leg >= separation:
					phantom_ticks += 1
		for ship_name in SHIPS:
			_locomotion(ship_name)._step(DT)
		ticks += 1
		var turned := absf(wrapf(locomotion.heading - heading, -PI, PI))
		var moved := locomotion.planar_position.distance_to(position)
		turning += turned
		travelled += moved
		if ticks % 60 == 0:
			window.append([turning, travelled, locomotion.planar_position.distance_to(destination) if locomotion.has_destination else 0.0])
			if window.size() > 31:
				window.pop_front()
	var arrived := []
	var overlaps := 0
	var touches := 0
	for ship_name in GROUP:
		if not _locomotion(ship_name).has_destination:
			arrived.append(ship_name)
		overlaps += _avoidance(ship_name).contacts
		touches += _locomotion(ship_name).collision_count
	var final_distance := locomotion.planar_position.distance_to(destination) if locomotion.has_destination else 0.0
	var first: Array = window[0]
	print("  %d. %s: %.1f s, arrived: %s" % [number, watched, ticks * DT, ", ".join(arrived)])
	print("     %s whole run: turned %.0f deg, travelled %.2f u, distance to destination %.2f -> %.2f u" % [watched, rad_to_deg(turning), travelled, start_distance, final_distance])
	print("     %s last %d s: turned %.0f deg, travelled %.2f u, distance to destination %.2f -> %.2f u" % [watched, window.size() - 1,
		rad_to_deg(turning - first[0]), travelled - first[1], first[2], final_distance])
	print("     %s end: %s, speed %.2f u/s; group footprint overlaps %d, collision contacts %d" % [watched,
		["NORMAL", "PASSING", "YIELDING", "WAITING"][avoidance.state] if locomotion.has_destination else "arrived", locomotion.velocity.length(), overlaps, touches])
	if locomotion.has_destination:
		for other: Node in avoidance.encounters:
			var encounter: Dictionary = avoidance.encounters[other]
			print("     open encounter: %s, %s, other ship %s" % [other.name, ["none", "pass", "yield"][encounter.response],
				"with an order" if (other.get_node("Locomotion") as ShipLocomotion).has_destination else "idle"])
	_check("%d. group MOVE to (%.1f, %.1f): %s keeps no pass against an idle ship its remaining leg clears (%d ticks)" % [number, point.x, point.y, watched, phantom_ticks],
		phantom_ticks == 0)
	if require_arrival:
		_check("%d. every ship arrives (%d of %d), no footprint overlap (%d)" % [number, arrived.size(), GROUP.size(), overlaps], arrived.size() == GROUP.size() and overlaps == 0)
	else:
		_check("%d. no footprint overlap (%d)" % [number, overlaps], overlaps == 0)


# Every ship back at rest at its scene position, no orders, counters cleared.
func _reset() -> void:
	for ship_name in SHIPS:
		var start: Array = _starts[ship_name]
		_locomotion(ship_name).place(start[0], start[1])
		_follower(ship_name).clear()
		_avoidance(ship_name).reset()


func _place(ship_name: String, point: Vector2, heading: float) -> void:
	_locomotion(ship_name).place(point, heading)


func _follower(ship_name: String) -> RouteFollower:
	return _main.get_node("Ships/%s/RouteFollower" % ship_name) as RouteFollower


func _locomotion(ship_name: String) -> ShipLocomotion:
	return _main.get_node("Ships/%s/Locomotion" % ship_name) as ShipLocomotion


func _avoidance(ship_name: String) -> Node:
	return _main.get_node("Ships/%s/Avoidance" % ship_name)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%s: %s" % ["PASS" if ok else "FAIL", label])
