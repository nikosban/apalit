extends SceneTree
## Experiment (PDC saturation fire): isolated comparison of FF-01's four point-defense
## mounts against one Wayfarer salvo (4 missiles) or one Barrage salvo (8 rockets) aimed at
## a target FF-01, for a few fixed seeds. Scenario sets (all by default; name sets after
## `--` to run only those):
##   static   - both ships stationary, the attacker's launcher fires normally;
##   moving   - both ships under way on opposite courses across the line of fire (2 s
##              head start), the attacker's launcher fires normally;
##   incoming - test setup only: the salvo is created already in powered flight (missiles,
##              at top speed, homing) or committed flight (rockets, at cruise speed, aimed
##              with the Barrage's 3° dispersion) at a set distance from a stationary
##              target, so ejection-phase shots cannot occur;
##   combined - the target under way (2 s head start) meets a Barrage salvo launched
##              normally by a stationary FF-01 45 u away and four Wayfarers created in
##              powered flight 70 u out on a bearing 40° from the rockets' (test setup),
##              timed so both threats are inside the target's PDC coverage together.
## `-- trace`: only the production Kestrel, Incoming Wayfarer 70 u, seed 1, with a per-tick trace of
## every mount engaging the first missile (orientation, limits, aim, eligibility).
## `-- diagnose`: only raid_sweep, combined set, seed 3, with a per-round and per-burst
## account of every round fired at Wayfarers 9, 10 and 11 (selection, aiming latency,
## committed prediction against the actual track, shared error, closest approach).
## Variants on the target's four PDC hardpoints:
##   production - the production PDC-20 Kestrel (pdc.gd: raid sweep, committed prediction
##                from the start of firing; until 2026-10-28 the 25 u per-tick Kestrel);
##   control    - experimental configuration (75 u, 30 rds/s, 120 / 1200), per-tick aiming;
##   saturation - the same configuration with committed prediction;
##   raid_sweep - the same with raid_sweep targeting (pdc_raid_sweep.gd: 4-round
##                micro-bursts cycled across the incoming threats).
## Observations only (no pass threshold). Everything is stepped manually at 60 Hz, as in
## guided_missile_test.gd.
## Run (headless): <godot console> --headless --path . --fixed-fps 60 -s res://experiments/pdc_saturation/saturation_eval.gd
## Run (windowed rendering measurement): <godot console> --path . --fixed-fps 60 -s res://experiments/pdc_saturation/saturation_eval.gd -- visual

const ARENA := preload("res://game/scenes/combat_test.tscn")
const UNIT := preload("res://game/ships/ff01_unit.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Weapon := preload("res://game/weapons/weapon.gd")
const WAYFARER := preload("res://game/weapons/gcm4_wayfarer.tres")
const BARRAGE := preload("res://game/weapons/rl8_barrage.tres")
const VARIANTS := {
	"production": preload("res://game/weapons/pdc20_kestrel.tscn"),
	"control": preload("res://experiments/pdc_saturation/pdc20_kestrel_control.tscn"),
	"saturation": preload("res://experiments/pdc_saturation/pdc20_kestrel_saturation.tscn"),
	"raid_sweep": preload("res://experiments/pdc_saturation/pdc20_kestrel_raid_sweep.tscn")}
const SCENARIOS := [
	{"set": "static", "name": "Wayfarer close", "weapon": "WayfarerHardpoint", "salvo": 4, "distance": 30.0},
	{"set": "static", "name": "Wayfarer long", "weapon": "WayfarerHardpoint", "salvo": 4, "distance": 70.0},
	# Launched beyond the 75 u experimental range (Wayfarer acquisition 90 u): no ejection-phase shots.
	{"set": "static", "name": "Wayfarer far", "weapon": "WayfarerHardpoint", "salvo": 4, "distance": 85.0},
	{"set": "static", "name": "Barrage close", "weapon": "BarrageHardpoint", "salvo": 8, "distance": 25.0},
	{"set": "static", "name": "Barrage long", "weapon": "BarrageHardpoint", "salvo": 8, "distance": 55.0},
	# Distances at the start of the head start; the ships separate while crossing.
	{"set": "moving", "name": "Moving Wayfarer 60 u", "weapon": "WayfarerHardpoint", "salvo": 4, "distance": 60.0},
	{"set": "moving", "name": "Moving Wayfarer 85 u", "weapon": "WayfarerHardpoint", "salvo": 4, "distance": 85.0},
	{"set": "moving", "name": "Moving Barrage 40 u", "weapon": "BarrageHardpoint", "salvo": 8, "distance": 40.0},
	# Created this far from the target, already in flight; same release spacing as a salvo
	# (missiles 0.2 s, rockets about 0.12 s apart), small lateral spread.
	{"set": "incoming", "name": "Incoming Wayfarer 70 u", "config": WAYFARER, "salvo": 4, "distance": 70.0, "interval": 12,
		"lateral": [-0.75, -0.25, 0.25, 0.75]},
	{"set": "incoming", "name": "Incoming Barrage 55 u", "config": BARRAGE, "salvo": 8, "distance": 55.0, "interval": 7,
		"lateral": [-0.45, -0.15, 0.15, 0.45, -0.45, -0.15, 0.15, 0.45]},
	# Rockets from the attacker (west); Wayfarers from 40° toward the target's course, starting
	# about 1.9 s after the first salvo tick, so both reach 25 u of the target in the same window.
	{"set": "combined", "name": "Combined: Barrage salvo 45 u + 4 Wayfarers powered 70 u", "weapon": "BarrageHardpoint", "salvo": 8, "distance": 45.0,
		"config": WAYFARER, "missiles": 4, "missile_distance": 70.0, "missile_from": Vector3(-0.766044, 0.0, 0.642788), "missile_start": 115,
		"interval": 12, "lateral": [-0.75, -0.25, 0.25, 0.75]}]
const MOVE_LEG := 120.0 # u each ship travels on its course (moving set)
const HEAD_START := 120 # ticks under way before the salvo (moving set)
const SEEDS := [1, 2, 3]
const PDCS := ["ForwardPortPDCHardpoint", "ForwardStarboardPDCHardpoint", "AftPortPDCHardpoint", "AftStarboardPDCHardpoint"]
const DT := 1.0 / 60.0
const SITE := Vector2(-260, -260)
const MAX_TICKS := 780 # 13 s: Wayfarer flight time 9 s plus launch and margin

var visual := false
var trace := false
var diagnose := false
const DIAGNOSE_IDS := [9, 10, 11]
var _diag_rounds: Array[Dictionary] = [] # per round fired at a diagnosed missile
var _diag_selected := {} # mount index -> [ordnance id, tick selected, first-shot tick]
var _diag_bursts: Array[Dictionary] = [] # per selection of a diagnosed missile by a mount
var _diag_missile := {} # missile id -> {tick: position}, and "end" tick
var scene: Node3D
var attacker: Node3D
var victim: Node3D
var projectiles: Node


func _initialize() -> void:
	visual = OS.get_cmdline_user_args().has("visual")
	trace = OS.get_cmdline_user_args().has("trace")
	diagnose = OS.get_cmdline_user_args().has("diagnose")
	await process_frame
	if diagnose:
		var combined: Dictionary = SCENARIOS.filter(func(x: Dictionary) -> bool: return x.set == "combined")[0]
		var r: Dictionary = await _run("raid_sweep", combined, 3)
		print("diagnose run (raid_sweep, combined, seed 3): missile impacts %d, rocket impacts %d, hull lost %.2f" % [
			r.by_kind.missile.impacts, r.by_kind.rocket.impacts, r.hull_lost])
		_diag_report()
		scene.free()
		await process_frame
		quit(0)
		return
	if trace:
		var incoming: Dictionary = SCENARIOS.filter(func(x: Dictionary) -> bool: return x.name == "Incoming Wayfarer 70 u")[0]
		var r: Dictionary = await _run("production", incoming, SEEDS[0])
		print("trace run: intercepted %d, impacts %d" % [r.intercepted, r.impacts])
		for note: String in r.notes:
			print("  " + note)
		scene.free()
		await process_frame
		quit(0)
		return
	if visual:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var sets: Array = Array(OS.get_cmdline_user_args()).filter(func(a: String) -> bool: return a in ["static", "moving", "incoming", "combined"])
	print("=== PDC saturation comparison (%s; seeds %s; sets %s)" % ["windowed" if visual else "headless", str(SEEDS), "all" if sets.is_empty() else str(sets)])
	var seeds: Array = SEEDS if not visual else [SEEDS[0]]
	for scenario: Dictionary in SCENARIOS:
		if not sets.is_empty() and not sets.has(scenario.set):
			continue
		print("\n%s (%.0f u, %d per salvo)" % [scenario.name, scenario.distance, scenario.salvo])
		if scenario.set == "combined":
			await _combined_report(scenario, seeds)
			continue
		for variant: String in VARIANTS:
			var totals := {"intercepted": 0, "impacts": 0, "other": 0, "rounds": 0, "ammo": 0, "collateral": 0}
			var phases := {}
			var distances: Array = []
			for seed: int in seeds:
				var r: Dictionary = await _run(variant, scenario, seed)
				for key: String in totals:
					totals[key] += r[key]
				for phase: String in r.phases:
					phases[phase] = phases.get(phase, 0) + r.phases[phase]
				distances.append_array(r.distances)
				var line := "  %-10s seed %d: intercepted %d %s, impacts %d, other %s; rounds %d, ammo %d; peak active rounds %d; intercept distance %s u; sim ms/tick mean %.2f max %.2f" % [
					variant, seed, r.intercepted, str(r.phases), r.impacts, str(r.other_outcomes), r.rounds, r.ammo, r.peak_rounds, str(r.distances), r.sim_mean, r.sim_max]
				if visual:
					line += "; frame ms mean %.2f max %.2f at peak %.2f; draw calls max %d (at peak %d); objects max %d" % [
						r.frame_mean, r.frame_max, r.frame_at_peak, r.draws_max, r.draws_at_peak, r.objects_max]
				print(line)
				for note: String in r.notes:
					print("      " + note)
			var mean_distance: float = distances.reduce(func(a: float, d: float) -> float: return a + d, 0.0) / maxi(distances.size(), 1)
			print("  %-10s total: %d intercepted %s (mean %.1f u from the target), %d impacts, %d other of %d; %d rounds, %d ammo, %.1f rounds per interception; %d intercepted by a round aimed at another threat" % [
				variant, totals.intercepted, str(phases), mean_distance, totals.impacts, totals.other, scenario.salvo * seeds.size(), totals.rounds, totals.ammo,
				float(totals.rounds) / maxi(totals.intercepted, 1), totals.collateral])
	if scene != null:
		scene.free()
	await process_frame
	quit(0)


func _silence(node: Node) -> void:
	node.process_mode = Node.PROCESS_MODE_DISABLED
	for child: Node in node.get_children():
		_silence(child)


func _place(ship: Node3D, point: Vector2, heading := 0.0) -> void:
	ship.get_node("Locomotion").place(point, heading)
	ship.get_node("Avoidance").reset()


func _load(variant: String) -> void:
	if scene != null:
		scene.free()
		await process_frame
	scene = ARENA.instantiate()
	scene.get_node("Asteroids").session_seed = 5005
	root.add_child(scene)
	_silence(scene)
	attacker = scene.get_node("Ships/FF01")
	var index := 0
	for ship: Node3D in scene.get_node("Ships").get_children():
		_place(ship, Vector2(1000 + 40 * index, 1000))
		index += 1
	victim = UNIT.instantiate()
	victim.name = "PDCTarget"
	victim.position.y = 1.5
	victim.get_node("Combat").faction = 1
	for mount: String in PDCS:
		var hardpoint := victim.get_node("Weapons/" + mount)
		var old := hardpoint.get_node("PDC20Kestrel")
		hardpoint.remove_child(old)
		old.free()
		var pdc: Node3D = VARIANTS[variant].instantiate()
		pdc.name = "PDC20Kestrel"
		hardpoint.add_child(pdc)
	scene.get_node("Ships").add_child(victim)
	scene.register_ship(victim)
	_silence(victim)
	for ship: Node in scene.get_node("Ships").get_children():
		var c = CombatShip.of(ship)
		c.stance = CombatShip.Stance.HOLD_FIRE
		for weapon in c.weapons:
			weapon.enabled = false
	projectiles = scene.get_node("Projectiles")
	if visual:
		var camera := Camera3D.new()
		scene.add_child(camera)
		camera.current = true


func _run(variant: String, scenario: Dictionary, seed: int) -> Dictionary:
	await _load(variant)
	var incoming: bool = scenario.set == "incoming"
	var moving: bool = scenario.set == "moving"
	var combined: bool = scenario.set == "combined"
	# Incoming: the (owning) attacker sits 10 u behind the creation point.
	var separation: float = scenario.distance + (10.0 if incoming else 0.0)
	_place(attacker, SITE)
	_place(victim, SITE + Vector2(separation, 0.0), PI if moving or combined else 0.0)
	var launcher: Node = null
	if not incoming:
		launcher = attacker.get_node("Weapons/" + scenario.weapon).weapon()
		launcher.enabled = true
		launcher.ammo = launcher.capacity()
		launcher.rng.seed = seed # Barrage per-rocket dispersion (fixed per seed).
	var rng := RandomNumberGenerator.new()
	rng.seed = seed # Incoming rocket dispersion.
	var ac = CombatShip.of(attacker)
	ac.stance = CombatShip.Stance.AGGRESSIVE
	ac.target = victim
	ac.manual_target = victim
	var pdcs: Array = PDCS.map(func(m: String) -> Node: return victim.get_node("Weapons/" + m).weapon())
	for i in pdcs.size():
		pdcs[i].enabled = true
		pdcs[i].rng.seed = seed * 100 + i
	if visual:
		var mid := Vector3(SITE.x + scenario.distance * 0.5, 1.5, SITE.y)
		var camera: Camera3D = scene.get_viewport().get_camera_3d()
		camera.global_position = mid + Vector3(0, 32, 32)
		camera.look_at(mid)
	scene.sensors.evaluate()
	if moving:
		# Opposite courses across the line of fire, each along its own bow; under way first.
		attacker.get_node("Locomotion").move_to(SITE + Vector2(0.0, -MOVE_LEG))
		victim.get_node("Locomotion").move_to(SITE + Vector2(separation, MOVE_LEG))
		for i in HEAD_START:
			scene.get_node("SimClock").time += DT
			attacker.get_node("Locomotion")._physics_process(DT)
			victim.get_node("Locomotion")._physics_process(DT)
		scene.sensors.evaluate()
	if combined:
		# Only the target moves (along its bow, across the rockets' line of fire).
		victim.get_node("Locomotion").move_to(SITE + Vector2(separation, MOVE_LEG))
		for i in HEAD_START:
			scene.get_node("SimClock").time += DT
			victim.get_node("Locomotion")._physics_process(DT)
		scene.sensors.evaluate()
	var ids := {}
	var kinds := {} # ordnance id and node name -> kind
	var target_distance := {} # ordnance id -> distance from the target where it ended
	var windows := {} # ordnance id -> [first tick within 75 u, first tick within 25 u] of the target
	var reloads := {"empty": 0, "idle": 0}
	var reload_ticks := 0 # mount-ticks spent reloading a magazine
	var shots_at := {} # ordnance id -> rounds fired at it
	var engaged := {} # ordnance id -> {firing-authorization reason: mount-ticks engaging it}
	var unengaged := {} # ordnance id -> {reason: mount-ticks within a mount's range, not engaged}
	var first_shot := {} # ordnance id -> its distance from the target at the first round fired at it
	projectiles.ordnance_launched.connect(func(node: Node3D) -> void:
		ids[node.id] = true
		kinds[node.id] = String(node.kind)
		kinds[String(node.name)] = String(node.kind))
	projectiles.ordnance_finished.connect(func(r: Dictionary) -> void:
		target_distance[r.id] = snappedf(Vector2(r.point.x, r.point.z).distance_to(Vector2(victim.global_position.x, victim.global_position.z)), 0.1))
	for w: Node in pdcs:
		w.reload_started.connect(func(_w: Node, cause: String) -> void: reloads[cause] = reloads.get(cause, 0) + 1)
	for w: Node in pdcs:
		w.shot.connect(func(_w: Node, _id: int, target: Node3D, _o: Transform3D) -> void:
			if target != null and is_instance_valid(target) and target.get("id") != null:
				shots_at[target.id] = shots_at.get(target.id, 0) + 1
				if not first_shot.has(target.id):
					first_shot[target.id] = snappedf(target.global_position.distance_to(victim.global_position), 0.1))
	var created := 0
	if diagnose:
		for i in pdcs.size():
			pdcs[i].shot.connect(_diag_shot.bind(i))
	var peak := 0
	var sim_total := 0.0
	var sim_max := 0.0
	var frames: Array[float] = []
	var frame_at_peak := 0.0
	var draws_max := 0
	var draws_at_peak := 0
	var objects_max := 0
	var last_usec := Time.get_ticks_usec()
	var ticks := 0
	var done_ticks := 0
	while ticks < MAX_TICKS:
		var t0 := Time.get_ticks_usec()
		scene.get_node("SimClock").time += DT
		if moving:
			attacker.get_node("Locomotion")._physics_process(DT)
		if moving or combined:
			victim.get_node("Locomotion")._physics_process(DT)
		scene.sensors._physics_process(DT)
		if incoming:
			while created < scenario.salvo and ticks == created * scenario.interval:
				_create_in_flight(scenario, created, rng)
				created += 1
		else:
			if launcher.shots < scenario.salvo:
				launcher.step(DT)
			while combined and created < scenario.missiles and ticks == scenario.missile_start + created * scenario.interval:
				_create_in_flight(scenario, created, rng)
				created += 1
		for w: Node in pdcs:
			w.step(DT)
			if w.reloading():
				reload_ticks += 1
		for node in projectiles.ordnance:
			if node.live and ids.has(node.id):
				var d: float = node.global_position.distance_to(victim.global_position)
				var window: Array = windows.get_or_add(node.id, [-1, -1])
				if window[0] < 0 and d <= 75.0:
					window[0] = ticks
				if window[1] < 0 and d <= 25.0:
					window[1] = ticks
		_classify(pdcs, engaged, unengaged)
		if trace:
			_trace(ticks, pdcs, ids)
		if diagnose:
			_diag_pre(ticks, pdcs)
		projectiles._physics_process(DT)
		if diagnose:
			_diag_post(ticks)
		var sim := (Time.get_ticks_usec() - t0) / 1000.0
		sim_total += sim
		sim_max = maxf(sim_max, sim)
		ticks += 1
		await process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := (now - last_usec) / 1000.0
		last_usec = now
		var active: int = projectiles.active.size()
		if visual:
			frames.append(frame_ms)
			var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			draws_max = maxi(draws_max, draws)
			objects_max = maxi(objects_max, int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
			if active > peak:
				frame_at_peak = frame_ms
				draws_at_peak = draws
		peak = maxi(peak, active)
		var released: int = created if incoming else launcher.shots
		var finished: bool = released >= scenario.salvo and (not combined or created >= scenario.missiles) and projectiles.ordnance.is_empty()
		done_ticks = done_ticks + 1 if finished else 0
		if done_ticks > 90 and projectiles.active.is_empty():
			break
	var result := {"intercepted": 0, "impacts": 0, "other": 0, "other_outcomes": {}, "distances": [], "phases": {}, "notes": [], "collateral": 0, "peak_rounds": peak,
		"rounds": pdcs.reduce(func(n: int, w: Node) -> int: return n + w.shots, 0),
		"ammo": pdcs.reduce(func(n: int, w: Node) -> int: return n + w.capacity() - w.rounds_left(), 0),
		"sim_mean": sim_total / maxi(ticks, 1), "sim_max": sim_max, "reloads": reloads, "reload_ticks": reload_ticks,
		"hull_lost": snappedf(CombatShip.of(victim).max_health - CombatShip.of(victim).health, 0.01),
		"switches": pdcs.reduce(func(n: int, w: Node) -> int: return n + int(w.get("switches") if w.get("switches") != null else 0), 0)}
	# Engaged mount-ticks by firing state over all threats: aiming ("Tracking"), firing, between
	# shots ("Reloading" = cooldown), magazine reload, other.
	var states := {}
	for held: Dictionary in engaged.values():
		for why: String in held:
			states[why] = states.get(why, 0) + held[why]
	result["engaged_states"] = states
	# Outcomes of the target's own rounds (expired = missed and flew to lifetime or travel).
	var round_outcomes := {}
	for r: Dictionary in projectiles.records:
		if r.owner_name == String(victim.name):
			round_outcomes[r.outcome] = round_outcomes.get(r.outcome, 0) + 1
	result["round_outcomes"] = round_outcomes
	result["rounds_in_flight"] = projectiles.active.size()
	if combined:
		result["by_kind"] = _by_kind(ids, kinds, target_distance, windows, shots_at, unengaged)
	var here := Vector2(victim.global_position.x, victim.global_position.z)
	for r: Dictionary in projectiles.ordnance_records:
		if not ids.has(r.id):
			continue
		match r.outcome:
			"intercepted":
				result.intercepted += 1
				result.distances.append(snappedf(Vector2(r.point.x, r.point.z).distance_to(here), 0.1))
				result.phases[r.phase] = result.phases.get(r.phase, 0) + 1
			"damage":
				result.impacts += 1
				result.notes.append(_cause(r, "hit the target", shots_at, engaged, unengaged, first_shot))
			_:
				result.other += 1
				result.other_outcomes[r.outcome] = result.other_outcomes.get(r.outcome, 0) + 1
				result.notes.append(_cause(r, r.outcome, shots_at, engaged, unengaged, first_shot))
	# Rounds that intercepted ordnance other than the threat they were fired at.
	for r: Dictionary in projectiles.records:
		if r.outcome == "intercept" and r.owner_name == String(victim.name) and r.ship != r.target_name:
			result.collateral += 1
	var live: int = ids.size() - (result.intercepted + result.impacts + result.other)
	if live > 0:
		result.other += live
		result.other_outcomes["live"] = live
	if visual:
		var sum := 0.0
		for f in frames:
			sum += f
		result.frame_mean = sum / maxi(frames.size(), 1)
		result.frame_max = frames.max() if not frames.is_empty() else 0.0
		result.frame_at_peak = frame_at_peak
		result.draws_max = draws_max
		result.draws_at_peak = draws_at_peak
		result.objects_max = objects_max
	return result


# Creates salvo member `index` already in flight `scenario.distance` u from the target:
# missiles powered at top speed (homing as usual), rockets committed at cruise speed with
# the Barrage's dispersion. Test setup only.
func _create_in_flight(scenario: Dictionary, index: int, rng: RandomNumberGenerator) -> void:
	var aim := victim.global_position
	var from: Vector3 = aim + Vector3.LEFT * scenario.distance + Vector3.BACK * float(scenario.lateral[index])
	var direction: Vector3 = (aim - from).normalized()
	var config: Resource = scenario.config
	if config.ordnance.kind == &"rocket":
		direction = Weapon.disperse(direction, config.dispersion_max_deg, rng)
	projectiles.launch(attacker, 0, Transform3D(Basis.looking_at(direction, Vector3.UP), from), config, victim)
	var node: Node3D = projectiles.ordnance.back()
	if node.kind == &"rocket":
		node.phase = "flight"
		node.rocket_cruise_direction = direction
		node.velocity = direction * node.config.speed
	else:
		node.phase = "powered"
		node.velocity = direction * node.config.max_speed


# Per live hostile ordnance, per mount within range: engaging it, or why not (outside the
# arc, no solution / obstructed, empty, reloading, on another threat).
func _classify(pdcs: Array, engaged: Dictionary, unengaged: Dictionary) -> void:
	for node in projectiles.ordnance:
		if not node.live or node.faction == 1:
			continue
		for w: Node in pdcs:
			if w.pitch_pivot.global_position.distance_to(node.global_position) > w.config.weapon_range:
				continue
			if w.defense_target == node:
				# Engaged: why the mount holds fire this tick (its firing-authorization reason).
				var held: Dictionary = engaged.get_or_add(node.id, {})
				var why: String = String(w.reason).trim_prefix("Point defense: ").get_slice(" (", 0)
				held[why] = held.get(why, 0) + 1
				continue
			var reason := "on another threat"
			var angles: Vector2 = w.angles_to(node.global_position)
			if absf(angles.x) > deg_to_rad(w.yaw_limit_deg()) or angles.y < deg_to_rad(w.pitch_min_deg()) or angles.y > deg_to_rad(w.pitch_max_deg()):
				reason = "outside arc"
			elif not w.engageable(node):
				reason = "no solution / obstructed"
			elif w.rounds_left() <= 0:
				reason = "empty"
			elif w.reloading():
				reason = "reloading"
			var d: Dictionary = unengaged.get_or_add(node.id, {})
			d[reason] = d.get(reason, 0) + 1


static func _cause(r: Dictionary, what: String, shots_at: Dictionary, engaged: Dictionary, unengaged: Dictionary, first_shot: Dictionary) -> String:
	return "%s %d %s (phase %s, age %.2f s): %d rounds fired at it (first at %s u); engaging mount-ticks by state %s; not engaging %s" % [
		r.kind, r.id, what, r.phase, r.age, shots_at.get(r.id, 0), str(first_shot.get(r.id, "-")), str(engaged.get(r.id, {})), str(unengaged.get(r.id, {}))]


# One line per mount engaging the first missile this tick (trace mode): missile state, the
# mount's current / wanted yaw and pitch, the step actually taken, limits, the solution and
# its change since the last tick, alignment error and the firing reason.
var _last := {}
func _trace(tick: int, pdcs: Array, ids: Dictionary) -> void:
	if ids.is_empty():
		return
	var first: int = ids.keys().min()
	var missile: Node3D = null
	for node in projectiles.ordnance:
		if node.id == first:
			missile = node
	if missile == null:
		return
	for i in pdcs.size():
		var w: Node = pdcs[i]
		if w.defense_target != missile:
			continue
		var key := "%d" % i
		var prev: Dictionary = _last.get(key, {})
		var aim: Vector3 = w.aim_point if w.has_solution else missile.global_position
		var error: float = w._alignment_error(w.muzzle.global_position, aim)
		var angles: Vector2 = w.angles_to(aim)
		var yaw_step: float = rad_to_deg(w.yaw - prev.get("yaw", w.yaw))
		var pitch_step: float = rad_to_deg(w.pitch - prev.get("pitch", w.pitch))
		var aim_shift: float = aim.distance_to(prev.get("aim", aim))
		print("t%03d %s | missile %s d=%.1f v=%s | yaw %.2f->wanted %.2f (step %.3f, limit +-%.0f, %.0f deg/s) pitch %.2f->wanted %.2f (step %.3f, limits %.0f..%.0f) | aim %s angles(yaw %.2f pitch %.2f) shift %.3f solved %s t=%.3f | error %.2f deg | coverage %s | %s | %s" % [
			tick, PDCS[i].trim_suffix("PDCHardpoint"), str(missile.global_position.snapped(Vector3.ONE * 0.01)), missile.global_position.distance_to(victim.global_position),
			str(missile.velocity.snapped(Vector3.ONE * 0.01)), rad_to_deg(w.yaw), rad_to_deg(w.wanted_yaw), yaw_step, w.yaw_limit_deg(), w.config.yaw_speed_deg,
			rad_to_deg(w.pitch), rad_to_deg(w.wanted_pitch), pitch_step, w.pitch_min_deg(), w.pitch_max_deg(), str(aim.snapped(Vector3.ONE * 0.01)),
			rad_to_deg(angles.x), rad_to_deg(angles.y), aim_shift, w.has_solution, w.flight_time, error, w.in_coverage, w.tracking, w.reason])
		_last[key] = {"yaw": w.yaw, "pitch": w.pitch, "aim": aim}


# Combined set: per seed and variant, Wayfarers and rockets separately.
func _combined_report(scenario: Dictionary, seeds: Array) -> void:
	for variant: String in VARIANTS:
		var totals := {}
		for seed: int in seeds:
			var r: Dictionary = await _run(variant, scenario, seed)
			print("  %-10s seed %d: rounds %d, ammo %d; magazine reloads %s, %d mount-ticks reloading; hull lost %.2f; peak active rounds %d; engaged mount-ticks %s; target switches %d; round outcomes %s, %d still in flight" % [
				variant, seed, r.rounds, r.ammo, str(r.reloads), r.reload_ticks, r.hull_lost, r.peak_rounds, str(r.engaged_states), r.switches,
				str(r.round_outcomes), r.rounds_in_flight])
			for kind: String in ["missile", "rocket"]:
				var k: Dictionary = r.by_kind[kind]
				print("      %-7s intercepted %d (remaining distance %s u), impacts %d, other %d; %d never fired at; by a round aimed at a %s %d, at a %s %d; mount-ticks: engaged elsewhere %d, reloading %d, outside arc %d; in 75 u from tick %s, in 25 u from tick %s" % [
					kind, k.intercepted, str(k.distances), k.impacts, k.other, k.zero_fire, "missile", k.collateral_by.missile, "rocket", k.collateral_by.rocket,
					k.busy, k.reloading, k.arc, str(k.window75), str(k.window25)])
				var t: Dictionary = totals.get_or_add(kind, {"intercepted": 0, "impacts": 0, "other": 0, "distances": [], "collateral": 0, "busy": 0, "zero_fire": 0})
				t.intercepted += k.intercepted
				t.impacts += k.impacts
				t.other += k.other
				t.distances.append_array(k.distances)
				t.collateral += k.collateral_by.missile + k.collateral_by.rocket + k.collateral_by.other
				t.busy += k.busy
				t.zero_fire += k.zero_fire
			for note: String in r.notes:
				print("      " + note)
			for key: String in ["rounds", "ammo", "reload_ticks"]:
				totals[key] = totals.get(key, 0) + r[key]
			totals["empty_reloads"] = totals.get("empty_reloads", 0) + r.reloads.get("empty", 0)
			totals["hull_lost"] = totals.get("hull_lost", 0.0) + r.hull_lost
			totals["switches"] = totals.get("switches", 0) + r.switches
			var states: Dictionary = totals.get_or_add("states", {})
			for why: String in r.engaged_states:
				states[why] = states.get(why, 0) + r.engaged_states[why]
		for kind: String in ["missile", "rocket"]:
			var t: Dictionary = totals[kind]
			var mean: float = t.distances.reduce(func(a: float, d: float) -> float: return a + d, 0.0) / maxi(t.distances.size(), 1)
			print("  %-10s total %-7s: %d intercepted (mean remaining %.1f u, %d by rounds aimed at another threat), %d impacts, %d other of %d; %d never fired at; %d mount-ticks engaged elsewhere" % [
				variant, kind, t.intercepted, mean, t.collateral, t.impacts, t.other, (scenario.missiles if kind == "missile" else scenario.salvo) * seeds.size(), t.zero_fire, t.busy])
		print("  %-10s total: %d rounds, %d ammo, %d empty-magazine reloads, %d mount-ticks reloading, hull lost %.2f; engaged mount-ticks %s; target switches %d" % [
			variant, totals.rounds, totals.ammo, totals.empty_reloads, totals.reload_ticks, totals.hull_lost, str(totals.states), totals.switches])


# Per ordnance kind: outcomes, distance from the target at each interception, interceptions by
# rounds aimed at another threat (by the kind that round was aimed at), mount-ticks the
# threat was within a mount's range but that mount was engaged elsewhere / reloading /
# outside its arc, and the first ticks within 75 u and 25 u of the target.
func _by_kind(ids: Dictionary, kinds: Dictionary, target_distance: Dictionary, windows: Dictionary, shots_at: Dictionary, unengaged: Dictionary) -> Dictionary:
	var out := {}
	for kind: String in ["missile", "rocket"]:
		out[kind] = {"intercepted": 0, "impacts": 0, "other": 0, "distances": [], "collateral_by": {"missile": 0, "rocket": 0, "other": 0},
			"busy": 0, "reloading": 0, "arc": 0, "window75": [], "window25": [], "zero_fire": 0}
	for r: Dictionary in projectiles.ordnance_records:
		if not ids.has(r.id):
			continue
		var k: Dictionary = out[r.kind]
		match r.outcome:
			"intercepted":
				k.intercepted += 1
				k.distances.append(target_distance.get(r.id, -1.0))
			"damage":
				k.impacts += 1
			_:
				k.other += 1
		var u: Dictionary = unengaged.get(r.id, {})
		k.busy += u.get("on another threat", 0)
		if shots_at.get(r.id, 0) == 0:
			k.zero_fire += 1
		k.reloading += u.get("reloading", 0)
		k.arc += u.get("outside arc", 0)
		var window: Array = windows.get(r.id, [-1, -1])
		k.window75.append(window[0])
		k.window25.append(window[1])
	for r: Dictionary in projectiles.records:
		if r.outcome != "intercept" or r.owner_name != String(victim.name) or r.ship == r.target_name or not kinds.has(r.ship):
			continue
		var aimed: String = kinds.get(r.target_name, "other")
		out[kinds[r.ship]].collateral_by[aimed] += 1
	return out


# --- Diagnose mode (raid_sweep Wayfarer misses) ---------------------------------------

func _diag_node(id: int) -> Node3D:
	for node in projectiles.ordnance:
		if node.id == id and node.live:
			return node
	return null


# Before the projectile step: selections (burst starts) and the round / missile positions the
# coming step starts from.
func _diag_pre(tick: int, pdcs: Array) -> void:
	for i in pdcs.size():
		var w: Node = pdcs[i]
		var id: int = w.defense_target.id if w.defense_target != null and is_instance_valid(w.defense_target) else -1
		var prev: Array = _diag_selected.get(i, [-1, -1, -1])
		if id != prev[0]:
			if id in DIAGNOSE_IDS:
				_diag_bursts.append({"mount": i, "missile": id, "selected": tick, "first_shot": -1, "rounds": 0, "error_deg": -1.0,
					"ended": -1, "states": {}})
			_diag_selected[i] = [id, tick, -1]
		for b: Dictionary in _diag_bursts:
			if b.mount == i and b.ended < 0 and b.missile == id:
				var why: String = String(w.reason).trim_prefix("Point defense: ").get_slice(" (", 0)
				b.states[why] = b.states.get(why, 0) + 1
			elif b.mount == i and b.ended < 0 and b.missile != id:
				b.ended = tick
	for r: Dictionary in _diag_rounds:
		if r.done:
			continue
		var record := _diag_record(r.id)
		var missile := _diag_node(r.missile)
		if record.is_empty() or missile == null:
			r.done = true
			continue
		r.prev_round = record.position
		r.prev_missile = missile.global_position


# After the projectile step: each live diagnosed round's closest approach to its missile over
# the step (relative motion, as the projectile system sweeps it).
func _diag_post(tick: int) -> void:
	# Missile positions at the end of tick `tick`.
	for id: int in DIAGNOSE_IDS:
		var node := _diag_node(id)
		if node != null:
			var track: Dictionary = _diag_missile.get_or_add(id, {})
			track[tick] = node.global_position
			track["velocity_%d" % tick] = node.velocity
	for r: Dictionary in _diag_rounds:
		if r.done or not r.has("prev_round"):
			continue
		var record := _diag_record(r.id)
		var missile := _diag_node(r.missile)
		if record.is_empty() or missile == null:
			r.done = true
			continue
		var a: Vector3 = r.prev_round - r.prev_missile
		var b: Vector3 = record.position - missile.global_position
		var closest := Geometry3D.get_closest_point_to_segment(Vector3.ZERO, a, b)
		var d := closest.length()
		if d < r.miss:
			r.miss = d
			r.miss_tick = tick
			var axis: Vector3 = missile.velocity.normalized()
			r.miss_along = closest.dot(axis) # + : the round passed ahead of the missile
			r.miss_cross = (closest - axis * r.miss_along).length()


func _diag_record(id: int) -> Dictionary:
	for record: Dictionary in projectiles.active:
		if record.id == id:
			return record
	return {}


func _diag_shot(w: Node, round_id: int, target: Node3D, origin: Transform3D, mount: int) -> void:
	if target == null or not is_instance_valid(target) or target.get("id") == null or not (target.id in DIAGNOSE_IDS):
		return
	var fire_tick := _diag_tick()
	var speed: float = w.config.projectile_speed
	var from := origin.origin
	# The committed prediction at this shot, before and after the shared error.
	var track: Vector3 = w._track_position + w._track_velocity * w._commit_age
	var time := Weapon.intercept_time(from, track, w._track_velocity, speed)
	var predicted: Vector3 = track + w._track_velocity * maxf(time, 0.0)
	# The per-tick (live) solution for comparison.
	var live_time := Weapon.intercept_time(from, target.global_position, target.velocity, speed)
	var live: Vector3 = target.global_position + target.velocity * maxf(live_time, 0.0)
	var error_deg := rad_to_deg(acos(clampf(w._error_cos, -1.0, 1.0)))
	# The round's direction against the barrel (dispersion), the barrel against the aim point
	# (alignment within tolerance) and the aim point against the undeviated prediction.
	var round_velocity: Vector3 = projectiles.active.back().velocity
	var barrel: Vector3 = w.forward()
	var angles := {"align": rad_to_deg(barrel.angle_to(w.aim_point - from)), "dispersion": rad_to_deg(round_velocity.angle_to(barrel)),
		"total": rad_to_deg(round_velocity.angle_to(predicted - from))}
	_diag_rounds.append({"id": round_id, "mount": mount, "missile": target.id, "commit": w.commits, "fire_seq": _diag_rounds.size(),
		"range": from.distance_to(target.global_position), "time": time, "predicted": predicted, "live": live,
		"predicted_vs_live": predicted.distance_to(live), "error_deg": error_deg,
		"error_offset": (w.aim_point - from).normalized().cross((predicted - from).normalized()).length() * from.distance_to(predicted),
		"fire_tick": fire_tick, "miss": INF, "miss_tick": -1, "miss_along": 0.0, "miss_cross": 0.0,
		"done": false, "burst_rounds": 0, "track_age": w._commit_age, "angles": angles})
	var r: Dictionary = _diag_rounds.back()
	for b: Dictionary in _diag_bursts:
		if b.mount == mount and b.ended < 0 and b.missile == target.id:
			b.rounds += 1
			if b.first_shot < 0:
				b.first_shot = fire_tick
			if b.error_deg < 0.0:
				b.error_deg = error_deg
	r.burst = _diag_bursts.size() - 1


# Loop tick being stepped (the clock advances before the step; the head start precedes it).
func _diag_tick() -> int:
	return roundi(scene.get_node("SimClock").time / DT) - HEAD_START - 1


func _diag_report() -> void:
	# Where each missile actually was when each round's predicted intercept time came.
	for r: Dictionary in _diag_rounds:
		# The prediction is made from start-of-tick positions; positions are kept at tick ends.
		var tick: int = r.fire_tick + roundi(r.time / DT) - 1
		var track: Dictionary = _diag_missile.get(r.missile, {})
		if track.has(tick):
			var actual: Vector3 = track[tick]
			var velocity: Vector3 = track["velocity_%d" % tick]
			var delta: Vector3 = actual - r.predicted
			var axis := velocity.normalized()
			r.ahead = delta.dot(axis) # + : the missile was ahead of the prediction (prediction lagged)
			r.cross = (delta - axis * r.ahead).length()
		else:
			r.ahead = NAN
			r.cross = NAN
	for id: int in DIAGNOSE_IDS:
		var rounds := _diag_rounds.filter(func(x: Dictionary) -> bool: return x.missile == id)
		var bursts := _diag_bursts.filter(func(b: Dictionary) -> bool: return b.missile == id)
		var track: Dictionary = _diag_missile.get(id, {})
		print("\nmissile %d: %d selections, %d with rounds fired, %d rounds" % [id, bursts.size(), bursts.filter(func(b: Dictionary) -> bool: return b.rounds > 0).size(), rounds.size()])
		for b: Dictionary in bursts:
			print("  mount %s selected t%d, first shot %s, rounds %d, ended %s, shared error %.2f deg; mount states while selected %s" % [
				PDCS[b.mount].trim_suffix("PDCHardpoint"), b.selected, "t%d" % b.first_shot if b.first_shot >= 0 else "-", b.rounds,
				"t%d" % b.ended if b.ended >= 0 else "-", b.error_deg, str(b.states)])
		for r: Dictionary in rounds:
			print("    round %d (%s, commit %d, %.2f s old): angles off the prediction: barrel-aim %.2f, round-barrel %.2f, total %.2f deg; range %.1f u, flight %.2f s; committed vs live intercept %.2f u; shared error %.2f deg = %.2f u at the intercept; missile at arrival vs prediction: ahead %.2f u, cross %.2f u; closest approach %.2f u (along %.2f, cross %.2f) at t%d" % [
				r.id, PDCS[r.mount].trim_suffix("PDCHardpoint"), r.commit, r.track_age, r.angles.align, r.angles.dispersion, r.angles.total, r.range, r.time, r.predicted_vs_live, r.error_deg, r.error_offset,
				r.ahead, r.cross, r.miss, r.miss_along, r.miss_cross, r.miss_tick])
