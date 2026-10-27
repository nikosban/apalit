extends SceneTree
## Stage 6B. Fixed 60 Hz production movement/weapon integration.
const Harness := preload("res://game/tests/combat/fixtures/combat_positioning_harness.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const DT := 1.0 / 60.0

class RefusalArena:
	extends "res://game/scenes/movement_lab.gd"
	var refuse_autonomous := false
	func autonomous_move(ship: Node3D, point: Vector2, through := PackedVector2Array()) -> bool:
		return false if refuse_autonomous else super.autonomous_move(ship, point, through)

var harness: Node
var checks := 0
var failures := 0


func _initialize() -> void:
	await process_frame
	if OS.get_cmdline_user_args().has("course"):
		await _course_comparison()
		_free()
		print("RESULT: %s (%d of %d checks failed)" % ["PASS" if failures == 0 else "FAIL", failures, checks])
		quit(1 if failures > 0 else 0)
		return
	if OS.get_cmdline_user_args().has("obstacle"):
		await _obstacle_case()
		_free()
		quit(1 if failures > 0 else 0)
		return
	if OS.get_cmdline_user_args().has("redirect"):
		await _redirect_cases()
		_free()
		print("RESULT: %s (%d of %d checks failed)" % ["PASS" if failures == 0 else "FAIL", failures, checks])
		quit(1 if failures > 0 else 0)
		return
	if OS.get_cmdline_user_args().has("movement"):
		await _movement()
		_free()
		print("RESULT: %s (%d of %d checks failed)" % ["PASS" if failures == 0 else "FAIL", failures, checks])
		quit(1 if failures > 0 else 0)
		return
	for side in [1, -1]:
		await _engagement(side)
	await _commands()
	await _lifecycle()
	await _availability_and_refusal()
	await _dynamic_and_boundaries()
	await _docking()
	await _ordinary_damage_and_faction()
	_free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if failures == 0 else "FAIL", failures, checks])
	quit(1 if failures > 0 else 0)


func _check(label: String, ok: bool) -> void:
	checks += 1
	failures += int(not ok)
	print("%s %s" % ["PASS" if ok else "FAIL", label])


func _free() -> void:
	if is_instance_valid(harness):
		harness.arena.free()
		harness.free()
	harness = null


func _load(start := Vector2(-240, -240), target_at := Vector2(-160, -240), side := 1) -> void:
	_free()
	harness = Harness.new()
	root.add_child(harness)
	await harness.setup(root, start, target_at, side)


func _run(seconds: float) -> void:
	for i in int(ceil(seconds * 60.0)):
		await physics_frame


func _engagement(side: int) -> void:
	await _load(Vector2(-240, -240), Vector2(-160, -240), side)
	harness.arena.orders.attack([harness.subject], harness.enemy)
	harness.move_enemy(Vector2(-160, 60), 0.6)
	await _run(140.0 + DT) # Include the final committed physics sample in the 60 s window.
	var stats: Dictionary = harness.statistics(80.0)
	var band_samples: Array = harness.samples.filter(func(s: Dictionary) -> bool: return s.distance <= 45.0 and s.distance >= 27.0)
	stats["first_band"] = band_samples[0].time if not band_samples.is_empty() else -1.0
	stats["side"] = side
	print("MEASURE " + JSON.stringify(stats))
	_check("side %d: complete 60 s measurement; detected denominator %.2f s, unobstructed %.2f s" % [side, stats.detected_seconds, stats.unobstructed_seconds],
		stats.seconds >= 59.9 and stats.detected_seconds >= 59.9 and stats.unobstructed_seconds >= 59.9)
	_check("side %d: band %.1f%% >=70%%" % [side, stats.band * 100.0], stats.band >= 0.7)
	_check("side %d: one cannon %.1f%% >=80%%; both %.1f%% >=60%%" % [side, stats.one * 100.0, stats.both * 100.0], stats.one >= 0.8 and stats.both >= 0.6)
	_check("side %d: useful movement %.1f%% >=70%%; %d cannon shots" % [side, stats.moving * 100.0, stats.shots], stats.moving >= 0.7 and stats.shots > 0)
	_check("side %d: physics, footprint and commitment" % side, _physics_ok() and _stable())


## Stage 6B.1: identical initial broadside headings and 80 u separation, first
## stationary then moving targets. "measure" captures the rejected Stage 6B before
## the production correction; it never disables the Stage 6B positioning prototype.
func _course_comparison() -> void:
	for moving in [false, true]:
		for side in [1, -1]:
			await _load(Vector2(-240, -240), Vector2(-160, -240), side)
			harness.arena.orders.attack([harness.subject], harness.enemy)
			if moving:
				harness.move_enemy(Vector2(-160, 60), 0.6)
			await _run(140.0 + DT)
			var band_samples: Array = harness.samples.filter(func(s: Dictionary) -> bool: return s.distance <= 45.0 and s.distance >= 27.0)
			var entry: float = band_samples[0].time if not band_samples.is_empty() else 140.0
			var approach: Dictionary = harness.flight_statistics(0.0, entry)
			var settled: Dictionary = harness.flight_statistics(80.0, 60.0)
			var combat_stats: Dictionary = harness.statistics(80.0)
			print("COURSE " + JSON.stringify({"moving_target": moving, "side": side, "entry": entry,
				"approach": approach, "settled_flight": settled, "settled_combat": combat_stats}))
			if OS.get_cmdline_user_args().has("measure"):
				continue
			_check("course %s side %d: approach primarily forward and faster than Stage 6B" % [moving, side], approach.within_30 >= 0.8 and entry < 35.0)
			_check("course %s side %d: no sustained sideways cruising or repeated stops" % [moving, side], settled.within_30 >= 0.8
				and settled.forward_hemisphere >= 0.95 and settled.max_sideways_seconds < 3.0 and combat_stats.stops == 0)
			_check("course %s side %d: useful range and cannon opportunities" % [moving, side], combat_stats.band >= 0.7 and combat_stats.one >= 0.8
				and combat_stats.shots > 0 and _physics_ok() and _stable())


## settle_exempt: the documented arrival settling step (remaining velocity below
## ARRIVE_SPEED set to zero as the destination ends) is not thrust.
func _physics_ok(settle_exempt := false) -> bool:
	var lo: Node = harness.subject.get_node("Locomotion")
	for i in range(1, harness.samples.size()):
		var a: Dictionary = harness.samples[i - 1]
		var b: Dictionary = harness.samples[i]
		if b.clearance < -0.001 or b.edge < -0.001 or b.ship_gap < -0.001:
			return false
		if absf(b.angular) > deg_to_rad(lo.max_turn_rate_deg) + 0.0001 or absf(b.angular - a.angular) > deg_to_rad(lo.turn_accel_deg) * DT + 0.0001:
			return false
		if b.collisions != a.collisions:
			continue # Collision may remove velocity beyond thrust limits.
		if settle_exempt and a.has_destination and not b.has_destination and b.speed == 0.0 and a.speed < lo.ARRIVE_SPEED + maxf(lo.forward_accel, lo.reverse_accel) * DT:
			continue
		var accel: Vector2 = (b.velocity - a.velocity) / DT
		var forward := Vector2(-sin(a.heading), -cos(a.heading))
		var right := Vector2(cos(a.heading), -sin(a.heading))
		var f := accel.dot(forward)
		var lateral := accel.dot(right)
		var limit: float = lo.forward_accel if f >= 0.0 else lo.reverse_accel
		if pow(f / limit, 2) + pow(lateral / lo.lateral_accel, 2) > 1.02:
			return false
	return true


func _stable() -> bool:
	var behavior: Node = harness.subject.get_node("Behavior")
	var objectives: Array = behavior.combat_objectives
	for i in range(2, objectives.size()):
		if objectives[i].time - objectives[i - 2].time < 6.0 and objectives[i].point.distance_to(objectives[i - 2].point) < 2.0:
			return false
	return behavior.combat_side_changes == 0


func _commands() -> void:
	await _load(Vector2(-240, -240), Vector2(-202, -240))
	var ship: Node3D = harness.subject
	var b: Node = ship.get_node("Behavior")
	var c: Node = ship.get_node("Combat")
	var lo: Node = ship.get_node("Locomotion")
	var orders: Node = harness.arena.orders
	orders.attack([ship], harness.enemy)
	await _run(5.0)
	_check("Attack owns a live cannon maneuver", b.command == Behavior.Command.ATTACK and lo.combat_control and b.combat_side != 0)
	orders.move([ship], Vector2(-245, -225))
	_check("Move retains valid designation, removes Attack authorization and overrides immediately", c.manual_target == harness.enemy and c.attack_target == null and not lo.combat_control)
	_check("Passive movement does not retain Attack fire authorization", c.stance_allows(harness.enemy) == CombatShip.TargetState.HOLD_FIRE)
	c.set_stance(CombatShip.Stance.AGGRESSIVE)
	var plans: int = ship.get_node("RouteFollower").plans
	var shots_before: int = harness.shots.size()
	await _run(45.0)
	_check("Move completes with no resumed pursuit of retained target", b.command == Behavior.Command.NONE and not lo.has_destination and ship.get_node("RouteFollower").plans == plans
		and c.manual_target == harness.enemy and not lo.combat_control)
	_check("normal authorized weapons continue firing during explicit movement", harness.shots.size() > shots_before)
	orders.attack([ship], harness.enemy)
	await _run(3.0)
	_check("new Attack reactivates positioning", lo.combat_control)
	orders.waypoint([ship], Vector2(-245, -210), false)
	orders.waypoint([ship], Vector2(-230, -210), true)
	plans = ship.get_node("RouteFollower").plans
	await _run(55.0)
	# Stage 6B.2: both legs are one fly-through route requested when the second is
	# added, so no further leg request follows.
	_check("Waypoint retains target, flies only its legs, then does not resume Attack", b.command == Behavior.Command.NONE and c.manual_target == harness.enemy
		and ship.get_node("RouteFollower").plans == plans and not lo.combat_control)
	orders.attack([ship], harness.enemy)
	await _run(2.0)
	orders.cancel([ship])
	await _run(15.0)
	_check("Cancel releases combat inputs and settles without renewed pursuit", b.command == Behavior.Command.NONE and not lo.combat_control and lo.velocity.length() < 0.05)
	# The preceding manual assignment was independent of this new Attack.
	_check("Cancel preserves independently assigned manual-target ownership", c.manual_target == harness.enemy and c.attack_target == null)


func _lifecycle() -> void:
	await _load(Vector2(-240, -240), Vector2(-202, -240))
	var ship: Node3D = harness.subject
	var b: Node = ship.get_node("Behavior")
	var c: Node = ship.get_node("Combat")
	var lo: Node = ship.get_node("Locomotion")
	harness.arena.orders.attack([ship], harness.enemy)
	await _run(4.0)
	var seen: Vector2 = b.last_known
	harness.arena.contacts.set_contact(0, harness.enemy, false)
	harness.move_enemy(Vector2(-180, -200), 1.0)
	await _run(1.0)
	_check("contact loss releases facing and investigates only stored position", b.investigating and b.station.distance_to(seen) < 0.001 and not lo.combat_control
		and b.combat_snapshot().get("distance") == null)
	harness.arena.contacts.set_contact(0, harness.enemy, true)
	await _run(2.0)
	_check("contact reacquisition reactivates the same Attack", b.command == Behavior.Command.ATTACK and not b.investigating and lo.combat_control)
	harness.arena.contacts.set_contact(0, harness.enemy, false)
	await _run(65.0)
	_check("permanent contact loss ends Attack and clears its owned leg and target", b.command == Behavior.Command.NONE and c.manual_target == null and c.attack_target == null
		and not lo.has_destination and not lo.combat_control and lo.velocity.length() < 0.05)
	await _load(Vector2(-240, -240), Vector2(-202, -240))
	ship = harness.subject
	harness.arena.orders.attack([ship], harness.enemy)
	await _run(2.0)
	harness.arena.contacts.set_contact(0, harness.enemy, false)
	await _run(1.0)
	harness.arena.orders.move([ship], Vector2(-270, -240))
	_check("Move retains a live designated enemy through sensor loss without retaining authorization", ship.get_node("Combat").manual_target == harness.enemy
		and ship.get_node("Combat").attack_target == null and not ship.get_node("Locomotion").combat_control)
	await _load(Vector2(-240, -240), Vector2(-202, -240))
	ship = harness.subject
	b = ship.get_node("Behavior")
	lo = ship.get_node("Locomotion")
	harness.arena.orders.attack([ship], harness.enemy)
	await _run(4.0)
	harness.enemy.get_node("Combat").destroy()
	await _run(0.6)
	_check("destroyed target releases only its Attack-owned route", b.command == Behavior.Command.NONE and not lo.combat_control and not lo.has_destination)
	await _load(Vector2(-240, -240), Vector2(-202, -240))
	ship = harness.subject
	lo = ship.get_node("Locomotion")
	harness.arena.orders.attack([ship], harness.enemy)
	await _run(2.0)
	harness.arena.orders.move([ship], Vector2(-280, -240))
	var destination: Vector2 = lo.destination
	harness.enemy.get_node("Combat").destroy()
	await _run(1.0)
	_check("target destruction never cancels a newer explicit Move", lo.has_destination and lo.destination == destination and not lo.combat_control)


func _availability_and_refusal() -> void:
	await _load(Vector2(-240, -240), Vector2(-202, -240))
	var ship: Node3D = harness.subject
	var b: Node = ship.get_node("Behavior")
	var lo: Node = ship.get_node("Locomotion")
	var cannons: Array = ship.get_node("Combat").weapons.filter(func(w: Node) -> bool: return w.config.family == &"cannon")
	harness.arena.orders.attack([ship], harness.enemy)
	await _run(3.0)
	for weapon in cannons:
		weapon.cooldown_left = 10.0
	await _run(2.0)
	_check("cooldowns do not abandon cannon positioning", lo.combat_control)
	for weapon in cannons:
		weapon.ammo = 0
		weapon.magazine = 0
	await _run(1.0)
	_check("both cannons empty stops only the cannon maneuver; Attack still designates", b.command == Behavior.Command.ATTACK and not lo.has_destination and not lo.combat_control
		and ship.get_node("Combat").manual_target == harness.enemy)
	for weapon in cannons:
		weapon.ammo = 20
	await _run(2.0)
	_check("restored availability reevaluates while Attack owns command", lo.combat_control)
	harness.arena.orders.move([ship], Vector2(-280, -250))
	var explicit_destination: Vector2 = lo.destination
	for weapon in cannons:
		weapon.ammo = 0
	await _run(1.0)
	_check("cannon unavailability cannot interrupt explicit movement", lo.has_destination and lo.destination == explicit_destination and not lo.combat_control)
	_free()
	harness = Harness.new()
	harness.arena_override = RefusalArena
	root.add_child(harness)
	await harness.setup(root, Vector2(-240, -240), Vector2(-202, -240))
	ship = harness.subject
	b = ship.get_node("Behavior")
	harness.arena.orders.attack([ship], harness.enemy)
	await _run(2.0)
	var before: int = b.move_requests
	var old_station: Vector2 = b.station
	harness.arena.refuse_autonomous = true
	var accepted: bool = b._request_move(Vector2(-270, -210), "forced refusal")
	_check("refused autonomous request cannot count the older active leg as success", not accepted and b.move_requests == before and b.station == old_station
		and ship.get_node("Locomotion").has_destination)


func _dynamic_and_boundaries() -> void:
	await _load(Vector2(-240, -240), Vector2(-202, -240))
	var b: Node = harness.subject.get_node("Behavior")
	harness.arena.orders.attack([harness.subject], harness.enemy)
	harness.move_enemy(Vector2(-232, -240), 0.8)
	await _run(45.0)
	var closing_requests: int = b.move_requests
	var current: Vector2 = harness.enemy.get_node("Locomotion").planar_position
	var away: Vector2 = (current - harness.subject.get_node("Locomotion").planar_position).normalized()
	harness.move_enemy(current + away * 45.0, 0.8)
	await _run(60.0)
	print("DYNAMIC " + JSON.stringify(harness.statistics(45.0)))
	_check("closing then retreating enemy produces adaptive objectives without penetration", closing_requests > 1 and b.move_requests > closing_requests + 1
		and harness.samples.all(func(s: Dictionary) -> bool: return s.edge >= 0.0 and s.clearance >= 0.0 and s.ship_gap >= 0.0))
	for side in [1, -1]:
		await _load(Vector2(355, -240), Vector2(345, -202), side)
		harness.arena.orders.attack([harness.subject], harness.enemy)
		harness.move_enemy(Vector2(345, -140), 0.5)
		await _run(90.0)
		var stats: Dictionary = harness.statistics(30.0)
		print("EDGE side %d " % side + JSON.stringify(stats))
		_check("edge side %d: navigable footprint retained, useful progress, no collision" % side,
			harness.samples.all(func(s: Dictionary) -> bool: return s.edge >= -0.001 and s.clearance >= -0.001 and s.ship_gap >= -0.001 and s.collisions == 0)
			and harness.subject.get_node("Behavior").move_requests > 2 and stats.moving >= 0.7)
	await _obstacle_case()


func _obstacle_case() -> void:
	await _load(Vector2(-132, 135), Vector2(-94, 135), 1)
	harness.arena.orders.attack([harness.subject], harness.enemy)
	harness.move_enemy(Vector2(-64, 165), 0.4)
	await _run(100.0)
	var max_points := 0
	for s: Dictionary in harness.samples:
		max_points = maxi(max_points, s.route_points)
	print("OBSTACLE routes up to %d points " % max_points + JSON.stringify(harness.statistics(40.0)))
	print("OBSTACLE TRACE " + JSON.stringify(harness.subject.get_node("Behavior").log))
	_check("authored asteroids produce a real navigation detour without penetration", max_points >= 3
		and harness.samples.all(func(s: Dictionary) -> bool: return s.clearance >= -0.001 and s.ship_gap >= -0.001 and s.edge >= -0.001))
	var stats: Dictionary = harness.statistics(40.0)
	var behavior: Node = harness.subject.get_node("Behavior")
	print("OBSTACLE FLIGHT " + JSON.stringify(harness.flight_statistics(40.0, 60.0)))
	# Stage 6B.1 prioritizes forward flight. One bounded braking turn is allowed
	# only for the logged committed escape from an obstructed approach. This is
	# distinct from repeated stop/rotate cycles in ordinary unobstructed engagement.
	var justified_pause: bool = stats.stops == 0 or (stats.stops == 1 and behavior.combat_side_changes == 1
		and behavior.log.any(func(line: String) -> bool: return line.contains("committed opposite approach")))
	_check("detour retains contact, useful motion and cannon opportunities; any pause is one justified escape", stats.detected_seconds >= 59.9 and stats.band >= 0.7
		and stats.one >= 0.8 and stats.both >= 0.6 and stats.moving >= 0.7 and justified_pause)


func _docking() -> void:
	_free()
	harness = Harness.new()
	harness.with_station = true
	root.add_child(harness)
	await harness.setup(root, Vector2(-270, -240), Vector2(-245, -290))
	var ship: Node3D = harness.subject
	var b: Node = ship.get_node("Behavior")
	var lo: Node = ship.get_node("Locomotion")
	var docking: Node = ship.get_node("Docking")
	var station: Node3D = harness.arena.get_node("Stations/Station")
	harness.arena.orders.attack([ship], harness.enemy)
	await _run(3.0)
	var taken: bool = harness.arena._order(ship, {"kind": harness.arena.CommandKind.DOCK, "station": station})
	var requests: int = b.move_requests
	var revoked := true
	var docked := false
	for i in 120 * 60:
		await physics_frame
		revoked = revoked and not lo.combat_control and b.move_requests == requests
		if docking.state == docking.State.DOCKED:
			docked = true
			break
	_check("FF-01 real docking owns approach and guidance, no combat requests or overrides", taken and docked and revoked and b.command == Behavior.Command.DOCK
		and lo.guided_order_errors == 0 and ship.get_node("RouteFollower").guided_refusals == 0)
	if not docked:
		return
	docking.undock()
	await _run(1.0)
	_check("combat-facing input is refused during controlled station guidance", lo.guided and not lo.combat_motion(0.0, 1.5))
	var held: bool = harness.arena._order(ship, {"kind": harness.arena.CommandKind.MOVE, "point": Vector2(-270, -210)})
	var controlled: bool = docking.under_control() and docking.has_held_command()
	await _run(60.0)
	_check("held Move exits docking without stale combat authority", held and controlled and not lo.combat_control and b.command in [Behavior.Command.MOVE, Behavior.Command.NONE])


func _ordinary_damage_and_faction() -> void:
	_free()
	harness = Harness.new()
	root.add_child(harness)
	await harness.setup(root, Vector2(-240, -240), Vector2(-202, -240), 1, false)
	var ship: Node3D = harness.subject
	harness.arena.orders.attack([ship], harness.enemy)
	await _run(45.0)
	var dead: bool = not is_instance_valid(harness.enemy) or not CombatShip.of(harness.enemy).alive
	_check("ordinary durability and stock: physical combat destroys enemy and ends owned maneuver", dead and not ship.get_node("Locomotion").has_destination
		and not ship.get_node("Locomotion").combat_control and ship.get_node("Behavior").command == Behavior.Command.NONE and not harness.shots.is_empty())
	_free()
	harness = Harness.new()
	harness.reverse_factions = true
	root.add_child(harness)
	await harness.setup(root, Vector2(-240, -240), Vector2(-202, -240))
	ship = harness.subject
	var taken: int = harness.arena.orders.attack([ship], harness.enemy)
	await _run(8.0)
	var snapshot: Dictionary = ship.get_node("Behavior").combat_snapshot()
	_check("hostile FF-01 uses the same positioning and faction-relative target checks", taken == 1 and ship.get_node("Locomotion").combat_control
		and ship.get_node("Combat").faction == 1 and snapshot.cannons.all(func(w: Dictionary) -> bool: return w.assessment.capable))


# --- Stage 6B.2 movement continuity ------------------------------------------------
# Identical scenarios before and after the correction, measured at 60 Hz from the
# harness trace. Synthetic internal routes are injected into the RouteFollower in
# open space (the isolated clear-corner test); queued Waypoints use the real orders.
# "-- movement trace" also prints frame traces around the worst speed dips.

const ROUTE_START := Vector2(-340, -270)
# Legs as [length u, turn before the leg in degrees]; mirrored for the other turn side.
const ROUTES := {
	"straight": [[200.0, 0.0]],
	"shallow": [[50.0, 0.0], [40.0, 10.0], [40.0, 10.0], [40.0, 10.0], [50.0, 0.0]],
	"short arc": [[60.0, 0.0], [5.0, 10.0], [5.0, 10.0], [5.0, 10.0], [5.0, 10.0], [5.0, 10.0], [5.0, 10.0], [60.0, 0.0]],
	"moderate": [[60.0, 0.0], [50.0, 45.0], [60.0, -45.0]],
	"sharp": [[70.0, 0.0], [70.0, 120.0]],
}
const WAYPOINT_SETS := {
	"zigzag": [[45.0, 0.0], [40.0, 20.0], [40.0, -25.0], [40.0, 20.0], [45.0, 0.0]],
	"reversal": [[60.0, 0.0], [50.0, 160.0], [40.0, 0.0]],
}


func _movement() -> void:
	if _wants("A"):
		await _combat_movement()
	if _wants("B"):
		for turn in [1.0, -1.0]:
			for name: String in ROUTES:
				await _route_case(name, ROUTES[name], turn)
			for name: String in WAYPOINT_SETS:
				await _waypoint_case(name, WAYPOINT_SETS[name], turn)
	if _wants("C"):
		await _obstacle_movement()


## "-- movement A" (or B, C) runs one scenario group; none given runs all three.
func _wants(group: String) -> bool:
	var args := OS.get_cmdline_user_args()
	return args.has(group) or not (args.has("A") or args.has("B") or args.has("C"))


func _combat_movement() -> void:
	for side in [1, -1]:
		await _load(Vector2(-240, -240), Vector2(-160, -240), side)
		harness.arena.orders.attack([harness.subject], harness.enemy)
		await _run(140.0 + DT)
		_combat_continuity("A stationary side %d" % side)
	await _load(Vector2(-240, -240), Vector2(-160, -240), 1)
	harness.arena.orders.attack([harness.subject], harness.enemy)
	harness.move_enemy(Vector2(-160, 60), 0.6)
	await _run(45.0)
	harness.move_enemy(Vector2(-120, -180), 0.8)
	await _run(30.0)
	harness.move_enemy(Vector2(-160, -260), 0.8)
	await _run(65.0 + DT)
	_combat_continuity("A moving course changes")


func _obstacle_movement() -> void:
	await _obstacle_case()
	_combat_continuity("C combat asteroid detour", 0.0, 100.0)
	for pair: Array in [[Vector2(-230, -40), Vector2(-20, 60)], [Vector2(-200, 170), Vector2(40, -10)]]:
		await _load(pair[0], Vector2(340, 340), 1)
		var lo: Node = harness.subject.get_node("Locomotion")
		lo.place(pair[0], lo.bearing_heading(pair[1] - pair[0]))
		var taken: bool = harness.arena.orders.move([harness.subject], pair[1])
		var route: PackedVector2Array = harness.subject.get_node("RouteFollower").route
		await _run_until_arrived(150.0)
		var result := _continuity("C move %s -> %s (%d points)" % [pair[0], pair[1], route.size()], 0.0, INF, route[route.size() - 1], route[route.size() - 2] if route.size() > 1 else pair[0])
		_check("C move %s: taken, arrives, no penetration, limits held" % pair[1], taken and result.arrived and result.min_clearance >= -0.001 and _physics_ok(true))


func _route_points(legs: Array, turn: float) -> PackedVector2Array:
	var points := PackedVector2Array([ROUTE_START])
	var direction := Vector2.RIGHT
	for leg: Array in legs:
		direction = direction.rotated(deg_to_rad(leg[1]) * turn)
		points.append(points[points.size() - 1] + direction * leg[0])
	return points


func _route_case(name: String, legs: Array, turn: float) -> void:
	await _load(ROUTE_START, Vector2(340, 340), 1)
	var lo: Node = harness.subject.get_node("Locomotion")
	var follower: Node = harness.subject.get_node("RouteFollower")
	var route := _route_points(legs, turn)
	var navigation: Node = harness.arena.get_node("StaticNavigation")
	var clear := true
	for i in route.size() - 1:
		clear = clear and navigation.segment_clear(route[i], route[i + 1], follower.planning_radius())
	lo.place(ROUTE_START, lo.bearing_heading(route[1] - route[0]))
	follower._start(route, ROUTE_START)
	await _run_until_arrived(150.0)
	var label := "B route %s %s" % [name, "left" if turn > 0.0 else "right"]
	var result := _continuity(label, 0.0, INF, route[route.size() - 1], route[route.size() - 2])
	_check("%s: open-space route, arrives without overshoot, limits held" % label, clear and result.arrived and result.overshoot < 0.25 and _physics_ok(true))


func _waypoint_case(name: String, legs: Array, turn: float) -> void:
	await _load(ROUTE_START, Vector2(340, 340), 1)
	var lo: Node = harness.subject.get_node("Locomotion")
	var points := _route_points(legs, turn)
	lo.place(ROUTE_START, lo.bearing_heading(points[1] - points[0]))
	for i in range(1, points.size()):
		harness.arena.orders.waypoint([harness.subject], points[i], i > 1)
	await _run_until_arrived(200.0)
	var label := "B waypoints %s %s" % [name, "left" if turn > 0.0 else "right"]
	var result := _continuity(label, 0.0, INF, points[points.size() - 1], points[points.size() - 2])
	# Fly-through tolerance for intermediate waypoints: the ship's own radius.
	var tolerance: float = harness.subject.get_node("RouteFollower").ship_radius
	var closest: Array[float] = []
	for i in range(1, points.size() - 1):
		var nearest := INF
		for s: Dictionary in harness.samples:
			nearest = minf(nearest, s.position.distance_to(points[i]))
		closest.append(snappedf(nearest, 0.01))
	var passed := closest.filter(func(d: float) -> bool: return d <= tolerance).size()
	print("WAYPOINTS %s: closest pass of each intermediate waypoint %s u (tolerance %.1f u); intermediate stops %d" % [label, str(closest), tolerance, result.stops])
	_check("%s: every waypoint flown within tolerance, no intermediate stop, final stop, limits held" % label, result.arrived and passed == points.size() - 2 and result.stops == 0
		and harness.subject.get_node("Behavior").command == Behavior.Command.NONE and result.overshoot < 0.25 and _physics_ok(true))


func _run_until_arrived(limit: float) -> void:
	var lo: Node = harness.subject.get_node("Locomotion")
	var behavior: Node = harness.subject.get_node("Behavior")
	await _run(0.5)
	for i in int(limit * 60.0):
		if not lo.has_destination and behavior.command == Behavior.Command.NONE and lo.velocity.length() < 0.01:
			break
		await physics_frame
	await _run(1.0) # Settled samples after arrival.


func _combat_continuity(label: String, from := 0.0, to := 140.0) -> void:
	_continuity(label, from, to)
	var stats: Dictionary = harness.statistics(80.0) if to >= 140.0 else harness.statistics(40.0)
	var objectives: Array = harness.subject.get_node("Behavior").combat_objectives
	# At each accepted replacement: the change of the requested travel (desired velocity
	# direction) over that tick, and of the objective's bearing from the ship.
	var courses: Array[float] = []
	var bearings: Array[float] = []
	for i in range(1, harness.samples.size()):
		var a: Dictionary = harness.samples[i - 1]
		var s: Dictionary = harness.samples[i]
		if s.objectives != a.objectives and a.has_destination and a.combat_control:
			bearings.append(rad_to_deg(absf((a.destination - a.position).angle_to(s.destination - s.position))))
			if a.desired.length() > 0.05 and s.desired.length() > 0.05:
				courses.append(rad_to_deg(absf(a.desired.angle_to(s.desired))))
				if courses[-1] > 2.0:
					print("  replacement at %.2f s: requested travel turned %.1f deg, route status %d -> %d, speed %.2f, side changes %d" % [s.time, courses[-1],
						a.status, s.status, s.speed, harness.subject.get_node("Behavior").combat_side_changes])
	courses.sort()
	bearings.sort()
	print("COMBAT %s " % label + JSON.stringify({"band": stats.band, "one": stats.one, "both": stats.both, "moving": stats.moving,
		"shots": stats.shots, "stops": stats.stops, "replacements": objectives.size(),
		"replacement_course_step_deg": {"count": courses.size(), "median": courses[courses.size() / 2] if not courses.is_empty() else 0.0,
			"over_2": courses.filter(func(c: float) -> bool: return c > 2.0).size(), "max": courses[-1] if not courses.is_empty() else 0.0},
		"replacement_objective_bearing_deg": {"median": bearings[bearings.size() / 2] if not bearings.is_empty() else 0.0, "max": bearings[-1] if not bearings.is_empty() else 0.0}}))


## Speed continuity, steering-request continuity, presentation and safety for one run.
## Dips: a fall of more than 25 % from a running peak (>= 0.5 u/s) that later recovers
## at least half way; final arrival braking never recovers and is not a dip.
func _continuity(label: String, from := 0.0, to := INF, final := Vector2.INF, final_from := Vector2.INF) -> Dictionary:
	var window: Array = harness.samples.filter(func(s: Dictionary) -> bool: return s.time >= from and s.time <= to)
	var result := {"label": label, "seconds": window.size() / 60.0, "dips": [], "worst_dip": 0.0, "min_cruise_speed": INF,
		"max_heading_request_step_deg": 0.0, "heading_request_jumps": 0, "max_desired_turn_step_deg": 0.0, "desired_turn_steps_over_2deg": 0,
		"angular_reversals": 0, "max_aim_jump_at_advance_deg": 0.0, "max_aim_step_deg": 0.0, "advances": 0,
		"idle_while_moving_events": 0, "idle_while_moving_seconds": 0.0, "plume_out_while_moving": 0,
		"stops": 0, "forward_share": 0.0, "min_clearance": INF, "min_edge": INF, "collisions": 0,
		"arrived": false, "arrival_time": -1.0, "overshoot": 0.0}
	if window.size() < 2:
		return result
	var peak := 0.0
	var peak_i := 0
	var low := INF
	var low_i := 0
	var turn_sign := 0
	var moving := 0
	var forward := 0
	for i in range(1, window.size()):
		var a: Dictionary = window[i - 1]
		var s: Dictionary = window[i]
		result.min_clearance = minf(result.min_clearance, s.clearance)
		result.min_edge = minf(result.min_edge, s.edge)
		var step := absf(rad_to_deg(wrapf(s.target_heading - a.target_heading, -PI, PI)))
		if s.has_destination and a.has_destination:
			result.max_heading_request_step_deg = maxf(result.max_heading_request_step_deg, step)
			# A step in the heading request: faster than twice the hull's turn rate (at least 1 degree per tick).
			result.heading_request_jumps += int(step > maxf(1.0, 2.0 * harness.subject.get_node("Locomotion").max_turn_rate_deg * DT))
			if s.desired.length() > 0.05 and a.desired.length() > 0.05:
				result.max_desired_turn_step_deg = maxf(result.max_desired_turn_step_deg, rad_to_deg(absf(a.desired.angle_to(s.desired))))
				result.desired_turn_steps_over_2deg += int(absf(a.desired.angle_to(s.desired)) > deg_to_rad(2.0))
		if absf(s.angular) > deg_to_rad(0.5):
			var sign := int(signf(s.angular))
			result.angular_reversals += int(turn_sign != 0 and sign != turn_sign)
			turn_sign = sign
		if s.status == 3 and a.status == 3 and s.plans == a.plans and s.replans == a.replans:
			var turn := rad_to_deg(absf((a.aim - a.position).angle_to(s.aim - s.position)))
			if s.segment != a.segment:
				result.advances += 1
				result.max_aim_jump_at_advance_deg = maxf(result.max_aim_jump_at_advance_deg, turn)
			else:
				result.max_aim_step_deg = maxf(result.max_aim_step_deg, turn)
		if s.speed > 0.5:
			moving += 1
			forward += int(s.forward_velocity > 0.0)
			if s.view_state == 1: # ThrusterView.State.IDLE
				result.idle_while_moving_seconds += DT
				result.idle_while_moving_events += int(a.view_state != 1)
			result.plume_out_while_moving += int(s.plume <= 0.0 and a.plume > 0.0)
		if s.speed < 0.1 and a.speed >= 0.1 and window.slice(i).any(func(r: Dictionary) -> bool: return r.speed > 0.5):
			result.stops += 1 # Intermediate: the ship gets under way again afterwards.
		# Dips.
		if s.speed > peak:
			peak = s.speed
			peak_i = i
			low = s.speed
			low_i = i
		elif s.speed < low:
			low = s.speed
			low_i = i
		if peak >= 0.5 and peak - low > 0.25 * peak and s.speed >= low + 0.5 * (peak - low):
			result.dips.append(_dip(window, peak_i, low_i))
			peak = s.speed
			peak_i = i
			low = s.speed
			low_i = i
	result.forward_share = float(forward) / maxi(moving, 1)
	result.collisions = window[-1].collisions - window[0].collisions
	# Lowest speed between first reaching 95 % of the run's top speed and the start of
	# the final deceleration (the last sample still at 95 %).
	var top := 0.0
	for s: Dictionary in window:
		top = maxf(top, s.speed)
	var first_fast := -1
	var last_fast := -1
	for i in window.size():
		if window[i].speed >= 0.95 * top:
			last_fast = i
			if first_fast < 0:
				first_fast = i
	for i in range(maxi(first_fast, 0), last_fast + 1):
		result.min_cruise_speed = minf(result.min_cruise_speed, window[i].speed)
	if OS.get_cmdline_user_args().has("timeline"):
		_print_trace(window, 0, window.size(), 30)
	if OS.get_cmdline_user_args().has("track"): # 10 Hz series for before/after plots.
		var track := {"label": label, "t": [], "speed": [], "turn": [], "plume": [], "x": [], "y": []}
		for i in range(0, window.size(), 6):
			var s: Dictionary = window[i]
			track.t.append(snappedf(s.time, 0.01))
			track.speed.append(snappedf(s.speed, 0.001))
			track.turn.append(snappedf(rad_to_deg(s.angular), 0.01))
			track.plume.append(snappedf(s.plume, 0.001))
			track.x.append(snappedf(s.position.x, 0.01))
			track.y.append(snappedf(s.position.y, 0.01))
		print("TRACK " + JSON.stringify(track))
	for dip: Dictionary in result.dips:
		result.worst_dip = maxf(result.worst_dip, dip.drop)
	if final != Vector2.INF:
		var last: Dictionary = window[-1]
		result.arrived = not last.has_destination and last.position.distance_to(final) <= 1.5 and last.speed < 0.05
		var approach := (final - final_from).normalized()
		for s: Dictionary in window:
			result.overshoot = maxf(result.overshoot, (s.position - final).dot(approach))
			if result.arrival_time < 0.0 and not s.has_destination and s.position.distance_to(final) <= 1.5 and s.time > 1.0:
				result.arrival_time = s.time
	var summary := result.duplicate()
	summary.dips = result.dips.map(func(d: Dictionary) -> String: return "%.1fs %.2f->%.2f (-%d%%) at=%s onset=%s %s" % [d.time, d.peak, d.low, int(d.drop * 100.0), d.reason, d.onset, d.events])
	print("CONTINUITY " + JSON.stringify(summary))
	if OS.get_cmdline_user_args().has("trace") and not result.dips.is_empty():
		var worst: Dictionary = result.dips[0]
		for dip: Dictionary in result.dips:
			if dip.drop > worst.drop:
				worst = dip
		_print_trace(window, worst.peak_i - 30, worst.low_i + 90)
	return result


func _dip(window: Array, peak_i: int, low_i: int) -> Dictionary:
	var peak: Dictionary = window[peak_i]
	var low: Dictionary = window[low_i]
	var onset_i := peak_i
	while onset_i < low_i and window[onset_i].speed >= peak.speed * 0.97:
		onset_i += 1
	var events: Array[String] = []
	for i in range(maxi(1, onset_i - 180), low_i + 1):
		var a: Dictionary = window[i - 1]
		var s: Dictionary = window[i]
		if s.plans != a.plans:
			events.append("plan@%.1f" % s.time)
		if s.replans != a.replans:
			events.append("replan@%.1f" % s.time)
		if s.segment != a.segment:
			events.append("segment%d@%.1f" % [s.segment, s.time])
		if s.objectives != a.objectives:
			events.append("objective@%.1f" % s.time)
	return {"time": low.time, "peak": peak.speed, "low": low.speed, "drop": 1.0 - low.speed / peak.speed, "reason": low.reason,
		"onset": "%s@%.1f" % [window[onset_i].reason, window[onset_i].time], "events": events, "peak_i": peak_i, "low_i": low_i}


func _print_trace(window: Array, first: int, last: int, every := 6) -> void:
	print("  t      speed  limit  why     des_v  tgt_hdg  hdg     w deg/s fwd    rev    lat    seg  aim_brg  rcap   ccap   view main  plume")
	for i in range(maxi(first, 0), mini(last, window.size() - 1), every):
		var s: Dictionary = window[i]
		var aim_bearing := rad_to_deg((s.aim - s.position).angle()) if s.status == 3 else 0.0
		print("  %6.2f %5.2f  %5.2f  %-7s %5.2f  %7.1f  %7.1f %6.2f  %5.3f  %5.3f  %5.3f  %3d  %7.1f  %5.2f  %5.2f  %d    %4.2f  %4.2f" % [s.time, s.speed,
			minf(s.limit, 99.0), s.reason, s.desired.length(), rad_to_deg(s.target_heading), rad_to_deg(s.heading), rad_to_deg(s.angular),
			s.forward_push, s.reverse_push, s.lateral_push, s.segment, aim_bearing, minf(s.route_cap, 99.0), minf(s.combat_cap, 99.0) if s.combat_control else -1.0,
			s.view_state, s.main, s.plume])


# --- Stage 6B.2 final: repeated Move commands --------------------------------------
# "-- redirect" (optionally "trace"): FF-01 under way at cruise speed takes new Move
# commands through the production player path (CombatOrders.move -> issue_move ->
# _order -> _execute), unobstructed and on a routed path. Directions are relative to
# the ship's current travel; + turns left (counterclockwise on the X/Z plane).

const REDIRECTS := {
	"45 redirect": [[0.0, 45.0]],
	"90 redirect": [[0.0, 90.0]],
	"170 reversal": [[0.0, 170.0]],
	"180 reversal": [[0.0, 180.0]],
	"alternating left/right": [[0.0, 40.0], [1.5, -40.0], [1.5, 40.0], [1.5, -40.0]],
	"rapid 0.3 s": [[0.0, 20.0], [0.3, 35.0], [0.3, 10.0], [0.3, 50.0], [0.3, 25.0], [0.3, 40.0]],
	"rapid 0.5 s": [[0.0, -30.0], [0.5, 15.0], [0.5, -45.0], [0.5, 0.0], [0.5, 30.0]],
	"while turning left, go right": [[0.0, 90.0], [1.2, -90.0]],
	"while turning right, go left": [[0.0, -90.0], [1.2, 90.0]],
}
const REDIRECT_DISTANCE := 80.0


func _redirect_cases() -> void:
	for name: String in REDIRECTS:
		await _redirect_case(name, REDIRECTS[name], Vector2(-300, -270), Vector2.RIGHT, false)
	# Routed: under way on a route with corners around the asteroid field, then redirected
	# to points whose new routes also have corners.
	for name: String in ["45 redirect", "180 reversal", "alternating left/right", "rapid 0.3 s"]:
		await _redirect_case(name, REDIRECTS[name], Vector2(-230, -40), Vector2(1, 0.48).normalized(), true)


func _redirect_case(name: String, commands: Array, start: Vector2, travel: Vector2, routed: bool) -> void:
	await _load(start, Vector2(340, 340), 1)
	var lo: Node = harness.subject.get_node("Locomotion")
	var follower: Node = harness.subject.get_node("RouteFollower")
	lo.place(start, lo.bearing_heading(travel))
	harness.arena.orders.move([harness.subject], start + travel * (200.0 if routed else 250.0))
	await _run(12.0 if not routed else 20.0) # At cruise (3 u/s after 2.5 s) before the first redirect.
	var events: Array[Dictionary] = []
	for command: Array in commands:
		await _run(command[0])
		var heading: Vector2 = lo.velocity.normalized() if lo.velocity.length() > 0.1 else Vector2(-sin(lo.heading), -cos(lo.heading))
		var point: Vector2 = lo.planar_position + heading.rotated(-deg_to_rad(command[1])) * REDIRECT_DISTANCE
		if routed: # The nearest point along that direction whose route has a corner.
			for distance in [60.0, 80.0, 100.0, 120.0, 140.0, 160.0]:
				var candidate: Vector2 = lo.planar_position + heading.rotated(-deg_to_rad(command[1])) * distance
				if harness.arena.get_node("StaticNavigation").plan(follower.planning_radius(), lo.planar_position, candidate).size() >= 3:
					point = candidate
					break
		var plans: int = follower.plans
		var taken: bool = harness.arena.orders.move([harness.subject], point)
		events.append({"time": harness.elapsed + DT, "point": point, "turn": command[1], "taken": taken and follower.plans == plans + 1,
			"route_points": follower.route.size()})
	await _run(25.0)
	var label := "%s %s" % ["routed" if routed else "open", name]
	var result := _redirect_report(label, events)
	_check("%s: every Move taken, turn and acceleration limits held, no stop, no penetration" % label, events.all(func(e: Dictionary) -> bool: return e.taken)
		and result.max_heading_step_deg <= lo.max_turn_rate_deg * DT + 0.0001 and result.max_angular_accel <= lo.turn_accel_deg + 0.01
		and result.stops == 0 and result.min_clearance >= -0.001 and _physics_ok(true))
	# The snap: the heading request stepping toward the new destination (22-180 degrees in
	# one tick before the correction) and the hull swinging far ahead of its travel.
	# A new route with corners (near obstacles) keeps the immediate redirection for its
	# clearance-checked steering line: measured only.
	if events.any(func(e: Dictionary) -> bool: return e.route_points > 2):
		print("MEASURED ONLY %s: a new route with corners is redirected at once (request step %.1f deg, hull lead %.0f deg)" % [label, result.max_target_step_deg, result.max_hull_lead_deg])
		return
	_check("%s: continuous transition: heading request steps %.1f deg (<= 10), hull leads travel by %.0f deg (<= 60)" % [label, result.max_target_step_deg, result.max_hull_lead_deg],
		result.max_target_step_deg <= 10.0 and result.max_hull_lead_deg <= 60.0)


func _redirect_report(label: String, events: Array[Dictionary]) -> Dictionary:
	var first: float = events[0].time
	var last: float = events[-1].time
	var window: Array = harness.samples.filter(func(s: Dictionary) -> bool: return s.time >= first - 0.5 and s.time <= last + 25.0)
	var result := {"label": label, "commands": events.size(), "max_heading_step_deg": 0.0, "max_angular_accel": 0.0, "max_turn_rate": 0.0,
		"max_target_step_deg": 0.0, "target_jumps_over_1deg": 0, "max_desired_step_deg": 0.0, "turn_reversals": 0, "max_render_gap_deg": 0.0,
		"speed_before": window[0].speed, "min_speed": INF, "stops": 0, "course_time": -1.0, "min_clearance": INF, "collisions": 0, "frozen_ticks": 0,
		"max_accel_step": 0.0, "max_hull_lead_deg": 0.0, "mode_changes": 0}
	var sign := 0
	for i in range(1, window.size()):
		var a: Dictionary = window[i - 1]
		var s: Dictionary = window[i]
		result.max_heading_step_deg = maxf(result.max_heading_step_deg, absf(rad_to_deg(wrapf(s.heading - a.heading, -PI, PI))))
		result.max_angular_accel = maxf(result.max_angular_accel, absf(rad_to_deg(s.angular - a.angular)) / DT)
		if i >= 2:
			var before_accel: float = (a.angular - window[i - 2].angular) / DT
			result.max_accel_step = maxf(result.max_accel_step, absf(rad_to_deg((s.angular - a.angular) / DT - before_accel)))
		if s.speed > 0.3:
			result.max_hull_lead_deg = maxf(result.max_hull_lead_deg, absf(rad_to_deg(wrapf(s.heading - harness.subject.get_node("Locomotion").bearing_heading(s.velocity), -PI, PI))))
		result.mode_changes += int(s.heading_mode != a.heading_mode)
		result.max_turn_rate = maxf(result.max_turn_rate, absf(rad_to_deg(s.angular)))
		var target := absf(rad_to_deg(wrapf(s.target_heading - a.target_heading, -PI, PI)))
		result.max_target_step_deg = maxf(result.max_target_step_deg, target)
		result.target_jumps_over_1deg += int(target > 1.0)
		if s.desired.length() > 0.05 and a.desired.length() > 0.05:
			result.max_desired_step_deg = maxf(result.max_desired_step_deg, rad_to_deg(absf(a.desired.angle_to(s.desired))))
		result.max_render_gap_deg = maxf(result.max_render_gap_deg, absf(rad_to_deg(wrapf(s.rendered_heading - s.heading, -PI, PI))))
		if absf(s.angular) > deg_to_rad(1.0):
			var next := int(signf(s.angular))
			result.turn_reversals += int(sign != 0 and next != sign)
			sign = next
		result.min_speed = minf(result.min_speed, s.speed)
		result.stops += int(s.speed < 0.1 and a.speed >= 0.1)
		result.min_clearance = minf(result.min_clearance, s.clearance)
		result.frozen_ticks += int(s.frozen)
		# New course established: hull within 5 degrees of its travel and travel within 5 degrees
		# of the requested direction, held from then on.
		var settled: bool = s.speed > 0.3 and s.desired.length() > 0.05 and absf(rad_to_deg(s.velocity.angle_to(s.desired))) < 5.0 \
			and absf(rad_to_deg(wrapf(s.heading - harness.subject.get_node("Locomotion").bearing_heading(s.velocity), -PI, PI))) < 5.0
		if s.time > last and settled and result.course_time < 0.0:
			result.course_time = s.time - last
		elif not settled and s.time > last:
			result.course_time = -1.0
	result.collisions = window[-1].collisions - window[0].collisions
	print("REDIRECT " + JSON.stringify(result))
	if OS.get_cmdline_user_args().has("trace"):
		for e: Dictionary in events:
			print("  command at %.2f s: Move %+.0f deg to (%.1f, %.1f), route of %d points" % [e.time, e.turn, e.point.x, e.point.y, e.route_points])
		print("  t       cmd speed  hdg     tgt     d_tgt  w deg/s a deg/s2  des_dir  mode frz st seg why")
		var times: Array = events.map(func(e: Dictionary) -> float: return e.time)
		for i in range(1, window.size()):
			var s: Dictionary = window[i]
			var near := times.any(func(t: float) -> bool: return s.time >= t - 0.5 and s.time <= t + 2.0)
			var command := times.any(func(t: float) -> bool: return absf(s.time - t) < DT * 0.5)
			if not near or (i % 3 != 0 and not command):
				continue
			var a: Dictionary = window[i - 1]
			print("  %6.2f  %s  %4.2f  %6.1f  %6.1f  %5.2f  %6.2f  %6.1f  %6.1f   %d    %d   %d  %d  %s" % [s.time, "*" if command else " ", s.speed,
				rad_to_deg(s.heading), rad_to_deg(s.target_heading), rad_to_deg(wrapf(s.target_heading - a.target_heading, -PI, PI)),
				rad_to_deg(s.angular), rad_to_deg(s.angular - a.angular) / DT, rad_to_deg(s.desired.angle()) if s.desired.length() > 0.01 else 0.0,
				s.heading_mode, int(s.frozen), s.status, s.segment, s.reason])
	return result
