extends SceneTree
## Combat migration M6: combat behavior with real production docking, on main.tscn (real
## stations, real right-clicks through the scene's input, the production Behavior on an
## FF-01 added where the starting warships were). Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/combat_docking_test.gd
##   K1 a guarding FF-01 receives Dock (right-click on the Station): Guard ends for good,
##      the station has movement authority, Behavior requests nothing, it docks normally
##   K2 Behavior's own movement requests are refused while the station has the ship
##      (approach, entry, docked, exit), nothing changes
##   K3 a player Move given during the controlled exit is held, runs when control ends and
##      is recorded as the player's Move; an Aggressive ship with a hostile in contact does
##      not override it before arrival (the held-command defect found in the audit)
##   K4 destroying a docked ship releases its station records at once; the hulk is removed
##   K5 destruction during the controlled entry and during the controlled exit leaves no
##      reservation, queue entry, hold or exit corridor behind; the berth serves the next
##      ship once the hulk is gone
##   K6 civilian ships carry no Behavior: mining and transport keep sole ownership of their
##      movement orders

const MAIN := preload("res://main.tscn")
const FF01 := preload("res://game/ships/ff01_unit.tscn")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const Docking := preload("res://game/stations/docking.gd")
const DT := 1.0 / 60.0

var scene: Node3D
var station: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _load()
	await _k1_k3()
	await _k4()
	await _load()
	await _k5()
	await _k6()
	_free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


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


func _load() -> void:
	_free()
	scene = MAIN.instantiate()
	var ff01: Node3D = FF01.instantiate()
	ff01.name = "FF01"
	ff01.position = Vector3(0, 1.5, 0)
	scene.get_node("Ships").add_child(ff01)
	root.add_child(scene)
	station = scene.get_node("Stations/Station")
	for i in 10:
		await physics_frame


func _ship(name: String) -> Node3D:
	return scene.get_node("Ships").get_node_or_null(name)


func _run(seconds: float, until: Callable = Callable()) -> bool:
	for i in roundi(seconds / DT):
		await physics_frame
		if until.is_valid() and until.call():
			return true
	return false


## A real right-click at a world point (the camera centred on it first).
func _right_click(point: Vector3) -> void:
	scene.get_node("CameraRig").global_position = Vector3(point.x, 0.0, point.z)
	await process_frame
	var screen := root.get_camera_3d().unproject_position(point)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = pressed
		event.position = screen
		event.global_position = screen
		root.push_input(event, true)
	await process_frame


# Every record a station keeps of a ship: berth reservation, queue entry, hold, exit.
func _records(of_station: Node3D, ship: Object) -> Array:
	var found := []
	for i in of_station.slots.size():
		if is_same(of_station.slots[i].ship, ship):
			found.append("berth %d" % i)
	for entry: Dictionary in of_station.queue:
		if is_same(entry.ship, ship):
			found.append("queue")
	for hold: Dictionary in of_station.holds:
		if is_same(hold.ship, ship):
			found.append("hold")
	if of_station._exiting.any(func(other: Variant) -> bool: return is_same(other, ship)):
		found.append("exit corridor")
	return found


func _k1_k3() -> void:
	print("\n=== K1 Guard, then Dock at a real station")
	var ff01 := _ship("FF01")
	var b = Behavior.of(ff01)
	var docking: Docking = ff01.get_node("Docking")
	var locomotion = ff01.get_node("Locomotion")
	var follower = ff01.get_node("RouteFollower")
	scene.orders.guard([ff01], _ship("Transporter"))
	await _run(3.0)
	var guarding: bool = b.command == Behavior.Command.GUARD and b.guard_target == _ship("Transporter")
	scene.selection().set_selection([ff01])
	await _right_click(station.global_position)
	await physics_frame
	var handed: bool = b.command == Behavior.Command.DOCK and b.guard_target == null and docking.is_docking_at(station)
	var requests_before: int = b.move_requests
	var refused := {"approach": [], "entry": [], "docked": []}
	var plans_ok := true
	var states := []
	var docked := await _run(150.0, func() -> bool:
		if states.is_empty() or states[-1] != docking.state_name():
			states.append(docking.state_name())
		var phase := "entry" if docking.under_control() else ("docked" if docking.state == Docking.State.DOCKED else "approach")
		if (refused[phase] as Array).size() < 3:
			var plans: int = follower.plans
			var state: int = docking.state
			(refused[phase] as Array).append(scene.autonomous_move(ff01, Vector2(-20, 12)))
			plans_ok = plans_ok and follower.plans == plans and docking.state == state
		return docking.state == Docking.State.DOCKED)
	_check("Guard then a right-click on the Station: Guard ends for good, the command is Dock, the station has the ship (%s)" % str(states),
		guarding and handed and docked)
	_check("while docking, Behavior made no movement request (%d) and the station saw no refused or erroneous order (%d / %d / %d)" % [
		b.move_requests - requests_before, locomotion.guided_order_errors, follower.guided_refusals, docking.refused_during_control],
		b.move_requests == requests_before and locomotion.guided_order_errors == 0 and follower.guided_refusals == 0 and docking.refused_during_control == 0)
	print("\n=== K2 autonomous requests refused under the station")
	var all_refused: bool = refused.values().all(func(list: Array) -> bool: return not list.is_empty() and list.all(func(r: bool) -> bool: return not r))
	_check("autonomous_move refused on the approach, in the controlled entry and docked (%s); no plan, docking unchanged" % str(refused), all_refused and plans_ok)
	print("\n=== K3 player Move held during the controlled exit")
	scene.orders.set_stance([ff01], CombatShip.Stance.AGGRESSIVE)
	var raider: Node3D = FF01.instantiate()
	raider.name = "Raider"
	raider.get_node("Combat").faction = 1
	raider.get_node("Combat").stance = CombatShip.Stance.HOLD_FIRE
	raider.transform = Transform3D(Basis(), Vector3(-60, 1.5, 30))
	scene.get_node("Ships").add_child(raider)
	scene.register_ship(raider) # As a ship added at run time (picking, notices, removal).
	docking.undock()
	await _run(1.0)
	var exit_refused: bool = docking.under_control() and not scene.autonomous_move(ff01, Vector2(-20, 12))
	var click := Vector3(-20, 0, 12)
	await _right_click(click)
	var held: bool = docking.under_control() and docking.has_held_command() and b.command == Behavior.Command.DOCK
	var released := await _run(60.0, func() -> bool: return not docking.under_control())
	await physics_frame
	var recorded: bool = b.command == Behavior.Command.MOVE and locomotion.has_destination and follower.requested.distance_to(Vector2(click.x, click.z)) < 3.0
	var in_contact: bool = CombatShip.of(ff01).target_status(raider) == CombatShip.TargetState.VALID
	var requests: int = b.move_requests
	var destination: Vector2 = locomotion.destination
	var kept := true
	var arrived := await _run(60.0, func() -> bool:
		kept = kept and (not locomotion.has_destination or locomotion.destination.distance_to(destination) < 0.01)
		return not locomotion.has_destination)
	_check("a right-click during the controlled exit is held (autonomous request refused there too) and runs when control ends", exit_refused and held and released)
	_check("the released Move is recorded as the player's Move (%s), toward the clicked point" % Behavior.COMMAND_NAMES[b.command if not arrived else Behavior.Command.MOVE], recorded)
	_check("Aggressive with a hostile in contact (%s): no autonomous request, destination kept until arrival (%d requests)" % [in_contact, b.move_requests - requests],
		in_contact and arrived and kept and b.move_requests == requests and locomotion.planar_position.distance_to(destination) < 1.5)


func _k4() -> void:
	print("\n=== K4 destroyed while docked")
	var ff01 := _ship("FF01")
	var docking: Docking = ff01.get_node("Docking")
	scene.selection().set_selection([ff01])
	await _right_click(station.global_position)
	var docked := await _run(150.0, func() -> bool: return docking.state == Docking.State.DOCKED)
	var before := _records(station, ff01)
	CombatShip.of(ff01).destroy()
	var after := _records(station, ff01)
	var gone: WeakRef = weakref(ff01)
	ff01 = null
	var removed := await _run(4.0, func() -> bool: return gone.get_ref() == null)
	_check("docked (%s), then destroyed: station records %s -> %s at once; hulk removed" % [docked, str(before), str(after)],
		docked and before == ["berth %d" % before[0].substr(6).to_int()] and after.is_empty() and removed)


func _k5() -> void:
	print("\n=== K5 destroyed during the controlled entry and the controlled exit")
	var miner := _ship("Miner2")
	var docking: Docking = miner.get_node("Docking")
	scene._order(miner, {"kind": scene.CommandKind.DOCK, "station": station})
	var entering := await _run(150.0, func() -> bool: return docking.under_control())
	var berth: int = docking.slot
	var before := _records(station, miner)
	CombatShip.of(miner).destroy()
	var after := _records(station, miner)
	var gone: WeakRef = weakref(miner)
	miner = null
	await _run(4.0, func() -> bool: return gone.get_ref() == null)
	_check("destroyed in the controlled entry (%s): records %s -> %s; hulk removed" % [entering, str(before), str(after)],
		entering and not before.is_empty() and after.is_empty() and gone.get_ref() == null)
	# The berth serves the next ship once the hulk is gone.
	var next := _ship("Miner1")
	var next_docking: Docking = next.get_node("Docking")
	scene._order(next, {"kind": scene.CommandKind.DOCK, "station": station})
	var served := await _run(180.0, func() -> bool: return next_docking.state == Docking.State.DOCKED)
	_check("the next ship docks normally afterwards (berth %d, now %s)" % [berth, next_docking.state_name()], served)
	next_docking.undock()
	var exiting := await _run(10.0, func() -> bool: return next_docking.under_control() and next_docking.state == Docking.State.UNDOCKING)
	await _run(2.0)
	before = _records(station, next)
	CombatShip.of(next).destroy()
	after = _records(station, next)
	gone = weakref(next)
	next = null
	await _run(4.0, func() -> bool: return gone.get_ref() == null)
	var errors_free: bool = station.slots.all(func(s: Dictionary) -> bool: return s.ship == null or is_instance_valid(s.ship))
	await _run(2.0) # Stations keep processing: no stale entry is touched.
	_check("destroyed in the controlled exit (%s): records %s -> %s; every berth free or held by a live ship" % [exiting, str(before), str(after)],
		exiting and before.has("exit corridor") and after.is_empty() and errors_free and gone.get_ref() == null)


func _k6() -> void:
	print("\n=== K6 civilian ships")
	var civilians := ["Transporter"].map(func(n: String) -> Node3D: return _ship(n))
	var none: bool = civilians.all(func(s: Node3D) -> bool: return s != null and s.get_node_or_null("Behavior") == null)
	var armed: bool = ["FF01"].all(func(n: String) -> bool: return _ship(n).get_node_or_null("Behavior") != null)
	_check("no Behavior on the civilian ships (Transporter; the Miners were removed above); the armed FF-01 has one",
		none and armed)
