extends Node
## Commands, Tactics and Weapon Profiles for one armed ship (node `Behavior`, in the
## Gunship and Destroyer variants; migrated from the behavior prototype v0.1 accepted in
## P01–P03 and E05). Friendly and hostile ships run the same code; a hostile ship's
## commands come from its commander. It never moves, turns or fires the ship itself: it
## decides movement intentions and hands them to the existing systems — a point through
## the scene's autonomous_move() (one RouteFollower order: Avoidance, Locomotion and
## PlanarCollision execute it; no assignment is cancelled and it is not a player command)
## or an idle turn through Locomotion.face() — and it sets the Attack authorization on the
## ship's Combat. Weapons keep their own full firing authorization.
##
## Precedence (highest first):
##   1 Commands (player or script; CombatOrders): Move (the scene's `command_given` for a
##     MOVE executed for this ship — a right-click, a group MOVE, CombatOrders.move(), or
##     one held during station control when it is released; also any other RouteFollower
##     order this node did not give), Attack, Guard, Attack-Move,
##     Waypoint Move, Dock (detected from the ship's Docking node, when it has one),
##     Cancel. A command replaces the previous one; Move, Attack, Attack-Move, Waypoint
##     Move, Dock and Cancel end Guard for good. During a Move or Waypoint Move the layer
##     gives no movement but the legs (weapons fire as the tactic allows); an Attack-Move
##     may break off for an Aggressive encounter within its leash. A command clears only
##     the state it owns (the Attack's manual target only if the Attack set it).
##   2 Tactic (the ship's stance; never changed here), only without a command:
##     Aggressive pursues its target (manual, automatic, else the nearest hostile in
##     contact) while in contact; Defensive keeps the defended area around the point where
##     it became idle (local firing positions only, never a pursuit); Hold Fire (Passive)
##     does nothing.
##   3 Weapon Profile: where Aggressive pursuit and Attack hold their target (band), and
##     the idle turn that brings a weapon's arc onto it. Never under Guard or a Move.
## Decisions every DECISION_INTERVAL; a new movement request only when the wanted point
## moved by more than a tolerance, and not more often than MIN_ORDER_INTERVAL.
## Information: only targets in the faction's contact (Combat.target_status() VALID); a
## lost Attack target leaves only its last position seen while in contact.

const CombatShip := preload("res://game/combat/combat_ship.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const Profiles := preload("res://game/behavior/weapon_profiles.gd")
const Docking := preload("res://game/stations/docking.gd")
const CombatObstacles := preload("res://game/combat/combat_obstacles.gd")
const TS := CombatShip.TargetState

enum Command { NONE, MOVE, ATTACK, GUARD, ATTACK_MOVE, WAYPOINTS, DOCK }

const COMMAND_NAMES := ["None", "Move", "Attack", "Guard", "Attack-Move", "Waypoint Move", "Dock"]
const ATTACK_MOVE_LEASH := 30.0 # u an Attack-Move encounter position may lie off its planned route
const ARRIVAL := 1.5 # u from a resolved destination that counts as arrived (Attack-Move, waypoints)
const DECISION_INTERVAL := 0.5 # s
const MIN_ORDER_INTERVAL := 1.0 # s between two movement requests (engagement, defense)
const RESTATION := 8.0 # u an engagement station must move before it is requested again
const MAP_LIMIT := 135.0 # u from the centre on each axis
const ROCK_CLEARANCE := 3.0 # u between a footprint and an asteroid
const SIGHT_MARGIN := 0.5 # u added to asteroid radii for a line of fire
const ROTATION_STEP := 15.0 # ° between engagement stations tried around the target
const MAX_ROTATION := 120.0 # °
const FALLBACK_HOLD := 5.0 # s a profile without a reachable station is skipped
const MAX_FALLBACK_HOLD := 40.0 # s
const MAX_RETREATS := 3 # open-range requests in a row (each within RETREAT_WINDOW) before falling back
const RETREAT_WINDOW := 4.0 # s
const RETREAT_REACH := 30.0 # u: a standoff position farther from the ship is not pursued (cornered)
const HEADING_TOLERANCE := 5.0 # °
## Defensive (provisional, to be tuned in play).
const DEFENSE_RADIUS := 12.0 # u around the anchor a defender may reposition within
const DEFENSE_RINGS := [4.0, 8.0, 12.0] # u, candidate firing positions around the anchor
const DEFENSE_DIRECTIONS := 12
const RETURN_DELAY := 3.0 # s without a threat before it returns to the anchor
const ANCHOR_TOLERANCE := 2.0 # u
## Guard (provisional).
const GUARD_BUFFER := 4.0 # u between the guard's and the protected ship's hulls at a guard position
const GUARD_SEPARATION := 1.5 # u between two guards' hulls at their positions (avoidance keeps 1)
const GUARD_SLOTS := [90.0, -90.0, 135.0, -135.0, 45.0, -45.0, 180.0] # ° from the protected bow (+ = left)
const GUARD_LEAD := 2.0 # s ahead along the protected ship's velocity
const GUARD_RESTATION := 3.0 # u
const GUARD_ORDER_INTERVAL := 0.5 # s
const GUARD_BLOCKED := 1.0 # s a position must stay unusable before another is chosen
const GUARD_CHOICE_MARGIN := 4.0 # u of extra asteroid clearance a newly chosen position needs
const GUARD_NEAR := 6.0 # u beyond the guard distance that still counts as useful proximity
const INVESTIGATE_ARRIVAL := 6.0 # u

var command := Command.NONE
var requested_profile := Profiles.Profile.SIEGE
var effective_profile := -1
var fallback_reason := ""
var guard_target: Node3D = null
var guard_slot := -1
var attack_target: Node3D = null
var last_known := Vector2.ZERO # Attack: where the target was last seen in contact.
var has_last_known := false
var investigating := false
var anchor := Vector2.ZERO # Defensive: the defended position.
var has_anchor := false
var station := Vector2.ZERO # The last movement request of this layer (the point asked for).
var has_station := false
var _resolved := Vector2.ZERO # Where that request was resolved to (an occupied point moves it).
var destination := Vector2.ZERO # Attack-Move: the objective.
var waypoints: Array[Vector2] = [] # Waypoint Move: the legs still to fly (the first is under way).
var waypoint_offset := Vector2.ZERO # Waypoint Move in a group: this ship's spot minus the clicked point.
var encounter: Node3D = null # Attack-Move: the enemy it is engaging on the way.
var _route_start := Vector2.ZERO
var _route_resolved := Vector2.ZERO
var _route := PackedVector2Array() # Attack-Move: the route last planned to the destination.
var _owns_target := false # The Attack set the manual target (and clears it when it ends).
var _pursued: Node3D = null # The target of the last engagement request (Aggressive pursuit).
var log: Array[String] = []
# Measurements.
var move_requests := 0
var heading_requests := 0
var direction_changes := 0 # approach <-> open-range reversals
var reposition_requests := 0 # Defensive local firing positions
var guard_reassignments := 0
var fallbacks: Array[String] = []
var firing_time := 0.0 # s with a valid firing opportunity (a weapon in state Valid)
var max_anchor_distance := 0.0
var guard_time := 0.0 # s under Guard
var guard_near_time := 0.0 # s of it within useful proximity

var _clock := 0.0
var _plans_seen := 0
var _own_request := Vector2.INF
var _last_order := -INF
var _last_heading := INF
var _direction := 0
var _blocked_until := {} # profile -> time
var _block_reason := {} # profile -> why it is skipped
var _block_hold := {} # profile -> current skip duration (s)
var _retreats := 0
var _last_retreat := -INF
var _last_threat := -INF
var _slot_blocked := 0.0
var _last_stance := -1

@onready var ship := get_parent() as Node3D
@onready var combat = ship.get_node("Combat")
@onready var locomotion = ship.get_node("Locomotion")
@onready var follower = ship.get_node("RouteFollower") as RouteFollower
@onready var arena := ship.get_parent().get_parent()
@onready var asteroids = arena.get_node_or_null("Asteroids")


static func of(node: Variant):
	if node == null or not is_instance_valid(node):
		return null
	return (node as Node).get_node_or_null("Behavior")


func _ready() -> void:
	process_physics_priority = -3 # After the sensors, before scripted orders, RouteFollower and Locomotion.
	_plans_seen = follower.plans
	var available := Profiles.available(combat)
	if not available.is_empty():
		requested_profile = available[0]
	_last_stance = combat.stance
	if arena.has_signal("command_given"):
		arena.command_given.connect(_on_command_given)


## The scene executed a player command for a ship (right-click, group MOVE,
## CombatOrders.move(), or a command held during station control when it is released). A
## MOVE for this ship is the player's Move: it replaces the current command at once (also
## while paused). A Dock is picked up from the Docking state.
func _on_command_given(target: Node3D, kind: int) -> void:
	if target != ship or not combat.alive:
		return
	_plans_seen = follower.plans
	if kind == arena.CommandKind.MOVE or kind == arena.CommandKind.GROUP_MOVE:
		_replace("Move")
		command = Command.MOVE
		_note("move to (%.0f, %.0f)" % [follower.requested.x, follower.requested.y])
	elif kind == arena.CommandKind.DOCK:
		_detect_docking()


func now() -> float:
	return CombatShip.now()


# --- Commands (CombatOrders is the caller) -------------------------------------------

## Attack: owns the Attack authorization and, unless the ship already had that manual
## target, the manual target it sets (only what it owns is cleared when it ends).
func order_attack(target: Node3D) -> bool:
	if not combat.alive or not combat.is_hostile_to(target) or combat.target_status(target) in [TS.INVALID, TS.DESTROYED]:
		return false
	_replace("Attack")
	command = Command.ATTACK
	attack_target = target
	combat.attack_target = target
	_owns_target = combat.manual_target != target
	combat.assign_target(target)
	has_last_known = false
	investigating = false
	_note_contact()
	_note("attack %s" % target.name)
	_clock = 0.0
	return true


func order_guard(target: Node3D) -> bool:
	var other = CombatShip.of(target)
	if not combat.alive or target == ship or other == null or not other.alive or other.faction != combat.faction:
		return false
	_replace("Guard")
	command = Command.GUARD
	guard_target = target
	if not other.destroyed.is_connected(_on_protected_destroyed):
		other.destroyed.connect(_on_protected_destroyed)
	guard_slot = _choose_slot(-1)
	_slot_blocked = 0.0
	_note("guard %s (slot %s)" % [target.name, _slot_name(guard_slot)])
	_clock = 0.0
	return true


## Attack-Move: the destination stays the objective. Aggressive: an enemy met on the way
## (its current target in contact) may interrupt travel for engagement positioning, but
## only at positions within ATTACK_MOVE_LEASH of its current planned route; when the encounter
## ends (destroyed, contact lost, no position within the leash) it travels on. Defensive
## and Passive travel on (their weapons fire as the tactic allows).
func order_attack_move(point: Vector2) -> bool:
	if not combat.alive:
		return false
	_replace("Attack-Move")
	_route_start = _here()
	destination = point
	if not _request_move(point, "attack-move destination"):
		return false
	_route_resolved = _resolved
	_route = follower.route.duplicate()
	command = Command.ATTACK_MOVE
	return true


## Waypoint Move: `append` adds to a sequence under way, otherwise a new sequence replaces
## the current command. Each leg is an ordinary move; the next is requested on arrival.
func order_waypoint(point: Vector2, append: bool) -> bool:
	if not combat.alive:
		return false
	if append and command == Command.WAYPOINTS:
		waypoints.append(point)
		_note("waypoint %d (%.0f, %.0f) added" % [waypoints.size(), point.x, point.y])
		return true
	_replace("Waypoint Move")
	waypoints = [point]
	command = Command.WAYPOINTS
	if not _request_move(point, "waypoint 1"):
		_end_command("waypoint unreachable")
		return false
	return true


## Dock as a request without a station (combat ships carry the production Docking
## component, but no combat map has a station): its replacement of the current command
## only. A real dock request (the scene's existing Dock command on a station) is picked up
## from the ship's Docking node every tick (_detect_docking()).
func request_replacement(kind: String) -> bool:
	if not combat.alive:
		return false
	_replace(kind)
	_note("%s requested (replacement only)" % kind)
	return true


## Cancel: the command and everything it owns end (Guard, the Attack's target, waypoints);
## a ship under way brakes to a stop; tactic and profile stay.
func order_cancel() -> bool:
	if not combat.alive:
		return false
	_replace("Cancel")
	_stop()
	return true


func set_profile(profile: int) -> bool:
	if not Profiles.available(combat).has(profile):
		return false
	requested_profile = profile
	_blocked_until.clear()
	_note("profile %s" % Profiles.NAMES[profile])
	return true


# --- Tick ----------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not combat.alive:
		if command != Command.NONE:
			_end_command("ship destroyed")
		return
	_detect_docking()
	if command == Command.DOCK:
		return # The station's docking process has movement authority.
	sync()
	if command == Command.GUARD and not _guard_target_valid():
		_end_guard("protected ship destroyed or invalid")
		_stop()
	if command == Command.ATTACK:
		if is_instance_valid(attack_target) and combat.manual_target != attack_target and not (combat.target_status(attack_target) in [TS.INVALID, TS.DESTROYED]):
			_owns_target = false # Assigned or cleared independently: that assignment stays.
			_end_attack("target assignment changed")
		else:
			_note_contact()
	if command == Command.MOVE and not _moving():
		_end_command("arrived")
	if command == Command.WAYPOINTS:
		_advance_waypoints()
	if combat.stance != _last_stance:
		_last_stance = combat.stance
		if command == Command.NONE:
			_set_anchor()
	_measure(delta)
	_clock -= delta
	if _clock > 0.000001:
		return
	_clock += DECISION_INTERVAL
	match command:
		Command.NONE:
			if combat.stance == CombatShip.Stance.AGGRESSIVE:
				var target := _pursuit_target()
				if target == null and _moving() and is_instance_valid(_pursued) and combat.target_status(_pursued) == TS.CONTACT_LOST:
					_note("contact lost with %s: pursuit stopped" % _pursued.name)
					_pursued = null
					_stop() # No hidden position is followed.
				_engage(target)
			elif combat.stance == CombatShip.Stance.DEFENSIVE:
				_defend()
		Command.ATTACK:
			_attack()
		Command.GUARD:
			_guard()
		Command.ATTACK_MOVE:
			_attack_move()


## Picks up a RouteFollower order given outside this layer and not announced as a
## command (a direct order from a script or test): treated as a Move, as before. Player
## commands arrive through _on_command_given().
func sync() -> void:
	_detect_external_order()


# A RouteFollower plan this node did not request (and no command announced) is a Move: it
# replaces the current command.
func _detect_external_order() -> void:
	if follower.plans == _plans_seen:
		return
	_plans_seen = follower.plans
	if follower.requested.distance_to(_own_request) <= 0.001 and follower.status != RouteFollower.RouteStatus.WAITING:
		return # A refused plan: nothing changed.
	_replace("Move")
	command = Command.MOVE
	_note("move to (%.0f, %.0f)" % [follower.requested.x, follower.requested.y])


func _moving() -> bool:
	return locomotion.has_destination or follower.status == RouteFollower.RouteStatus.WAITING


func _measure(delta: float) -> void:
	var target: Node3D = combat.target
	if target != null and combat.target_status(target) == TS.VALID:
		for weapon in combat.weapons:
			if weapon.state == TS.VALID:
				firing_time += delta
				break
	if command == Command.NONE and combat.stance == CombatShip.Stance.DEFENSIVE and has_anchor:
		max_anchor_distance = maxf(max_anchor_distance, _here().distance_to(anchor))
	if command == Command.GUARD:
		guard_time += delta
		if _here().distance_to(_planar(guard_target)) <= guard_distance() + GUARD_NEAR:
			guard_near_time += delta


# --- Command bookkeeping ---------------------------------------------------------------

# A new command replaces the current one (Guard and Attack end for good).
func _replace(by: String) -> void:
	if command == Command.GUARD:
		_end_guard("canceled by %s" % by)
	elif command == Command.ATTACK:
		_end_attack("replaced by %s" % by)
	elif command != Command.NONE:
		_note("%s replaced by %s" % [COMMAND_NAMES[command], by])
	command = Command.NONE
	waypoints.clear()
	encounter = null
	has_anchor = false
	has_station = false


func _end_command(why: String) -> void:
	if command == Command.GUARD:
		_end_guard(why)
	elif command == Command.ATTACK:
		_end_attack(why)
	else:
		_note("%s ended: %s" % [COMMAND_NAMES[command], why])
	command = Command.NONE
	waypoints.clear()
	encounter = null
	has_station = false
	_set_anchor()


func _end_guard(why: String) -> void:
	_note("guard ended: %s" % why)
	guard_target = null
	guard_slot = -1
	command = Command.NONE
	_set_anchor()


# The Attack's authorization and the manual target it set end with it.
func _end_attack(why: String) -> void:
	_note("attack ended: %s" % why)
	if is_instance_valid(attack_target):
		if combat.attack_target == attack_target:
			combat.attack_target = null
		if _owns_target and combat.manual_target == attack_target:
			combat.clear_target()
	attack_target = null
	_owns_target = false
	investigating = false
	has_last_known = false
	command = Command.NONE
	_set_anchor()


func _set_anchor() -> void:
	anchor = _here()
	has_anchor = true
	_last_threat = now()


# Stops a ship that is under way: one request to its braking point ahead.
func _stop() -> void:
	if not _moving():
		return
	var speed: float = locomotion.velocity.length()
	var point := _here()
	if speed > 0.05:
		var braking := 0.9 * float(locomotion.forward_accel if locomotion.local_velocity().x < 0.0 else locomotion.reverse_accel)
		point += locomotion.velocity / speed * (speed * speed / (2.0 * maxf(braking, 0.05)))
	_request_move(point, "stop")
	has_station = false
	_set_anchor()
	anchor = point # Where it comes to rest.


# --- Movement requests -----------------------------------------------------------------

## The one way this layer moves the ship: the scene's autonomous_move() (not a command).
func _request_move(point: Vector2, why: String) -> bool:
	if not arena.has_method("autonomous_move"):
		return false # A scene without the production command layer: the layer stays passive.
	_own_request = point
	arena.autonomous_move(ship, point)
	# As the accepted prototype read it: the ship is under way (this order, or the one it
	# had when this one was refused).
	var given: bool = locomotion.has_destination or follower.status == RouteFollower.RouteStatus.WAITING
	_plans_seen = follower.plans
	_own_request = follower.requested
	if not given:
		return false
	station = point
	_resolved = locomotion.destination if locomotion.has_destination else point
	has_station = true
	_last_order = now()
	move_requests += 1
	_note("request (%.0f, %.0f): %s" % [station.x, station.y, why])
	return true


## Idle turn toward `heading` (Locomotion.face(); refused while moving or locked).
func _request_heading(heading: float) -> void:
	if _moving() or locomotion.guided:
		return
	var error: float = absf(wrapf(heading - locomotion.heading, -PI, PI))
	if error <= deg_to_rad(HEADING_TOLERANCE):
		return
	if absf(wrapf(heading - _last_heading, -PI, PI)) <= deg_to_rad(HEADING_TOLERANCE) and absf(locomotion.angular_velocity) > 0.001:
		return # Already turning there.
	if locomotion.face(heading):
		_last_heading = heading
		heading_requests += 1


# --- Engagement (Aggressive pursuit, Attack) ---------------------------------------------

# Aggressive without a command: its manual target, else its current target, else the
# nearest hostile in the faction's contact (movement objective only; Combat acquires).
func _pursuit_target() -> Node3D:
	for candidate: Node3D in [combat.manual_target, combat.target]:
		if candidate != null and combat.target_status(candidate) == TS.VALID:
			return candidate
	var best: Node3D = null
	var best_distance := INF
	for other: Node in arena.get_node("Ships").get_children():
		if other != ship and combat.target_status(other) == TS.VALID and combat.distance_to(other) < best_distance:
			best = other
			best_distance = combat.distance_to(other)
	return best


## Holds `target` in the effective profile's band: approach beyond the band (unless one
## of the profile's weapons can already engage, or the target is within their reach with
## a clear line, where a turn does), open the distance inside it, otherwise stay and turn
## a weapon's arc onto it. A standoff position more than RETREAT_REACH away, or repeated
## retreats that do not restore the band, make the next profile take over for a while.
## `on_route` (Attack-Move): positions only within ATTACK_MOVE_LEASH of the route, and
## travel goes on when none is needed or allowed. Returns whether the ship is engaging
## (holding or moving for the target) rather than travelling.
func _engage(target: Node3D, on_route := false) -> bool:
	if target == null or combat.target_status(target) != TS.VALID:
		return false
	var profile := effective()
	if profile < 0:
		return false
	var band := Profiles.band(combat, profile)
	var here := _here()
	var there := _planar(target)
	var distance := here.distance_to(there)
	var need := 0
	if distance < band.near:
		need = -1
	elif distance > band.far and not _capable(Profiles.usable(combat, profile), target) \
			and (distance > band.reach - Profiles.RANGE_MARGIN or not line_clear(here, there)):
		need = 1 # Beyond reach or blocked; within reach a turn is enough.
	var travelling: bool = on_route and _moving() and _on_route()
	if need == 0:
		if travelling:
			return false # Fires on the way.
		if not _moving():
			_orient(target, Profiles.usable(combat, profile))
		return true
	if _moving() and has_station and not _on_route() and _station_ok(station, there, band):
		return true # The position under way still works.
	if now() - _last_order < MIN_ORDER_INTERVAL - 0.000001:
		return not travelling
	var stations := _stations(there, here, band.station)
	if stations.is_empty():
		_position_fallback(profile, "no reachable position")
		return false
	if on_route:
		stations = stations.filter(func(point: Vector2) -> bool: return _route_offset(point) <= ATTACK_MOVE_LEASH)
		if stations.is_empty():
			return false # Off the leash: travel on.
	if need < 0 and stations[0].distance_to(here) > RETREAT_REACH:
		_position_fallback(profile, "no standoff position nearby")
		return false
	if need < 0:
		# Opening the range again while the last retreat has not restored the band: the
		# target is faster or the ship is cornered; the next profile is tried instead.
		_retreats = _retreats + 1 if now() - _last_retreat <= RETREAT_WINDOW else 1
		_last_retreat = now()
		if _retreats > MAX_RETREATS:
			_retreats = 0
			_position_fallback(profile, "standoff not held")
			return false
	for point: Vector2 in stations:
		var why := "%s %s at %.0f u (%s band %.0f-%.0f u)" % ["approach" if need > 0 else "open range from", target.name, distance, Profiles.NAMES[profile], band.near, band.far]
		if _request_move(point, why):
			if _direction != 0 and need != _direction:
				direction_changes += 1
			_direction = need
			_pursued = target
			return true
	_position_fallback(profile, "no reachable position")
	return false


# --- Attack-Move and Waypoint Move ---------------------------------------------------------

func _attack_move() -> void:
	var enemy: Node3D = null
	if combat.stance == CombatShip.Stance.AGGRESSIVE and combat.target != null \
			and combat.target_status(combat.target) == TS.VALID and combat.stance_allows(combat.target) == TS.VALID:
		enemy = combat.target
	if enemy != null and _engage(enemy, true):
		if encounter != enemy:
			_note("encounter with %s on the way" % enemy.name)
		encounter = enemy
		return
	if encounter != null:
		_note("encounter ended: travel on")
		encounter = null
	if not _moving() and _here().distance_to(_route_resolved) <= ARRIVAL:
		_end_command("arrived")
		return
	if (_moving() and _on_route()) or now() - _last_order < MIN_ORDER_INTERVAL - 0.000001:
		return
	if _request_move(destination, "resume attack-move to (%.0f, %.0f)" % [destination.x, destination.y]):
		_route_resolved = _resolved
		_route = follower.route.duplicate() # The route now planned from here.
	else:
		_end_command("destination unreachable")


# The current request of this layer is the Attack-Move destination.
func _on_route() -> bool:
	return has_station and station.distance_to(destination) < 0.01


## Distance of a point from the Attack-Move's route: the RouteFollower route planned for its
## destination (the straight line from the start until one exists).
func _route_offset(point: Vector2) -> float:
	if _route.size() < 2:
		return Geometry2D.get_closest_point_to_segment(point, _route_start, destination).distance_to(point)
	var best := INF
	for i in _route.size() - 1:
		best = minf(best, Geometry2D.get_closest_point_to_segment(point, _route[i], _route[i + 1]).distance_to(point))
	return best


# Waypoint Move: on arrival at the current leg, the next one; the last ends the command.
func _advance_waypoints() -> void:
	if _moving() or _here().distance_to(_resolved) > ARRIVAL:
		return
	waypoints.remove_at(0)
	if waypoints.is_empty():
		_end_command("last waypoint reached")
		return
	if not _request_move(waypoints[0], "waypoint (%d left)" % waypoints.size()):
		_note("waypoint (%.0f, %.0f) unreachable: skipped" % [waypoints[0].x, waypoints[0].y])
		_resolved = _here() # Treated as reached: the next leg follows.


# Docking (the ship's production Docking node, when it has one): from the dock request
# until it is cancelled or refused, the command is Dock and the layer requests nothing
# (the docking process owns the movement); Guard ends.
func _detect_docking() -> void:
	var docking := ship.get_node_or_null("Docking")
	if docking == null:
		return
	var docked: bool = docking.under_control() or not (docking.state in [Docking.State.NONE, Docking.State.UNABLE])
	if docked and command != Command.DOCK:
		_replace("Dock")
		command = Command.DOCK
		_note("docking: movement handed to the station")
	elif not docked and command == Command.DOCK:
		command = Command.NONE
		_plans_seen = follower.plans
		_set_anchor()
		_note("docking ended")


## The profile has no usable position: skipped for FALLBACK_HOLD, doubled each time it
## fails again right after being retried (at most MAX_FALLBACK_HOLD).
func _position_fallback(profile: int, why: String) -> void:
	var again: bool = now() - _blocked_until.get(profile, -INF) <= DECISION_INTERVAL * 2.0 + 0.000001
	_block_hold[profile] = minf(_block_hold.get(profile, FALLBACK_HOLD) * 2.0, MAX_FALLBACK_HOLD) if again else FALLBACK_HOLD
	_blocked_until[profile] = now() + _block_hold[profile]
	_block_reason[profile] = why


# A station still serves: in the band from the target's current position, on the map,
# clear of asteroids, with a clear line of fire.
func _station_ok(point: Vector2, there: Vector2, band: Dictionary) -> bool:
	var distance := point.distance_to(there)
	return distance >= band.near and distance <= band.far and _position_ok(point) and line_clear(point, there)


func _attack() -> void:
	var target := attack_target
	if not is_instance_valid(target) or combat.target_status(target) in [TS.INVALID, TS.DESTROYED, TS.NOT_HOSTILE]:
		_end_attack("target destroyed or invalid")
		return
	if combat.target_status(target) == TS.VALID:
		if investigating:
			_note("contact reacquired: %s" % target.name)
		investigating = false
		_engage(target)
		return
	if not has_last_known:
		_end_attack("contact lost, no last known position")
		return
	if not investigating:
		investigating = true
		if not _request_move(last_known, "investigate last known position of %s" % target.name):
			_end_attack("last known position unreachable")
		return
	if _here().distance_to(last_known) <= INVESTIGATE_ARRIVAL or not _moving():
		_end_attack("not reacquired at the last known position")
		_stop()


func _note_contact() -> void:
	if is_instance_valid(attack_target) and combat.target_status(attack_target) == TS.VALID:
		last_known = _planar(attack_target)
		has_last_known = true


## Effective profile now: the requested one if it can still fire and has had a reachable
## station, else the next in fallback order. Records every change with its reason.
func effective() -> int:
	var chosen := -1
	var reason := ""
	for profile: int in Profiles.fallback_order(requested_profile):
		if Profiles.usable(combat, profile).is_empty():
			if profile == requested_profile:
				reason = "no ammunition"
			continue
		if _blocked_until.get(profile, -INF) > now():
			if profile == requested_profile:
				reason = _block_reason.get(profile, "no reachable position")
			continue
		chosen = profile
		break
	if chosen < 0:
		for profile: int in Profiles.fallback_order(requested_profile):
			if not Profiles.usable(combat, profile).is_empty():
				chosen = profile
				break
	if chosen != effective_profile:
		var text := "%s -> %s" % ["none" if effective_profile < 0 else Profiles.NAMES[effective_profile], "none" if chosen < 0 else Profiles.NAMES[chosen]]
		if chosen != requested_profile and reason != "":
			text += " (%s)" % reason
		fallbacks.append("%.1f %s" % [now(), text])
		_note("profile " + text)
	effective_profile = chosen
	fallback_reason = reason if chosen != requested_profile else ""
	return chosen


func _capable(weapons: Array, target: Node3D) -> bool:
	for weapon in weapons:
		if weapon.assess(target).capable:
			return true
	return false


# Idle turn: when none of `weapons` covers the target, the heading that brings the
# nearest one's mount onto it (its mount's yaw in the ship frame).
func _orient(target: Node3D, weapons: Array) -> void:
	if weapons.is_empty():
		return
	for weapon in weapons:
		if weapon.assess(target).state != TS.OUTSIDE_ARC:
			return
	var bearing: float = locomotion.bearing_heading(_planar(target) - _here())
	var best := INF
	var best_heading := 0.0
	for weapon in weapons:
		var mount: Node3D = weapon.hardpoint if weapon.hardpoint != null else weapon
		var local := ship.global_basis.inverse() * mount.global_basis
		var heading := wrapf(bearing - local.get_euler().y, -PI, PI)
		var turn := absf(wrapf(heading - locomotion.heading, -PI, PI))
		if turn < best:
			best = turn
			best_heading = heading
	_request_heading(best_heading)


# Stations at `distance` from the target around the line target -> ship, rotated by up to
# ±MAX_ROTATION in ROTATION_STEP steps: on the map, clear of asteroids, clear line of
# fire; nearest to the ship first.
func _stations(target: Vector2, here: Vector2, distance: float) -> Array[Vector2]:
	var found: Array[Vector2] = []
	var axis := (here - target).normalized() if here.distance_to(target) > 0.01 else Vector2.RIGHT
	var steps := int(MAX_ROTATION / ROTATION_STEP)
	for k in range(-steps, steps + 1):
		var point := target + axis.rotated(deg_to_rad(ROTATION_STEP * k)) * distance
		if _position_ok(point) and line_clear(point, target):
			found.append(point)
	found.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.distance_to(here) < b.distance_to(here))
	return found


# --- Defensive ---------------------------------------------------------------------------

## Defended area: answer confirmed attackers in contact from the anchor; when no weapon
## can engage the target from here, turn (outside the arcs) or, when the line of fire is
## obscured, move to the nearest firing position within DEFENSE_RADIUS of the anchor
## (none: stay). An attacker out of range is not approached; nothing is pursued. After
## RETURN_DELAY without a threat, back to the anchor.
func _defend() -> void:
	if not has_anchor:
		_set_anchor()
	var target: Node3D = combat.target
	var engaged: bool = target != null and combat.target_status(target) == TS.VALID and combat.stance_allows(target) == TS.VALID
	if not engaged:
		if now() - _last_threat >= RETURN_DELAY and not _moving() and _here().distance_to(anchor) > ANCHOR_TOLERANCE \
				and now() - _last_order >= MIN_ORDER_INTERVAL:
			_request_move(anchor, "return to the defended position")
		return
	_last_threat = now()
	var weapons: Array = combat.weapons.filter(func(weapon: Node) -> bool: return weapon.offensive_reach() > 0.0)
	if _capable(weapons, target):
		return
	var states := weapons.map(func(weapon: Node) -> int: return weapon.assess(target).state)
	if states.has(TS.OUTSIDE_ARC) and not states.has(TS.OBSCURED):
		if not _moving():
			_orient(target, weapons)
		return
	if not states.has(TS.OBSCURED):
		return # Out of range: a defender does not close the distance.
	if _moving() and has_station and _firing_position_ok(station, target, weapons):
		return # On the way to a position that still works.
	if now() - _last_order < MIN_ORDER_INTERVAL - 0.000001:
		return
	var point: Variant = _firing_position(target, weapons)
	if point == null or (point as Vector2).distance_to(_here()) < 1.0:
		return
	if _request_move(point, "firing position on %s" % target.name):
		reposition_requests += 1


func _firing_position(target: Node3D, weapons: Array) -> Variant:
	var here := _here()
	var best: Variant = null
	var best_distance := INF
	var points: Array[Vector2] = [anchor]
	for ring: float in DEFENSE_RINGS:
		for i in DEFENSE_DIRECTIONS:
			points.append(anchor + Vector2.RIGHT.rotated(TAU * i / DEFENSE_DIRECTIONS) * ring)
	for point: Vector2 in points:
		if point.distance_to(anchor) > DEFENSE_RADIUS + 0.001 or not _firing_position_ok(point, target, weapons):
			continue
		if point.distance_to(here) < best_distance:
			best = point
			best_distance = point.distance_to(here)
	return best


# From `point`: inside the area and the map, clear of asteroids, a weapon in range, the
# line of fire clear of asteroids and friendly hulls (planar; turrets turn, so arcs are
# left to the idle turn).
func _firing_position_ok(point: Vector2, target: Node3D, weapons: Array) -> bool:
	if point.distance_to(anchor) > DEFENSE_RADIUS + 0.001 or not _position_ok(point):
		return false
	var there := _planar(target)
	var reach := 0.0
	for weapon in weapons:
		reach = maxf(reach, weapon.config.weapon_range)
	if point.distance_to(there) > reach - 2.0 or not line_clear(point, there):
		return false
	for other: Node in arena.get_node("Ships").get_children():
		var friend = CombatShip.of(other)
		if other == ship or friend == null or friend.removed_from_play or (friend.alive and friend.faction != combat.faction):
			continue
		var centre := _planar(other)
		var r: float = other.get_node("RouteFollower").ship_radius
		if Geometry2D.get_closest_point_to_segment(centre, point, there).distance_to(centre) <= r:
			return false
	return true


# --- Guard -------------------------------------------------------------------------------

func guard_distance() -> float:
	if not is_instance_valid(guard_target):
		return 0.0
	return follower.ship_radius + guard_target.get_node("RouteFollower").ship_radius + GUARD_BUFFER


func slot_point(slot: int) -> Vector2:
	var heading: float = guard_target.get_node("Locomotion").heading + deg_to_rad(GUARD_SLOTS[slot])
	return _planar(guard_target) + Vector2(-sin(heading), -cos(heading)) * guard_distance()


# The protected ship's destruction ends Guard in the same tick (no automatic new target).
func _on_protected_destroyed(destroyed_ship: Node3D) -> void:
	if command == Command.GUARD and destroyed_ship == guard_target and combat.alive:
		_end_guard("protected ship destroyed")
		_stop()


func _guard_target_valid() -> bool:
	if not is_instance_valid(guard_target) or not guard_target.is_inside_tree():
		return false
	var other = CombatShip.of(guard_target)
	return other != null and other.alive and not other.removed_from_play and other.faction == combat.faction


func _guard() -> void:
	if guard_slot < 0:
		guard_slot = _choose_slot(-1)
		if guard_slot < 0:
			return # No usable position around the protected ship now; tried again next decision.
	var point := slot_point(guard_slot)
	if _slot_usable(guard_slot):
		_slot_blocked = 0.0
	else:
		_slot_blocked += DECISION_INTERVAL
		if _slot_blocked >= GUARD_BLOCKED - 0.000001:
			var next := _choose_slot(guard_slot)
			if next >= 0 and next != guard_slot:
				_note("guard position %s unusable (%s) -> %s" % [_slot_name(guard_slot), _unusable_reason(point), _slot_name(next)])
				guard_slot = next
				guard_reassignments += 1
				point = slot_point(guard_slot)
			_slot_blocked = 0.0
	var velocity: Vector2 = guard_target.get_node("Locomotion").velocity
	var goal := point + velocity * GUARD_LEAD
	if not _position_ok(goal):
		goal = point
	var shifted := not has_station or station.distance_to(goal) > GUARD_RESTATION
	var displaced: bool = not _moving() and _here().distance_to(goal) > GUARD_RESTATION and _here().distance_to(_resolved) > GUARD_RESTATION
	if not shifted and not displaced:
		return
	if now() - _last_order < GUARD_ORDER_INTERVAL - 0.000001:
		return
	_request_move(goal, "guard position %s" % _slot_name(guard_slot))


# Nearest usable slot to the ship, not held by another guard of the same ship; `exclude`
# is the slot being given up. A new choice needs GUARD_CHOICE_MARGIN more clearance from
# asteroids than keeping one does (hysteresis: no hopping along a rock's edge).
func _choose_slot(exclude: int) -> int:
	for margin: float in [GUARD_CHOICE_MARGIN, 0.0]:
		var best := -1
		var best_distance := INF
		for slot in GUARD_SLOTS.size():
			if slot == exclude or not _slot_usable(slot, margin):
				continue
			var distance := _here().distance_to(slot_point(slot))
			if distance < best_distance:
				best = slot
				best_distance = distance
		if best >= 0:
			return best
	return -1


# On the map, clear of asteroids, and clear of every other guard's position.
func _slot_usable(slot: int, margin := 0.0) -> bool:
	var point := slot_point(slot)
	if not _position_ok(point, margin):
		return false
	for other: Node in arena.get_node("Ships").get_children():
		var behavior = of(other)
		if behavior == null or behavior == self or behavior.command != Command.GUARD or behavior.guard_target != guard_target or behavior.guard_slot < 0:
			continue
		var separation: float = follower.ship_radius + other.get_node("RouteFollower").ship_radius + GUARD_SEPARATION
		if behavior.slot_point(behavior.guard_slot).distance_to(point) < separation:
			return false
	return true


# Why a guard position is unusable (for the log).
func _unusable_reason(point: Vector2) -> String:
	if not _position_ok(point):
		return "asteroid" if absf(point.x) <= MAP_LIMIT - follower.ship_radius and absf(point.y) <= MAP_LIMIT - follower.ship_radius else "map edge"
	return "another guard"


func _slot_name(slot: int) -> String:
	if slot < 0:
		return "none"
	var angle: float = GUARD_SLOTS[slot]
	return "%s %.0f°" % ["left" if angle > 0.0 else ("right" if angle < 0.0 else "ahead"), absf(angle)] if absf(angle) < 180.0 else "astern"


# --- Geometry ----------------------------------------------------------------------------

## Whether the straight line between two planar points clears every asteroid.
## Production world: stations block it too (combat_obstacles.gd, at the ship's height).
func line_clear(a: Vector2, b: Vector2) -> bool:
	if asteroids != null:
		for id: int in asteroids.ids():
			var c: Vector3 = asteroids.center(id)
			var centre := Vector2(c.x, c.z)
			if Geometry2D.get_closest_point_to_segment(centre, a, b).distance_to(centre) <= asteroids.radius(id) + SIGHT_MARGIN:
				return false
	var y := ship.global_position.y
	return not CombatObstacles.blocked(get_tree(), Vector3(a.x, y, a.y), Vector3(b.x, y, b.y))


# A footprint at `point`: on the map and clear of every asteroid and station (the same
# clearance as from an asteroid).
func _position_ok(point: Vector2, margin := 0.0) -> bool:
	var radius: float = follower.ship_radius + margin
	if absf(point.x) > MAP_LIMIT - radius or absf(point.y) > MAP_LIMIT - radius:
		return false
	if asteroids != null:
		for id: int in asteroids.ids():
			var c: Vector3 = asteroids.center(id)
			if point.distance_to(Vector2(c.x, c.z)) < asteroids.radius(id) + radius + ROCK_CLEARANCE:
				return false
	return CombatObstacles.footprint_clear(get_tree(), point, ship.global_position.y, radius + ROCK_CLEARANCE)


func _here() -> Vector2:
	return locomotion.planar_position


static func _planar(node: Node3D) -> Vector2:
	return Vector2(node.global_position.x, node.global_position.z)


func _note(text: String) -> void:
	log.append("%.2f %s" % [now(), text])
	if log.size() > 200:
		log.remove_at(0)


## One-line state for the HUD.
func describe() -> String:
	var text := "Command: %s" % COMMAND_NAMES[command]
	match command:
		Command.ATTACK:
			text += " %s%s" % [attack_target.name if is_instance_valid(attack_target) else "?", " (investigating last known position)" if investigating else ""]
		Command.GUARD:
			text += " %s (%s)" % [guard_target.name if is_instance_valid(guard_target) else "?", _slot_name(guard_slot)]
		Command.ATTACK_MOVE:
			text += " to (%.0f, %.0f)%s" % [destination.x, destination.y, " - engaging %s" % encounter.name if is_instance_valid(encounter) else ""]
		Command.WAYPOINTS:
			text += " (%d waypoint%s left)" % [waypoints.size(), "" if waypoints.size() == 1 else "s"]
	var profile := "Profile: %s" % Profiles.NAMES[requested_profile]
	if effective_profile >= 0 and effective_profile != requested_profile:
		profile += " -> %s%s" % [Profiles.NAMES[effective_profile], " (%s)" % fallback_reason if fallback_reason != "" else ""]
	var available := Profiles.available(combat)
	if available.size() < 3:
		profile += " [only %s]" % ", ".join(available.map(func(p: int) -> String: return Profiles.NAMES[p]))
	return "%s  |  %s" % [text, profile]
