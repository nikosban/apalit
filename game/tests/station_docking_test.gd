extends SceneTree
## Headless Phase 2.5 stage 2b checks on the playable main scene: station-controlled
## entry and exit through the stations' Berth nodes, reservations / physical
## occupancy / corridor clearance, FIFO hand-overs (incl. the former Hold1 / Hold4
## deadlocks and the Destroyer's ExitB at Station's west berth), single movement
## authority, held single and group commands, docked command validation, cancel()
## semantics, the panel, and mining / transport / blocked transfers through the
## maneuvers. Ship physics is stepped manually at 60 Hz in the game's order (per ship
## RouteFollower then Avoidance, then Locomotion, then Mining / Transport, Docking and
## Fuel, then the stations). Every check is PASS/FAIL; measured rows are printed.
## One deliberate cancel() during station control logs one expected error line.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/station_docking_test.gd

const MAIN := preload("res://main.tscn")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const Docking := preload("res://game/stations/docking.gd")
const Station := preload("res://game/stations/station.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const DT := 1.0 / 60.0
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2", "Transporter"]
const PARK := {"Frigate": Vector2(40, 30), "Gunship": Vector2(40, 15), "Destroyer": Vector2(40, -5), "Miner1": Vector2(40, -20),
	"Miner2": Vector2(40, -32), "Transporter": Vector2(60, 50)}
const BOXES := [[Vector2(0, 0), Vector2(4, 3)], [Vector2(6, 0), Vector2(2, 0.6)], [Vector2(-6, 0), Vector2(2, 0.6)]]
const HEADS := [[Vector2(8.6, 0), Vector2(0.6, 1.0)], [Vector2(-8.6, 0), Vector2(0.6, 1.0)]]
const BERTH_NAMES := ["E", "W"]

var _main: Node
var _a: Station
var _b: Station
var _nav: Node
var _failures := 0
var _checks := 0
var _notices: Array[String] = []
# Monitors (reset by _monitor_reset()).
var _hull_gap := INF
var _head_gap := INF
var _ship_gap := INF
var _ship_gap_pair := ""
var _authority := 0
var _occupancy_mismatch := 0
var _double_grants := 0
var _max_accel := 0.0
var _max_turn_accel := 0.0
var _snaps := 0
var _prev := {}
var _guided_before := {}


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_a = _main.get_node("Stations/Station")
	_b = _main.get_node("Stations/Station2")
	_nav = _main.get_node("StaticNavigation")
	_main.get_node("Survey").set_physics_process(false)
	for station in [_a, _b]:
		station.set_physics_process(false)
	for s in SHIPS:
		for child in ["Locomotion", "RouteFollower", "Avoidance", "Scanner", "Mining", "Transport", "Docking", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [s, child])
			if node != null:
				node.set_physics_process(false)
		for child in ["Docking", "RouteFollower", "Mining", "Transport", "Fuel"]:
			var node := _main.get_node_or_null("Ships/%s/%s" % [s, child])
			if node != null:
				node.notice.connect(func(t: String) -> void: _notices.append(t))
	for s in SHIPS:
		while not _nav.is_ready(_n(s, "RouteFollower").planning_radius()):
			await physics_frame
	_test_entries()
	_test_exits()
	_test_handovers()
	_test_both_berths()
	_test_cancel()
	await _test_commands()
	await _test_group()
	await _test_panel()
	_test_operations()
	_test_counters()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# ------------------------------------------------------------------ entries
func _test_entries() -> void:
	print("== ENTRY (the other berth reserved by a parked ship, so the berth is forced)")
	print("ship        berth from    total  entry  alignErr posErr hullGap headGap contacts snaps maxAcc maxTurnAcc authority drift10s visualFwd")
	var ok_all := true
	for s in ["Miner1", "Frigate", "Gunship", "Transporter", "Destroyer"]:
		for berth in 2:
			var axis: Vector2 = _a.slots[berth].axis
			var center := _planar(_a)
			var normal := Vector2(-axis.y, axis.x)
			var starts := {"front": center + axis * 55.0, "side": center + axis * 14.0 + normal * 40.0, "behind": center - axis * 45.0 + normal * 10.0}
			for key: String in starts:
				if s == "Destroyer" and key != "front":
					continue
				_reset()
				_a.slots[1 - berth].ship = _ship("Gunship" if s != "Gunship" else "Frigate")
				_place(s, _nav.closest_point(_n(s, "RouteFollower").planning_radius(), starts[key]))
				_monitor_reset()
				var r := _entry(s, _a)
				var held := _hold_check(s, _a.berths[berth].park_heading(), 600)
				var ok: bool = r.docked and _dk(s).slot == berth and r.align <= 0.5 and r.pos <= 0.05 and _hull_gap >= 0.0 and _head_gap >= 0.0 \
					and _lo(s).collision_count == 0 and _snaps == 0 and _authority == 0 and held.drift <= 0.01 and held.visual <= 0.5
				ok_all = ok_all and ok
				print("%-11s %s     %-7s %5.1f %6.1f %6.2f°  %6.3f %6.2f %6.2f   %d        %d   %.2f   %.1f   %d        %.3f°   %.3f°%s" % [s, BERTH_NAMES[berth], key,
					r.total, r.entry, r.align, r.pos, _hull_gap, _head_gap, _lo(s).collision_count, _snaps, _max_accel, _max_turn_accel, _authority,
					held.drift, held.visual, "" if ok else "  <-- FAIL"])
	_check("every class docks on both berths (3 approach directions; Destroyer from the front): heading on the berth axis <= 0.5° at Docked and after 10 s (visible bow), position <= 0.05 u, no clipping of hull or docking heads, no contacts, snaps or shared control", ok_all)


func _entry(s: String, st: Station) -> Dictionary:
	var dk := _dk(s)
	dk.dock(st)
	var r := {"docked": false, "total": -1.0, "entry": -1.0, "align": INF, "pos": INF}
	var handover := -1
	for tick in 60 * 180:
		_step()
		if handover < 0 and dk.under_control():
			handover = tick
		if dk.state == Docking.State.DOCKED:
			r.docked = true
			r.total = tick * DT
			r.entry = (tick - handover) * DT
			r.align = absf(rad_to_deg(wrapf(_lo(s).heading - st.berths[dk.slot].park_heading(), -PI, PI)))
			r.pos = _lo(s).planar_position.distance_to(dk.dock_point)
			break
	return r


# ------------------------------------------------------------------ exits
func _test_exits() -> void:
	print("== EXIT (alone at the station)")
	print("ship        berth side t_exit t_release release(along,lateral) gapAtRelease prevGap hullGap headGap contacts snaps maxAcc maxTurnAcc authority driftAfter")
	var ok_all := true
	for s in ["Miner1", "Transporter", "Destroyer"]:
		for berth in 2:
			_reset()
			_a.slots[1 - berth].ship = _ship("Gunship")
			_place(s, _nav.closest_point(_n(s, "RouteFollower").planning_radius(), _planar(_a) + _a.slots[berth].axis * 55.0))
			_entry(s, _a)
			_a.slots[1 - berth].ship = null
			_monitor_reset()
			var r := _exit(s, _a, berth)
			var after := _hold_check(s, _lo(s).heading, 300)
			var valid: bool = _a.exit_sides(berth, _r(s)).has(_dk(s).exit_side)
			var ok: bool = r.ended and r.released and r.gap_at_release >= 0.0 and r.prev_gap < 0.0 and valid and _hull_gap >= 0.0 and _head_gap >= 0.0 \
				and _lo(s).collision_count == 0 and _snaps == 0 and _authority == 0 and _occupancy_mismatch == 0 and after.drift <= 0.01
			ok_all = ok_all and ok
			print("%-11s %s     %+d  %6.1f %8.1f  (%5.1f, %5.1f)            %6.3f  %6.3f %6.2f %6.2f   %d        %d   %.2f   %.1f   %d        %.3f°%s" % [s, BERTH_NAMES[berth],
				_dk(s).exit_side, r.t_exit, r.t_release, r.along, r.lateral, r.gap_at_release, r.prev_gap, _hull_gap, _head_gap, _lo(s).collision_count, _snaps,
				_max_accel, _max_turn_accel, _authority, after.drift, "" if ok else "  <-- FAIL"])
	_check("exits: a valid authored side, the reservation released exactly when the circle leaves the rectangle (gap >= 0 after, < 0 before), occupancy = physical overlap, no clipping, contacts, snaps, shared control or rotation after control returns", ok_all)
	_check("the Destroyer at Station's west berth has only ExitB (ExitA blocked by an asteroid) and used it", _a.exit_sides(1, 6.2) == [-1])


func _exit(s: String, st: Station, berth: int) -> Dictionary:
	var dk := _dk(s)
	dk.undock()
	var r := {"ended": false, "released": false, "t_exit": -1.0, "t_release": -1.0, "along": 0.0, "lateral": 0.0, "gap_at_release": -INF, "prev_gap": INF}
	var radius := _r(s)
	var prev_gap: float = st.berths[berth].rect_gap(_lo(s).planar_position) - radius
	for tick in 60 * 120:
		_step()
		var gap: float = st.berths[berth].rect_gap(_lo(s).planar_position) - radius
		if not r.released and st.slots[berth].ship != _ship(s):
			r.released = true
			r.t_release = tick * DT
			var rel: Vector2 = _lo(s).planar_position - st.slots[berth].end
			r.along = rel.dot(st.slots[berth].axis)
			r.lateral = rel.dot(Vector2(-st.slots[berth].axis.y, st.slots[berth].axis.x))
			r.gap_at_release = gap
			r.prev_gap = prev_gap
		prev_gap = gap
		if dk.state != Docking.State.UNDOCKING:
			r.ended = true
			r.t_exit = tick * DT
			break
	return r


# ------------------------------------------------------------------ hand-overs
func _test_handovers() -> void:
	print("== HAND-OVERS (A docked east, B docked west, C waits at a hold, the leaver undocks)")
	var cases := [
		["Frigate", "Gunship", "Transporter", Vector2(-20, 15), "Frigate", "Hold1 (former deadlock, east)"],
		["Gunship", "Frigate", "Transporter", Vector2(-52, -55), "Frigate", "Hold4 mirror (west)"],
		["Transporter", "Frigate", "Gunship", Vector2(-20, 15), "Transporter", "Transporter leaves east, Gunship at Hold1"],
		["Frigate", "Transporter", "Gunship", Vector2(-52, -55), "Transporter", "Transporter leaves west, Gunship at Hold4"],
		["Miner1", "Miner2", "Frigate", Vector2(-20, 15), "Miner1", "Miner leaves east, Frigate at Hold1"],
		["Frigate", "Destroyer", "Transporter", Vector2(-52, -55), "Destroyer", "Destroyer leaves west (ExitB), Transporter at Hold4"],
		["Frigate", "Destroyer", "Transporter", Vector2(-52, 15), "Destroyer", "Destroyer leaves west (ExitB), Transporter at Hold2"],
	]
	var ok_all := true
	for c: Array in cases:
		_reset()
		var a: String = c[0]
		var b: String = c[1]
		var q: String = c[2]
		var leaver: String = c[4]
		_place(a, _nav.closest_point(_n(a, "RouteFollower").planning_radius(), _planar(_a) + Vector2(50, 0)))
		_dk(a).dock(_a)
		_until(func() -> bool: return _dk(a).state == Docking.State.DOCKED, 60 * 150)
		_place(b, _nav.closest_point(_n(b, "RouteFollower").planning_radius(), _planar(_a) + Vector2(-55, 0)))
		_dk(b).dock(_a)
		_until(func() -> bool: return _dk(b).state == Docking.State.DOCKED, 60 * 150)
		_place(q, _nav.closest_point(_n(q, "RouteFollower").planning_radius(), c[3]))
		_dk(q).dock(_a)
		_until(func() -> bool: return not _lo(q).has_destination, 60 * 60)
		var hold := _a.hold_of(_ship(q))
		var freed: int = _dk(leaver).slot
		var setup_ok: bool = _dk(a).state == Docking.State.DOCKED and _dk(b).state == Docking.State.DOCKED and hold >= 0 and freed >= 0
		_monitor_reset()
		_dk(leaver).undock()
		var released := -1.0
		var granted := -1.0
		var docked := -1.0
		var clean_grant := false
		for tick in 60 * 150:
			_step()
			if released < 0 and _a.slots[freed].ship != _ship(leaver):
				released = tick * DT
			if granted < 0 and _a.slots[freed].ship == _ship(q):
				granted = tick * DT
				clean_grant = _a.berth_occupants(freed).is_empty() and (not _dk(leaver).under_control() or _a.corridor_clear(freed, _ship(q)))
			if _dk(q).state == Docking.State.DOCKED:
				docked = tick * DT
				break
		var contacts := _lo(leaver).collision_count + _lo(q).collision_count
		var ok: bool = setup_ok and docked >= 0 and clean_grant and granted >= released and contacts == 0 and _ship_gap >= 1.0 and _double_grants == 0
		ok_all = ok_all and ok
		print("%-52s waits at Hold%d, exit side %+d, released %.1f s, granted %.1f s (rectangle empty, corridor clear: %s), %s, min ship gap %.2f u (%s), contacts %d%s" % [
			c[5], hold + 1, _dk(leaver).exit_side, released, granted, clean_grant, ("docked %.1f s" % docked) if docked >= 0 else "NOT DOCKED (%s)" % _dk(q).state_name(),
			_ship_gap, _ship_gap_pair, contacts, "" if ok else "  <-- FAIL"])
	_check("hand-overs incl. the former Hold1 deadlock, its Hold4 mirror and the Destroyer's ExitB with a ship waiting on either side: every waiting ship docks; granted only with the rectangle empty and the corridor clear, never before the release; 0 contacts; ships >= 1 u apart", ok_all)


# ------------------------------------------------------------------ both berths
func _test_both_berths() -> void:
	_reset()
	_place("Miner1", Vector2(-10, -40))
	_place("Transporter", Vector2(-80, -45))
	_monitor_reset()
	_dk("Miner1").dock(_a)
	_dk("Transporter").dock(_a)
	_until(func() -> bool: return _dk("Miner1").state == Docking.State.DOCKED and _dk("Transporter").state == Docking.State.DOCKED, 60 * 150)
	var both: bool = _dk("Miner1").state == Docking.State.DOCKED and _dk("Transporter").state == Docking.State.DOCKED and _dk("Miner1").slot != _dk("Transporter").slot
	var occupancy: bool = both and _a.berth_occupants(_dk("Miner1").slot) == [_ship("Miner1")] and _a.berth_occupants(_dk("Transporter").slot) == [_ship("Transporter")]
	_check("both berths reserved and occupied independently, each rectangle holds only its ship", both and occupancy)
	_dk("Miner1").undock()
	_dk("Transporter").undock()
	_until(func() -> bool: return _dk("Miner1").state == Docking.State.NONE and _dk("Transporter").state == Docking.State.NONE, 60 * 120)
	_check("both undock at once: exits finish, berths released, 0 contacts, no shared control or double grant (min ship gap %.2f u)" % _ship_gap,
		_a.slots.all(func(slot: Dictionary) -> bool: return slot.ship == null) and _contacts() == 0 and _authority == 0 and _double_grants == 0 and _occupancy_mismatch == 0)


# ------------------------------------------------------------------ cancel()
func _test_cancel() -> void:
	# During station control: refused, the maneuver goes on.
	_reset()
	_a.slots[1].ship = _ship("Gunship")
	_place("Miner1", _planar(_a) + Vector2(55, 0))
	_dk("Miner1").dock(_a)
	_until(func() -> bool: return _dk("Miner1").under_control(), 60 * 60)
	_dk("Miner1").cancel() # Deliberate: one expected error line.
	var refused: bool = _dk("Miner1").refused_during_control == 1 and _dk("Miner1").state == Docking.State.APPROACHING and _a.slots[0].ship == _ship("Miner1")
	var done := _until(func() -> bool: return _dk("Miner1").state == Docking.State.DOCKED, 60 * 60)
	_check("cancel() during the controlled entry: refused and counted, the reservation kept, the entry finishes (Docked)", refused and done >= 0)
	# While docked: the request is released, the ship does not move, the berth stays physically occupied.
	var at := _lo("Miner1").planar_position
	_dk("Miner1").cancel()
	_place("Frigate", _nav.closest_point(2.6, _planar(_a) + Vector2(20, 30)))
	_dk("Frigate").dock(_a)
	_steps(600)
	var still: bool = _lo("Miner1").planar_position == at and not _lo("Miner1").has_destination and _dk("Miner1").state == Docking.State.NONE
	var blocked: bool = _a.slots[0].ship == _ship("Miner1") and _a.slots[0].leaving and _dk("Frigate").state == Docking.State.WAITING
	_check("cancel() while docked: no movement (cancelling is not undocking), the request released, the berth stays reserved while the ship is inside it, the waiting ship is not granted it", still and blocked)


# ------------------------------------------------------------------ held and validated commands
func _test_commands() -> void:
	var selection := _main.get_node("Selection")
	var first := _planar(_a) + Vector2(24, -12)
	var second := _planar(_a) + Vector2(30, 8)
	# Move during the controlled exit: held, the newest wins, executed when control ends.
	await _dock_selected("Miner1")
	_dk("Miner1").undock()
	_steps(60)
	var plans: int = _n("Miner1", "RouteFollower").plans
	_right_click(first)
	_steps(30)
	_right_click(second)
	var early := false
	for tick in 60 * 60:
		var controlled_before := _dk("Miner1").under_control()
		_step()
		if not controlled_before:
			break
		if _dk("Miner1").under_control(): # Still under control after this tick: nothing may have been executed.
			early = early or _n("Miner1", "RouteFollower").plans != plans or _lo("Miner1").has_destination
	_check("Move during the exit: held (nothing executed during control), the later click replaced the earlier, executed when control ended",
		not early and _n("Miner1", "RouteFollower").requested.distance_to(second) < 0.5 and _lo("Miner1").has_destination and not _dk("Miner1").has_held_command())
	_until(func() -> bool: return not _lo("Miner1").has_destination, 60 * 60)
	_check("... and the Miner arrives there under normal movement", _lo("Miner1").planar_position.distance_to(second) < 0.3)
	# Move during the controlled entry: the entry finishes on the pose, then the exit, then the Move.
	_reset()
	selection.set_selection([_ship("Miner1")])
	_a.slots[1].ship = _ship("Gunship")
	_place("Miner1", _planar(_a) + Vector2(55, 0))
	_dk("Miner1").dock(_a)
	_until(func() -> bool: return _dk("Miner1").under_control(), 60 * 60)
	_right_click(first)
	var closest := INF
	var exited := false
	while (_dk("Miner1").under_control() or _dk("Miner1").state == Docking.State.APPROACHING) and _lo("Miner1").guided or _dk("Miner1").state == Docking.State.UNDOCKING:
		_step()
		closest = minf(closest, _lo("Miner1").planar_position.distance_to(_dk("Miner1").dock_point))
		exited = exited or _dk("Miner1").state == Docking.State.UNDOCKING
	_step()
	_check("Move during the entry: entry completed on the parking pose (%.3f u), then the controlled exit, then the Move" % closest,
		closest < 0.01 and exited and _n("Miner1", "RouteFollower").requested.distance_to(first) < 0.5 and _lo("Miner1").has_destination)
	# Move while docked: validated, then the controlled exit, then the Move.
	await _dock_selected("Miner1")
	_right_click(first)
	var exiting: bool = _dk("Miner1").state == Docking.State.UNDOCKING and _dk("Miner1").under_control()
	_until(func() -> bool: return not _dk("Miner1").under_control(), 60 * 60)
	_step()
	_check("Move while docked: accepted, the controlled exit starts at once, the Move follows it", exiting and _n("Miner1", "RouteFollower").requested.distance_to(first) < 0.5)
	# Dock on its own station while docked: nothing changes. (Refused Mine / Dock
	# elsewhere while docked: order_consistency_test.)
	await _dock_selected("Miner1")
	var slot: int = _dk("Miner1").slot
	_right_click(_planar(_a))
	_steps(5)
	_check("right-click on its own station while docked changes nothing (still Docked in its berth, not leaving, nothing held)",
		_dk("Miner1").state == Docking.State.DOCKED and not _dk("Miner1").has_held_command() and _a.slot_of(_ship("Miner1")) == slot and not _a.slots[slot].leaving)
	selection.set_selection([])


func _dock_selected(s: String) -> void:
	_reset()
	_main.get_node("Selection").set_selection([_ship(s)])
	_a.slots[1].ship = _ship("Gunship")
	_place(s, _planar(_a) + Vector2(55, 0))
	_dk(s).dock(_a)
	_until(func() -> bool: return _dk(s).state == Docking.State.DOCKED, 60 * 150)
	_a.slots[1].ship = null
	_frame(_planar(_a) + Vector2(18, 0), 40.0)
	await process_frame


# Group MOVE with a free ship, a docked ship and a ship under station control: one
# GroupOrders assignment; each ship ends at its own assigned destination.
func _test_group() -> void:
	var selection := _main.get_node("Selection")
	_reset()
	_a.slots[1].ship = _ship("Destroyer")
	_place("Miner1", _planar(_a) + Vector2(55, 0))
	_dk("Miner1").dock(_a)
	_until(func() -> bool: return _dk("Miner1").state == Docking.State.DOCKED, 60 * 150)
	_a.slots[1].ship = null
	_place("Transporter", _nav.closest_point(5.1, _planar(_a) + Vector2(-55, 0)))
	_dk("Transporter").dock(_a)
	_until(func() -> bool: return _dk("Transporter").under_control(), 60 * 90)
	_place("Frigate", Vector2(10, -30))
	var ships := [_ship("Frigate"), _ship("Miner1"), _ship("Transporter")]
	selection.set_selection(ships)
	_frame(Vector2(-5, -25), 45.0)
	await process_frame
	var click := Vector2(0, -40)
	# As the scene input does: the clicked ground point from the camera ray, the selection order.
	var camera: Camera3D = _main.get_node("CameraRig/Camera3D")
	var screen := camera.unproject_position(Vector3(click.x, 0, click.y))
	var hit: Vector3 = Plane(Vector3.UP, 0.0).intersects_ray(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
	var expected: Dictionary = _main.get_node("GroupOrders").assign(selection.selected, Vector2(hit.x, hit.z))
	_right_click(click)
	var frigate_now: bool = _lo("Frigate").has_destination and _ordered("Frigate", expected)
	var miner_exits: bool = _dk("Miner1").state == Docking.State.UNDOCKING and _dk("Miner1").has_held_command()
	var transporter_held: bool = _dk("Transporter").under_control() and _dk("Transporter").has_held_command()
	_until(func() -> bool: return not _dk("Miner1").under_control(), 60 * 60)
	_step()
	var miner_dest: bool = _lo("Miner1").has_destination and _ordered("Miner1", expected)
	# The Transporter finishes its entry (Docked), then its own controlled exit, then takes its destination.
	_until(func() -> bool: return _dk("Transporter").state == Docking.State.NONE and not _dk("Transporter").under_control(), 60 * 120)
	_step()
	var transporter_dest: bool = _lo("Transporter").has_destination and _ordered("Transporter", expected)
	_check("group MOVE: the free Frigate goes at once to its assigned destination (%s), the docked Miner leaves under control then goes to its own (%s), the Transporter under control finishes its entry and exit then goes to its own (%s); no RouteFollower order reached a guided ship" % [
		frigate_now, miner_exits and miner_dest, transporter_held and transporter_dest], frigate_now and miner_exits and miner_dest and transporter_held and transporter_dest
		and _guard_counts() == 0)
	selection.set_selection([])


# The ship's last order is exactly its GroupOrders destination (the point ordered; the
# route end may snap it).
func _ordered(s: String, expected: Dictionary) -> bool:
	return _n(s, "RouteFollower").requested.distance_to(expected[_ship(s)]) < 0.001


# ------------------------------------------------------------------ panel
func _test_panel() -> void:
	var panel := _main.get_node("ShipPanel")
	var selection := _main.get_node("Selection")
	# Under station control: Start / Resume disabled.
	_reset()
	_a.slots[1].ship = _ship("Gunship")
	selection.set_selection([_ship("Miner1")])
	_mining("Miner1").target = 19
	_mining("Miner1").status = MiningOperation.Status.CANCELED
	_place("Miner1", _planar(_a) + Vector2(55, 0))
	_dk("Miner1").dock(_a)
	_until(func() -> bool: return _dk("Miner1").under_control(), 60 * 60)
	await process_frame
	panel._process(0.0)
	var disabled_in_control: bool = panel._resume.disabled
	_until(func() -> bool: return _dk("Miner1").state == Docking.State.DOCKED, 60 * 60)
	panel._process(0.0)
	var enabled_docked: bool = not panel._resume.disabled
	panel._resume.pressed.emit()
	var leaving: bool = _dk("Miner1").state == Docking.State.UNDOCKING
	_until(func() -> bool: return not _dk("Miner1").under_control(), 60 * 60)
	_steps(3)
	_check("panel Resume Mining: disabled while the station moves the ship, enabled when docked; pressed while docked: controlled exit, then the assignment resumes (%s)" % _mining("Miner1").activity(),
		disabled_in_control and enabled_docked and leaving and _mining("Miner1").status == MiningOperation.Status.TRAVELING)
	# Start Transport docked at another station than the loading one: exit, then start.
	_reset()
	var transport := _transport()
	_a.storage.add(&"iron", 200)
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(&"iron", 100)
	_b.slots[1].ship = _ship("Gunship")
	_place("Transporter", _nav.closest_point(5.1, _planar(_b) + Vector2(55, 0)))
	_dk("Transporter").dock(_b)
	_until(func() -> bool: return _dk("Transporter").state == Docking.State.DOCKED, 60 * 150)
	_b.slots[1].ship = null
	selection.set_selection([_ship("Transporter")])
	await process_frame
	panel._process(0.0)
	var start_enabled: bool = not panel._start.disabled
	panel._start.pressed.emit()
	var exiting: bool = _dk("Transporter").state == Docking.State.UNDOCKING and transport.status != TransportOperation.Status.LOADING
	_until(func() -> bool: return not _dk("Transporter").under_control(), 60 * 60)
	_steps(3)
	_check("panel Start Transport docked at Station2 for loading at Station: enabled, controlled exit first, then started (%s)" % transport.activity(),
		start_enabled and exiting and transport.status == TransportOperation.Status.LOADING and _dk("Transporter").station == _a)
	# Start Transport docked at its loading station: loads in place.
	_reset()
	_a.storage.add(&"iron", 200)
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(&"iron", 100)
	_a.slots[1].ship = _ship("Gunship")
	_place("Transporter", _nav.closest_point(5.1, _planar(_a) + Vector2(55, 0)))
	_dk("Transporter").dock(_a)
	_until(func() -> bool: return _dk("Transporter").state == Docking.State.DOCKED, 60 * 150)
	panel._process(0.0)
	panel._start.pressed.emit()
	_steps(60)
	_check("panel Start Transport docked at its loading station: loads in place (%d aboard after 1 s), stays docked" % _cargo("Transporter").quantity(),
		_dk("Transporter").state == Docking.State.DOCKED and _cargo("Transporter").quantity() > 0)
	# A transport configuration pause during the controlled entry: the entry finishes, the ship stays docked, the edit kept.
	_reset()
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(&"iron", 100)
	_a.storage.add(&"iron", 200)
	_a.slots[1].ship = _ship("Gunship")
	_place("Transporter", _nav.closest_point(5.1, _planar(_a) + Vector2(55, 0)))
	transport.start()
	_until(func() -> bool: return _dk("Transporter").under_control(), 60 * 90)
	transport.set_unload_station(_a)
	transport.set_unload_station(_b) # Two edits: paused once.
	var paused := transport.status == TransportOperation.Status.PAUSED and _dk("Transporter").under_control()
	_until(func() -> bool: return _dk("Transporter").state == Docking.State.DOCKED, 60 * 60)
	_steps(120)
	_check("transport configuration edited during the controlled entry: paused at once, the entry finishes, the ship stays docked with no transfer, the configuration kept",
		paused and _dk("Transporter").state == Docking.State.DOCKED and _dk("Transporter").transfer == Docking.Transfer.NONE and transport.unload_station == _b
		and _dk("Transporter").refused_during_control == 0)
	selection.set_selection([])


# ------------------------------------------------------------------ operations
func _test_operations() -> void:
	_reset()
	var mining := _mining("Miner1")
	_place("Miner1", Vector2(-60, -12))
	_cargo("Miner1").add(&"iron", _cargo("Miner1").capacity - 20)
	mining.set_base(_a)
	_monitor_reset()
	mining.assign(19)
	var stored := _a.storage.quantity()
	var back := _until(func() -> bool: return mining.status == MiningOperation.Status.MINING and _a.storage.quantity() > stored, 60 * 400)
	_check("automated mining: returns, docks under station control, unloads %d, refuels, exits, mines again (%.0f s), 0 contacts" % [_a.storage.quantity() - stored, back * DT],
		back >= 0 and _contacts() == 0 and _authority == 0)
	mining.base = null
	_reset()
	var transport := _transport()
	_a.storage.add(&"iron", 300)
	transport.set_load_station(_a)
	transport.set_unload_station(_b)
	transport.set_requirement(&"iron", 300)
	_place("Transporter", Vector2(-10, -40))
	var plans: int = _n("Transporter", "RouteFollower").plans
	transport.start()
	var delivered := _until(func() -> bool: return transport.deliveries >= 1, 60 * 600)
	_check("transport: loads at Station, delivers 300 at Station2 through controlled entries and exits (%.0f s, %d route orders), 0 contacts" % [delivered * DT,
		_n("Transporter", "RouteFollower").plans - plans], delivered >= 0 and _b.storage.quantity_of(&"iron") == 300 and _contacts() == 0)
	_reset()
	_cargo("Miner1").add(&"iron", 200)
	_a.slots[1].ship = _ship("Gunship")
	_place("Miner1", _planar(_a) + Vector2(55, 0))
	_dk("Miner1").dock(_a)
	_until(func() -> bool: return _dk("Miner1").state == Docking.State.DOCKED, 60 * 150)
	_a.slots[1].ship = null
	_a.storage.capacity = 60
	_dk("Miner1").unload()
	var exited := _until(func() -> bool: return _dk("Miner1").state == Docking.State.BLOCKED, 60 * 60)
	_until(func() -> bool: return not _lo("Miner1").has_destination, 60 * 60)
	var at_hold := _a.hold_of(_ship("Miner1")) >= 0
	_a.storage.capacity = 5000
	var redone := _until(func() -> bool: return _dk("Miner1").transfer == Docking.Transfer.NONE and _dk("Miner1").state == Docking.State.DOCKED, 60 * 150)
	_check("blocked transfer: leaves through the controlled exit, waits at a hold, docks again under control and finishes (%d aboard)" % _cargo("Miner1").quantity(),
		exited >= 0 and at_hold and redone >= 0 and _cargo("Miner1").quantity() == 0)


func _test_counters() -> void:
	var refused := 0
	for s in SHIPS:
		refused += _dk(s).refused_during_control
	_check("no RouteFollower order reached a guided ship (RouteFollower refusals + Locomotion guard: %d), cancel()/dock() refused only in the deliberate check (%d)" % [_guard_counts(), refused],
		_guard_counts() == 0 and refused == 1)


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
	for station in [_a, _b]:
		station._physics_process(DT)
	_monitor()


func _steps(count: int) -> void:
	for i in count:
		_step()


func _monitor() -> void:
	for i in SHIPS.size():
		var s: String = SHIPS[i]
		var lo := _lo(s)
		var p := lo.planar_position
		var r := _r(s)
		for st in [_a, _b]:
			_hull_gap = minf(_hull_gap, _box_gap(st, p, r, BOXES))
			_head_gap = minf(_head_gap, _box_gap(st, p, r, HEADS))
		for j in range(i + 1, SHIPS.size()):
			var gap: float = p.distance_to(_lo(SHIPS[j]).planar_position) - r - _r(SHIPS[j])
			if gap < _ship_gap:
				_ship_gap = gap
				_ship_gap_pair = "%s-%s" % [s, SHIPS[j]]
		var dk := _dk(s)
		var moved_guided: bool = _guided_before.get(s, false)
		if dk.under_control() or moved_guided:
			var avoidance := _n(s, "Avoidance")
			if lo.has_destination or avoidance.offset != Vector2.ZERO or avoidance.speed_cap != INF \
					or (moved_guided and lo.contacts.is_empty() and lo.committed_motion.distance_to(lo.desired_velocity * DT) > 0.000001):
				_authority += 1
		var before: Array = _prev.get(s, [lo.velocity, lo.angular_velocity, p, lo.heading])
		if moved_guided:
			var accel: float = (lo.velocity - before[0]).length() / DT
			var turn_accel: float = absf(rad_to_deg(lo.angular_velocity - before[1])) / DT
			_max_accel = maxf(_max_accel, accel)
			_max_turn_accel = maxf(_max_turn_accel, turn_accel)
			if accel > minf(_a.guide_accel, maxf(lo.forward_accel, lo.reverse_accel)) * 1.05 or turn_accel > minf(_a.guide_turn_accel_deg, lo.turn_accel_deg) * 1.05 \
					or p.distance_to(before[2]) > minf(_a.guide_speed, lo.max_speed) * DT * 1.05 \
					or absf(rad_to_deg(wrapf(lo.heading - before[3], -PI, PI))) > minf(_a.guide_turn_rate_deg, lo.max_turn_rate_deg) * DT * 1.05:
				_snaps += 1
		_prev[s] = [lo.velocity, lo.angular_velocity, p, lo.heading]
	for st in [_a, _b]:
		for i in st.berths.size():
			var physical: Array = []
			for s in SHIPS:
				if _own_rect_gap(st, i, _lo(s).planar_position) < _r(s):
					physical.append(_ship(s))
			var reported: Array = st.berth_occupants(i)
			if physical.size() != reported.size() or not physical.all(func(x: Node) -> bool: return reported.has(x)):
				_occupancy_mismatch += 1
	var held := {}
	for s in SHIPS:
		var dk := _dk(s)
		if dk.state in [Docking.State.APPROACHING, Docking.State.DOCKED] and dk.slot >= 0:
			var key := "%s/%d" % [dk.station.name, dk.slot]
			if held.has(key):
				_double_grants += 1
			held[key] = true


func _monitor_reset() -> void:
	_hull_gap = INF
	_head_gap = INF
	_ship_gap = INF
	_ship_gap_pair = ""
	_authority = 0
	_occupancy_mismatch = 0
	_double_grants = 0
	_max_accel = 0.0
	_max_turn_accel = 0.0
	_snaps = 0
	_prev.clear()


func _hold_check(s: String, heading: float, ticks: int) -> Dictionary:
	var start := _lo(s).heading
	var drift := 0.0
	for i in ticks:
		_step()
		drift = maxf(drift, absf(rad_to_deg(wrapf(_lo(s).heading - start, -PI, PI))))
	var basis: Basis = _ship(s).global_basis
	var bow := Vector2(-basis.z.x, -basis.z.z).normalized()
	return {"drift": drift, "visual": absf(rad_to_deg(bow.angle_to(Vector2(-sin(heading), -cos(heading)))))}


# Same rectangle definition as Berth.rect_gap(), separate code.
func _own_rect_gap(st: Station, i: int, p: Vector2) -> float:
	var axis: Vector2 = st.slots[i].axis
	var rel: Vector2 = p - st.slots[i].end
	var size: Vector2 = st.berths[i].slot_size
	var along: float = rel.dot(axis)
	var lateral: float = absf(rel.dot(Vector2(-axis.y, axis.x)))
	var dx := maxf(maxf(-along, along - size.x), 0.0)
	var dz := maxf(lateral - size.y * 0.5, 0.0)
	if dx == 0.0 and dz == 0.0:
		return -minf(minf(along, size.x - along), size.y * 0.5 - lateral)
	return Vector2(dx, dz).length()


func _guard_counts() -> int:
	var total := 0
	for s in SHIPS:
		total += _n(s, "RouteFollower").guided_refusals + _lo(s).guided_order_errors
	return total


func _reset() -> void:
	for s in SHIPS:
		var dk := _dk(s)
		dk.phase = Docking.Phase.NONE
		dk.hold_command(Callable())
		_lo(s).place(PARK[s], 0.0) # Also ends any guidance.
		dk.cancel()
		dk.state = Docking.State.NONE
		dk.transfer = Docking.Transfer.NONE
		var f := _n(s, "RouteFollower")
		f.clear()
		_n(s, "Avoidance").reset()
		_n(s, "Fuel")._set_fuel(_n(s, "Fuel").capacity)
		var cargo := _main.get_node_or_null("Ships/%s/Cargo" % s)
		if cargo != null:
			cargo.inventory.amounts.clear()
	for m in ["Miner1", "Miner2"]:
		var mining := _mining(m)
		mining.cancel()
		mining.target = -1
		mining.status = MiningOperation.Status.NONE
		mining._route_pending = false
		mining.base = null
	var transport := _transport()
	transport.cancel()
	transport.status = TransportOperation.Status.NONE
	transport.deliveries = 0
	for st in [_a, _b]:
		for slot in st.slots:
			slot.ship = null
			slot.leaving = false
		for h in st.holds:
			h.ship = null
		st.queue.clear()
		st._exiting.clear()
		st.storage.amounts.clear()
		st.storage.capacity = st.storage_capacity
		st.fuel_stock = 1000.0
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


func _nearest_asteroid(from: Vector2) -> int:
	var field := _main.get_node("Asteroids")
	var best := -1
	for id: int in field.ids():
		if best < 0 or _planar_v(field.center(id)).distance_to(from) < _planar_v(field.center(best)).distance_to(from):
			best = id
	return best


func _box_gap(st: Node3D, point: Vector2, radius: float, boxes: Array) -> float:
	var local3: Vector3 = st.global_transform.affine_inverse() * Vector3(point.x, st.global_position.y, point.y)
	var local := Vector2(local3.x, local3.z)
	var gap := INF
	for rect: Array in boxes:
		var d: Vector2 = (local - rect[0]).abs() - rect[1]
		gap = minf(gap, Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() + minf(maxf(d.x, d.y), 0.0) - radius)
	return gap


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


func _lo(s: String) -> ShipLocomotion:
	return _n(s, "Locomotion") as ShipLocomotion


func _dk(s: String) -> Docking:
	return _n(s, "Docking") as Docking


func _mining(s: String) -> MiningOperation:
	return _n(s, "Mining") as MiningOperation


func _transport() -> TransportOperation:
	return _n("Transporter", "Transport") as TransportOperation


func _cargo(s: String) -> Inventory:
	return _n(s, "Cargo").inventory


static func _planar(n: Node3D) -> Vector2:
	return Vector2(n.global_position.x, n.global_position.z)


static func _planar_v(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-150s %s" % [label, "PASS" if ok else "FAIL"])
