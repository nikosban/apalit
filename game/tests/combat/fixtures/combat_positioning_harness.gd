extends Node
## Test-only two-ship Combat Test instance. The authored roster, asteroid layout,
## production weapons and movement services are never saved or changed.
## Sustained measurements use a durable target and extra per-instance cannon stock;
## ordinary-damage cases can opt out. Target travel uses the normal Move command.

const ARENA := preload("res://game/scenes/combat_test.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")

@export var run_demo := false
@export var demo_side := 1
@export var demo_moving_target := true
@export var demo_course_changes := false

var arena: Node3D
var subject: Node3D
var enemy: Node3D
var samples: Array[Dictionary] = []
var shots: Array[Dictionary] = []
var elapsed := 0.0
var active := false
var arena_override: Script
var with_station := false
var reverse_factions := false
var _demo_change := 0
var _demo_log := -1


# Stage 6B.2: samples the propulsion presentation after ThrusterView's tick (priority
# 1000) into the same tick's movement sample.
class ViewProbe:
	extends Node
	var harness: Node
	func _ready() -> void:
		process_physics_priority = 1001
	func _physics_process(_delta: float) -> void:
		harness._sample_view()


func _ready() -> void:
	process_physics_priority = 4 # Observe committed movement and the same tick's shots.
	if run_demo:
		await setup(self, Vector2(-240, -240), Vector2(-160, -240), demo_side)
		arena.selection().set_selection([subject])
		arena.orders.attack([subject], enemy)
		if demo_moving_target and not OS.get_cmdline_user_args().has("stationary"):
			move_enemy(Vector2(-160, -140), 0.6)
		var rig: Node = arena.get_node("CameraRig")
		rig.position = Vector3(-200, 0, -220)
		rig.zoom_distance = 115.0
		rig.zoom_target = 115.0
		rig._apply_zoom()
		rig.follow(subject)


func setup(parent: Node, start: Vector2, target_at: Vector2, side := 1, sustained := true) -> void:
	arena = ARENA.instantiate()
	arena.get_node("Asteroids").session_seed = 20261026
	if arena_override != null:
		arena.set_script(arena_override)
	if with_station:
		var station := preload("res://game/stations/station.tscn").instantiate()
		station.name = "Station"
		station.position = Vector3(-200, 1.5, -240)
		arena.get_node("Stations").add_child(station)
	# Remove irrelevant ships before registration, retaining production variants.
	for ship in arena.get_node("Ships").get_children():
		if ship.name not in [&"FF01", &"HostileFF01"]:
			ship.free()
	subject = arena.get_node("Ships/FF01")
	enemy = arena.get_node("Ships/HostileFF01")
	if reverse_factions:
		subject.get_node("Combat").faction = 1
		enemy.get_node("Combat").faction = 0
	parent.add_child(arena)
	var probe := ViewProbe.new()
	probe.harness = self
	add_child(probe)
	for ship in [subject, enemy]:
		ship.process_mode = Node.PROCESS_MODE_DISABLED # Start both ships on the same synchronized tick.
		var combat: Node = ship.get_node("Combat")
		combat.stance = CombatShip.Stance.HOLD_FIRE
		# Per-mount seeds, independent of frame timing or other weapon draws.
		for i in combat.weapons.size():
			var weapon: Node = combat.weapons[i]
			weapon.rng.seed = 100 + i
			weapon.shot.connect(func(w: Node, id: int, target: Node3D, _origin: Transform3D) -> void:
				shots.append({"time": elapsed, "family": String(w.config.family), "mount": String(w.get_parent().name),
					"target": String(target.name) if is_instance_valid(target) else "", "id": id}))
	if sustained:
		var target_combat := enemy.get_node("Combat")
		target_combat.max_health = 100000.0
		target_combat.health = 100000.0
		for weapon in subject.get_node("Combat").weapons:
			if weapon.config.family == &"cannon":
				weapon.ammo = 1000
	var heading: float = subject.get_node("Locomotion").bearing_heading((target_at - start).orthogonal() * side)
	subject.get_node("Locomotion").place(start, heading)
	enemy.get_node("Locomotion").place(target_at, 0.0)
	for ship in [subject, enemy]:
		ship.get_node("Avoidance").reset()
	for i in 120:
		if [subject, enemy].all(func(s: Node) -> bool: return arena.get_node("StaticNavigation").is_ready(s.get_node("RouteFollower").planning_radius())):
			break
		await get_tree().physics_frame
	for ship in [subject, enemy]:
		ship.process_mode = Node.PROCESS_MODE_INHERIT
	arena.sensors.evaluate()
	active = true


func move_enemy(point: Vector2, speed := 0.6) -> bool:
	enemy.get_node("Locomotion").max_speed = speed # Runtime fixture condition only.
	return arena.orders.move([enemy], point)


func _physics_process(delta: float) -> void:
	if not active or not is_instance_valid(subject) or not is_instance_valid(enemy):
		return
	elapsed += delta
	if run_demo:
		if (demo_course_changes or OS.get_cmdline_user_args().has("course_changes")) and elapsed >= 45.0 + _demo_change * 30.0 and _demo_change < 2:
			move_enemy(Vector2(-120, -180) if _demo_change == 0 else Vector2(-160, -260), 0.8)
			_demo_change += 1
		if int(elapsed / 10.0) > _demo_log:
			_demo_log = int(elapsed / 10.0)
			print("DEMO %.1f " % elapsed + JSON.stringify(subject.get_node("Behavior").combat_snapshot()))
	var lo := subject.get_node("Locomotion")
	var other := enemy.get_node("Locomotion")
	var combat := subject.get_node("Combat")
	var radial: Vector2 = lo.planar_position - other.planar_position
	var distance := radial.length()
	var normal := radial.normalized()
	var relative: Vector2 = lo.velocity - other.velocity
	var capable := 0
	var ready := 0
	for weapon in combat.weapons:
		if weapon.config.family != &"cannon":
			continue
		var assessment: Dictionary = weapon.assess(enemy)
		capable += int(assessment.capable)
		var fired_now := shots.any(func(s: Dictionary) -> bool: return s.mount == String(weapon.get_parent().name) and s.time >= elapsed - delta - 0.00001)
		ready += int(assessment.reason == "Ready" or fired_now)
	var navigation: Node = arena.get_node("StaticNavigation")
	var follower: Node = subject.get_node("RouteFollower")
	var forward := Vector2(-sin(lo.heading), -cos(lo.heading))
	var right := Vector2(cos(lo.heading), -sin(lo.heading))
	var slip := absf(rad_to_deg(lo.velocity.angle_to(forward))) if lo.velocity.length() > 0.01 else 0.0
	var acceleration := Vector2.ZERO
	var before_heading: float = lo.heading
	if not samples.is_empty():
		acceleration = (lo.velocity - samples[-1].velocity) / delta
		before_heading = samples[-1].heading
	var before_forward := Vector2(-sin(before_heading), -cos(before_heading))
	var before_right := Vector2(cos(before_heading), -sin(before_heading))
	samples.append({"time": elapsed, "distance": distance, "speed": lo.velocity.length(),
		"slip": slip, "forward_velocity": lo.velocity.dot(forward), "lateral_velocity": lo.velocity.dot(right),
		"forward_push": maxf(0.0, acceleration.dot(before_forward)), "reverse_push": maxf(0.0, -acceleration.dot(before_forward)),
		"lateral_push": absf(acceleration.dot(before_right)),
		"position": lo.planar_position, "velocity": lo.velocity, "heading": lo.heading, "angular": lo.angular_velocity,
		"radial": relative.dot(normal), "tangent": relative.dot(normal.orthogonal()),
		"capable": capable, "ready": ready, "contact": combat.target_status(enemy) == CombatShip.TargetState.VALID,
		"clear": subject.get_node("Behavior").line_clear(lo.planar_position, other.planar_position),
		"destination": lo.destination, "plans": follower.plans, "replans": follower.replans, "route_points": follower.route.size(),
		"clearance": navigation.surface_distance(lo.planar_position) - follower.ship_radius,
		"edge": navigation.map_half_size - follower.ship_radius - maxf(absf(lo.planar_position.x), absf(lo.planar_position.y)),
		"ship_gap": distance - follower.ship_radius - enemy.get_node("RouteFollower").ship_radius,
		"collisions": lo.collision_count, "avoidance_cap": lo.avoidance_cap,
		# Stage 6B.2 movement-continuity trace (this tick's controller inputs and decisions).
		"target_heading": lo._target_heading, "desired": lo.desired_velocity, "limit": lo.speed_limit,
		"reason": String(lo.speed_limit_reason), "frozen": lo._heading_frozen, "has_destination": lo.has_destination, "heading_mode": lo.heading_mode,
		"rendered_heading": subject.global_rotation.y,
		"status": follower.status, "segment": follower.segment, "aim": follower.aim_point, "progress": follower.progress,
		"lookahead": follower.lookahead, "route_cap": follower.speed_cap, "remaining": follower.remaining,
		"combat_control": lo.combat_control, "combat_cap": lo.combat_speed_cap, "combat_heading": lo.combat_heading,
		"objectives": subject.get_node("Behavior").combat_objectives.size(), "avoid_offset": lo._avoid_offset,
		"view_state": -1, "main": 0.0, "retro": 0.0, "plume": 0.0})


func _sample_view() -> void:
	if samples.is_empty() or not is_instance_valid(subject):
		return
	var view: Node = arena.get_node_or_null("ThrusterView")
	if view == null:
		return
	var record: Dictionary = view._ships.get(subject.get_instance_id(), {})
	if record.is_empty():
		return
	samples[-1].view_state = record.state
	samples[-1].main = record.intensity.Main
	samples[-1].retro = record.intensity.get("Retro_L", 0.0)
	samples[-1].plume = record.engines[0].thrust


func statistics(from: float, duration := 60.0) -> Dictionary:
	var window := samples.filter(func(s: Dictionary) -> bool: return s.time + 0.000001 >= from and s.time < from + duration - 0.000001)
	var detected := window.filter(func(s: Dictionary) -> bool: return s.contact)
	var clear := detected.filter(func(s: Dictionary) -> bool: return s.clear)
	var result := {"seconds": window.size() / 60.0, "detected_seconds": detected.size() / 60.0, "unobstructed_seconds": clear.size() / 60.0,
		"band": 0.0, "one": 0.0, "both": 0.0, "moving": 0.0, "ready_one": 0.0, "ready_both": 0.0, "shots": 0,
		"heading_travel_deg": 0.0, "turn_reversals": 0, "stops": 0, "requests": 0, "min_clearance": INF, "min_edge": INF}
	result.band = _fraction(detected, func(s: Dictionary) -> bool: return s.distance >= 27.0 and s.distance <= 45.0)
	result.one = _fraction(clear, func(s: Dictionary) -> bool: return s.capable >= 1)
	result.both = _fraction(clear, func(s: Dictionary) -> bool: return s.capable >= 2)
	result.moving = _fraction(clear, func(s: Dictionary) -> bool: return s.speed >= 0.5)
	result.ready_one = _fraction(clear, func(s: Dictionary) -> bool: return s.ready >= 1)
	result.ready_both = _fraction(clear, func(s: Dictionary) -> bool: return s.ready >= 2)
	result.shots = shots.filter(func(s: Dictionary) -> bool: return s.family == "cannon" and s.time >= from and s.time < from + duration).size()
	var turn_sign := 0
	for i in window.size():
		var s: Dictionary = window[i]
		result.min_clearance = minf(result.min_clearance, s.clearance)
		result.min_edge = minf(result.min_edge, s.edge)
		if i == 0:
			continue
		result.heading_travel_deg += absf(rad_to_deg(wrapf(s.heading - window[i - 1].heading, -PI, PI)))
		if absf(s.angular) > deg_to_rad(1.0):
			var next_sign := int(signf(s.angular))
			if turn_sign != 0 and turn_sign != next_sign:
				result.turn_reversals += 1
			turn_sign = next_sign
		result.stops += int(s.speed < 0.1 and window[i - 1].speed >= 0.1)
		result.requests += maxi(0, s.plans - window[i - 1].plans)
	return result


func flight_statistics(from: float, duration: float) -> Dictionary:
	var window := samples.filter(func(s: Dictionary) -> bool: return s.time + 0.000001 >= from and s.time < from + duration - 0.000001)
	var moving := window.filter(func(s: Dictionary) -> bool: return s.speed > 0.5)
	var result := {"seconds": window.size() / 60.0, "moving_seconds": moving.size() / 60.0,
		"within_30": _fraction(moving, func(s: Dictionary) -> bool: return s.slip <= 30.0),
		"forward_hemisphere": _fraction(moving, func(s: Dictionary) -> bool: return s.forward_velocity > 0.0),
		"mean_slip": 0.0, "max_sideways_seconds": 0.0, "mean_speed": 0.0,
		"forward_delta_v": 0.0, "reverse_delta_v": 0.0, "lateral_delta_v": 0.0, "mean_closing": 0.0, "distance_progress": 0.0}
	var sideways := 0.0
	for s: Dictionary in window:
		result.forward_delta_v += s.forward_push / 60.0
		result.reverse_delta_v += s.reverse_push / 60.0
		result.lateral_delta_v += s.lateral_push / 60.0
		result.mean_speed += s.speed / maxf(window.size(), 1)
		result.mean_closing -= s.radial / maxf(window.size(), 1)
		if s.speed > 0.5:
			result.mean_slip += s.slip / maxf(moving.size(), 1)
		if s.speed > 0.5 and s.slip > 45.0:
			sideways += 1.0 / 60.0
			result.max_sideways_seconds = maxf(result.max_sideways_seconds, sideways)
		else:
			sideways = 0.0
	if not window.is_empty():
		result.distance_progress = window[0].distance - window[-1].distance
	return result


static func _fraction(rows: Array, predicate: Callable) -> float:
	return float(rows.filter(predicate).size()) / rows.size() if not rows.is_empty() else 0.0
