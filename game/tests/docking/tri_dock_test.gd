extends SceneTree
## Docking regression (from the station-controlled docking experiment; moved here in the
## M8 cleanup): tri-dock stress test on tri_dock_demo.tscn, on the production Station /
## Berth / Docking code
## (asteroid field hidden and not an obstacle; the tri-dock station at (70, 60)).
## Steps the scene manually at 60 Hz in the game's order.
##   <godot console> --headless --path . -s res://game/tests/docking/tri_dock_test.gd

const DEMO := "res://game/tests/docking/tri_dock_demo.tscn"
const Docking := preload("res://game/stations/docking.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Miner3", "Transporter2", "FF01", "Miner1", "Miner2", "Transporter"]
const CLASSES := ["Miner1", "Miner3", "Transporter2", "Transporter"]
const BAYS := ["Left", "Right", "Bottom"]

var _main: Node
var _t: Node # The tri-dock station.
var _nav: Node
var _failures := 0
var _checks := 0
var _notices: Array[String] = []
var _guided_gap := INF # Ship circle vs any static obstacle while under station control.
var _gap := INF # ... at any time.
var _ship_gap := INF
var _ship_gap_pair := ""
var _authority_violations := 0
var _occupancy_mismatch := 0
var _double_grants := 0
var _max_accel := 0.0
var _max_turn_accel := 0.0
var _snaps := 0
var _prev := {}
var _guided_before := {}


func _initialize() -> void:
	await process_frame
	_main = (load(DEMO) as PackedScene).instantiate()
	# Stand-ins for the retired warships, on their former spawn points.
	for added: Array in [["Miner3", "res://game/ships/miner_unit.tscn", Vector3(-12, 1.5, 0)], ["Transporter2", "res://game/ships/transporter_unit.tscn", Vector3(0, 1.5, 0)], ["FF01", "res://game/ships/ff01_unit.tscn", Vector3(14, 1.5, 0)]]:
		var ship: Node3D = load(added[1]).instantiate()
		ship.name = added[0]
		ship.position = added[2]
		_main.get_node("Ships").add_child(ship)
	root.add_child(_main)
	_t = _main.get_node("Stations/TriStation")
	_nav = _main.get_node("StaticNavigation")
	_main.get_node("Survey").set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	for s in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Transport", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [s, child])
			if node != null:
				node.set_physics_process(false)
		_dk(s).notice.connect(func(t: String) -> void: _notices.append(t))
	for s in SHIPS:
		while not _nav.is_ready(_n(s, "RouteFollower").planning_radius()):
			await physics_frame
	_test_geometry()
	_test_entries()
	_test_exits()
	_test_three_bays()
	_test_depart_while_receiving()
	_test_handovers()
	await _test_deferred()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# ------------------------------------------------------------------ geometry
func _test_geometry() -> void:
	print("== GEOMETRY (tri-dock station at %s)" % _planar(_t))
	for i in 3:
		var axis: Vector2 = _t.slots[i].axis
		print("bay %-6s axis (%.3f, %.3f), rectangle %.1f x %.1f u from %s, final heading %.1f deg (bow %s)" % [BAYS[i], axis.x, axis.y,
			_t.berths[i].slot_size.x, _t.berths[i].slot_size.y, _t.slots[i].end - _planar(_t), rad_to_deg(_t.berths[i].park_heading()),
			Vector2(-sin(_t.berths[i].park_heading()), -cos(_t.berths[i].park_heading())).snapped(Vector2(0.001, 0.001))])
	var bows_in := true
	for i in 3:
		var bow := Vector2(-sin(_t.berths[i].park_heading()), -cos(_t.berths[i].park_heading()))
		bows_in = bows_in and absf(rad_to_deg(bow.angle_to(-_t.slots[i].axis))) < 0.01
	_check("each bay's authored final heading (ParkStop -Z) points along its own axis toward the hub", bows_in)
	print("ship        r    bays it can dock   park wall gap   exit outside rect   handover outside rect")
	var fits_ok := true
	for s in CLASSES + ["FF01"]:
		var r := _r(s)
		_place(s, _planar(_t) + Vector2(0, -70))
		var allowed: Array = _dk(s)._allowed_slots(_t)
		var walls := INF
		var exits := INF
		var mouths := INF
		for i in 3:
			walls = minf(walls, _nav.surface_distance(_t.berths[i].park_point(r)) - r)
			for side: int in [1, -1]:
				exits = minf(exits, _t.berths[i].rect_gap(_t.berths[i].exit_legs(r, side)[2].move) - r)
			mouths = minf(mouths, _t.berths[i].rect_gap(_t.berths[i].handover_point(r)) - r)
		print("%-11s %.1f  %-18s %6.2f          %6.2f              %6.2f" % [s, r, str(allowed.map(func(i: int) -> String: return BAYS[i])), walls, exits, mouths])
		if s != "FF01":
			fits_ok = fits_ok and allowed.size() == 3 and walls >= 0.4 and exits >= 0.99 and mouths >= 0.99
		else:
			_check("geometry limitation: the FF01 (collision radius 6.2) does not fit the 10 u bays (walls 5 u from the axis): no bay offered, Dock refused", allowed.is_empty() and not _dk(s).can_dock(_t))
		_place(s, _park_spot(s))
	_check("Miner, Miner3, Transporter2, Transporter fit all three bays: parked circle clear of walls and back block, exits and handover points outside the rectangle by the margin", fits_ok)
	var apart := true
	var centre := _planar(_t)
	for x in range(-100, 101):
		for z in range(-100, 101):
			var p := centre + Vector2(x, z) * 0.5
			var inside := 0
			for i in 3:
				if _t.berths[i].rect_gap(p) < 0.0:
					inside += 1
					apart = apart and _nav.surface_distance(p) >= 0.0
			apart = apart and inside <= 1
	_check("the three rectangles do not overlap each other or any wall, back block or the hub", apart)
	var paths_ok := true
	var r_t := _r("Transporter")
	for i in 3:
		for j in 3:
			if i == j:
				continue
			for side_i: int in [1, -1]:
				for side_j: int in [1, -1]:
					var a := _paths(i, r_t, side_i)
					var b := _paths(j, r_t, side_j)
					for pa: PackedVector2Array in a:
						for pb: PackedVector2Array in b:
							paths_ok = paths_ok and _t._polyline_distance(pa, pb) - 2.0 * r_t >= _t.corridor_margin
	_check("entry and exit paths of different bays keep two Transporter footprints + margin apart (every side combination)", paths_ok)
	var holds_ok := true
	for hold: Dictionary in _t.holds:
		for i in 3:
			holds_ok = holds_ok and _t.berths[i].rect_gap(hold.point) > r_t + 1.0
			for side: int in [1, -1]:
				var legs: Array = _t.berths[i].exit_legs(r_t, side)
				holds_ok = holds_ok and Geometry2D.get_closest_point_to_segment(hold.point, legs[0].move, legs[2].move).distance_to(hold.point) > 2.0 * r_t + 1.0
	_check("holds outside every rectangle and every exit path by two Transporter footprints + margin", holds_ok)


func _paths(i: int, r: float, side: int) -> Array:
	var legs: Array = _t.berths[i].exit_legs(r, side)
	return [PackedVector2Array([_t.berths[i].handover_point(r), _t.berths[i].park_point(r)]), PackedVector2Array([_t.berths[i].park_point(r), legs[0].move, legs[2].move])]


# ------------------------------------------------------------------ entries
func _test_entries() -> void:
	print("== ENTRY (other bays reserved so the bay is forced)")
	print("ship        bay    from    t_total entry  alignErr posErr guidedWallGap anyWallGap contacts snaps maxAcc maxTurnAcc authority drift10s visualFwd")
	var ok_all := true
	for s in CLASSES:
		for bay in 3:
			var axis: Vector2 = _t.slots[bay].axis
			var starts := {"front": _planar(_t) + axis * 62.0, "left": _planar(_t) + axis.rotated(deg_to_rad(60)) * 58.0, "right": _planar(_t) + axis.rotated(deg_to_rad(-60)) * 58.0}
			for key: String in starts:
				_reset()
				_reserve_others(bay)
				_place(s, starts[key])
				_monitor_reset()
				var r := _entry(s)
				var held := _hold_check(s, _t.berths[bay].park_heading(), 600)
				var ok: bool = r.docked and _dk(s).slot == bay and r.align <= 0.5 and r.pos <= 0.05 and _guided_gap >= 0.0 and _gap >= 0.0 \
					and _lo(s).collision_count == 0 and _snaps == 0 and _authority_violations == 0 and held.drift <= 0.01 and held.visual <= 0.5
				ok_all = ok_all and ok
				print("%-11s %-6s %-7s %6.1f %6.1f %6.2f°  %6.3f %8.2f %10.2f      %d        %d   %.2f   %.1f   %d        %.3f°   %.3f°%s" % [s, BAYS[bay], key, r.total, r.entry,
					r.align, r.pos, _guided_gap, _gap, _lo(s).collision_count, _snaps, _max_accel, _max_turn_accel, _authority_violations, held.drift, held.visual,
					"" if ok else "  <-- FAIL"])
	_check("4 classes x 3 bays x 3 approach directions: docked in the bay, heading on the bay axis (<= 0.5°) at Docked and after 10 s, position <= 0.05 u, no clipping, contacts, snaps or shared control", ok_all)


func _entry(s: String) -> Dictionary:
	var dk := _dk(s)
	dk.dock(_t)
	var r := {"docked": false, "total": -1.0, "entry": -1.0, "align": INF, "pos": INF}
	var handover := -1
	for tick in 60 * 180:
		_step()
		if handover < 0 and dk.phase == dk.Phase.ENTRY:
			handover = tick
		if dk.state == Docking.State.DOCKED:
			r.docked = true
			r.total = tick * DT
			r.entry = (tick - handover) * DT
			r.align = absf(rad_to_deg(wrapf(_lo(s).heading - _t.berths[dk.slot].park_heading(), -PI, PI)))
			r.pos = _lo(s).planar_position.distance_to(dk.dock_point)
			break
	return r


# ------------------------------------------------------------------ exits
func _test_exits() -> void:
	print("== EXIT (alone at the station)")
	print("ship        bay    side t_exit t_release releasePos(along,lateral) gapAtRelease prevGap guidedWallGap contacts snaps maxAcc maxTurnAcc authority driftAfter")
	var ok_all := true
	for s in CLASSES:
		for bay in 3:
			_reset()
			_reserve_others(bay)
			_place(s, _planar(_t) + _t.slots[bay].axis * 62.0)
			_entry(s)
			_clear_reservations()
			_monitor_reset()
			var dk := _dk(s)
			var radius := _r(s)
			var prev_gap: float = _t.berths[bay].rect_gap(_lo(s).planar_position) - radius
			dk.undock()
			var released := -1.0
			var along := 0.0
			var lateral := 0.0
			var at_release := -INF
			var before_release := INF
			var ended := -1.0
			for tick in 60 * 120:
				_step()
				var gap: float = _t.berths[bay].rect_gap(_lo(s).planar_position) - radius
				if released < 0 and _t.slots[bay].ship != _ship(s):
					released = tick * DT
					var rel: Vector2 = _lo(s).planar_position - _t.slots[bay].end
					along = rel.dot(_t.slots[bay].axis)
					lateral = rel.dot(Vector2(-_t.slots[bay].axis.y, _t.slots[bay].axis.x))
					at_release = gap
					before_release = prev_gap
				prev_gap = gap
				if dk.state != Docking.State.UNDOCKING:
					ended = tick * DT
					break
			var after := _hold_check(s, _lo(s).heading, 300)
			var ok: bool = ended >= 0 and released >= 0 and at_release >= 0.0 and before_release < 0.0 and _guided_gap >= 0.0 and _lo(s).collision_count == 0 \
				and _snaps == 0 and _authority_violations == 0 and _occupancy_mismatch == 0 and after.drift <= 0.01
			ok_all = ok_all and ok
			print("%-11s %-6s %+d  %6.1f %8.1f  (%5.1f, %5.1f)               %6.3f  %6.3f %8.2f       %d        %d   %.2f   %.1f   %d        %.3f°%s" % [s, BAYS[bay], dk.exit_side,
				ended, released, along, lateral, at_release, before_release, _guided_gap, _lo(s).collision_count, _snaps, _max_accel, _max_turn_accel,
				_authority_violations, after.drift, "" if ok else "  <-- FAIL"])
	_check("exits from every bay: straight back out of the recess, turn, leave; reservation released exactly when the circle leaves the rectangle; no clipping, contacts, snaps, shared control or rotation after control returns", ok_all)


# ------------------------------------------------------------------ three bays at once
func _test_three_bays() -> void:
	_reset()
	var ships := ["Miner1", "Transporter2", "Transporter"]
	for k in 3:
		_place(ships[k], _planar(_t) + _t.slots[k].axis * 62.0)
	_monitor_reset()
	for s in ships:
		_dk(s).dock(_t)
	var t := _until(func() -> bool: return ships.all(func(s: String) -> bool: return _dk(s).state == Docking.State.DOCKED), 60 * 150)
	var slots := ships.map(func(s: String) -> int: return _dk(s).slot)
	var occupancy := true
	for s: String in ships:
		occupancy = occupancy and _dk(s).slot >= 0 and _t.slots[_dk(s).slot].ship == _ship(s) and _t.berth_occupants(_dk(s).slot) == [_ship(s)]
	_check("three ships requested at once all docked (%.1f s) in three different bays %s; each rectangle holds only its ship; 0 contacts, no double grant" % [t * DT,
		str(slots.map(func(i: int) -> String: return BAYS[i] if i >= 0 else "-"))], t >= 0 and slots[0] != slots[1] and slots[1] != slots[2] and slots[0] != slots[2]
		and occupancy and _contacts() == 0 and _double_grants == 0 and _occupancy_mismatch == 0)
	for s in ships:
		_dk(s).undock()
	var out := _until(func() -> bool: return ships.all(func(s: String) -> bool: return _dk(s).state == Docking.State.NONE), 60 * 120)
	_check("all three undock at once: exits finish (%.1f s), every bay released, 0 contacts, min ship gap %.2f u (%s)" % [out * DT, _ship_gap, _ship_gap_pair],
		out >= 0 and _t.slots.all(func(slot: Dictionary) -> bool: return slot.ship == null) and _contacts() == 0 and _authority_violations == 0)


# ------------------------------------------------------------------ departure while another bay receives
func _test_depart_while_receiving() -> void:
	print("== DEPARTURE FROM ONE BAY WHILE ANOTHER BAY RECEIVES A SHIP")
	var ok_all := true
	for leaving_bay in 3:
		for arriving_bay in 3:
			if leaving_bay == arriving_bay:
				continue
			_reset()
			_reserve_only(leaving_bay)
			_place("Miner1", _planar(_t) + _t.slots[leaving_bay].axis * 62.0)
			_entry("Miner1")
			_clear_reservations()
			_reserve_only(arriving_bay)
			_t.slots[leaving_bay].ship = _ship("Miner1")
			_place("Transporter", _planar(_t) + _t.slots[arriving_bay].axis * 40.0)
			_dk("Transporter").dock(_t)
			_until(func() -> bool: return _dk("Transporter").phase == _dk("Transporter").Phase.ENTRY, 60 * 60)
			_monitor_reset()
			_dk("Miner1").undock()
			var t := _until(func() -> bool: return _dk("Transporter").state == Docking.State.DOCKED and _dk("Miner1").state == Docking.State.NONE, 60 * 90)
			var ok: bool = t >= 0 and _dk("Transporter").slot == arriving_bay and _contacts() == 0 and _ship_gap >= 1.0 and _authority_violations == 0
			ok_all = ok_all and ok
			print("Miner1 leaves %-6s while the Transporter enters %-6s: both done %.1f s, Miner side %+d, min ship gap %.2f u, contacts %d%s" % [BAYS[leaving_bay], BAYS[arriving_bay],
				t * DT, _dk("Miner1").exit_side, _ship_gap, _contacts(), "" if ok else "  <-- FAIL"])
	_check("a departure from one bay during another bay's controlled entry: both complete, 0 contacts, ships >= 1 u apart (all 6 bay pairs)", ok_all)


# ------------------------------------------------------------------ same-bay hand-overs
func _test_handovers() -> void:
	print("== SAME-BAY HAND-OVERS (Miner3 docked, other bays reserved, Transporter waits at a hold, Miner3 undocks)")
	var ok_all := true
	for bay in 3:
		for side: int in [1, -1]:
			_reset()
			_reserve_only(bay)
			_place("Miner3", _planar(_t) + _t.slots[bay].axis * 62.0)
			_entry("Miner3")
			_clear_reservations()
			for other in 3:
				if other != bay:
					_t.slots[other].ship = _ship("FF01")
			_place("Transporter", _planar(_t) + _t.slots[bay].axis.rotated(side * deg_to_rad(60)) * 58.0)
			_dk("Transporter").dock(_t)
			_until(func() -> bool: return not _lo("Transporter").has_destination, 60 * 60)
			var hold: int = _t.hold_of(_ship("Transporter"))
			_monitor_reset()
			_dk("Miner3").undock()
			var released := -1.0
			var granted := -1.0
			var rect_empty_at_grant := false
			var t := -1.0
			for tick in 60 * 120:
				_step()
				if released < 0 and _t.slots[bay].ship != _ship("Miner3"):
					released = tick * DT
				if granted < 0 and _t.slots[bay].ship == _ship("Transporter"):
					granted = tick * DT
					rect_empty_at_grant = not _t.berths[bay].overlaps(_lo("Miner3").planar_position, _r("Miner3"))
				if _dk("Transporter").state == Docking.State.DOCKED:
					t = tick * DT
					break
			var ok: bool = hold >= 0 and t >= 0 and granted >= released and rect_empty_at_grant and _contacts() == 0 and _ship_gap >= 1.0 and _double_grants == 0
			ok_all = ok_all and ok
			print("bay %-6s Transporter at Hold%d: Miner3 exits side %+d, released %.1f s, granted %.1f s (Miner3 outside the rectangle: %s), Transporter docked %.1f s, min gap %.2f u (%s), contacts %d%s" % [
				BAYS[bay], hold + 1, _dk("Miner3").exit_side, released, granted, rect_empty_at_grant, t, _ship_gap, _ship_gap_pair, _contacts(), "" if ok else "  <-- FAIL"])
	_check("same-bay hand-over for every bay from both neighbouring holds: granted only after the leaver's circle left the rectangle, waiting ship docks, 0 contacts, ships >= 1 u apart", ok_all)


# ------------------------------------------------------------------ deferred Move
func _test_deferred() -> void:
	var selection := _main.get_node("Selection")
	_reset()
	var bay := 2
	_reserve_only(bay)
	_place("Transporter2", _planar(_t) + _t.slots[bay].axis * 62.0)
	_entry("Transporter2")
	_clear_reservations()
	var axis: Vector2 = _t.slots[bay].axis
	var first: Vector2 = _planar(_t) + axis * 48.0 + Vector2(-axis.y, axis.x) * 14.0
	var second: Vector2 = _planar(_t) + axis * 50.0 - Vector2(-axis.y, axis.x) * 20.0
	_frame(_planar(_t) + axis * 35.0, 40.0)
	await process_frame
	selection.set_selection([_ship("Transporter2")])
	_dk("Transporter2").undock()
	_steps(60)
	var plans: int = _n("Transporter2", "RouteFollower").plans
	_right_click(first)
	_steps(30)
	_right_click(second)
	var early := false
	var ended := false
	for tick in 60 * 60:
		_step()
		if _dk("Transporter2").under_control():
			early = early or _n("Transporter2", "RouteFollower").plans != plans or _lo("Transporter2").has_destination
		else:
			ended = true
			break
	var requested: Vector2 = _n("Transporter2", "RouteFollower").requested
	_check("Move during exit from the Bottom bay: nothing executed during control, the later click replaced the earlier, executed when control ended (requested %s, expected %s)" % [requested.round(), second.round()],
		ended and not early and requested.distance_to(second) < 0.5 and _lo("Transporter2").has_destination and not _dk("Transporter2").has_held_command() and _dk("Transporter2").refused_during_control == 0)
	_until(func() -> bool: return not _lo("Transporter2").has_destination, 60 * 60)
	_check("... and the Transporter2 arrives there under normal movement", _lo("Transporter2").planar_position.distance_to(second) < 0.3)
	selection.set_selection([])


# ------------------------------------------------------------------ stepping and monitors
func _step() -> void:
	for s in SHIPS:
		_n(s, "RouteFollower")._physics_process(DT)
		_n(s, "Avoidance")._physics_process(DT)
	for s in SHIPS:
		_guided_before[s] = _lo(s).guided
		_lo(s)._step(DT)
	for s in SHIPS:
		for child in ["Mining", "Transport"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [s, child])
			if node != null:
				node._physics_process(DT)
		_dk(s)._physics_process(DT)
		_n(s, "Fuel")._physics_process(DT)
	for station in _main.get_node("Stations").get_children():
		station._physics_process(DT)
	_monitor()


func _steps(count: int) -> void:
	for i in count:
		_step()


func _monitor() -> void:
	for i in SHIPS.size():
		var s: String = SHIPS[i]
		var lo: Node = _lo(s)
		var p: Vector2 = lo.planar_position
		var r := _r(s)
		var wall: float = _nav.surface_distance(p) - r
		_gap = minf(_gap, wall)
		var dk := _dk(s)
		var moved_guided: bool = _guided_before.get(s, false)
		if dk.under_control() or moved_guided:
			_guided_gap = minf(_guided_gap, wall)
		for j in range(i + 1, SHIPS.size()):
			var gap: float = p.distance_to(_lo(SHIPS[j]).planar_position) - r - _r(SHIPS[j])
			if gap < _ship_gap:
				_ship_gap = gap
				_ship_gap_pair = "%s-%s" % [s, SHIPS[j]]
		var avoidance := _n(s, "Avoidance")
		if dk.under_control() or moved_guided:
			if lo.has_destination or _n(s, "RouteFollower").status != 0 or avoidance.offset != Vector2.ZERO or avoidance.speed_cap != INF:
				_authority_violations += 1
			elif moved_guided and lo.contacts.is_empty() and lo.committed_motion.distance_to(lo.desired_velocity * DT) > 0.000001:
				_authority_violations += 1
		var before: Array = _prev.get(s, [lo.velocity, lo.angular_velocity, p, lo.heading])
		if moved_guided:
			var accel: float = (lo.velocity - before[0]).length() / DT
			var turn_accel: float = absf(rad_to_deg(lo.angular_velocity - before[1])) / DT
			_max_accel = maxf(_max_accel, accel)
			_max_turn_accel = maxf(_max_turn_accel, turn_accel)
			var cap: float = minf(_t.guide_accel, maxf(lo.forward_accel, lo.reverse_accel))
			var turn_cap: float = minf(_t.guide_turn_accel_deg, lo.turn_accel_deg)
			var top: float = minf(_t.guide_speed, lo.max_speed)
			if accel > cap * 1.05 or turn_accel > turn_cap * 1.05 or p.distance_to(before[2]) > top * DT * 1.05 \
					or absf(rad_to_deg(wrapf(lo.heading - before[3], -PI, PI))) > minf(_t.guide_turn_rate_deg, lo.max_turn_rate_deg) * DT * 1.05:
				_snaps += 1
		_prev[s] = [lo.velocity, lo.angular_velocity, p, lo.heading]
	for i in 3:
		var physical: Array = []
		for s in SHIPS:
			if _own_rect_gap(i, _lo(s).planar_position) < _r(s):
				physical.append(_ship(s))
		if physical.size() != _t.berth_occupants(i).size() or not physical.all(func(x: Node) -> bool: return _t.berth_occupants(i).has(x)):
			_occupancy_mismatch += 1
	var held := {}
	for s in SHIPS:
		var dk := _dk(s)
		if dk.state in [Docking.State.APPROACHING, Docking.State.DOCKED] and dk.slot >= 0 and dk.station == _t:
			if held.has(dk.slot):
				_double_grants += 1
			held[dk.slot] = true


# Same rectangle definition as the station's, separate code.
func _own_rect_gap(i: int, p: Vector2) -> float:
	var axis: Vector2 = _t.slots[i].axis
	var rel: Vector2 = p - _t.slots[i].end
	var size: Vector2 = _t.berths[i].slot_size
	var along: float = rel.dot(axis)
	var lateral: float = absf(rel.dot(Vector2(-axis.y, axis.x)))
	var dx := maxf(maxf(-along, along - size.x), 0.0)
	var dz := maxf(lateral - size.y * 0.5, 0.0)
	if dx == 0.0 and dz == 0.0:
		return -minf(minf(along, size.x - along), size.y * 0.5 - lateral)
	return Vector2(dx, dz).length()


func _hold_check(s: String, heading: float, ticks: int) -> Dictionary:
	var start: float = _lo(s).heading
	var drift := 0.0
	for i in ticks:
		_step()
		drift = maxf(drift, absf(rad_to_deg(wrapf(_lo(s).heading - start, -PI, PI))))
	var basis: Basis = _ship(s).global_basis
	var bow := Vector2(-basis.z.x, -basis.z.z).normalized()
	return {"drift": drift, "visual": absf(rad_to_deg(bow.angle_to(Vector2(-sin(heading), -cos(heading)))))}


func _monitor_reset() -> void:
	_guided_gap = INF
	_gap = INF
	_ship_gap = INF
	_ship_gap_pair = ""
	_authority_violations = 0
	_occupancy_mismatch = 0
	_double_grants = 0
	_max_accel = 0.0
	_max_turn_accel = 0.0
	_snaps = 0
	_prev.clear()


# Other bays held by a far-away ship (reservation only), so `bay` is the one granted.
func _reserve_others(bay: int) -> void:
	for i in 3:
		if i != bay:
			_t.slots[i].ship = _ship("FF01")


func _reserve_only(bay: int) -> void:
	_reserve_others(bay)


func _clear_reservations() -> void:
	for slot in _t.slots:
		if slot.ship == _ship("FF01"):
			slot.ship = null


func _park_spot(s: String) -> Vector2:
	return Vector2(-130 + 18 * SHIPS.find(s), -135)


func _reset() -> void:
	for s in SHIPS:
		var dk := _dk(s)
		dk.phase = dk.Phase.NONE
		dk.hold_command(Callable())
		_lo(s).guided = false
		dk.cancel()
		dk.state = Docking.State.NONE
		dk.transfer = Docking.Transfer.NONE
		var f := _n(s, "RouteFollower")
		f.status = f.RouteStatus.NONE
		f.route = PackedVector2Array()
		_n(s, "Avoidance").reset()
		_place(s, _park_spot(s))
		_n(s, "Fuel")._set_fuel(_n(s, "Fuel").capacity)
	for station in _main.get_node("Stations").get_children():
		for slot in station.slots:
			slot.ship = null
			slot.leaving = false
		for h in station.holds:
			h.ship = null
		station.queue.clear()
		station._exiting.clear()
	_notices.clear()


func _until(condition: Callable, limit: int) -> int:
	for tick in limit:
		if condition.call():
			return tick
		_step()
	return -1


func _frame(center: Vector2, zoom: float) -> void:
	var rig := _main.get_node("CameraRig")
	rig.global_position = Vector3(center.x, 0, center.y)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = zoom
	rig._apply_zoom()


func _right_click(point: Vector2) -> void:
	var camera: Camera3D = _main.get_node("CameraRig/Camera3D")
	var screen := camera.unproject_position(Vector3(point.x, 0, point.y))
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = pressed
		event.position = screen
		event.global_position = screen
		event.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		root.push_input(event, true)


func _contacts() -> int:
	var total := 0
	for s in SHIPS:
		total += _lo(s).collision_count
	return total


func _place(s: String, p: Vector2) -> void:
	_lo(s).place(p, 0.0)


func _r(s: String) -> float:
	return _n(s, "RouteFollower").ship_radius


func _ship(s: String) -> Node3D:
	return _main.get_node("Ships/" + s)


func _n(s: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [s, child])


func _lo(s: String) -> Node:
	return _n(s, "Locomotion")


func _dk(s: String) -> Node:
	return _n(s, "Docking")


static func _planar(n: Node3D) -> Vector2:
	return Vector2(n.global_position.x, n.global_position.z)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-150s %s" % [label, "PASS" if ok else "FAIL"])
