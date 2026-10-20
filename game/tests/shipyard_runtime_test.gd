extends SceneTree
## Headless Phase 4 integration test in the uninterrupted game loop: nothing is stepped
## by hand and no physics processing is switched off (also not on the produced ships).
## Part A (gameplay API): a Mining Ship order is supplied by the existing Transporter
## (Station2 -> Shipyard), constructed and deployed; the new ship's registration, its
## initial state and resolved settings against the authored Miner1 captured before the
## first physics tick, and the first ticks after deployment; a Transport Ship completes
## while Miner3 still holds the deployment point (Awaiting Deployment), Miner3 is moved
## away with a right-click through the existing command path, Transporter2 deploys
## exactly once; both new ships move and arrive.
## Part B (player controls, on a fresh scene): the Shipyard selected with a left-click;
## Order / Cancel Order through the station panel's buttons (real clicks), the panel's
## states; the ingots brought by the existing Transporter configured in the ship panel;
## Miner3 selected with a left-click and moved off the deployment point with a
## right-click (Transporter2 waits, then deploys); Miner3 docks at the Shipyard by
## right-click, undocks with the panel's Undock, mines an asteroid by right-click and
## unloads at its base; Transporter2 runs a transport assignment set up in the ship
## panel (Station -> Shipyard) and delivers.
## Run from the project folder (fixed 60 Hz, as fast as possible):
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/shipyard_runtime_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const Station := preload("res://game/stations/station.gd")
const Shipyard := preload("res://game/shipyard/shipyard.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const Docking := preload("res://game/stations/docking.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const IRON := &"iron_ingot"
const NICKEL := &"nickel_ingot"
const SILICON := &"silicon_ingot"
const TITANIUM := &"titanium_ingot"
const COBALT := &"cobalt_ingot"
const COMPONENTS := ["Locomotion", "RouteFollower", "Avoidance", "Cargo", "Extractor", "Mining", "Transport", "Scanner", "Docking", "Fuel"]
const PATHS := {"Locomotion": ["collision_path"], "RouteFollower": ["navigation_path"], "Avoidance": ["ships_path", "navigation_path"],
	"Extractor": ["field_path"], "Mining": ["field_path", "navigation_path", "ships_path"], "Scanner": ["survey_path"], "Docking": ["navigation_path"]}

var _failures := 0
var _checks := 0
var _main: Node
var _yard_station: Station
var _yard: Shipyard
var _deployment: Node3D
var _camera: Camera3D
var _reference := {} # ship name -> snapshot before the first physics tick
var _deployed: Array[Node3D] = []
var _deployed_snapshots: Array[Dictionary] = []
var _deployed_frames: Array[int] = []
var _completion_notices := 0


func _initialize() -> void:
	await process_frame
	await _load_main()
	await _part_api()
	_main.queue_free()
	await process_frame
	await _load_main()
	await _part_ui()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


func _load_main() -> void:
	_main = MAIN.instantiate()
	root.add_child(_main)
	# Every _ready() has run; no physics tick yet: the starting ships' initial state.
	for ship_name in ["Miner1", "Transporter"]:
		_reference[ship_name] = _snapshot(_main.get_node("Ships/" + ship_name))
	_yard_station = _main.get_node("Stations/Shipyard")
	_yard = _yard_station.get_node("Shipyard")
	_deployment = _yard_station.get_node("Deployment")
	_camera = _main.get_node("CameraRig/Camera3D")
	_deployed.clear()
	_deployed_snapshots.clear()
	_deployed_frames.clear()
	_completion_notices = 0
	_yard.ship_deployed.connect(_on_deployed)
	_yard.notice.connect(func(text: String) -> void:
		if text.ends_with(" completed"):
			_completion_notices += 1)
	var nav := _main.get_node("StaticNavigation")
	while not (nav.is_ready(2.6) and nav.is_ready(5.1) and nav.is_ready(7.2) and nav.is_ready(4.4)):
		await physics_frame


func _on_deployed(ship: Node3D) -> void:
	# Emitted in the call that added the ship: before its first physics tick.
	_deployed.append(ship)
	_deployed_snapshots.append(_snapshot(ship))
	_deployed_frames.append(Engine.get_physics_frames())


# --- Part A: gameplay API, uninterrupted loop -----------------------------------------

func _part_api() -> void:
	var station2: Station = _main.get_node("Stations/Station2")
	var transport := _main.get_node("Ships/Transporter/Transport") as TransportOperation
	station2.storage.add(IRON, 200)
	station2.storage.add(NICKEL, 100)
	station2.storage.add(SILICON, 50)
	transport.set_load_station(station2)
	transport.set_unload_station(_yard_station)
	transport.set_requirement(IRON, 200)
	transport.set_requirement(NICKEL, 100)
	transport.set_requirement(SILICON, 50)
	transport.start()
	_check("A1. Mining Ship ordered with no ingots at the Shipyard: Waiting for Materials", _yard.order(&"mining_ship") and _yard.state == Shipyard.State.WAITING)
	var started := await _until(func() -> bool: return _yard.state == Shipyard.State.CONSTRUCTING, 60 * 600)
	var storage := _yard_station.storage
	var cargo: Inventory = _main.get_node("Ships/Transporter/Cargo").inventory
	var elsewhere := 0
	for inventory: Inventory in [storage, station2.storage, cargo]:
		elsewhere += inventory.quantity_of(IRON) + inventory.quantity_of(NICKEL) + inventory.quantity_of(SILICON)
	_check("A2. the existing Transporter delivers the ingots (%.0f s): construction starts on delivery, the 350 ingots consumed once (left anywhere: %d)" % [
		started / 60.0, elsewhere], started >= 0 and elsewhere == 0)
	transport.cancel() # Nothing more to carry; the assignment pauses.
	var start_frame := Engine.get_physics_frames()
	await _until(func() -> bool: return not _deployed.is_empty(), 60 * 70)
	var miner: Node3D = _deployed[0] if not _deployed.is_empty() else null
	_check("A3. constructed in 60 s (%.2f s) and deployed in the same tick: %s" % [
		(_deployed_frames[0] - start_frame) / 60.0 if miner != null else -1.0, miner.name if miner != null else "none"],
		miner != null and miner.name == "Miner3" and absi(_deployed_frames[0] - start_frame - 3600) <= 2 and _yard.state == Shipyard.State.IDLE)
	if miner == null:
		return
	_check_parity_c(miner, "Miner1", _deployed_snapshots[0])
	_check_registration(miner)
	var loco := miner.get_node("Locomotion") as ShipLocomotion
	var authored := _main.get_node("Ships/Miner1")
	var processing := COMPONENTS.all(func(c: String) -> bool:
		var node := miner.get_node_or_null(c)
		return node == null or node.is_physics_processing() == authored.get_node(c).is_physics_processing())
	await _frames(3)
	_check("A6. first ticks after deployment: physics processing as on Miner1 (nothing switched off), still at the marker and at rest (%s)" % str(loco.planar_position),
		processing and loco.planar_position.distance_to(_planar(_deployment.global_position)) < 0.001 and loco.velocity == Vector2.ZERO
		and loco.collision_count == 0)

	# Blocked deployment: Miner3 stays at the marker while a Transport Ship completes.
	storage.add(IRON, 300)
	storage.add(TITANIUM, 100)
	storage.add(COBALT, 50)
	_yard.order(&"transport_ship")
	var awaiting := await _until(func() -> bool: return _yard.state == Shipyard.State.AWAITING_DEPLOYMENT, 60 * 95)
	await _frames(60 * 10)
	_check("A7. Transport Ship completed while Miner3 holds the deployment point: Awaiting Deployment for 10 s, no second ship",
		awaiting >= 0 and _yard.state == Shipyard.State.AWAITING_DEPLOYMENT and _deployed.size() == 1 and _main.get_node("Ships").get_child_count() == 7)
	# Miner3 moved away with a right-click (existing command path), as a player would.
	_main.get_node("Selection").set_selection([miner])
	var away: Vector2 = _main.get_node("StaticNavigation").closest_point(2.6, Vector2(-75, -128))
	await _right_click_at(away)
	_check("A8. right-click MOVE for Miner3 through the command path: order taken", loco.has_destination
		and (miner.get_node("RouteFollower") as RouteFollower).status != RouteFollower.RouteStatus.NONE)
	await _until(func() -> bool: return _deployed.size() >= 2, 60 * 60)
	await _frames(60)
	var transporter: Node3D = _deployed[1] if _deployed.size() >= 2 else null
	_check("A9. Transporter2 deployed exactly once after Miner3 left (%s), Shipyard Idle, %d completion notices" % [
		transporter.name if transporter != null else "none", _completion_notices],
		transporter != null and transporter.name == "Transporter2" and _deployed.size() == 2 and _yard.state == Shipyard.State.IDLE
		and _completion_notices == 2 and _main.get_node("Ships").get_child_count() == 8)
	if transporter == null:
		return
	_check_parity_c(transporter, "Transporter", _deployed_snapshots[1])
	_check_registration(transporter)
	var arrived := await _until(func() -> bool: return not loco.has_destination, 60 * 90)
	_check("A10. Miner3 arrives (%.0f s): %.3f u from its destination, 0 contacts" % [arrived / 60.0, loco.planar_position.distance_to(away)],
		arrived >= 0 and loco.planar_position.distance_to(away) < 0.25 and loco.collision_count == 0)
	_main.get_node("Selection").set_selection([transporter])
	var t_loco := transporter.get_node("Locomotion") as ShipLocomotion
	var target: Vector2 = _main.get_node("StaticNavigation").closest_point(5.1, Vector2(0, -70))
	await _right_click_at(target)
	var t_arrived := await _until(func() -> bool: return not t_loco.has_destination, 60 * 90)
	_check("A11. Transporter2 commanded by right-click arrives (%.0f s): %.3f u from its destination, 0 contacts" % [t_arrived / 60.0, t_loco.planar_position.distance_to(target)],
		t_arrived >= 0 and t_loco.planar_position.distance_to(target) < 0.25 and t_loco.collision_count == 0)
	_main.get_node("Selection").set_selection([])


# --- Part B: player controls, uninterrupted loop --------------------------------------

func _part_ui() -> void:
	var panel := _main.get_node("StationPanel")
	var production: Control = panel.get_node("Panel/Layout/Scroll/Body/Production")
	var status: Label = production.get_node("Status")
	var details: RichTextLabel = production.get_node("Details")
	var order_mining: Button = production.get_node("Buttons/OrderMining")
	var order_transport: Button = production.get_node("Buttons/OrderTransport")
	var cancel: Button = production.get_node("Buttons/Cancel")
	var station2: Station = _main.get_node("Stations/Station2")
	var base: Station = _main.get_node("Stations/Station")

	await _left_click_world(station2.global_position)
	var refinery_station: bool = panel.station == station2 and not production.visible
	await _left_click_world(_yard_station.global_position)
	_check("B1. left-click selects the Shipyard: Ship Production shown (not for Station2), idle, recipes with missing ingots and both Order buttons",
		refinery_station and panel.station == _yard_station and production.visible and status.text == "Status: Idle"
		and details.get_parsed_text().contains("Mining Ship - 60 s") and details.get_parsed_text().contains("Transport Ship - 90 s")
		and details.get_parsed_text().contains("Iron Ingots: required 200, available 0 - missing 200")
		and order_mining.visible and order_transport.visible and not cancel.visible)
	await _click_control(order_mining)
	_check("B2. Order Mining Ship (button): Waiting for Materials; required / available / missing shown; Cancel Order only",
		_yard.state == Shipyard.State.WAITING and status.text == "Status: Waiting for Materials - Mining Ship"
		and details.get_parsed_text().contains("Silicon Ingots: required 50, available 0 - missing 50")
		and cancel.visible and not order_mining.visible and not order_transport.visible and not production.get_node("Progress").visible)
	_yard_station.storage.add(IRON, 120)
	await _frames(2)
	await _click_control(cancel)
	_check("B3. Cancel Order (button): Idle again, nothing consumed (iron 120 kept)", _yard.state == Shipyard.State.IDLE
		and _yard_station.storage.quantity_of(IRON) == 120 and order_mining.visible and not cancel.visible)
	_yard_station.storage.remove(IRON, 120)
	await _click_control(order_mining)

	# The existing Transporter brings the ingots (Station2 -> Shipyard), set up in the ship panel.
	station2.storage.add(IRON, 200)
	station2.storage.add(NICKEL, 100)
	station2.storage.add(SILICON, 50)
	var transporter: Node3D = _main.get_node("Ships/Transporter")
	await _left_click_world(transporter.global_position)
	var selected_transporter: bool = _main.get_node("Selection").selected == [transporter]
	await _configure_transport(transporter, station2, _yard_station, {IRON: 200, NICKEL: 100, SILICON: 50})
	var transport := transporter.get_node("Transport") as TransportOperation
	_check("B4. Transporter selected with a left-click; ship panel: Load at Station2, Unload at Shipyard, three ingot requirements, Start",
		selected_transporter and transport.load_station == station2 and transport.unload_station == _yard_station
		and transport.required[IRON] == 200 and transport.required[NICKEL] == 100 and transport.required[SILICON] == 50 and transport.is_active())
	var started := await _until(func() -> bool: return _yard.state == Shipyard.State.CONSTRUCTING, 60 * 600)
	await _left_click_world(_yard_station.global_position) # Back to the Shipyard's panel.
	await _frames(60 * 10)
	_check("B5. delivered by the Transporter (%.0f s): Constructing, progress and time remaining shown, no actions" % (started / 60.0),
		started >= 0 and status.text == "Status: Constructing Mining Ship" and production.get_node("Progress").visible
		and details.get_parsed_text().contains("s remaining - cannot be cancelled") and not order_mining.visible and not cancel.visible)
	transport.cancel()
	await _until(func() -> bool: return not _deployed.is_empty(), 60 * 60)
	await _frames(2)
	var miner: Node3D = _deployed[0] if not _deployed.is_empty() else null
	var notice_label: Label = _main.get_node("NoticeUI/Notice")
	_check("B6. Miner3 completed: notice \"%s\", panel Idle with \"%s\"" % [notice_label.text, production.get_node("LastCompleted").text],
		miner != null and miner.name == "Miner3" and notice_label.text == "Shipyard: Miner3 completed"
		and production.get_node("LastCompleted").text == "Last completed: Miner3" and status.text == "Status: Idle" and order_transport.visible)
	if miner == null:
		return

	# Transport Ship while Miner3 holds the deployment point.
	_yard_station.storage.add(IRON, 300)
	_yard_station.storage.add(TITANIUM, 100)
	_yard_station.storage.add(COBALT, 50)
	await _click_control(order_transport)
	var constructing := _yard.state == Shipyard.State.CONSTRUCTING
	await _until(func() -> bool: return _yard.state == Shipyard.State.AWAITING_DEPLOYMENT, 60 * 95)
	await _frames(60 * 5)
	_check("B7. Order Transport Ship with every ingot here: Constructing at once; completed behind Miner3: Awaiting Deployment shown",
		constructing and _yard.state == Shipyard.State.AWAITING_DEPLOYMENT and status.text == "Status: Awaiting Deployment - Transport Ship"
		and details.get_parsed_text().contains("deployment area is obstructed") and not order_mining.visible and not cancel.visible
		and _deployed.size() == 1)
	await _left_click_world(miner.global_position)
	var selected_miner: bool = _main.get_node("Selection").selected == [miner]
	var away: Vector2 = _main.get_node("StaticNavigation").closest_point(2.6, Vector2(-75, -128))
	await _right_click_at(away)
	await _until(func() -> bool: return _deployed.size() >= 2, 60 * 60)
	var transporter2: Node3D = _deployed[1] if _deployed.size() >= 2 else null
	var m_loco := miner.get_node("Locomotion") as ShipLocomotion
	var arrived := await _until(func() -> bool: return not m_loco.has_destination, 60 * 90)
	_check("B8. Miner3 selected with a left-click, moved off by right-click and arrives (%.3f u); then Transporter2 deploys exactly once" % m_loco.planar_position.distance_to(away),
		selected_miner and arrived >= 0 and m_loco.planar_position.distance_to(away) < 0.25 and transporter2 != null
		and transporter2.name == "Transporter2" and _deployed.size() == 2 and _completion_notices == 2)
	if transporter2 == null:
		return

	# Miner3: dock at the Shipyard (right-click), Undock (panel), mine (right-click).
	var m_docking := miner.get_node("Docking") as Docking
	await _right_click_world(_yard_station.global_position)
	var docked := await _until(func() -> bool: return m_docking.state == Docking.State.DOCKED, 60 * 120)
	var off := _bow_offset(miner, m_docking)
	await _frames(2)
	var undock: Button = _main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Actions/Docking/Undock")
	await _click_control(undock)
	var left := await _until(func() -> bool: return m_docking.state == Docking.State.NONE, 60 * 90)
	_check("B9. Miner3 docks at the Shipyard by right-click (%.0f s, bow %.2f deg off the berth axis) and leaves with Undock (panel button)" % [docked / 60.0, off],
		docked >= 0 and absf(off) <= 0.5 and left >= 0)
	var asteroid := _mineable_asteroid(miner)
	var totals_before := _station_totals()
	var field := _main.get_node("Asteroids")
	await _right_click_world(field.center(asteroid))
	var mining := miner.get_node("Mining")
	var assigned: bool = mining.target == asteroid
	var cycle := await _until(func() -> bool: return mining.activity() == "Returning to Asteroid", 60 * 600)
	var gained := _station_totals() - totals_before
	_check("B10. Miner3 mines asteroid %d by right-click, returns to %s and unloads its full hold (%d units, %.0f s)" % [
		asteroid, mining.trip_base.name if mining.trip_base != null else "none", gained, cycle / 60.0],
		assigned and cycle >= 0 and gained == miner.get_node("Cargo").inventory.capacity and miner.get_node("Cargo").inventory.quantity() == 0)
	await _left_click_world(miner.global_position)
	await _right_click_at(_main.get_node("StaticNavigation").closest_point(2.6, _planar(miner.global_position) + Vector2(0, 8)))

	# Transporter2: a transport assignment from the Base to the Shipyard, set up in the ship panel.
	base.storage.add(IRON, 100)
	var yard_iron := _yard_station.storage.quantity_of(IRON)
	await _left_click_world(transporter2.global_position)
	var selected_t2: bool = _main.get_node("Selection").selected == [transporter2]
	await _configure_transport(transporter2, base, _yard_station, {IRON: 100})
	var t2_transport := transporter2.get_node("Transport") as TransportOperation
	var t2_docking := transporter2.get_node("Docking") as Docking
	var docked_at_base := await _until(func() -> bool: return t2_docking.state == Docking.State.DOCKED and t2_docking.station == base, 60 * 300)
	var base_off := _bow_offset(transporter2, t2_docking)
	var delivered := await _until(func() -> bool: return t2_transport.deliveries >= 1, 60 * 600)
	_check("B11. Transporter2 selected with a left-click; ship-panel assignment Station -> Shipyard: docks at Station (bow %.2f deg), delivers 100 iron ingots (Shipyard %d -> %d)" % [
		base_off, yard_iron, _yard_station.storage.quantity_of(IRON)],
		selected_t2 and docked_at_base >= 0 and absf(base_off) <= 0.5 and delivered >= 0 and _yard_station.storage.quantity_of(IRON) == yard_iron + 100)
	var contacts := 0
	var refusals := 0
	for ship in _deployed:
		contacts += (ship.get_node("Locomotion") as ShipLocomotion).collision_count
		refusals += (ship.get_node("RouteFollower") as RouteFollower).guided_refusals + (ship.get_node("Locomotion") as ShipLocomotion).guided_order_errors
	_check("B12. produced ships: %d contacts, %d orders refused or rejected under station control" % [contacts, refusals], contacts == 0 and refusals == 0)


# Sets up a transport assignment in the ship panel's Transport section (the ship is selected).
func _configure_transport(ship: Node3D, from: Node3D, to: Node3D, required: Dictionary) -> void:
	await _frames(2)
	var rows := _main.get_node("ShipPanel/Panel/Layout/Scroll/Body/Actions/Transport")
	for pair in [["LoadRow/Station", from], ["UnloadRow/Station", to]]:
		var choice: OptionButton = rows.get_node(pair[0])
		for i in choice.item_count:
			if choice.get_item_metadata(i) == pair[1]:
				choice.select(i)
				choice.item_selected.emit(i)
	# UX round P7: the requirements through Configure Cargo, the editor rows and Apply
	# (before: the single requirement row).
	var editor := _main.get_node("ShipPanel/TransportEditor")
	await _click_control(rows.get_node("Configure"))
	for resource: StringName in required:
		(editor.row(0 if Inventory.RAW.has(resource) else 1, resource).get_node("Amount") as SpinBox).value = required[resource]
	await _frames(2)
	await _click_control(editor.get_node("Panel/Layout/Footer/Buttons/Apply"))
	await _click_control(editor.get_node("Panel/Layout/Footer/Buttons/Cancel")) # Closes it (nothing unapplied).
	await _frames(2)
	await _click_control(rows.get_node("Start"))


func _mineable_asteroid(ship: Node3D) -> int:
	var field := _main.get_node("Asteroids")
	var mining := ship.get_node("Mining")
	var best := -1
	var best_distance := INF
	for id: int in field.ids():
		var deposit = field.deposit(id)
		var distance: float = _planar(field.center(id)).distance_to(_planar(ship.global_position))
		if deposit.family == 0 and deposit.reserves >= 1000 and distance < best_distance and mining.can_mine(id):
			best = id
			best_distance = distance
	return best


func _station_totals() -> int:
	var total := 0
	for station: Station in _main.get_node("Stations").get_children():
		total += station.storage.quantity()
	return total


func _bow_offset(ship: Node3D, docking: Docking) -> float:
	if docking.station == null or docking.slot < 0:
		return 999.0
	var heading: float = (ship.get_node("Locomotion") as ShipLocomotion).heading
	var bow := Vector2(-sin(heading), -cos(heading))
	return rad_to_deg(bow.angle_to(-docking.station.slots[docking.slot].axis))


func _check_registration(ship: Node3D) -> void:
	var selection := _main.get_node("Selection")
	var connected := 0
	var expected := 0
	for node_name in ["RouteFollower", "Mining", "Docking", "Fuel", "Transport"]:
		var node := ship.get_node_or_null(node_name)
		if node == null:
			continue
		expected += 1
		connected += node.notice.get_connections().filter(func(c: Dictionary) -> bool: return c.callable.get_object() == _main).size()
	var markers: Array = _main._markers[ship] if _main._markers.has(ship) else []
	_check("A5. %s registered in the call that added it: selection boxes and ring, destination marker and request line, %d notice signals connected once" % [ship.name, expected],
		selection._parts.has(ship) and selection._rings.has(ship) and markers.size() == 2 and markers[0].get_parent() == _main
		and connected == expected)


# Initial state and resolved settings of a produced ship against the authored ship,
# both captured before their first physics tick (position and heading: the marker).
func _check_parity_c(ship: Node3D, reference_name: String, snapshot: Dictionary) -> void:
	var reference: Dictionary = _reference[reference_name]
	var differences: Array[String] = []
	for key in reference:
		if key == "pose":
			continue
		if not snapshot.has(key) or snapshot[key] != reference[key]:
			differences.append("%s: %s vs %s" % [key, str(snapshot.get(key)), str(reference[key])])
	var pose: Array = snapshot.pose
	var deploy := _planar(_deployment.global_position)
	var at_marker: bool = pose[0].distance_to(deploy) < 0.001 and absf(angle_difference(pose[1], _deployment.global_rotation.y)) < 0.0001
	_check("A4. %s initial state and resolved node paths = %s before its first tick; pose at the marker%s" % [ship.name, reference_name,
		"" if differences.is_empty() else " - " + "; ".join(differences)], differences.is_empty() and at_marker)


func _snapshot(ship: Node3D) -> Dictionary:
	var s := {}
	var loco := ship.get_node("Locomotion")
	s.pose = [loco.planar_position, loco.heading]
	for c in COMPONENTS:
		var node := ship.get_node_or_null(c)
		s["has " + c] = node != null
		if node != null:
			s["priority " + c] = node.process_physics_priority
			for property: String in PATHS.get(c, []):
				s["%s.%s -> node" % [c, property]] = node.get_node_or_null(node.get(property))
	s.locomotion = [loco.velocity, loco.angular_velocity, loco.has_destination, loco.guided, loco.propulsion, loco.collision_count]
	var follower := ship.get_node("RouteFollower")
	s.route = [follower.status, follower.route.size(), follower.plans, follower.ship_radius, follower.planning_radius()]
	var avoidance := ship.get_node("Avoidance")
	s.avoidance = [avoidance.state, avoidance.encounters.size(), avoidance.contacts]
	var cargo: Inventory = ship.get_node("Cargo").inventory
	s.cargo = [cargo.capacity, cargo.quantity()]
	var mining := ship.get_node_or_null("Mining")
	if mining != null:
		s.mining = [mining.target, mining.base, mining.status]
	var transport := ship.get_node_or_null("Transport")
	if transport != null:
		s.transport = [transport.load_station, transport.unload_station, transport.total_required(), transport.status, transport.deliveries]
	var scanner := ship.get_node("Scanner")
	s.scanner = [scanner.kind, scanner.cooldown_left]
	var docking := ship.get_node("Docking")
	s.docking = [docking.station, docking.state, docking.slot, docking.transfer]
	var fuel := ship.get_node("Fuel")
	s.fuel = [fuel.fuel, fuel.capacity, fuel.warned, fuel.refueling]
	return s


# --- Helpers ------------------------------------------------------------------------

func _until(condition: Callable, limit: int) -> int:
	for frame in limit:
		if condition.call():
			return frame
		await physics_frame
	return -1


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


func _frame_camera(center: Vector2) -> void:
	var rig := _main.get_node("CameraRig")
	rig.global_position = Vector3(center.x, 0, center.y)
	rig.rotation = Vector3.ZERO
	rig.zoom_distance = 30.0
	rig._apply_zoom()


func _right_click_at(point: Vector2) -> void:
	_frame_camera(point)
	await process_frame
	var position := _camera.unproject_position(Vector3(point.x, 0, point.y))
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = pressed
		event.position = position
		event.global_position = position
		event.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		root.push_input(event, true)
	await physics_frame


func _right_click_world(point: Vector3) -> void:
	_frame_camera(_planar(point))
	await process_frame
	var position := _camera.unproject_position(point)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = pressed
		event.position = position
		event.global_position = position
		event.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		root.push_input(event, true)
	await physics_frame


func _left_click_world(point: Vector3) -> void:
	_frame_camera(_planar(point))
	await process_frame
	await _left_click(_camera.unproject_position(point))


func _click_control(control: Control) -> void:
	await process_frame
	await _left_click(control.get_global_rect().get_center())


func _left_click(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		event.global_position = position
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		root.push_input(event, true)
	await process_frame
	await process_frame


static func _planar(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
