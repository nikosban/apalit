extends SceneTree
## Combat prototype v0.3 checks: hardpoints and loadouts, ammunition and reloads, strict
## manual focus, cannons (range, tracking degradation), Gatlings (streams, magazines,
## idle reload), torpedoes, missiles, point defense, visual transforms, the encounters
## E01–E04 and regressions (movement, resets, fixed weapons). Uninterrupted game loop,
## one fresh scene per case; run with a fixed physics step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/weapons_test.gd
## Optional: `-- <case prefix>` runs matching cases only. Every check is PASS/FAIL.
##
## Independent checks run in every case:
##   - every shot or launch, when it happens: owner alive; offensive shots at a live,
##     hostile, observable target the stance authorizes, the manual target whenever one
##     is set (strict focus); point-defense shots (Gatlings) at live hostile ordnance;
##     within the maximum range; from the muzzle transform along the barrel; inside the
##     hardpoint's traverse / elevation (articulated) or launch cone (torpedo); aligned
##     within tolerance (articulated); not before the cooldown; never inside a running
##     magazine reload; each launch's ordnance starts exactly on the launcher marker;
##   - ammunition ledger per weapon: starting stock − shots = rounds left, magazine
##     never above its size, no reload restarted while one runs;
##   - every tick for every ordnance: torpedo nose turn ≤ turn rate × dt, none before the
##     arming distance, velocity along the nose (≤ 0.5°); missile ejection without turning
##     or thrust, outside its own hull boxes, at the ejection velocity; orientation
##     drifting (velocity unchanged) with nose turns ≤ the orientation rate; powered only
##     once within 15° of the wanted direction; powered velocity change per tick ≤
##     acceleration × dt and speed ≤ maximum; main plume shown only under thrust and
##     behind the nozzle (−forward); trail = exhaust: the nozzle positions of the ticks
##     with the main engine lit, newest at the nozzle (none for a missile before powered flight); attitude thrusters lit only after a measured turn
##     about their axis (recomputed here from consecutive transforms).

const ENCOUNTERS := [
	preload("res://game/tests/combat/fixtures/e01_cannon.tscn"),
	preload("res://game/tests/combat/fixtures/e02_torpedo.tscn"),
	preload("res://game/tests/combat/fixtures/e03_escort.tscn"),
	preload("res://game/tests/combat/fixtures/e04_missile.tscn"),
]
const RANGE := preload("res://game/tests/combat/fixtures/weapon_range.tscn")
const LAB := preload("res://game/tests/combat/fixtures/combat_lab.tscn")
const ESCORT := preload("res://game/ships/gunship_unit.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const CombatHud := preload("res://game/ui/combat_hud.gd")
const MAIN_FX := preload("res://game/presentation/thrusters/main_thruster_fx.tscn")
const JET_FX := preload("res://game/presentation/thrusters/directional_thruster_fx.tscn")
const Gatling := preload("res://game/weapons/gatling.gd")
const Ordnance := preload("res://game/combat/ordnance.gd")
const CANNON := preload("res://game/weapons/cannon.tres")
const GATLING := preload("res://game/weapons/gatling.tres")
const TORPEDO := preload("res://game/weapons/torpedo.tres")
const MISSILE := preload("res://game/weapons/missile.tres")
const DT := 1.0 / 60.0
const HOLD := 0
const DEFENSIVE := 1
const AGGRESSIVE := 2
const EAST := -PI * 0.5
const WEST := PI * 0.5
const NORTH := 0.0
const SOUTH := PI
const EPS := 0.0001

var scene: Node3D
var _checks := 0
var _failures := 0
var _only := ""
# Shot audit.
var _bad: Array[String] = []
var _shots: Array[Dictionary] = [] # current scene: {frame, time, ship, weapon, family, target, defense, id}
var _total_shots := 0
var _last_shot := {} # weapon id -> frame
var _stock := {} # weapon id -> starting rounds
var _fired := {} # weapon id -> shots
var _weapons := {} # weapon id -> weapon (current scene)
var _reload_open := {} # weapon id -> frame started
var _reloads: Array[Dictionary] = [] # {weapon, cause, start, end}
var _reload_restarts := 0
var _ledger_errors: Array[String] = []
var _launch_xf := {} # ordnance id -> transform at launch
# Ordnance audit.
var _ord := {} # id -> per-ordnance state
var _ord_bad: Array[String] = []
var _ord_ticks := 0
var _stats := {"torpedo_turn": 0.0, "missile_orient_turn": 0.0, "missile_turn": 0.0, "dv": 0.0, "nose_velocity": 0.0,
	"rcs_lit_ticks": 0, "eject_ticks": 0, "orient_ticks": 0, "powered_ticks": 0, "torpedo_ticks": 0}


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	_only = args[0] if args.size() > 0 else ""
	var cases := [
		["H1 hardpoints and loadouts", _case_loadouts],
		["H2 hardpoint compatibility", _case_compatibility],
		["H3 weapon geometry and clearance", _case_geometry],
		["A1 empty stocks never fire", _case_empty_stock],
		["F1 strict manual focus", _case_strict_focus],
		["K1 cannon effective and maximum range", _case_cannon_range],
		["K2 cannon tracking degradation", _case_cannon_accuracy],
		["K3 E01 positioning", _case_e01],
		["G1 Gatling stream and magazines", _case_gatling_stream],
		["G2 Gatling idle reload", _case_gatling_idle_reload],
		["G3 Gatling reload stability", _case_gatling_stability],
		["T1 torpedo launch cone", _case_torpedo_cone],
		["T2 torpedo targets and evasion", _case_torpedo_guidance],
		["T3 torpedo overshoot and terminal miss", _case_torpedo_overshoot],
		["T4 torpedo obstacle, contact and interception", _case_torpedo_misc],
		["T5 E02 evasion", _case_e02],
		["M1 E04 missile guidance", _case_e04],
		["M2 missile avoidance control", _case_missile_avoidance],
		["M3 missile sharp turn and overshoot", _case_missile_turn],
		["M4 missile interception during ejection", _case_missile_eject_intercept],
		["M5 visuals do not drive the missile", _case_missile_visuals],
		["P1 point-defense priority", _case_pd_priority],
		["P2 point defense ignores passed ordnance", _case_pd_passed],
		["P3 point-defense arcs and hull", _case_pd_arcs],
		["P4 interruption and resumption", _case_pd_interruption],
		["P5 E03 escort positioning", _case_e03],
		["R1 movement unchanged by combat", _case_movement],
		["R3 HUD ammunition", _case_hud],
		["R4 repeated resets", _case_resets],
	]
	for entry in cases:
		if _only != "" and not String(entry[0]).begins_with(_only):
			continue
		print("\n=== %s" % entry[0])
		await entry[1].call()
		_audit()
	_free()
	print("\nShots and launches checked: %d, unauthorized or incorrect: %d" % [_total_shots, _bad.size()])
	for line in _bad.slice(0, 20):
		print("  BAD SHOT: " + line)
	_check("zero unauthorized or incorrect shots and launches across all cases", _bad.is_empty() and _total_shots > 0)
	_check("ammunition ledger exact for every weapon in every case (%d errors)" % _ledger_errors.size(), _ledger_errors.is_empty())
	for line in _ledger_errors.slice(0, 10):
		print("  LEDGER: " + line)
	_check("no magazine reload restarted while one was running (%d)" % _reload_restarts, _reload_restarts == 0)
	print("Ordnance ticks checked: %d (torpedo %d, ejection %d, orientation %d, powered %d); largest torpedo turn %.4f deg/tick, missile orientation %.4f, pursuit %.4f; largest velocity change %.4f u/s per tick; largest missile nose-velocity angle %.1f deg; RCS lit ticks %d" % [
		_ord_ticks, _stats.torpedo_ticks, _stats.eject_ticks, _stats.orient_ticks, _stats.powered_ticks, rad_to_deg(_stats.torpedo_turn),
		rad_to_deg(_stats.missile_orient_turn), rad_to_deg(_stats.missile_turn), _stats.dv, rad_to_deg(_stats.nose_velocity), _stats.rcs_lit_ticks])
	for line in _ord_bad.slice(0, 20):
		print("  BAD ORDNANCE TICK: " + line)
	_check("every ordnance tick within its flight model and presentation rules (%d violations)" % _ord_bad.size(), _ord_bad.is_empty() and _ord_ticks > 0)
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


# --- Harness --------------------------------------------------------------------------

func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _free() -> void:
	if scene != null and is_instance_valid(scene):
		root.remove_child(scene)
		scene.free()
	scene = null


## Loads an encounter; `prepare` applies test conditions after its set-up and before the
## first physics tick (ships engage from their first tick); `authored` changes the scene
## before it enters the tree (asteroids are read once, in their field's _ready).
func _encounter(index: int, prepare: Callable = Callable(), authored: Callable = Callable()) -> Node3D:
	_free()
	scene = ENCOUNTERS[index].instantiate()
	scene.scenario_index = index
	if authored.is_valid():
		authored.call()
	root.add_child(scene)
	if prepare.is_valid():
		prepare.call()
	_hook(scene)
	await _step()
	while not scene.enemy_controller.started:
		await _step()
	return scene


## Test condition: the encounter's scripted events and patrols are removed.
func _quiet() -> void:
	var controller = scene.enemy_controller
	controller._steps.clear()
	controller._triggers.clear()
	controller._patrols.clear()


func _range(prepare: Callable = Callable()) -> Node3D:
	_free()
	scene = RANGE.instantiate()
	root.add_child(scene)
	CombatShip.of(scene.get_node("Ships/Dummy")).health = 1000000.0
	if prepare.is_valid():
		prepare.call()
	_hook(scene)
	await _step()
	return scene


func _hook(a: Node3D) -> void:
	_shots.clear()
	_weapons.clear()
	_reload_open.clear()
	_reloads.clear()
	_launch_xf.clear()
	_ord.clear()
	for ship: Node3D in a.get_node("Ships").get_children():
		var combat = CombatShip.of(ship)
		for weapon in combat.weapons:
			var key: int = weapon.get_instance_id()
			_weapons[key] = weapon
			_stock[key] = weapon.rounds_left()
			_fired[key] = 0
			weapon.shot.connect(_on_shot.bind(a))
			weapon.reload_started.connect(_on_reload_started)
			weapon.reload_finished.connect(_on_reload_finished)
	var projectiles = a.get_node("Projectiles")
	projectiles.ordnance_launched.connect(func(node: Node3D) -> void: _launch_xf[node.id] = node.global_transform)
	projectiles.ordnance_finished.connect(func(record: Dictionary) -> void:
		if _ord.has(record.id):
			_ord[record.id]["record"] = record)


## A test changed a weapon's stock directly: restart its ledger from here.
func _rebase(weapon: Node) -> void:
	var key: int = weapon.get_instance_id()
	_stock[key] = weapon.rounds_left()
	_fired[key] = 0


func _audit() -> void:
	for key: int in _weapons:
		var weapon = _weapons[key]
		if not is_instance_valid(weapon):
			continue
		if _stock[key] - _fired[key] != weapon.rounds_left():
			_ledger_errors.append("%s %s: start %d - shots %d != left %d" % [weapon.ship.name, weapon.name, _stock[key], _fired[key], weapon.rounds_left()])
		if weapon.config.magazine_size > 0 and (weapon.magazine > weapon.config.magazine_size or weapon.magazine < 0 or weapon.ammo < 0):
			_ledger_errors.append("%s %s: magazine %d reserve %d" % [weapon.ship.name, weapon.name, weapon.magazine, weapon.ammo])


func _frame() -> int:
	return Engine.get_physics_frames()


func _now() -> float:
	if scene != null and is_instance_valid(scene) and scene.get("enemy_controller") != null:
		return scene.enemy_controller.time
	return CombatShip.now()


func _step() -> void:
	await physics_frame
	_sample()


func _run(seconds: float) -> void:
	for i in roundi(seconds / DT):
		await _step()


func _ship(ship_name: String) -> Node3D:
	return scene.get_node("Ships").get_node_or_null(ship_name)


func _c(ship_name: String) -> Variant:
	return CombatShip.of(_ship(ship_name))


func _w(ship_name: String, path: String) -> Variant:
	return _ship(ship_name).get_node("Weapons/" + path)


func _place(ship_name: String, x: float, z: float, heading: float) -> void:
	_ship(ship_name).get_node("Locomotion").place(Vector2(x, z), heading)
	_ship(ship_name).get_node("Avoidance").reset()


## Scenario condition set by a test: every weapon of `family` on the ship with `rounds`.
func _set_stock(ship_name: String, family: StringName, rounds: int) -> void:
	for weapon in _c(ship_name).weapons:
		if weapon.config.family == family:
			if weapon.config.magazine_size > 0:
				weapon.magazine = mini(rounds, weapon.config.magazine_size)
				weapon.ammo = rounds - weapon.magazine
			else:
				weapon.ammo = rounds
			weapon.reload_left = 0.0
			_rebase(weapon)


func _by(ship_name: String, family: String = "", defense: int = -1) -> Array:
	return _shots.filter(func(s: Dictionary) -> bool:
		return s.ship == ship_name and (family == "" or s.family == family) and (defense < 0 or s.defense == (defense == 1)))


func _on_reload_started(weapon: Node, cause: String) -> void:
	var key: int = weapon.get_instance_id()
	if _reload_open.has(key):
		_reload_restarts += 1
	_reload_open[key] = _frame()
	_reloads.append({"weapon": weapon, "cause": cause, "start": _frame(), "end": -1, "magazine": weapon.magazine, "reserve": weapon.ammo})


func _on_reload_finished(weapon: Node, moved: int) -> void:
	var key: int = weapon.get_instance_id()
	_reload_open.erase(key)
	for i in range(_reloads.size() - 1, -1, -1):
		if _reloads[i].weapon == weapon and _reloads[i].end < 0:
			_reloads[i].end = _frame()
			_reloads[i].moved = moved
			break


# Independent check of one shot or launch, when it happens.
func _on_shot(weapon: Node, id: int, target: Node3D, origin: Transform3D, a: Node3D) -> void:
	var combat = weapon.combat
	var key: int = weapon.get_instance_id()
	var family := String(weapon.config.family)
	var problems: Array[String] = []
	var defense := target != null and is_instance_valid(target) and CombatShip.of(target) == null
	if not combat.alive or not weapon.enabled:
		problems.append("owner not operational")
	var muzzle: Transform3D = origin # The marker the shot used (launchers advance to the next cell after firing).
	if family != "missile":
		muzzle = weapon.muzzle.global_transform
	if origin.origin.distance_to(muzzle.origin) > EPS or (-origin.basis.z).normalized().angle_to(-muzzle.basis.z) > 0.0001:
		problems.append("not from the muzzle transform")
	if defense:
		if family != "gatling":
			problems.append("point defense by a non-Gatling")
		if not target.live or target.faction == combat.faction:
			problems.append("point defense at friendly or dead ordnance")
		if muzzle.origin.distance_to(target.global_position) > weapon.config.weapon_range + EPS:
			problems.append("point defense beyond range")
	else:
		var target_combat = CombatShip.of(target)
		if target_combat == null or not target_combat.alive or target_combat.removed_from_play:
			problems.append("target not live")
		elif target_combat.faction == combat.faction:
			problems.append("target not hostile")
		elif not a.get_node("Contacts").observable(combat.faction, target):
			problems.append("target not observable")
		match combat.stance:
			HOLD:
				problems.append("Hold Fire")
			DEFENSIVE:
				if not combat.is_threat(target):
					problems.append("Defensive without a confirmed threat")
		if combat.manual_target != null and combat.manual_target != target:
			problems.append("not the manual target (strict focus)")
		if target != null and is_instance_valid(target) and muzzle.origin.distance_to(target.global_position) > weapon.config.weapon_range + EPS:
			problems.append("beyond maximum range")
	if weapon.get("yaw_pivot") != null:
		if absf(rad_to_deg(weapon.yaw)) > weapon.yaw_limit_deg() + EPS or rad_to_deg(weapon.pitch) < weapon.pitch_min_deg() - EPS \
				or rad_to_deg(weapon.pitch) > weapon.pitch_max_deg() + EPS:
			problems.append("beyond the hardpoint's limits")
		if rad_to_deg((-muzzle.basis.z).angle_to(weapon.aim_point - muzzle.origin)) > weapon.config.alignment_tolerance_deg + EPS:
			problems.append("not aligned")
	if family == "torpedo":
		# The launch cone is judged against the intercept point at torpedo speed, recomputed here.
		var bow: Vector3 = -weapon.ship.global_basis.z
		var p: Vector3 = target.global_position - muzzle.origin
		var v: Vector3 = CombatShip.of(target).velocity()
		var speed: float = weapon.config.ordnance.speed
		var qa := v.dot(v) - speed * speed
		var qb := 2.0 * p.dot(v)
		var qc := p.dot(p)
		var root := sqrt(maxf(0.0, qb * qb - 4.0 * qa * qc))
		var time := maxf((-qb - root) / (2.0 * qa), (-qb + root) / (2.0 * qa))
		var to_aim: Vector3 = p + v * time
		if (-muzzle.basis.z).angle_to(bow) > 0.001:
			problems.append("tube not hull-aligned")
		if absf(rad_to_deg(Vector2(bow.x, bow.z).angle_to(Vector2(to_aim.x, to_aim.z)))) > weapon.cone_deg() + 0.01:
			problems.append("intercept point outside the launch cone")
	if family == "missile" and (-origin.basis.z).dot(Vector3.UP) < 0.999:
		problems.append("missile not launched upward")
	if family in ["torpedo", "missile"]:
		if not _launch_xf.has(id):
			problems.append("no ordnance launched")
		else:
			var xf: Transform3D = _launch_xf[id]
			if xf.origin.distance_to(origin.origin) > EPS or not xf.basis.is_equal_approx(origin.basis):
				problems.append("ordnance not on the launcher marker")
	if _last_shot.has(key) and (_frame() - _last_shot[key]) * DT < weapon.config.cooldown - DT * 0.5:
		problems.append("cooldown not elapsed")
	if _reload_open.has(key) and _reload_open[key] < _frame():
		problems.append("fired during a magazine reload")
	_last_shot[key] = _frame()
	_fired[key] = _fired.get(key, 0) + 1
	_total_shots += 1
	_shots.append({"frame": _frame(), "time": _now(), "ship": String(weapon.ship.name), "weapon": weapon, "family": family, "fixed": weapon.fixed,
		"target": String(target.name) if target != null and is_instance_valid(target) else "", "defense": defense, "id": id})
	if not problems.is_empty():
		_bad.append("%.2f %s %s -> %s: %s" % [_now(), weapon.ship.name, weapon.name, target.name if target != null and is_instance_valid(target) else "?", ", ".join(problems)])


# Per-tick ordnance audit (flight model and presentation).
func _sample() -> void:
	if scene == null or not is_instance_valid(scene):
		return
	var projectiles = scene.get_node("Projectiles")
	for node in projectiles.ordnance:
		_ord_ticks += 1
		var id: int = node.id
		var c: Resource = node.config
		var forward: Vector3 = node.forward()
		if not _ord.has(id):
			_ord[id] = {"node": node, "kind": node.kind, "prev_basis": node.global_basis, "prev_velocity": node.velocity, "prev_phase": node.phase,
				"prev_traveled": node.traveled, "prev_position": node.global_position, "turns": [], "min_distance": INF, "approaches": 0,
				"closing": false, "max_nose_velocity": 0.0, "phases": [node.phase], "positions": [node.global_position], "contact": [],
				"goal": [], "wanted_at_powered": -1.0, "orient_drift": 0.0,
				"prev_nozzle": node.global_transform * Vector3(0, 0, c.length * 0.5), "prev_lit": node.kind == &"torpedo" or node.thrusting}
			continue
		var s: Dictionary = _ord[id]
		var turn: float = (-(s.prev_basis as Basis).z).angle_to(forward)
		var where := "%s%d %s t=%.2f" % [node.kind, id, node.phase, node.age]
		# Independent local turn from consecutive transforms: the previous nose seen in the new frame.
		var local: Vector3 = node.global_basis.inverse() * (-(s.prev_basis as Basis).z)
		var turn_local := Vector2(-local.x, -local.y)
		(s.turns as Array).append(turn_local)
		if (s.turns as Array).size() > 8:
			(s.turns as Array).remove_at(0)
		# Trail = exhaust: nozzle exits of the ticks with the main engine lit (recomputed here
		# from the transform and the model length).
		var nozzle: Vector3 = node.global_transform * Vector3(0, 0, c.length * 0.5)
		var lit: bool = node.kind == &"torpedo" or node.thrusting
		if not lit:
			if not node.trail.is_empty():
				_ord_bad.append("%s: trail before the main engine was lit" % where)
		elif node.trail.is_empty() or (node.trail[-1] as Vector3).distance_to(nozzle) > EPS:
			_ord_bad.append("%s: trail does not end at the nozzle" % where)
		elif node.trail.size() >= 2 and s.prev_lit and (node.trail[-2] as Vector3).distance_to(s.prev_nozzle) > EPS:
			_ord_bad.append("%s: trail point is not the previous nozzle position" % where)
		if node.kind == &"torpedo":
			_stats.torpedo_ticks += 1
			_stats.torpedo_turn = maxf(_stats.torpedo_turn, turn)
			if turn > deg_to_rad(c.turn_rate_deg) * DT + 0.000001:
				_ord_bad.append("%s: torpedo turn %.4f deg > limit" % [where, rad_to_deg(turn)])
			if turn > 0.000001 and s.prev_traveled < c.arming_distance - 0.000001:
				_ord_bad.append("%s: torpedo turned before its arming distance" % where)
			if forward.angle_to(node.velocity) > deg_to_rad(0.5):
				_ord_bad.append("%s: torpedo velocity off its nose" % where)
			if node._plume.thrust <= 0.0 or ((node._plume as Node3D).global_position - node.global_position).normalized().dot(-forward) < 0.9999:
				_ord_bad.append("%s: torpedo plume not lit behind the nozzle" % where)
		else:
			match node.phase:
				"eject":
					_stats.eject_ticks += 1
					if turn > 0.000001 or node.thrusting:
						_ord_bad.append("%s: turned or thrust during ejection" % where)
					if node.velocity.distance_to(node.launch_axis * c.eject_speed) > EPS:
						_ord_bad.append("%s: ejection velocity changed" % where)
					var owner_combat = node.owner_combat
					if owner_combat != null and is_instance_valid(node.owner_ship):
						var p: Vector3 = (node.owner_ship as Node3D).global_transform.affine_inverse() * node.global_position
						for box: AABB in owner_combat.hitboxes:
							if box.has_point(p):
								_ord_bad.append("%s: inside its own hull during ejection" % where)
				"orient", "powered":
					if s.prev_phase == "orient" and node.phase == "orient":
						_stats.orient_ticks += 1
					if node.phase == "orient" or s.prev_phase == "orient":
						_stats.missile_orient_turn = maxf(_stats.missile_orient_turn, turn)
						if turn > deg_to_rad(c.orient_rate_deg) * DT + 0.000001:
							_ord_bad.append("%s: orientation turn %.3f deg > limit" % [where, rad_to_deg(turn)])
						if node.velocity.distance_to(s.prev_velocity) > EPS:
							_ord_bad.append("%s: velocity changed during orientation" % where)
						if node.thrusting:
							_ord_bad.append("%s: main thrust during orientation" % where)
						if node.phase == "powered" and rad_to_deg(forward.angle_to(node.wanted_direction)) > c.powered_within_deg + EPS:
							_ord_bad.append("%s: powered flight began %.1f deg off the wanted direction" % [where, rad_to_deg(forward.angle_to(node.wanted_direction))])
					if s.prev_phase == "powered":
						_stats.powered_ticks += 1
						_stats.missile_turn = maxf(_stats.missile_turn, turn)
						var dv: float = node.velocity.distance_to(s.prev_velocity)
						_stats.dv = maxf(_stats.dv, dv / DT)
						if dv > c.acceleration * DT + EPS:
							_ord_bad.append("%s: velocity jumped %.3f u/s in one tick" % [where, dv])
						if turn > deg_to_rad(c.turn_rate_deg) * DT + 0.000001:
							_ord_bad.append("%s: pursuit turn %.3f deg > limit" % [where, rad_to_deg(turn)])
						if node.velocity.length() > c.max_speed + EPS:
							_ord_bad.append("%s: above maximum speed" % where)
						if not node.thrusting or node._plume.thrust <= 0.0 or ((node._plume as Node3D).global_position - node.global_position).normalized().dot(-forward) < 0.9999:
							_ord_bad.append("%s: main plume not lit behind the nozzle under thrust" % where)
						var nv: float = forward.angle_to(node.velocity)
						s.max_nose_velocity = maxf(s.max_nose_velocity, nv)
						_stats.nose_velocity = maxf(_stats.nose_velocity, nv)
			if node.phase != "powered" and node._plume.thrust > 0.0:
				_ord_bad.append("%s: main plume lit without thrust" % where)
			# Attitude thrusters: lit only within 0.1 s after a measured turn about their axis.
			var threshold := deg_to_rad(Ordnance.RCS_THRESHOLD_DEG) * DT
			for i in 4:
				if node._rcs[i].thrust <= 0.0:
					continue
				_stats.rcs_lit_ticks += 1
				var justified := false
				for t: Vector2 in (s.turns as Array).slice(-7):
					var value := t.x if i < 2 else t.y
					if (i % 2 == 1 and value > threshold) or (i % 2 == 0 and value < -threshold):
						justified = true
				if not justified:
					_ord_bad.append("%s: attitude thruster %d lit without a matching turn" % [where, i])
		if node.phase not in s.phases:
			(s.phases as Array).append(node.phase)
		s.avoided = (node.avoided as Array).duplicate()
		(s.contact as Array).append(node.has_contact)
		(s.goal as Array).append([node.has_goal, node.goal, node.last_known, _now()])
		(s.positions as Array).append(node.global_position)
		s.prev_basis = node.global_basis
		s.prev_velocity = node.velocity
		s.prev_phase = node.phase
		s.prev_traveled = node.traveled
		s.prev_position = node.global_position
		s.prev_nozzle = nozzle
		s.prev_lit = lit


func _outcomes(kind: String = "") -> Dictionary:
	var counts := {}
	for r in scene.get_node("Projectiles").ordnance_records:
		if kind == "" or r.kind == kind:
			counts[r.outcome] = counts.get(r.outcome, 0) + 1
	return counts


func _record(id: int) -> Dictionary:
	for r in scene.get_node("Projectiles").ordnance_records:
		if r.id == id:
			return r
	return {}


func _launch(owner_name: String, launcher_path: String, from: Vector3, direction: Vector3, target_name: String, config: Resource = null) -> Node3D:
	var projectiles = scene.get_node("Projectiles")
	var owner_ship := _ship(owner_name)
	var launcher = owner_ship.get_node("Weapons/" + launcher_path)
	var up := Vector3.UP if absf(direction.normalized().dot(Vector3.UP)) < 0.99 else Vector3.BACK
	var id: int = projectiles.launch(owner_ship, CombatShip.of(owner_ship).faction, Transform3D(Basis.looking_at(direction, up), from),
		config if config != null else launcher.config, _ship(target_name))
	for node in projectiles.ordnance:
		if node.id == id:
			return node
	return null


func _wait_records(count: int, limit: float) -> void:
	for i in roundi(limit / DT):
		await _step()
		if scene.get_node("Projectiles").ordnance_records.size() >= count:
			return


# --- Phase 1: hardpoints, ammunition, focus ----------------------------------------------

func _case_loadouts() -> void:
	await _encounter(2)
	var expected := {"Gunship": ["DorsalHardpoint/Cannon", "LeftHardpoint/Gatling", "RightHardpoint/Gatling"],
		"Destroyer": ["BowHardpoint/TorpedoTube", "DeckHardpoint/MissileCells", "TowerHardpoint/Cannon", "SternHardpoint/Gatling"]}
	for ship_name in ["Gunship", "Destroyer", "HostileGunship", "HostileDestroyer"]:
		var paths: Array = expected["Gunship" if ship_name.ends_with("Gunship") else "Destroyer"]
		var combat = _c(ship_name)
		var names: Array = combat.weapons.map(func(w: Node) -> String: return "%s/%s" % [w.get_parent().name, w.name])
		var limits := true
		for weapon in combat.weapons:
			limits = limits and weapon.hardpoint != null and weapon.hardpoint.accepts(weapon.config)
		_check("%s loadout %s, every weapon on a hardpoint that accepts it" % [ship_name, str(names)], names == paths and limits)
	var cannon = _w("Gunship", "DorsalHardpoint/Cannon")
	var gatling = _w("Gunship", "LeftHardpoint/Gatling")
	_check("articulated limits come from the hardpoint (cannon yaw %.0f / pitch %.0f..%.0f; side Gatling yaw %.0f / pitch %.0f..%.0f)" % [
		cannon.yaw_limit_deg(), cannon.pitch_min_deg(), cannon.pitch_max_deg(), gatling.yaw_limit_deg(), gatling.pitch_min_deg(), gatling.pitch_max_deg()],
		cannon.yaw_limit_deg() == 160.0 and cannon.pitch_max_deg() == 60.0 and gatling.yaw_limit_deg() == 100.0 and gatling.pitch_min_deg() == -10.0)
	var stocks := []
	for weapon in _c("Destroyer").weapons + _c("Gunship").weapons:
		stocks.append("%s %d" % [weapon.config.display_name, weapon.rounds_left()])
	_check("finite stocks at start (%s)" % ", ".join(stocks), _c("Destroyer").weapons[0].rounds_left() == 4 and _c("Destroyer").weapons[1].rounds_left() == 6
		and cannon.rounds_left() == 40 and gatling.rounds_left() == 400 and gatling.magazine == 40)
	_check("damage per hit: torpedo %.0f > missile %.0f > cannon %.0f > Gatling round %.0f" % [TORPEDO.damage, MISSILE.damage, CANNON.damage, GATLING.damage],
		TORPEDO.damage > MISSILE.damage and MISSILE.damage > CANNON.damage and CANNON.damage > GATLING.damage)
	_check("effective (%.0f u) and maximum (%.0f u) cannon ranges are separate values" % [CANNON.effective(), CANNON.weapon_range], CANNON.effective() < CANNON.weapon_range)


func _case_compatibility() -> void:
	var dorsal = ESCORT.instantiate().get_node("Weapons/DorsalHardpoint")
	var side = ESCORT.instantiate().get_node("Weapons/LeftHardpoint")
	var matrix := {"cannon on medium cannon hardpoint": dorsal.accepts(CANNON), "Gatling on medium cannon hardpoint": dorsal.accepts(GATLING),
		"cannon on small Gatling hardpoint": side.accepts(CANNON), "Gatling on small Gatling hardpoint": side.accepts(GATLING),
		"torpedo on small Gatling hardpoint": side.accepts(TORPEDO), "missile on medium cannon hardpoint": dorsal.accepts(MISSILE)}
	dorsal.get_parent().get_parent().free()
	side.get_parent().get_parent().free()
	print("  %s" % str(matrix))
	_check("hardpoints accept only listed families no larger than their size", matrix.values() == [true, false, false, true, false, false])
	# The weapon range's platform mirrors the escort Gunship's hardpoints and weapons.
	var escort: Node3D = ESCORT.instantiate()
	var range_scene: Node3D = RANGE.instantiate()
	var same := true
	for path in ["DorsalHardpoint", "LeftHardpoint", "RightHardpoint"]:
		var x: Node3D = escort.get_node("Weapons/" + path)
		var y: Node3D = range_scene.get_node("Ships/Platform/Weapons/" + path)
		same = same and x.transform.is_equal_approx(y.transform) and x.families == y.families and x.size == y.size and x.yaw_limit_deg == y.yaw_limit_deg \
			and x.pitch_min_deg == y.pitch_min_deg and x.pitch_max_deg == y.pitch_max_deg and x.get_child(0).config == y.get_child(0).config
	escort.free()
	range_scene.free()
	_check("the weapon range's test platform carries exactly the escort Gunship's hardpoints and weapons", same)
	# An incompatible installation: the range platform's left Gatling given the cannon configuration.
	_free()
	scene = RANGE.instantiate()
	var wrong = scene.get_node("Ships/Platform/Weapons/LeftHardpoint/Gatling")
	wrong.config = CANNON
	root.add_child(scene)
	_hook(scene)
	CombatShip.of(scene.get_node("Ships/Dummy")).health = 1000000.0
	scene.get_node("Ships/Dummy").place(Vector3(-15, 1.5, 1.6))
	await _run(3.0)
	var platform = CombatShip.of(scene.get_node("Ships/Platform"))
	_check("incompatible weapon disabled and not stepped (%s; registered %d weapons; shots %d)" % [wrong.reason, platform.weapons.size(), wrong.shots],
		not platform.weapons.has(wrong) and platform.incompatible.has(wrong) and not wrong.enabled and wrong.shots == 0 and wrong.reason == "Incompatible hardpoint")


func _case_geometry() -> void:
	await _encounter(2)
	for ship_name in ["Gunship", "Destroyer"]:
		var ship := _ship(ship_name)
		var combat = CombatShip.of(ship)
		var to_ship := ship.global_transform.affine_inverse()
		var hull := AABB()
		for i in combat.hitboxes.size():
			hull = combat.hitboxes[i] if i == 0 else hull.merge(combat.hitboxes[i])
		for weapon in combat.weapons:
			var label := "%s %s" % [ship_name, weapon.get_parent().name]
			var parts := _part_boxes(weapon, to_ship)
			var base_name := "MountMesh" if parts.has("MountMesh") else ("MountBase" if parts.has("MountBase") else "Housing")
			var attached := false
			for box: AABB in combat.hitboxes:
				attached = attached or box.grow(0.002).intersects(parts[base_name])
			_check("%s mount attached to the hull (%s)" % [label, base_name], attached)
			if weapon.get("yaw_pivot") != null:
				var clipping := 0
				var axis_error := 0.0
				var limit: float = weapon.yaw_limit_deg()
				for yaw_step in range(-20, 21):
					var yaw_deg := limit * yaw_step / 20.0
					for pitch_deg in [weapon.pitch_min_deg(), 0.0, 30.0, weapon.pitch_max_deg()]:
						weapon.yaw_pivot.rotation = Vector3(0, deg_to_rad(yaw_deg), 0)
						weapon.pitch_pivot.rotation = Vector3(deg_to_rad(pitch_deg), 0, 0)
						if combat.segment_fraction(weapon.pitch_pivot.global_position, weapon.muzzle.global_position) >= 0.0:
							clipping += 1
						# Each barrel's axis, and the same line one barrel radius lower (the hull is below).
						for barrel: MeshInstance3D in weapon.pitch_pivot.find_children("Barrel*", "MeshInstance3D", true, false):
							var cylinder := barrel.mesh as CylinderMesh
							var axis: Vector3 = barrel.global_basis.y.normalized()
							for offset: Vector3 in [Vector3.ZERO, Vector3.DOWN * cylinder.top_radius]:
								var start: Vector3 = barrel.global_position - axis * cylinder.height * 0.5 + offset
								var end: Vector3 = barrel.global_position + axis * cylinder.height * 0.5 + offset
								if combat.segment_fraction(start, end) >= 0.0:
									clipping += 1
						var dir: Vector3 = -weapon.pitch_pivot.global_basis.z
						var along: Vector3 = weapon.muzzle.global_position - weapon.pitch_pivot.global_position
						axis_error = maxf(axis_error, (along - dir * along.dot(dir)).length())
				weapon.yaw_pivot.rotation = Vector3.ZERO
				weapon.pitch_pivot.rotation = Vector3.ZERO
				_check("%s barrel clear of the hull over yaw ±%.0f and pitch %.0f..%.0f (%d clipping poses); muzzle on the barrel axis (%.6f u)" % [
					label, limit, weapon.pitch_min_deg(), weapon.pitch_max_deg(), clipping, axis_error], clipping == 0 and axis_error < 0.0001)
			elif weapon.config.family == &"torpedo":
				var muzzle_local: Vector3 = to_ship * weapon.muzzle.global_position
				var clear := true
				for key in ["Tube", "Opening"]:
					for box: AABB in combat.hitboxes:
						clear = clear and not box.intersects((parts[key] as AABB).grow(-0.001))
				var length_share: float = TORPEDO.ordnance.length / hull.size.z
				_check("%s torpedo tube along the bow axis, clear of the hull, muzzle ahead of the bow (z %.2f < %.2f)" % [label, muzzle_local.z, hull.position.z],
					clear and muzzle_local.z < hull.position.z and (-weapon.muzzle.global_basis.z).angle_to(-ship.global_basis.z) < 0.0001)
			else:
				var clear_path := true
				var clear_end := true
				for marker in weapon.muzzles:
					var start: Vector3 = marker.global_position
					var end: Vector3 = start + Vector3.UP * MISSILE.ordnance.clearance
					clear_path = clear_path and combat.segment_fraction(start, end) < 0.0 and combat.segment_fraction(start, start + Vector3.UP * 0.001) < 0.0
					var local_end: Vector3 = to_ship * end
					for box: AABB in combat.hitboxes:
						clear_end = clear_end and not box.grow(MISSILE.ordnance.hull_margin).has_point(local_end)
				_check("%s missile cells on the deck: vertical %.1f u ejection path clear of the hull, clear by %.1f u at its end (%d cells)" % [label,
					MISSILE.ordnance.clearance, MISSILE.ordnance.hull_margin, weapon.muzzles.size()], clear_path and clear_end)
	# Visual scale (C7): ordnance size relative to the measured hulls.
	var gunship_length := 6.59
	var destroyer_length := 12.18
	print("  scale: torpedo %.2f u x %.2f u = %.0f %% of Gunship / %.0f %% of Destroyer length; missile %.2f u x %.2f u = %.0f %% / %.0f %%" % [
		TORPEDO.ordnance.length, TORPEDO.ordnance.body_radius * 2.0, TORPEDO.ordnance.length / gunship_length * 100.0, TORPEDO.ordnance.length / destroyer_length * 100.0,
		MISSILE.ordnance.length, MISSILE.ordnance.body_radius * 2.0, MISSILE.ordnance.length / gunship_length * 100.0, MISSILE.ordnance.length / destroyer_length * 100.0])
	_check("ordnance smaller than the hulls' weapon mounts' reach (torpedo < 15 %%, missile < 10 %% of the Gunship's length)",
		TORPEDO.ordnance.length / gunship_length < 0.15 and MISSILE.ordnance.length / gunship_length < 0.10)


func _part_boxes(root_node: Node3D, to_ship: Transform3D) -> Dictionary:
	var boxes := {}
	for mesh_instance: MeshInstance3D in root_node.find_children("*", "MeshInstance3D", true, false):
		boxes[String(mesh_instance.name)] = (to_ship * mesh_instance.global_transform) * mesh_instance.get_aabb()
	return boxes


func _case_empty_stock() -> void:
	await _encounter(1) # HostileDestroyer: only torpedoes; Gunship Gatlings empty.
	await _run(8.0)
	var emptied := ["HostileDestroyer/DeckHardpoint/MissileCells", "HostileDestroyer/TowerHardpoint/Cannon", "HostileDestroyer/SternHardpoint/Gatling",
		"Gunship/LeftHardpoint/Gatling", "Gunship/RightHardpoint/Gatling"]
	var fired := 0
	var reasons := true
	for path: String in emptied:
		var weapon = _ship(path.get_slice("/", 0)).get_node("Weapons/" + path.substr(path.find("/") + 1))
		fired += weapon.shots
		reasons = reasons and weapon.reason == "Out of ammunition" and weapon.rounds_left() == 0 and not weapon.reloading()
	_check("emptied weapons never fire and report it (%d shots; reasons 'Out of ammunition', no reload)" % fired, fired == 0 and reasons)
	_check("the conditions are listed as scenario conditions (%s)" % str(scene.conditions), scene.conditions.size() == 4)
	var tube = _w("HostileDestroyer", "BowHardpoint/TorpedoTube")
	_check("the torpedo tube used one torpedo per launch (%d launches, %d left of 4)" % [tube.shots, tube.rounds_left()], tube.shots > 0 and tube.rounds_left() == 4 - tube.shots)


func _case_strict_focus() -> void:
	await _encounter(2, func() -> void:
		var o = scene.orders
		_place("Gunship", 0, 0, NORTH); _place("HostileGunship", 18, 0, WEST); _place("HostileDestroyer", 0, -40, SOUTH); _place("Destroyer", -60, 60, NORTH)
		for ship_name in ["Gunship", "HostileGunship", "HostileDestroyer", "Destroyer"]:
			_c(ship_name).health = 5000.0
		_set_stock("HostileDestroyer", &"torpedo", 0)
		_set_stock("HostileDestroyer", &"missile", 0)
		o.set_stance([_ship("HostileDestroyer"), _ship("Destroyer")], HOLD)
		o.clear_target([_ship("HostileDestroyer"), _ship("HostileGunship")])
		o.set_stance([_ship("HostileGunship")], AGGRESSIVE)
		o.assign_target([_ship("HostileGunship")], _ship("Gunship"))
		o.set_stance([_ship("Gunship")], DEFENSIVE)
		o.assign_target([_ship("Gunship")], _ship("HostileDestroyer")))
	var o = scene.orders
	await _run(6.0)
	var g = _c("Gunship")
	var at_attacker := _by("Gunship").filter(func(s: Dictionary) -> bool: return s.target == "HostileGunship").size()
	_check("Defensive, manual target not a threat: the attacker (a confirmed threat, in range) is not engaged (%d shots at it; HostileGunship fired %d)" % [at_attacker, _by("HostileGunship").size()],
		at_attacker == 0 and g.is_threat(_ship("HostileGunship")) and _by("HostileGunship").size() > 0)
	_check("weapons wait on the manual target ('%s'); target %s; manual assignment kept" % [g.weapons[0].reason, g.target.name if g.target else "none"],
		g.target == _ship("HostileDestroyer") and g.manual_target == _ship("HostileDestroyer") and g.weapons.all(func(w: Node) -> bool: return w.reason == "Not a confirmed threat" or String(w.reason).begins_with("Point defense")))
	o.set_stance([_ship("Gunship")], AGGRESSIVE)
	var before := _by("Gunship").size()
	await _run(6.0)
	var after := _by("Gunship").slice(before)
	var cannon_at_manual := after.filter(func(s: Dictionary) -> bool: return s.family == "cannon" and s.target == "HostileDestroyer").size()
	var gatlings := after.filter(func(s: Dictionary) -> bool: return s.family == "gatling").size()
	_check("Aggressive: the cannon engages the manual target at 40 u (%d shots); the Gatlings wait (out of range) and never take the nearer attacker (%d shots)" % [cannon_at_manual, gatlings],
		cannon_at_manual > 0 and gatlings == 0 and after.all(func(s: Dictionary) -> bool: return s.target == "HostileDestroyer"))
	_check("Gatling waits with the manual target out of its range ('%s')" % _w("Gunship", "RightHardpoint/Gatling").reason, String(_w("Gunship", "RightHardpoint/Gatling").reason).begins_with("Out of range"))
	o.clear_target([_ship("Gunship")])
	before = _by("Gunship").size()
	await _run(3.0)
	after = _by("Gunship").slice(before)
	_check("without a manual target the stance's automatic acquisition is kept (nearest: %s; %d shots at it)" % [g.target.name if g.target else "none", after.size()],
		g.auto_target == _ship("HostileGunship") and after.size() > 0)


# --- Phase 2: cannons --------------------------------------------------------------------

func _range_setup(distance: float) -> Dictionary:
	await _range(func() -> void:
		var platform := scene.get_node("Ships/Platform") as Node3D
		var dummy := scene.get_node("Ships/Dummy") as Node3D
		dummy.rotation = Vector3(0, -PI * 0.5, 0) # bow along +X: crossing targets present their length along the motion
		dummy.place(Vector3(0, 1.5, -distance))
		for path in ["LeftHardpoint/Gatling", "RightHardpoint/Gatling"]:
			var weapon = platform.get_node("Weapons/" + path)
			weapon.ammo = 0
			weapon.magazine = 0
		scene.get_node("CombatOrders").assign_target([platform], dummy))
	var platform := scene.get_node("Ships/Platform") as Node3D
	return {"platform": platform, "dummy": scene.get_node("Ships/Dummy"), "cannon": platform.get_node("Weapons/DorsalHardpoint/Cannon")}


func _case_cannon_range() -> void:
	var setup := await _range_setup(80.0)
	var cannon = setup.cannon
	await _run(4.0)
	_check("target at 80 u (beyond the 75 u maximum): no shot, reason '%s'" % cannon.reason, cannon.shots == 0 and String(cannon.reason).begins_with("Out of range"))
	setup.dummy.place(Vector3(0, 1.5, -70))
	await _run(6.0)
	var degraded: float = cannon.lead_factor
	_check("target at 70 u (between effective 45 and maximum 75): fires (%d shots, lead factor %.2f)" % [cannon.shots, degraded], cannon.shots > 0 and degraded < 1.0)
	setup.dummy.place(Vector3(0, 1.5, -40))
	await _run(3.0)
	_check("target at 40 u: full lead (factor %.2f)" % cannon.lead_factor, cannon.lead_factor == 1.0)


# Hit rate of the cannon against the dummy at `distance`, for one motion.
func _accuracy(distance: float, motion: String, seconds: float) -> Dictionary:
	var setup := await _range_setup(distance)
	var dummy: Node3D = setup.dummy
	var speed: float = {"stationary": 0.0, "slow": 1.5, "fast": 4.5, "zigzag": 4.5}[motion]
	if motion == "zigzag":
		var points := PackedVector3Array()
		for i in 40:
			points.append(Vector3(-4.5 if i % 2 == 0 else 4.5, 1.5, -distance))
		dummy.place(Vector3(0, 1.5, -distance))
		dummy.fly(points, speed) # reverses every 2 s
	elif speed > 0.0:
		dummy.fly(PackedVector3Array([Vector3(-14, 1.5, -distance), Vector3(14, 1.5, -distance)]), speed)
	await _run(seconds)
	var cannon = setup.cannon
	var hits: int = scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.outcome == "damage" and r.ship == "Dummy").size()
	var shots: int = cannon.shots
	return {"shots": shots, "hits": hits, "rate": float(hits) / maxf(1.0, shots), "lead": cannon.lead_factor,
		"sequence": scene.get_node("Projectiles").records.map(func(r: Dictionary) -> String: return r.outcome)}


func _case_cannon_accuracy() -> void:
	var table := {}
	for distance in [35.0, 65.0]:
		for motion in ["stationary", "slow", "fast", "zigzag"]:
			var result := await _accuracy(distance, motion, 30.0)
			table["%s@%d" % [motion, distance]] = result
			print("  cannon at %2d u, %-10s: %2d of %2d shots hit (%3.0f %%), lead factor %.2f" % [distance, motion, result.hits, result.shots, result.rate * 100.0, result.lead])
	_check("stationary targets: tracking degradation does not affect them (%.0f %% at 35 u, %.0f %% at 65 u; >= 90 %%)" % [table["stationary@35"].rate * 100.0, table["stationary@65"].rate * 100.0],
		table["stationary@35"].rate >= 0.9 and table["stationary@65"].rate >= 0.9)
	_check("fast crossing target: hit rate inside the effective range at least twice that in the degraded band (%.0f %% vs %.0f %%)" % [table["fast@35"].rate * 100.0, table["fast@65"].rate * 100.0],
		table["fast@35"].rate >= 0.5 and table["fast@35"].rate >= 2.0 * table["fast@65"].rate)
	_check("degradation grows with target speed at 65 u (slow %.0f %% >= fast %.0f %%)" % [table["slow@65"].rate * 100.0, table["fast@65"].rate * 100.0], table["slow@65"].rate >= table["fast@65"].rate)
	_check("direction changes defeat the full lead inside the effective range (zigzag %.0f %% < straight %.0f %% at 35 u; at 65 u %.0f %% vs %.0f %%, reported)" % [table["zigzag@35"].rate * 100.0,
		table["fast@35"].rate * 100.0, table["zigzag@65"].rate * 100.0, table["fast@65"].rate * 100.0], table["zigzag@35"].rate < table["fast@35"].rate)
	var again := await _accuracy(65.0, "fast", 30.0)
	_check("deterministic: no random spread (identical outcome sequence on a rerun)", again.sequence == table["fast@65"].sequence)


func _case_e01() -> void:
	var results := {}
	for entry in [["far", Vector2(-42, 0)], ["near", Vector2(-12, 0)], ["rock", Vector2(-40, 24)]]:
		await _encounter(0)
		scene.orders.move([_ship("Gunship")], entry[1])
		var obscured := {"seen": false}
		var hg_health: float = _c("HostileGunship").health
		for i in roundi(50.0 / DT):
			await _step()
			obscured.seen = obscured.seen or String(_w("Gunship", "DorsalHardpoint/Cannon").reason).ends_with("(asteroid)")
		var hits: int = scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.outcome == "damage" and r.ship == "HostileGunship").size()
		var shots := _by("Gunship", "cannon").size()
		results[entry[0]] = {"hits": hits, "shots": shots, "damage": hg_health - (_c("HostileGunship").health if _c("HostileGunship") != null else 0.0), "obscured": obscured.seen,
			"rock": scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.outcome == "asteroid").size()}
		print("  E01 position %s %s: %d of %d shots hit, %.0f damage, obscured seen %s, %d rounds on the asteroid" % [entry[0], str(entry[1]), hits, shots, results[entry[0]].damage, str(obscured.seen), results[entry[0]].rock])
	_check("E01: no fire from the start position beyond maximum range, fire once the player closes (far %d shots)" % results.far.shots, results.far.shots > 0)
	_check("E01: positioning changes the outcome: closer (~40 u) deals more damage than the degraded band (~70 u) (%.0f vs %.0f)" % [results.near.damage, results.far.damage],
		results.near.damage > results.far.damage)
	_check("E01: the asteroid obscures the line of fire from behind it (reason seen, %d rounds lost on it)" % results.rock.rock, results.rock.obscured)


# --- Phase 3: Gatlings ---------------------------------------------------------------------

func _gatling_range(target: Vector3) -> Dictionary:
	await _range(func() -> void:
		var dummy := scene.get_node("Ships/Dummy") as Node3D
		dummy.place(target)
		scene.get_node("Ships/Platform/Weapons/DorsalHardpoint/Cannon").ammo = 0
		scene.get_node("CombatOrders").assign_target([scene.get_node("Ships/Platform")], dummy))
	var platform := scene.get_node("Ships/Platform") as Node3D
	var dummy := scene.get_node("Ships/Dummy") as Node3D
	return {"platform": platform, "dummy": dummy, "left": platform.get_node("Weapons/LeftHardpoint/Gatling"), "right": platform.get_node("Weapons/RightHardpoint/Gatling")}


func _case_gatling_stream() -> void:
	var setup := await _gatling_range(Vector3(-15, 1.5, 1.6))
	var left = setup.left
	var spin := {"max": 0.0}
	for i in roundi(12.0 / DT):
		await _step()
		spin.max = maxf(spin.max, absf(left.spinner.rotation.z))
	var frames: Array = _shots.filter(func(s: Dictionary) -> bool: return s.weapon == left).map(func(s: Dictionary) -> int: return s.frame)
	var bursts := [[frames[0]]] if not frames.is_empty() else []
	var gaps := []
	for i in range(1, frames.size()):
		if frames[i] - frames[i - 1] > 10:
			gaps.append(frames[i] - frames[i - 1])
			bursts.append([frames[i]])
		else:
			bursts[-1].append(frames[i])
	var intervals_ok := true
	for i in range(1, frames.size()):
		var interval: int = frames[i] - frames[i - 1]
		intervals_ok = intervals_ok and (interval == 5 or interval > 10)
	var sizes: Array = bursts.map(func(b: Array) -> int: return b.size())
	var reload_ticks := roundi(GATLING.reload_time / DT)
	print("  left Gatling bursts %s, gaps between bursts %s ticks (reload %d ticks + 1 cooldown tick allowance)" % [str(sizes), str(gaps), reload_ticks])
	_check("magazine bursts of at most 40 rounds at 12 rounds/s (every 5 ticks) (%s)" % str(sizes), not sizes.is_empty() and sizes.max() <= 40 and sizes[0] == 40 and intervals_ok)
	_check("visible pauses between magazines equal the reload (%s ticks; reload %d)" % [str(gaps), reload_ticks], not gaps.is_empty() and gaps.all(func(g: int) -> bool: return absi(g - reload_ticks) <= 1))
	var empties := _reloads.filter(func(r: Dictionary) -> bool: return r.weapon == left and r.cause == "empty" and r.end > 0)
	_check("empty-magazine reloads last %s ticks" % str(empties.map(func(r: Dictionary) -> int: return r.end - r.start)), not empties.is_empty()
		and empties.all(func(r: Dictionary) -> bool: return absi(r.end - r.start - reload_ticks) <= 1 and r.moved == 40))
	var tracers: Array = scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.style == &"tracer")
	_check("individually simulated tracer rounds (%d tracer records, %d hits)" % [tracers.size(), tracers.filter(func(r: Dictionary) -> bool: return r.outcome == "damage").size()], tracers.size() >= 60)
	_check("barrel cluster spins while firing (%.1f rad)" % spin.max, spin.max > 0.1)
	var right = setup.right
	_check("the opposite Gatling cannot see the target past its own hull (%d shots; '%s')" % [right.shots, right.reason], right.shots == 0 and (String(right.reason).contains("hull") or String(right.reason).contains("coverage")))


func _case_gatling_idle_reload() -> void:
	var setup := await _gatling_range(Vector3(-15, 1.5, 1.6))
	var left = setup.left
	while left.shots < 10:
		await _step()
	setup.dummy.place(Vector3(-60, 1.5, 1.6)) # out of range: no actionable shot
	var left_at_stop: int = left.magazine
	var reserve_at_stop: int = left.ammo
	await _run(4.0)
	var idle := _reloads.filter(func(r: Dictionary) -> bool: return r.weapon == left and r.cause == "idle")
	var delay: int = idle[0].start - _last_shot[left.get_instance_id()] if not idle.is_empty() else -1
	_check("partly used magazine (%d) refilled after %d ticks idle (delay %.2f s), then full (%d, reserve %d -> %d)" % [left_at_stop, delay, GATLING.idle_reload_delay, left.magazine, reserve_at_stop, left.ammo],
		idle.size() == 1 and left.magazine == 40 and left.ammo == reserve_at_stop - (40 - left_at_stop) and delay <= roundi(GATLING.idle_reload_delay / DT) + 2)
	_check("idle reload lasts as long as an empty reload (%d ticks)" % (idle[0].end - idle[0].start if not idle.is_empty() else -1),
		not idle.is_empty() and absi(idle[0].end - idle[0].start - roundi(GATLING.reload_time / DT)) <= 1)
	# Partial refill: only 5 rounds in reserve.
	setup.dummy.place(Vector3(-15, 1.5, 1.6))
	while left.magazine > 20:
		await _step()
	setup.dummy.place(Vector3(-60, 1.5, 1.6))
	left.ammo = 5
	_rebase(left)
	var magazine_before: int = left.magazine
	await _run(4.0)
	_check("short reserve: partial refill (%d + 5 -> %d, reserve %d); nothing created" % [magazine_before, left.magazine, left.ammo], left.magazine == magazine_before + 5 and left.ammo == 0)
	# Tracking toward a target about to align: no idle reload while slewing.
	setup.dummy.place(Vector3(-15, 1.5, 1.6))
	left.ammo = 100
	_rebase(left)
	while left.magazine > 15:
		await _step()
	var reloads_before := _reloads.size()
	setup.dummy.place(Vector3(-4, 1.5, -16)) # near the bow: the mount slews ~70 degrees
	var slew := {"ticks": 0}
	var shots_before: int = left.shots
	while left.shots == shots_before and slew.ticks < 120:
		await _step()
		slew.ticks += 1
	_check("slewing toward a target about to align: no idle reload (%d ticks of tracking, %d reloads started; magazine %d)" % [slew.ticks, _reloads.size() - reloads_before, left.magazine],
		slew.ticks > roundi(GATLING.idle_reload_delay / DT) and _reloads.size() == reloads_before and left.shots > shots_before)


func _case_gatling_stability() -> void:
	var setup := await _gatling_range(Vector3(-15, 1.5, 1.6))
	var left = setup.left
	while left.shots < 6:
		await _step()
	# The target drifts in and out of range around 25 u for 20 s.
	setup.dummy.fly(PackedVector3Array([Vector3(-23.5, 1.5, 1.6), Vector3(-27.5, 1.5, 1.6)]), 1.0)
	await _run(20.0)
	var started := _reloads.filter(func(r: Dictionary) -> bool: return r.weapon == left)
	var overlapping := 0
	for i in range(1, started.size()):
		if started[i - 1].end < 0 or started[i].start < started[i - 1].end:
			overlapping += 1
	print("  boundary drift: %d shots, %d reloads (%s)" % [left.shots, started.size(), str(started.map(func(r: Dictionary) -> String: return "%s %d-%d" % [r.cause, r.start, r.end]))])
	_check("target crossing the range boundary: reloads never overlap or restart (%d reloads, %d overlapping)" % [started.size(), overlapping], overlapping == 0 and started.size() <= 6)


# --- Phase 4: torpedoes ----------------------------------------------------------------------

func _torpedo_setup(target_x: float, target_z: float, torpedoes: int = 1, extra: Callable = Callable(), heading: float = EAST) -> void:
	await _encounter(1, func() -> void:
		_c("Gunship").health = 100000.0
		_place("Gunship", target_x, target_z, heading)
		_set_stock("HostileDestroyer", &"torpedo", torpedoes)
		if extra.is_valid():
			extra.call())


## Production port: the prototype's heading lock is not migrated; the hull is held still by
## stopping its Locomotion for the first part (test-only), then released.
func _hold_hull(name: String, held: bool) -> void:
	_ship(name).get_node("Locomotion").set_physics_process(not held)


func _case_torpedo_cone() -> void:
	await _torpedo_setup(20, -30, 4, func() -> void: _hold_hull("HostileDestroyer", true)) # ~41 deg off the bow
	await _run(3.0)
	var tube = _w("HostileDestroyer", "BowHardpoint/TorpedoTube")
	_check("target outside the ±15 deg launch cone, hull held: no launch ('%s')" % tube.reason, tube.shots == 0 and String(tube.reason).begins_with("Outside launch cone"))
	_place("Gunship", -20, -14, EAST) # ~10.6 deg off the bow
	await _run(1.0)
	_check("target inside the cone: launched (%d)" % tube.shots, tube.shots == 1)
	_hold_hull("HostileDestroyer", false)
	_place("Gunship", 20, -30, EAST)
	var turned := {"ok": false}
	for i in roundi(10.0 / DT):
		await _step()
		turned.ok = turned.ok or tube.shots > 1
	_check("released and idle: the hull turns to bring the tube to bear, then launches (%d launches)" % tube.shots, turned.ok)


func _first_ordnance(limit: float) -> Node3D:
	for i in roundi(limit / DT):
		await _step()
		var list: Array = scene.get_node("Projectiles").ordnance
		if not list.is_empty():
			return list[0]
	return null


func _follow(node: Node3D, limit: float, each: Callable = Callable()) -> Dictionary:
	var id: int = node.id
	for i in roundi(limit / DT):
		await _step()
		if each.is_valid():
			each.call()
		if not _record(id).is_empty():
			break
	return _record(id)


func _case_torpedo_guidance() -> void:
	var results := {}
	# a) stationary target
	await _torpedo_setup(-20, 0)
	var t := await _first_ordnance(3.0)
	results["stationary"] = await _follow(t, 15.0)
	# b) target crossing at constant speed: the tube is loaded once the target cruises
	await _torpedo_setup(-20, -50, 0, Callable(), SOUTH)
	scene.orders.move([_ship("Gunship")], Vector2(-20, 90))
	await _run(3.0)
	_set_stock("HostileDestroyer", &"torpedo", 1)
	t = await _first_ordnance(8.0)
	results["moving"] = await _follow(t, 20.0)
	# c) perpendicular evasion after launch: the target, at rest and side-on, accelerates
	# ahead once the torpedo is within 26 u (c2: too late, within 12 u)
	for entry in [["evasion", 26.0], ["late evasion", 12.0]]:
		await _torpedo_setup(-20, 0, 1, Callable(), NORTH)
		t = await _first_ordnance(3.0)
		var dodge := {"done": false, "node": t, "at": entry[1]}
		results[entry[0]] = await _follow(t, 32.0, func() -> void:
			if not dodge.done and is_instance_valid(dodge.node) and dodge.node.live and (dodge.node as Node3D).global_position.distance_to(_ship("Gunship").global_position) < dodge.at:
				dodge.done = true
				scene.orders.move([_ship("Gunship")], Vector2(-20, -30)))
	# d) course change: crossing, then reversing when the torpedo is close
	await _torpedo_setup(-20, -25)
	scene.orders.move([_ship("Gunship")], Vector2(-20, 50))
	t = await _first_ordnance(8.0)
	var reverse := {"done": false, "node": t}
	results["course change"] = await _follow(t, 32.0, func() -> void:
		if not reverse.done and is_instance_valid(reverse.node) and reverse.node.live and (reverse.node as Node3D).global_position.distance_to(_ship("Gunship").global_position) < 20.0:
			reverse.done = true
			scene.orders.move([_ship("Gunship")], Vector2(-20, -40)))
	for key in results:
		print("  torpedo vs %-13s: %s after %.1f s, %.0f u" % [key, results[key].get("outcome", "?"), results[key].get("age", -1.0), results[key].get("traveled", -1.0)])
	_check("stationary target hit", results.stationary.get("outcome", "") == "damage")
	_check("target crossing at constant speed hit (lead pursuit)", results.moving.get("outcome", "") == "damage")
	_check("perpendicular evasion starting at 26 u made it miss (%s); started at 12 u it still hits (%s)" % [results.evasion.get("outcome", "?"), results["late evasion"].get("outcome", "?")],
		results.evasion.get("outcome", "damage") != "damage" and not results.evasion.is_empty() and results["late evasion"].get("outcome", "") == "damage")
	_check("target course change recorded (%s); no probability involved" % results["course change"].get("outcome", "?"), not results["course change"].is_empty())


# Evasion run (side-on target sprinting ahead once the torpedo is within 26 u) at a given
# turn rate: approaches closer than 20 u and the outcome, over the torpedo's whole life.
func _overshoot(turn_rate: float) -> Dictionary:
	await _torpedo_setup(-20, 0, 1, func() -> void:
		var tube = _w("HostileDestroyer", "BowHardpoint/TorpedoTube")
		tube.config = tube.config.duplicate(true)
		tube.config.ordnance.turn_rate_deg = turn_rate, NORTH)
	var t := await _first_ordnance(3.0)
	var state := {"done": false, "node": t, "minima": [], "last": INF, "closing": false}
	var record := await _follow(t, 32.0, func() -> void:
		if not is_instance_valid(state.node) or not state.node.live:
			return
		var distance: float = (state.node as Node3D).global_position.distance_to(_ship("Gunship").global_position)
		if not state.done and distance < 26.0:
			state.done = true
			scene.orders.move([_ship("Gunship")], Vector2(-20, -30))
		if state.closing and distance > state.last and state.last < 20.0:
			(state.minima as Array).append(snappedf(state.last, 0.1))
		state.closing = distance < state.last
		state.last = distance)
	return {"record": record, "minima": state.minima}


func _case_torpedo_overshoot() -> void:
	var proposed := await _overshoot(18.0)
	var tuned := await _overshoot(TORPEDO.ordnance.turn_rate_deg)
	print("  turn rate 18 deg/s (proposed): approaches %s u, outcome %s after %.1f s" % [str(proposed.minima), proposed.record.get("outcome", "?"), proposed.record.get("age", -1.0)])
	print("  turn rate %.0f deg/s (tuned): approaches %s u, outcome %s after %.1f s, %.0f u" % [TORPEDO.ordnance.turn_rate_deg, str(tuned.minima), tuned.record.get("outcome", "?"),
		tuned.record.get("age", -1.0), tuned.record.get("traveled", -1.0)])
	_check("measured: at the proposed 18 deg/s the same timely evasion still ends in a hit (%s), so no genuine miss is possible" % proposed.record.get("outcome", "?"),
		proposed.record.get("outcome", "") == "damage")
	_check("tuned: overshoot is a genuine miss - one pass (%s u), no loop back, then the technical limit (%s)" % [str(tuned.minima), tuned.record.get("outcome", "?")],
		tuned.minima.size() == 1 and tuned.record.get("outcome", "") == "expired")

func _case_torpedo_misc() -> void:
	# Obstacle: launched at a target behind an asteroid.
	await _torpedo_setup(-20, -20, 0, func() -> void: _place("HostileDestroyer", 55, -20, WEST))
	var rock: Vector3 = scene.get_node("Asteroids").center(1)
	var t := _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(48, 1.5, -20), Vector3.LEFT, "Gunship")
	var record := await _follow(t, 10.0)
	_check("no obstacle avoidance: a torpedo flying at a target behind an asteroid (%s) hits the asteroid (%s)" % [str(rock), record.get("outcome", "?")], record.get("outcome", "") == "asteroid")
	# Contact loss: last known position, then reacquisition.
	await _torpedo_setup(-20, 0)
	t = await _first_ordnance(3.0)
	await _run(0.5)
	scene.contacts.set_contact(1, _ship("Gunship"), false)
	var lost_at: Vector3 = _ship("Gunship").global_position
	scene.orders.move([_ship("Gunship")], Vector2(-20, 25))
	var lkp_ok := true
	for i in roundi(2.5 / DT):
		await _step()
		if is_instance_valid(t) and t.live:
			lkp_ok = lkp_ok and not t.has_contact and t.last_known.distance_to(lost_at) < 0.2 and (not t.has_goal or t.goal.distance_to(lost_at) < 0.2)
	var heading_to_lkp: float = rad_to_deg(t.forward().angle_to(lost_at - t.global_position)) if is_instance_valid(t) and t.live else -1.0
	_check("contact lost: guided to the last known position, which reveals nothing new (heading %.1f deg off it)" % heading_to_lkp, lkp_ok and heading_to_lkp >= 0.0 and heading_to_lkp < 5.0)
	scene.contacts.set_contact(1, _ship("Gunship"), true)
	await _run(0.2)
	var reacquired: bool = is_instance_valid(t) and t.live and t.has_contact and t.goal.distance_to(_ship("Gunship").global_position) < 15.0
	record = await _follow(t, 20.0)
	_check("contact restored: guidance back on the live target (%s, outcome %s)" % [str(reacquired), record.get("outcome", "?")], reacquired)
	# Interception by a Gatling round; no damage to anything nearby.
	await _torpedo_setup(-20, 0, 1, func() -> void: _set_stock("Gunship", &"gatling", 400))
	var healths := {}
	for ship_name in ["Gunship", "Destroyer", "HostileGunship", "HostileDestroyer"]:
		healths[ship_name] = _c(ship_name).health
	t = await _first_ordnance(3.0)
	record = await _follow(t, 15.0)
	var unchanged := true
	for ship_name in healths:
		unchanged = unchanged and _c(ship_name).health == healths[ship_name]
	var killer: Array = scene.get_node("Projectiles").records.filter(func(r: Dictionary) -> bool: return r.outcome == "intercept")
	_check("one Gatling round intercepts the torpedo (Hold Fire: point defense still authorized) (%s by %s, %d intercepting rounds)" % [record.get("outcome", "?"), record.get("intercepted_by", "?"), killer.size()],
		record.get("outcome", "") == "intercepted" and killer.size() == 1)
	_check("an intercepted torpedo damages nothing (all hulls unchanged)", unchanged)


func _case_e02() -> void:
	var results := {}
	for mode in ["stand", "dodge", "cover"]:
		await _encounter(1)
		_c("Gunship").health = 100000.0
		var dodged := {}
		for i in roundi(40.0 / DT):
			await _step()
			if mode == "dodge":
				# The player turns side-on, waits, and sprints ahead whenever a torpedo closes to 28 u.
				if i == 1:
					scene.orders.move([_ship("Gunship")], Vector2(-20, -4))
				for node in scene.get_node("Projectiles").ordnance:
					if not dodged.has(node.id) and node.global_position.distance_to(_ship("Gunship").global_position) < 28.0:
						dodged[node.id] = true
						var lo = _ship("Gunship").get_node("Locomotion")
						scene.orders.move([_ship("Gunship")], lo.planar_position + Vector2(0, -30))
			elif mode == "cover" and i == 1:
				scene.orders.move([_ship("Gunship")], Vector2(4, -27)) # behind the asteroid at (12, -20) seen from (55, 0)
		results[mode] = _outcomes("torpedo")
		print("  E02 %-5s: %s; launches %d; reason now '%s'" % [mode, str(results[mode]), _w("HostileDestroyer", "BowHardpoint/TorpedoTube").shots, _w("HostileDestroyer", "BowHardpoint/TorpedoTube").reason])
	_check("E02: standing still, the torpedoes hit (%s)" % str(results.stand), results.stand.get("damage", 0) >= 3)
	_check("E02: moving across the torpedoes' path makes them miss (%d hits of %d)" % [results.dodge.get("damage", 0), results.dodge.values().reduce(func(a: int, b: int) -> int: return a + b, 0)],
		results.dodge.get("damage", 0) < results.stand.get("damage", 0))
	_check("E02: behind the asteroid the torpedoes are refused or stopped by the rock (%s)" % str(results.cover), results.cover.get("damage", 0) < results.stand.get("damage", 0))


# --- Phase 5: missiles -----------------------------------------------------------------------

func _case_e04() -> void:
	await _encounter(3)
	var during_loss := {"ok": true, "checked": 0}
	var after_restore := {"ok": false}
	var lost_at := {"pos": Vector3.ZERO}
	for i in roundi(36.0 / DT):
		await _step()
		var now := _now()
		if absf(now - 9.0) < DT * 0.5:
			lost_at.pos = _ship("HostileGunship").global_position
		for node in scene.get_node("Projectiles").ordnance:
			if now > 9.05 and now < 13.0:
				during_loss.checked += 1
				during_loss.ok = during_loss.ok and not node.has_contact and node.last_known.distance_to(lost_at.pos) < 0.5
			if now > 13.05 and now < 20.0 and node.has_contact:
				after_restore.ok = true
	var outcomes := _outcomes("missile")
	var avoided := 0
	for id in _ord:
		if (_ord[id].get("avoided", []) as Array).has("asteroid 1"):
			avoided += 1
	var self_destruct: Array = scene.get_node("Projectiles").ordnance_records.filter(func(r: Dictionary) -> bool: return r.outcome == "self_destruct")
	print("  E04 outcomes %s; launches %d; events %s" % [str(outcomes), _w("Destroyer", "DeckHardpoint/MissileCells").shots, str(scene.enemy_controller.log)])
	# Since the missile feel revision the slower orientation climbs above this rock (r 6), so
	# avoidance is rarely needed here; avoidance itself is checked in M2 against a larger rock.
	_check("E04: missiles launched over the asteroid on the line of fire hit the target; none hit the asteroid (%d steered around it; %s)" % [avoided, str(outcomes)],
		outcomes.get("asteroid", 0) == 0 and outcomes.get("damage", 0) > 0)
	_check("E04: the target's Gatlings intercepted some (%d)" % outcomes.get("intercepted", 0), outcomes.get("intercepted", 0) > 0)
	_check("E04: during contact loss missiles fly to the last known position (%d ticks checked)" % during_loss.checked, during_loss.ok and during_loss.checked > 0)
	_check("E04: contact restored, a missile in flight reacquires the target", after_restore.ok)
	_check("E04: after contact is lost for good the last missile expires: self-destruct at %s s (flight time %.0f s)" % [str(self_destruct.map(func(r: Dictionary) -> String: return "%.3f" % r.age)), MISSILE.ordnance.flight_time],
		not self_destruct.is_empty() and self_destruct.all(func(r: Dictionary) -> bool: return absf(r.age - MISSILE.ordnance.flight_time) <= DT + 0.0001))
	var stages := true
	for id in _ord:
		if _ord[id].kind == &"missile":
			var phases: Array = _ord[id].phases
			stages = stages and phases == ["eject", "orient", "powered"].slice(0, phases.size())
	_check("every missile went through ejection, orientation and powered pursuit in that order", stages)


# Test condition: E04's rock enlarged to r 9 (scale 18), so its top (10.5 u) is above the
# missiles' cruise height after orientation and it really stands on their flight path.
func _missile_run(avoidance: bool, seconds: float) -> Dictionary:
	await _encounter(3, func() -> void:
		_quiet()
		_set_stock("HostileGunship", &"gatling", 0)
		var cells = _w("Destroyer", "DeckHardpoint/MissileCells")
		cells.config = cells.config.duplicate(true)
		cells.config.ordnance.avoidance = avoidance
		_set_stock("Destroyer", &"missile", 3),
		func() -> void: (scene.get_node("Asteroids/Asteroid1") as Node3D).scale = Vector3.ONE * 18.0)
	await _run(seconds)
	return _outcomes("missile")


func _case_missile_avoidance() -> void:
	var with := await _missile_run(true, 16.0)
	var without := await _missile_run(false, 16.0)
	print("  rock r 9; avoidance on: %s; off: %s" % [str(with), str(without)])
	_check("with local avoidance the missiles clear the asteroid and hit (%s)" % str(with), with.get("asteroid", 0) == 0 and with.get("damage", 0) == 3)
	_check("control without avoidance: the asteroid stops them (%s)" % str(without), without.get("asteroid", 0) >= 1)
	# Tight geometry: target close behind a large rock.
	await _encounter(3, func() -> void:
		_quiet()
		_set_stock("HostileGunship", &"gatling", 0)
		_set_stock("Destroyer", &"missile", 3)
		_place("Destroyer", -25, 0, EAST)
		_place("HostileGunship", 4.5, 0, WEST))
	await _run(14.0)
	var tight := _outcomes("missile")
	print("  tight geometry (target 1.5 u behind the rock's surface): %s" % str(tight))
	_check("tight geometry: missiles can still collide with the obstacle or miss (bounded steering, no pathfinding) - recorded %s" % str(tight), not tight.is_empty())


func _case_missile_turn() -> void:
	await _encounter(3, func() -> void:
		_quiet()
		_set_stock("HostileGunship", &"gatling", 0)
		_set_stock("Destroyer", &"missile", 1)
		_place("Destroyer", 0, -40, EAST)
		_place("HostileGunship", -40, -40, WEST) # behind the launcher
		_hold_hull("Destroyer", true))
	var t := await _first_ordnance(3.0)
	var trace := {"headings": [], "node": t}
	var record := await _follow(t, 12.0, func() -> void:
		if is_instance_valid(trace.node) and trace.node.live and trace.node.phase == "powered":
			var v: Vector3 = trace.node.velocity
			if Vector2(v.x, v.z).length() > 5.0:
				(trace.headings as Array).append(rad_to_deg(atan2(-v.x, -v.z))))
	var max_lag: float = rad_to_deg(_ord[record.id].max_nose_velocity) if _ord.has(record.get("id", -1)) else -1.0
	var h: Array = trace.headings
	print("  sharp turn: outcome %s after %.2f s; velocity heading %s -> %s deg; nose led the velocity by up to %.1f deg" % [record.get("outcome", "?"), record.get("age", -1.0),
		str(snappedf(h[0], 0.1)) if not h.is_empty() else "?", str(snappedf(h[-1], 0.1)) if not h.is_empty() else "?", max_lag])
	_check("target behind the launcher: the missile reverses with momentum (nose leads velocity by %.1f deg; no velocity jump)" % max_lag,
		record.get("outcome", "") == "damage" and max_lag > 10.0)
	# Overshoot from momentum (missile feel revision tuning): a target crossing close behind
	# the launcher; the missile turning back cannot pull in tight enough, passes it and has to
	# come back (or runs out of flight time).
	await _encounter(3, func() -> void:
		_quiet()
		_set_stock("HostileGunship", &"gatling", 0)
		_set_stock("Destroyer", &"missile", 1)
		_place("Destroyer", 0, -60, EAST)
		_place("HostileGunship", -18, -60, NORTH))
	scene.orders.move([_ship("HostileGunship")], Vector2(-18, -10))
	t = await _first_ordnance(3.0)
	var pass_state := {"minima": [], "last": INF, "closing": false, "node": t}
	record = await _follow(t, 10.0, func() -> void:
		if not is_instance_valid(pass_state.node) or not pass_state.node.live:
			return
		var distance: float = (pass_state.node as Node3D).global_position.distance_to(_ship("HostileGunship").global_position)
		if pass_state.closing and distance > pass_state.last and pass_state.last < 15.0:
			(pass_state.minima as Array).append(snappedf(pass_state.last, 0.1))
		pass_state.closing = distance < pass_state.last
		pass_state.last = distance)
	print("  momentum overshoot (target crossing 18 u behind): passes at %s u, outcome %s after %.2f s" % [str(pass_state.minima), record.get("outcome", "?"), record.get("age", -1.0)])
	_check("momentum: the missile overshoots, passes the target (%s u) and has to come back (%s after %.1f s)" % [str(pass_state.minima), record.get("outcome", "?"), record.get("age", -1.0)],
		(pass_state.minima as Array).size() >= 1 and record.get("age", 0.0) > 5.0)

func _case_missile_eject_intercept() -> void:
	await _encounter(3, func() -> void:
		_quiet()
		_set_stock("Destroyer", &"missile", 0))
	var cells = _w("Destroyer", "DeckHardpoint/MissileCells")
	var marker: Node3D = cells.muzzles[0]
	var m := _launch("Destroyer", "DeckHardpoint/MissileCells", marker.global_position, Vector3.UP, "HostileGunship")
	await _step()
	await _step()
	# A hostile round aimed at where the ejecting missile will be in 0.25 s.
	var future: Vector3 = m.global_position + m.velocity * 0.25
	var from := future + Vector3(10, 2, 0)
	scene.get_node("Projectiles").spawn(_ship("HostileGunship"), 1, from, (future - from).normalized() * 40.0, 1.0, 30.0, 1.0, null, &"tracer")
	var record := await _follow(m, 2.0)
	_check("a missile is interceptable during ejection (%s in phase %s)" % [record.get("outcome", "?"), record.get("phase", "?")], record.get("outcome", "") == "intercepted" and record.get("phase", "") == "eject")


func _missile_trace(detach: bool) -> Array:
	await _encounter(3, func() -> void:
		_quiet()
		_set_stock("Destroyer", &"missile", 0)
		_set_stock("HostileGunship", &"gatling", 0))
	var marker: Node3D = _w("Destroyer", "DeckHardpoint/MissileCells").muzzles[0]
	var m := _launch("Destroyer", "DeckHardpoint/MissileCells", marker.global_position, Vector3.UP, "HostileGunship")
	var spare: Array = []
	var spare_plume: Node3D = MAIN_FX.instantiate() # Stand-ins outside the tree: they take the thrust.
	if detach:
		# Remove every presentation node from the missile: the simulation must not notice.
		for i in 4:
			spare.append(JET_FX.instantiate())
		m._plume.free()
		for node in m._rcs:
			(node as Node).get_parent().free()
		m._plume = spare_plume
		m._rcs = spare
		for child in m.get_children():
			child.free()
	var trace := []
	var holder := {"m": m}
	for i in roundi(4.0 / DT):
		await physics_frame
		if not is_instance_valid(holder.m) or not holder.m.live:
			break
		trace.append([holder.m.global_transform, holder.m.velocity])
	for node in [spare_plume] + spare:
		(node as Node).free()
	return trace


func _case_missile_visuals() -> void:
	var normal := await _missile_trace(false)
	var bare := await _missile_trace(true)
	var same := normal.size() == bare.size() and normal.size() > 30
	for i in mini(normal.size(), bare.size()):
		same = same and (normal[i][0] as Transform3D).is_equal_approx(bare[i][0]) and (normal[i][1] as Vector3).is_equal_approx(bare[i][1])
	_check("missile flight identical with its model, plume and attitude thrusters removed (%d ticks)" % normal.size(), same)


# --- Phase 6: point defense ----------------------------------------------------------------

func _pd_setup(extra: Callable = Callable()) -> void:
	await _encounter(2, func() -> void:
		var o = scene.orders
		_place("Gunship", 0, 0, NORTH); _place("Destroyer", 0, 16, NORTH); _place("HostileGunship", -80, -80, NORTH); _place("HostileDestroyer", 80, -80, NORTH)
		o.set_stance([_ship("Gunship"), _ship("Destroyer"), _ship("HostileGunship"), _ship("HostileDestroyer")], HOLD)
		o.clear_target([_ship("Gunship"), _ship("HostileDestroyer")])
		_set_stock("HostileDestroyer", &"torpedo", 0)
		_set_stock("HostileDestroyer", &"missile", 0)
		_set_stock("Destroyer", &"gatling", 0)
		for ship_name in ["Gunship", "Destroyer"]:
			_c(ship_name).health = 100000.0
		if extra.is_valid():
			extra.call())


func _case_pd_priority() -> void:
	await _pd_setup()
	var right = _w("Gunship", "RightHardpoint/Gatling")
	var a := _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(23, 1.5, 0), Vector3.LEFT, "Gunship")
	var b := _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(14, 1.5, 16), Vector3.LEFT, "Destroyer")
	await _step()
	var times := [Gatling.threat_time(a, _ship("Gunship")), Gatling.threat_time(b, _ship("Destroyer"))]
	_check("own ship before ally: threat to the Gunship (%.2f s) engaged ahead of an earlier threat to the ally (%.2f s) (engaging %s, category %d)" % [times[0], times[1],
		right.defense_target.name if right.defense_target else "none", right.defense_category], right.defense_target == a and right.defense_category == 0 and times[1] < times[0])
	await _free_and_pd()
	right = _w("Gunship", "RightHardpoint/Gatling")
	var near := _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(19, 1.5, -2), Vector3.LEFT, "Gunship")
	var far := _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(24, 1.5, 3), Vector3.LEFT, "Gunship")
	await _step()
	_check("same category: the earliest predicted impact first (engaging %s; near %.2f s, far %.2f s)" % [right.defense_target.name if right.defense_target else "none",
		Gatling.threat_time(near, _ship("Gunship")), Gatling.threat_time(far, _ship("Gunship"))], right.defense_target == near)
	var result := await _follow(far, 6.0)
	_check("both intercepted (%s; %s)" % [str(_outcomes()), str(result.get("outcome", "?"))], _outcomes().get("intercepted", 0) == 2)
	await _free_and_pd()
	right = _w("Gunship", "RightHardpoint/Gatling")
	var ally_only := _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(14, 1.5, 16), Vector3.LEFT, "Destroyer")
	await _step()
	result = await _follow(ally_only, 6.0)
	_check("an ally within the defensive radius is protected (%s by %s)" % [result.get("outcome", "?"), result.get("intercepted_by", "?")], result.get("outcome", "") == "intercepted" and result.get("intercepted_by", "") == "Gunship")


func _free_and_pd() -> void:
	await _pd_setup()


func _case_pd_passed() -> void:
	await _pd_setup()
	var right = _w("Gunship", "RightHardpoint/Gatling")
	var passed := _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(5, 1.5, 0), Vector3.RIGHT, "Gunship") # already past, receding
	var engaged := {"ticks": 0, "threat": 0}
	for i in roundi(2.0 / DT):
		await _step()
		if is_instance_valid(passed) and passed.live:
			if right.defense_target == passed or _w("Gunship", "LeftHardpoint/Gatling").defense_target == passed:
				engaged.ticks += 1
			if Gatling.threat_time(passed, _ship("Gunship")) < INF:
				engaged.threat += 1
	var shots_at := _shots.filter(func(s: Dictionary) -> bool: return s.defense).size()
	_check("ordnance that has passed and recedes is not a threat (%d threat ticks), not engaged (%d ticks, %d rounds) though in range and arc" % [engaged.threat, engaged.ticks, shots_at],
		engaged.threat == 0 and engaged.ticks == 0 and shots_at == 0)
	# Out of flight time: a missile that cannot arrive before it self-destructs.
	await _pd_setup()
	var late := _launch("HostileDestroyer", "DeckHardpoint/MissileCells", Vector3(22, 1.5, 0), Vector3.LEFT, "Gunship")
	late.age = MISSILE.ordnance.flight_time - 0.2
	late.phase = "powered"
	late.velocity = Vector3.LEFT * 5.0
	var time := Gatling.threat_time(late, _ship("Gunship"))
	_check("ordnance unable to reach the ship within its remaining flight time is not a threat (time %s)" % str(time), time == INF)


func _case_pd_arcs() -> void:
	await _pd_setup()
	var right = _w("Gunship", "RightHardpoint/Gatling")
	var left = _w("Gunship", "LeftHardpoint/Gatling")
	var t := _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(22, 1.5, 0), Vector3.LEFT, "Gunship")
	var left_engaged := {"n": 0}
	var record := await _follow(t, 5.0, func() -> void:
		if left.defense_target != null:
			left_engaged.n += 1)
	_check("threat from the right: the right Gatling intercepts (%s), the left one never engages it past the hull (%d ticks, %d rounds)" % [record.get("outcome", "?"), left_engaged.n, left.defense_shots],
		record.get("outcome", "") == "intercepted" and left_engaged.n == 0 and left.defense_shots == 0 and right.defense_shots > 0)
	# The Destroyer's stern Gatling against a threat from dead ahead (its blind bow arc).
	await _pd_setup(func() -> void:
		_set_stock("Destroyer", &"gatling", 400)
		_place("Gunship", -80, 80, NORTH)
		_place("Destroyer", 0, 0, EAST))
	var stern = _w("Destroyer", "SternHardpoint/Gatling")
	t = _launch("HostileDestroyer", "BowHardpoint/TorpedoTube", Vector3(24, 1.5, 0), Vector3.LEFT, "Destroyer")
	var engageable := {"n": 0, "node": t}
	record = await _follow(t, 5.0, func() -> void:
		if is_instance_valid(engageable.node) and engageable.node.live and stern.engageable(engageable.node):
			engageable.n += 1)
	_check("threat from dead ahead: outside the stern Gatling's traverse, never engaged (%d engageable ticks, %d rounds; %s)" % [engageable.n, stern.defense_shots, record.get("outcome", "?")],
		engageable.n == 0 and stern.defense_shots == 0 and record.get("outcome", "") == "damage")


func _case_pd_interruption() -> void:
	await _encounter(2) # As authored: the escort engages HostileGunship; HostileDestroyer launches at the Destroyer.
	var guns := [_w("Gunship", "LeftHardpoint/Gatling"), _w("Gunship", "RightHardpoint/Gatling")]
	var state := {"interruptions": 0, "resumed": 0, "lost": 0, "reload_on_switch": 0, "manual_changed": 0}
	var prev := {}
	for gun in guns:
		prev[gun] = {"mode": gun.mode, "magazine": gun.magazine, "shots": gun.shots}
	for i in roundi(30.0 / DT):
		var reloads_before := _reloads.size()
		await _step()
		if _c("Gunship").manual_target != _ship("HostileGunship") and _c("HostileGunship") != null and _c("HostileGunship").alive:
			state.manual_changed += 1
		for gun in guns:
			var p: Dictionary = prev[gun]
			if p.mode == "offense" and gun.mode == "defense":
				state.interruptions += 1
				# Rounds before = rounds now + rounds fired this tick; no reload begun by the switch.
				if p.magazine - (gun.shots - p.shots) != gun.magazine and not gun.reloading():
					state.lost += 1
				for r in _reloads.slice(reloads_before):
					if r.weapon == gun and r.cause == "idle":
						state.reload_on_switch += 1
			if p.mode == "defense" and gun.mode == "offense":
				state.resumed += 1
			prev[gun] = {"mode": gun.mode, "magazine": gun.magazine, "shots": gun.shots}
	var offense_after_defense := 0
	for gun in guns:
		var defended := _shots.filter(func(s: Dictionary) -> bool: return s.weapon == gun and s.defense)
		if not defended.is_empty():
			offense_after_defense += _shots.filter(func(s: Dictionary) -> bool: return s.weapon == gun and not s.defense and s.frame > defended[0].frame).size()
	print("  escort Gatlings: %s; offense %d / %d rounds, defense %d / %d rounds" % [str(state), guns[0].offense_shots, guns[1].offense_shots, guns[0].defense_shots, guns[1].defense_shots])
	_check("point defense interrupted offensive fire (%d interruptions)" % state.interruptions, state.interruptions > 0)
	_check("interruption kept the magazine's rounds (%d lost) and started no reload (%d)" % [state.lost, state.reload_on_switch], state.lost == 0 and state.reload_on_switch == 0)
	_check("manual target never changed by point defense (%d ticks)" % state.manual_changed, state.manual_changed == 0)
	_check("offensive fire resumed on the manual target after the threats (%d resumptions, %d offensive rounds after the first defensive one)" % [state.resumed, offense_after_defense],
		state.resumed > 0 and offense_after_defense > 0)
	var counted := true
	for gun in guns:
		counted = counted and gun.defense_shots == _shots.filter(func(s: Dictionary) -> bool: return s.weapon == gun and s.defense).size() \
			and gun.offense_shots == _shots.filter(func(s: Dictionary) -> bool: return s.weapon == gun and not s.defense).size()
	_check("every round classified as offense or point defense by what it was fired at (Gatling counters match the shot audit)", counted)
	# Hold Fire: point defense only.
	await _encounter(2)
	scene.orders.set_stance([_ship("Gunship")], HOLD)
	await _run(15.0)
	_check("Hold Fire: no offensive rounds (%d), point defense still active (%d rounds)" % [_by("Gunship", "", 0).size(), _by("Gunship", "", 1).size()],
		_by("Gunship", "", 0).is_empty() and _by("Gunship", "", 1).size() > 0)


func _case_e03() -> void:
	var results := {}
	for mode in ["escorted", "alone"]:
		await _encounter(2)
		if mode == "alone":
			_place("Gunship", -25, 60, EAST) # 60 u away: outside the 30 u defensive radius
			scene.orders.clear_target([_ship("Gunship")])
			scene.orders.set_stance([_ship("Gunship")], HOLD)
		_c("Destroyer").health = 100000.0 # measure the damage delivered (test condition)
		await _run(40.0)
		results[mode] = {"damage": 100000.0 - _c("Destroyer").health, "outcomes": _outcomes(), "defense": _by("Gunship", "", 1).size(), "offense": _by("Gunship", "", 0).size()}
		print("  E03 %-8s: Destroyer took %.0f damage; ordnance %s; escort rounds offense %d, defense %d" % [mode, results[mode].damage, str(results[mode].outcomes),
			results[mode].offense, results[mode].defense])
	_check("E03: escort positioning changes the protected ship's outcome (%.0f vs %.0f damage)" % [results.escorted.damage, results.alone.damage], results.escorted.damage < results.alone.damage)
	_check("E03: the escort fought offensively and defended in the same encounter (%d / %d rounds)" % [results.escorted.offense, results.escorted.defense],
		results.escorted.offense > 0 and results.escorted.defense > 0)


# --- Regression ------------------------------------------------------------------------------

func _trace(hold: bool) -> Array:
	await _encounter(2)
	var ships: Array = scene.get_node("Ships").get_children()
	if hold:
		scene.orders.set_stance(ships, HOLD)
		for ship: Node3D in ships:
			CombatShip.of(ship).point_defense_authorized = false
	var orders := {"Gunship": Vector2(30, 6), "HostileGunship": Vector2(-30, -6), "Destroyer": Vector2(30, -16), "HostileDestroyer": Vector2(-30, 16)}
	_place("Gunship", -30, -6, EAST); _place("HostileGunship", 30, 6, WEST); _place("Destroyer", -30, 16, EAST); _place("HostileDestroyer", 30, -16, WEST)
	await _step()
	for ship_name in orders:
		scene.orders.move([_ship(ship_name)], orders[ship_name])
	var trace := []
	var destroyed := [false]
	for ship: Node3D in ships:
		CombatShip.of(ship).destroyed.connect(func(_s: Node3D) -> void: destroyed[0] = true)
	for i in 60 * 30:
		await _step()
		var poses := []
		var moving := 0
		for ship_name in orders:
			var ship := _ship(ship_name)
			if ship == null:
				continue
			var lo = ship.get_node("Locomotion")
			poses.append([lo.planar_position, lo.heading])
			moving += 1 if lo.has_destination else 0
		trace.append({"poses": poses, "destroyed": destroyed[0], "moving": moving})
	return trace


func _case_movement() -> void:
	var a := await _trace(false)
	var b := await _trace(true)
	var first := -1
	var compared := 0
	for i in mini(a.size(), b.size()):
		if a[i].destroyed or a[i].moving < 4:
			break
		compared += 1
		if a[i].poses != b[i].poses:
			first = i
			break
	_check("v0.3 ships: trajectories identical with and without combat while all four move (%d ticks compared, first difference %d)" % [compared, first], first < 0 and compared > 60)


func _case_hud() -> void:
	await _encounter(2)
	await _run(2.0)
	var text := CombatHud.describe(_ship("Gunship")) + "\n" + CombatHud.describe(_ship("HostileDestroyer"))
	print("  " + text.replace("\n", "\n  "))
	_check("HUD shows ammunition and reload state per weapon (magazine, reserve, ammo, EMPTY)", text.contains("magazine") and text.contains("reserve") and text.contains("ammo") and text.contains("EMPTY"))


func _case_resets() -> void:
	_free()
	var lab: Node = LAB.instantiate()
	root.add_child(lab)
	await _run(2.0)
	var olds := []
	var counts := {}
	var clean := true
	var orphans := []
	for i in 12:
		olds.append(weakref(lab.arena))
		lab.load_encounter(i % 4)
		var a: Node3D = lab.arena
		clean = clean and a.projectiles.ordnance.is_empty() and a.projectiles.active.is_empty() and a.effects.active_count() == 0 and a.get_node("OrdnanceTrails").trail_count() == 0
		for k in roundi(6.0 / DT):
			await physics_frame
		await process_frame
		if not counts.has(i % 4):
			counts[i % 4] = []
		counts[i % 4].append(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		orphans.append(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	olds.append(weakref(lab.arena))
	lab.load_encounter(0)
	await physics_frame
	await process_frame
	var freed := olds.all(func(w: WeakRef) -> bool: return w.get_ref() == null)
	print("  node counts per encounter after 6 s: %s; orphans %s" % [str(counts), str(orphans)])
	_check("previous arenas freed on every reset (%d), one arena under the lab" % olds.size(), freed and lab.get_child_count() == 1)
	_check("every reset starts with no ordnance, rounds, effects or trails", clean)
	_check("orphan node count stays 0", orphans.all(func(n: float) -> bool: return n == 0.0))
	var stable := true
	for key in counts:
		stable = stable and (counts[key] as Array).max() - (counts[key] as Array).min() <= 60
	_check("node count does not grow across resets of the same encounter", stable)
	root.remove_child(lab)
	lab.free()
