extends CanvasLayer
## Movement Debug panel (layout from the original game's DebugUI), showing the
## new locomotion state of the active ship only. Navigation Debug adds the
## active ship's route state to the HUD and shows the navigation drawing.
## Avoidance Debug adds the active ship's avoidance state and shows its drawing;
## it also shows the active ship's collision contacts (Stage 6).

const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipAvoidance := preload("res://game/avoidance/ship_avoidance.gd")
const SLIP_MIN_SPEED := 0.1 # u/s

@export var navigation_debug_path := NodePath()
@export var avoidance_debug_path := NodePath()

var target: ShipLocomotion = null
var follower: RouteFollower = null
var avoidance: ShipAvoidance = null
var target_name := ""
var selected_count := 0 # Ships selected; the HUD details need exactly one.

@onready var _toggle: CheckBox = $Panel/DebugToggle
@onready var _navigation_toggle: CheckBox = $Panel/NavigationDebugToggle
@onready var _avoidance_toggle: CheckBox = $Panel/AvoidanceDebugToggle
@onready var _hud: Label = $Panel/DebugHud


func _ready() -> void:
	_toggle.toggled.connect(_set_debug.unbind(1))
	_navigation_toggle.toggled.connect(_set_debug.unbind(1))
	_avoidance_toggle.toggled.connect(_set_debug.unbind(1))
	_set_debug()


func _process(_delta: float) -> void:
	if not _hud.visible:
		return
	if target == null:
		_hud.text = "%d ships selected" % selected_count if selected_count > 1 else "No ship selected"
		return
	var lines := []
	if _toggle.button_pressed:
		var local := target.local_velocity()
		lines.append_array([
			"%s: %s" % [target_name, target.get_status()],
			"Heading mode: %s" % ShipLocomotion.HeadingMode.keys()[target.heading_mode],
			"Velocity: %.2f u/s at %s" % [target.velocity.length(), _bearing_text(target.velocity)],
			"Forward %.2f, lateral %.2f u/s" % [local.x, local.y],
			"Desired: %.2f u/s at %s" % [target.desired_velocity.length(), _bearing_text(target.desired_velocity)],
			"Heading: %05.1f°" % fposmod(-rad_to_deg(target.heading), 360.0),
			"Heading vs velocity: %s" % _slip_text(local),
			"Turn rate: %.1f °/s" % (0.0 - rad_to_deg(target.angular_velocity)),
			"Distance: %s" % ("%.2f u" % target.distance_to_destination() if target.has_destination else "-"),
		])
	if _navigation_toggle.button_pressed and follower != null:
		lines.append_array(_navigation_lines())
	if _avoidance_toggle.button_pressed and avoidance != null:
		lines.append_array(_avoidance_lines())
	_hud.text = "\n".join(lines)


func _avoidance_lines() -> Array:
	var lines := ["Avoidance: %s" % ShipAvoidance.State.keys()[avoidance.state]]
	for ship: Node in avoidance.encounters:
		var encounter: Dictionary = avoidance.encounters[ship]
		var text := "  vs %s: " % ship.name
		if not encounter.give_way:
			text += "stand-on"
		elif encounter.response == ShipAvoidance.Response.PASS:
			text += "pass %s %.1f u%s" % ["starboard" if encounter.side > 0 else "port", encounter.shift, " (limited)" if encounter.limited else ""]
		else:
			text += "yield"
		lines.append(text + (" (head-on)" if encounter.head_on else " (crossing)" if encounter.astern != 0 else " (converging)" if encounter.converging != 0 else ""))
	var moving := target.has_destination
	lines.append("Avoidance target: %s" % ("%.1f, %.1f" % [avoidance.target.x, avoidance.target.y] if moving and avoidance.state == ShipAvoidance.State.PASSING else "-"))
	lines.append("Avoidance speed cap: %s" % ("%.2f u/s" % avoidance.speed_cap if avoidance.speed_cap < INF else "-"))
	lines.append("Closest approach: %s" % ("%s %.2f u in %.1f s" % [avoidance.closest_name, avoidance.closest_gap, avoidance.closest_time] if avoidance.closest_gap < INF else "-"))
	lines.append("Min separation: %s" % ("%.2f u" % avoidance.min_separation if avoidance.min_separation < INF else "-"))
	var all_contacts := 0
	for ship: Node in avoidance.get_parent().get_parent().get_children():
		var other := ship.get_node_or_null("Avoidance") as ShipAvoidance
		if other != null:
			all_contacts += other.contacts
	lines.append("Contacts: %d (all ships %d)" % [avoidance.contacts, int(all_contacts / 2.0)])
	lines.append("Changes: role %d, yield->pass %d, restarts %d, side flips %d" % [
		avoidance.role_changes, avoidance.response_changes, avoidance.restarts, avoidance.side_flips])
	# Collision enforcement (Stage 6): the last step's contacts and movement.
	var contact_texts := []
	for contact: Dictionary in target.contacts:
		contact_texts.append("%s (gap %.3f u, normal %s)" % [contact.blocker.name, contact.gap, _bearing_text(contact.normal)])
	lines.append("Collision: %s" % (", ".join(contact_texts) if not contact_texts.is_empty() else "-"))
	lines.append("Proposed / committed: %.3f / %.3f u per tick" % [target.proposed_motion.length(), target.committed_motion.length()])
	lines.append("Collisions: %d, blocked %.1f s, limit hits %d" % [target.collision_count, target.blocked_time, target.contact_limit_count])
	return lines


func _navigation_lines() -> Array:
	var route_text: String = RouteFollower.RouteStatus.keys()[follower.status]
	var following := follower.status == RouteFollower.RouteStatus.ROUTE and target.has_destination
	if follower.status == RouteFollower.RouteStatus.ROUTE:
		route_text += " (segment %d/%d)" % [follower.segment + 1, follower.route.size() - 1]
	var resolved := "-"
	if follower.route.size() > 0:
		resolved = "%.2f u from request" % follower.route[follower.route.size() - 1].distance_to(follower.requested)
	return [
		"Route: %s" % route_text,
		"Route remaining: %s" % ("%.2f u" % follower.remaining if following else "-"),
		"Lookahead: %s" % ("%.2f u" % follower.lookahead if following else "-"),
		"Route speed cap: %s" % ("%.2f u/s" % follower.speed_cap if following and follower.speed_cap < INF else "-"),
		"Off route: %s" % ("%.2f u" % follower.distance_off_route() if following else "-"),
		"Resolved: %s" % resolved,
		"Footprint clearance: %.2f u" % follower.footprint_clearance(),
	]


func _set_debug() -> void:
	_hud.visible = _toggle.button_pressed or _navigation_toggle.button_pressed or _avoidance_toggle.button_pressed
	if not navigation_debug_path.is_empty():
		get_node(navigation_debug_path).visible = _navigation_toggle.button_pressed
	if not avoidance_debug_path.is_empty():
		get_node(avoidance_debug_path).visible = _avoidance_toggle.button_pressed


# Angle of the actual velocity from the bow (positive = velocity to the right of
# the heading); hidden below SLIP_MIN_SPEED, where the angle is meaningless.
func _slip_text(local_velocity: Vector2) -> String:
	if local_velocity.length() < SLIP_MIN_SPEED:
		return "-"
	return "%.1f°" % rad_to_deg(local_velocity.angle())


# Compass bearing: 0° = -Z, clockwise seen from above.
func _bearing_text(vector: Vector2) -> String:
	if vector.length() < 0.01:
		return "-"
	return "%05.1f°" % fposmod(rad_to_deg(atan2(vector.x, -vector.y)), 360.0)
