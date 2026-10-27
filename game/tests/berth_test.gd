extends SceneTree
## Headless Phase 2.5 station docking stage 2a checks on the playable main scene: the
## stations' editor-authored Berth nodes (parking rectangles, poses, entry and exit
## legs) and the occupancy query. Since stage 2b the berths are the only source of
## docking positions; the parking points still equal the stage 3 docking positions. Every check is PASS/FAIL; measured rows are printed.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/berth_test.gd

const MAIN := preload("res://main.tscn")
const Station := preload("res://game/stations/station.gd")
const Berth := preload("res://game/stations/berth.gd")
const FF01 := preload("res://game/ships/ff01_unit.tscn") # The largest hull (radius 6.2), added to the scene.
const SHIPS := ["Miner1", "Transporter", "FF01"]
const MARKERS := ["ParkStop", "Handover", "ExitBack", "ExitA", "ExitB"]
const BOXES := [[Vector2(0, 0), Vector2(4, 3)], [Vector2(6, 0), Vector2(2, 0.6)], [Vector2(-6, 0), Vector2(2, 0.6)]] # Station hull (frame).
const HEADS := [[Vector2(8.6, 0), Vector2(0.6, 1.0)], [Vector2(-8.6, 0), Vector2(0.6, 1.0)]] # Visible docking heads (not obstacles).
const MARGIN := 1.0 # u between footprints kept along entry and exit paths (as the prototype's corridor margin).

var _main: Node
var _stations: Array[Station] = []
var _navigation: Node
var _failures := 0
var _checks := 0


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	var ff01 := FF01.instantiate()
	ff01.name = "FF01"
	ff01.position = Vector3(14, 1.5, 0)
	_main.get_node("Ships").add_child(ff01)
	root.add_child(_main)
	_navigation = _main.get_node("StaticNavigation")
	for station in _main.get_node("Stations").get_children():
		_stations.append(station as Station)
	_main.get_node("Survey").set_physics_process(false)
	for ship in _main.get_node("Ships").get_children():
		for child in ship.get_children():
			child.set_physics_process(false)
	for station in _stations:
		station.set_physics_process(false)
	for s in SHIPS:
		while not _navigation.is_ready(_follower(s).planning_radius()):
			await physics_frame
	_test_authoring()
	_test_parity()
	_test_rectangles()
	_test_poses()
	_test_exits()
	_test_separation()
	_test_occupancy()
	_test_passive()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# Berth nodes as authored: two per station, matching the slots (BerthEast = 0, BerthWest = 1).
func _test_authoring() -> void:
	var ok := true
	for station in _stations:
		ok = ok and station.berths.size() == 2 and station.berths[0].name == "BerthEast" and station.berths[1].name == "BerthWest"
		for i in 2:
			var berth: Berth = station.berths[i]
			ok = ok and berth.global_position.distance_to(station.to_global(Vector3([8.0, -8.0][i], 0, 0))) < 0.0001 and station.slots[i].end.distance_to(_planar(berth.global_position)) < 0.0001
			ok = ok and berth.axis().distance_to(station.slots[i].axis) < 0.0001 and berth.slot_size == Vector2(14.4, 13.4)
			for marker: String in MARKERS:
				ok = ok and berth.get_node_or_null(marker) is Marker3D
		print("%s: berth axes %s / %s, rectangle %s" % [station.name, station.berths[0].axis(), station.berths[1].axis(), station.berths[0].slot_size])
	_check("both stations: BerthEast / BerthWest at the arm ends, outward axes equal to the slots', 14.4 x 13.4 u rectangles, all five markers", ok)


# Docking still uses its own points: the authored parking point is the same place.
func _test_parity() -> void:
	var worst := 0.0
	for station in _stations:
		for i in 2:
			for s in SHIPS:
				var former: Vector2 = station.slots[i].end + station.slots[i].axis * (_follower(s).planning_radius() + 0.5) # Stage 3 formula (planning radius + 0.5 u beyond the arm end).
				worst = maxf(worst, station.berths[i].park_point(_r(s)).distance_to(former))
	_check("authored parking point = the former (stage 3) docking position for every class on every berth (largest difference %.6f u)" % worst, worst < 0.0001)


func _test_rectangles() -> void:
	var apart := true
	var hull := INF
	for station in _stations:
		var centre := _planar(station.global_position)
		for x in range(-60, 61):
			for z in range(-60, 61):
				var p := centre + Vector2(x, z) * 0.5
				apart = apart and not (station.berths[0].rect_gap(p) < 0.0 and station.berths[1].rect_gap(p) < 0.0)
		for i in 2:
			var corners := station.berths[i].corners()
			for k in 4:
				for t in 41:
					hull = minf(hull, _box_gap(station, corners[k].lerp(corners[(k + 1) % 4], t / 40.0), 0.0, BOXES))
	_check("the two rectangles of a station do not overlap; their edges stay outside the hull (closest %.2f u)" % hull, apart and hull >= -0.0001)
	var holds := INF
	for station in _stations:
		for hold: Dictionary in station.holds:
			for berth in station.berths:
				holds = minf(holds, berth.rect_gap(hold.point))
	_check("holding positions outside both rectangles by more than an FF-01 radius (closest %.2f u)" % holds, holds > 6.2)


func _test_poses() -> void:
	var headings := true
	var heads := INF
	var handovers := INF
	var inside := true
	for station in _stations:
		for i in 2:
			var berth: Berth = station.berths[i]
			var bow := Vector2(-sin(berth.park_heading()), -cos(berth.park_heading()))
			headings = headings and absf(rad_to_deg(bow.angle_to(-berth.axis()))) < 0.001
			var legs := berth.entry_legs(1.6)
			headings = headings and legs[0].turn == berth.park_heading()
			for s in SHIPS:
				var park := berth.park_point(_r(s))
				heads = minf(heads, _box_gap(station, park, _r(s), HEADS))
				inside = inside and berth.overlaps(park, _r(s))
				handovers = minf(handovers, berth.rect_gap(berth.handover_point(_r(s))) - _r(s))
	_check("final heading (ParkStop -Z) along each berth's axis, bow toward the station; entry legs turn to it", headings)
	_check("parked circles inside their rectangle, clear of the visible docking heads (closest %.2f u); handover points outside the rectangle by the margin (%.2f u)" % [heads, handovers],
		inside and heads >= 0.0 and handovers >= 0.999)


# Fixed exits sized for the FF-01: end points outside the rectangle by the margin
# for every class; per side, whether the departure leg is clear of static obstacles
# (a blocked side is recorded, not used in stage 2b while the other is clear).
func _test_exits() -> void:
	var outside := INF
	var every_berth_has_one := true
	var blocked: Array[String] = []
	for station in _stations:
		for i in 2:
			var berth: Berth = station.berths[i]
			for s in SHIPS:
				var r := _r(s)
				var usable := 0
				for side: int in [1, -1]:
					var legs := berth.exit_legs(r, side)
					outside = minf(outside, berth.rect_gap(legs[2].move) - r)
					var clear: bool = _navigation.segment_clear(legs[0].move, legs[2].move, r) and _navigation.segment_clear(berth.park_point(r), legs[0].move, r)
					if clear:
						usable += 1
					else:
						blocked.append("%s %s %s %s" % [station.name, ["east", "west"][i], "ExitA" if side > 0 else "ExitB", s])
				every_berth_has_one = every_berth_has_one and usable >= 1
	print("exit sides blocked by static obstacles: %s" % (", ".join(blocked) if not blocked.is_empty() else "none"))
	_check("exit end points outside the rectangle by the margin for every class (closest %.2f u); every berth keeps at least one clear exit side for every class" % outside,
		outside >= 0.999 and every_berth_has_one)


func _test_separation() -> void:
	var worst := INF
	var holds := INF
	for station in _stations:
		for s in SHIPS:
			var r := _r(s)
			for side_a: int in [1, -1]:
				for side_b: int in [1, -1]:
					for a: PackedVector2Array in _paths(station.berths[0], r, side_a):
						for b: PackedVector2Array in _paths(station.berths[1], r, side_b):
							worst = minf(worst, _polyline_distance(a, b) - 2.0 * r)
			if s == "Transporter":
				for hold: Dictionary in station.holds:
					for berth in station.berths:
						for side: int in [1, -1]:
							var legs := berth.exit_legs(r, side)
							holds = minf(holds, Geometry2D.get_closest_point_to_segment(hold.point, legs[0].move, legs[2].move).distance_to(hold.point) - 2.0 * r)
	_check("east and west entry / exit paths keep two footprints + %.0f u apart for every class and side combination (closest %.2f u)" % [MARGIN, worst], worst >= MARGIN)
	_check("exit paths keep two Transporter footprints + %.0f u from every holding position (closest %.2f u)" % [MARGIN, holds], holds >= MARGIN)


# berth_occupants(): any part of the collision circle inside the rectangle, checked against
# separate code at, just inside and just outside the boundary.
func _test_occupancy() -> void:
	var station := _stations[0]
	var berth: Berth = station.berths[0]
	var axis := berth.axis()
	var normal := Vector2(-axis.y, axis.x)
	var start := _planar(berth.global_position)
	var r := _r("Transporter")
	var cases := {
		"parked": berth.park_point(r),
		"just inside the far end": start + axis * (14.4 + r - 0.01),
		"just outside the far end": start + axis * (14.4 + r + 0.01),
		"just inside the side": start + axis * 7.0 + normal * (6.7 + r - 0.01),
		"just outside the side": start + axis * 7.0 + normal * (6.7 + r + 0.01),
		"just outside a corner": start + axis * (14.4 + 0.7 * r) + normal * (6.7 + 0.72 * r),
		"at the handover point": berth.handover_point(r),
	}
	var ok := true
	var rows: Array[String] = []
	for label: String in cases:
		_park_all()
		(_main.get_node("Ships/Transporter/Locomotion")).place(cases[label], 0.0)
		var expected := _own_rect_gap(start, axis, cases[label]) < r
		var occupants := station.berth_occupants(0)
		var reported := occupants.has(_main.get_node("Ships/Transporter"))
		ok = ok and reported == expected and occupants.size() == (1 if expected else 0) and station.berth_occupants(1).is_empty()
		rows.append("%s %s" % [label, "occupied" if reported else "clear"])
	_park_all()
	(_main.get_node("Ships/Miner1/Locomotion")).place(berth.park_point(_r("Miner1")), 0.0)
	(_main.get_node("Ships/Transporter/Locomotion")).place(station.berths[1].park_point(_r("Transporter")), 0.0)
	var two: bool = station.berth_occupants(0) == [_main.get_node("Ships/Miner1")] and station.berth_occupants(1) == [_main.get_node("Ships/Transporter")]
	_check("berth_occupants() = any part of a collision circle in the rectangle (%s); two berths answer independently" % ", ".join(rows), ok and two)
	_check("occupancy is independent of reservations: slots stay free while ships stand in the rectangles", station.slots.all(func(slot: Dictionary) -> bool: return slot.ship == null))


# Passive: no debug drawing by default, the station is picked as before, no Berth child
# created at run time.
func _test_passive() -> void:
	var ok := true
	for station in _stations:
		ok = ok and not station.show_berths and station._berth_lines == null
		ok = ok and station.find_children("*", "MeshInstance3D", true, false).size() == 5
		for berth in station.berths:
			ok = ok and berth.get_child_count() == MARKERS.size()
	var camera_origin := Vector3(-36, 60, -20)
	var hit: float = _stations[0].pick(camera_origin, Vector3.DOWN)
	_check("passive: berth drawing off, no extra meshes or run-time children, the station still picked from above (%.2f u)" % hit, ok and hit < INF)


func _paths(berth: Berth, r: float, side: int) -> Array:
	var legs := berth.exit_legs(r, side)
	return [PackedVector2Array([berth.handover_point(r), berth.park_point(r)]), PackedVector2Array([berth.park_point(r), legs[0].move, legs[2].move])]


func _park_all() -> void:
	var k := 0
	for ship in _main.get_node("Ships").get_children():
		(ship.get_node("Locomotion")).place(Vector2(-130 + 15 * k, 135), 0.0)
		k += 1


func _own_rect_gap(start: Vector2, axis: Vector2, p: Vector2) -> float:
	var rel := p - start
	var along := rel.dot(axis)
	var lateral := absf(rel.dot(Vector2(-axis.y, axis.x)))
	var dx := maxf(maxf(-along, along - 14.4), 0.0)
	var dz := maxf(lateral - 6.7, 0.0)
	if dx == 0.0 and dz == 0.0:
		return -minf(minf(along, 14.4 - along), 6.7 - lateral)
	return Vector2(dx, dz).length()


static func _polyline_distance(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var best := INF
	for i in a.size() - 1:
		for j in b.size() - 1:
			var points := Geometry2D.get_closest_points_between_segments(a[i], a[i + 1], b[j], b[j + 1])
			best = minf(best, points[0].distance_to(points[1]))
	return best


func _box_gap(station: Node3D, point: Vector2, radius: float, boxes: Array) -> float:
	var local3: Vector3 = station.global_transform.affine_inverse() * Vector3(point.x, station.global_position.y, point.y)
	var local := Vector2(local3.x, local3.z)
	var gap := INF
	for rect: Array in boxes:
		var d: Vector2 = (local - rect[0]).abs() - rect[1]
		gap = minf(gap, Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() + minf(maxf(d.x, d.y), 0.0) - radius)
	return gap


func _r(s: String) -> float:
	return _follower(s).ship_radius


func _follower(s: String) -> Node:
	return _main.get_node("Ships/%s/RouteFollower" % s)


static func _planar(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-150s %s" % [label, "PASS" if ok else "FAIL"])
