extends "res://game/weapons/turret.gd"
## Combat (migrated from the prototype v0.3): Gatling. An articulated rotary mount (turret articulation,
## hardpoint limits) firing individually simulated tracer rounds from a magazine (the
## base weapon's ammunition model: one stock for offense and point defense, one round per
## shot, reload when empty or idle, a started reload always completes).
##
## Each tick it first looks for a point-defense target; only without one does it run the
## ship's offensive engagement (the shared target, strict manual focus). Point defense
## never changes the ship's manual or automatic target; when the threat ends the
## offensive engagement resumes with the rounds left in the magazine (switching targets
## never reloads). Point defense is authorized under every stance.
##
## Threat evaluation (per hostile ordnance, against the carrying ship, then each live ally
## within the defensive radius): from its current position and velocity relative to the
## protected ship,
##   - homing at that ship (its assigned target, still guided): a threat while closing
##     (a missile still in its ejection or orientation stage counts as closing); time to
##     impact = distance / closing speed (missile launch stages: distance / its top speed);
##   - otherwise: a threat only if its straight-line closest approach, still ahead in
##     time, passes within the ship's bounding radius plus its own radius;
##   - in both cases the time to impact must not exceed its remaining flight time.
## Passed (receding) and unreachable ordnance is never selected. A threat is engageable
## when it is within range, has an intercept solution inside the range, lies inside the
## mount's traverse and elevation, and the line from the mount is clear of asteroids, the
## own hull and friendly hulls. Order: threats to the own ship, then to allies, then the
## offensive target; within a category the earliest predicted impact (ordnance id breaks
## ties). The first engageable threat is engaged.

@export var spin_speed := 24.0 # rad/s of the barrel cluster while firing (visual)

var spinner: Node3D
var defense_target: Node3D = null
var defense_category := -1 # 0 own ship, 1 ally
var defense_time := INF # Predicted time to impact of the engaged threat.
var mode := "idle" # idle, offense, defense
var interruptions := 0 # Offense interrupted by point defense.
var defense_shots := 0
var offense_shots := 0
var _spin_left := 0.0


func _build() -> void:
	var parts := WeaponGeometry.build_gatling(self, base_diameter, body_height, barrel_length)
	yaw_pivot = parts.yaw
	pitch_pivot = parts.pitch
	muzzle = parts.muzzle
	spinner = parts.spinner


func step(delta: float) -> void:
	var previous_mode := mode
	defense_target = null
	defense_category = -1
	defense_time = INF
	if enabled and combat.alive and combat.point_defense_authorized and rounds_left() > 0:
		_choose_defense()
	if defense_target == null:
		mode = "offense"
		super.step(delta)
		mode = "offense" if actionable else "idle"
	else:
		if previous_mode == "offense":
			interruptions += 1
		mode = "defense"
		_tick(delta)
		has_solution = _solve(defense_target)
		_track(delta, defense_target)
		var fire := _authorize_shot(defense_target)
		reason = "Point defense: %s (%s)" % [reason, defense_target.name]
		if fire:
			_fire(defense_target)
		_idle_reload(delta)
	_spin_left = maxf(0.0, _spin_left - delta)
	if _spin_left > 0.0:
		spinner.rotation.z = wrapf(spinner.rotation.z + spin_speed * delta, -PI, PI)


func _fire(target: Node3D) -> void:
	if mode == "defense":
		defense_shots += 1
	else:
		offense_shots += 1
	_spin_left = 0.25
	if mode != "defense":
		super._fire(target)
		return
	# Point defense: the same round (deviated like an offensive one; no draw at dispersion
	# 0), no attack registered on a ship.
	var origin := muzzle.global_transform
	var direction := -origin.basis.z.normalized()
	var id := -1
	if combat.projectiles != null:
		var round_direction := disperse(direction, config.dispersion_max_deg, rng)
		id = combat.projectiles.spawn(ship, combat.faction, origin.origin, round_direction * config.projectile_speed,
			config.damage, config.max_travel(), config.projectile_lifetime, target, config.projectile_style,
			config.resolved_penetration(), config.armor_damage)
	_use_round()
	cooldown_left = config.cooldown
	shots += 1
	if combat.effects != null:
		combat.effects.muzzle_flash(origin.origin, direction, CombatShip.FACTION_COLORS[combat.faction], _flash_scale())
	shot.emit(self, id, target, origin)


func _flash_scale() -> float:
	return 0.45


# --- Point defense ----------------------------------------------------------------------

func _choose_defense() -> void:
	var projectiles = combat.projectiles
	if projectiles == null:
		return
	var protected: Array = [[ship, 0]]
	for other: Node in combat.ships_node.get_children():
		if other == ship:
			continue
		var other_combat = CombatShip.of(other)
		if other_combat != null and other_combat.alive and not other_combat.removed_from_play and other_combat.faction == combat.faction \
				and combat.distance_to(other) <= combat.rules.defensive_radius:
			protected.append([other, 1])
	var candidates := []
	for node in projectiles.ordnance:
		if not node.live or node.faction == combat.faction:
			continue
		var best_category := -1
		var best_time := INF
		for entry: Array in protected:
			var time := threat_time(node, entry[0])
			if time < INF and (best_category < 0 or entry[1] < best_category or (entry[1] == best_category and time < best_time)):
				best_category = entry[1]
				best_time = time
		if best_category >= 0:
			candidates.append([best_category, best_time, node.id, node])
	candidates.sort_custom(_defense_before)
	for entry: Array in candidates:
		if engageable(entry[3]):
			defense_target = entry[3]
			defense_category = entry[0]
			defense_time = entry[1]
			return


## Defensive order of two candidates [category, time to impact, ordnance id, ordnance]:
## category, then the earliest predicted impact, then the id (the PDC family overrides it).
func _defense_before(a: Array, b: Array) -> bool:
	return a[0] < b[0] or (a[0] == b[0] and (a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])))


## Predicted seconds until `node` reaches `protected_ship`, or INF when it is not a threat
## to it (receding, passing clear, or out of flight time).
static func threat_time(node: Node3D, protected_ship: Node3D) -> float:
	var combat = CombatShip.of(protected_ship)
	if combat == null or not node.live:
		return INF
	var offset: Vector3 = node.global_position - protected_ship.global_position
	var relative: Vector3 = node.velocity - combat.velocity()
	var distance := offset.length()
	var time := INF
	if node.target == protected_ship and node.homing():
		if node.kind == &"missile" and node.launching():
			time = distance / maxf(node.config.max_speed, 0.001)
		else:
			var closing := -offset.dot(relative) / maxf(distance, 0.001)
			if closing <= 0.05:
				return INF
			time = distance / closing
	else:
		var a := relative.dot(relative)
		if a < 0.000001:
			return INF
		var closest_time := -offset.dot(relative) / a
		if closest_time <= 0.0:
			return INF
		if (offset + relative * closest_time).length() > combat.bounds_radius + node.config.radius:
			return INF
		time = closest_time
	return time if time <= node.remaining_time() else INF


## Whether this mount can engage `node` now: range, intercept inside the range, inside
## its traverse and elevation, clear line from the mount.
func engageable(node: Node3D) -> bool:
	var origin := pitch_pivot.global_position
	if origin.distance_to(node.global_position) > config.weapon_range:
		return false
	var time := intercept_time(origin, node.global_position, node.velocity, config.projectile_speed)
	if time <= 0.0 or time > config.projectile_lifetime:
		return false
	var point: Vector3 = node.global_position + node.velocity * time
	if origin.distance_to(point) > config.weapon_range:
		return false
	var angles := angles_to(point)
	if absf(angles.x) > deg_to_rad(yaw_limit_deg()) or angles.y < deg_to_rad(pitch_min_deg()) or angles.y > deg_to_rad(pitch_max_deg()):
		return false
	return _path_blocker(origin, point, null) == ""

