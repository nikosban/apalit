extends SceneTree
## Headless UX round P3 (T07) checks on the playable main scene: a Mining Ship faces
## its asteroid while mining. Once its arrival at the working point is complete the
## Mining operation asks Locomotion.face() for the bearing to the asteroid's centre;
## Locomotion's ordinary bounded rotation turns it in place; extraction runs only while
## the bow is within 1 degree (MiningOperation.ALIGN_TOLERANCE), and the beam only
## while it extracts. Extraction per second of aligned mining is unchanged at 30 / 60 /
## 144 Hz. Ship physics is stepped manually in the game's order.
## Run from the project folder:
##   <godot console> --headless --path . -s res://game/tests/mining_facing_test.gd
## Every check is PASS/FAIL.

const MAIN := preload("res://main.tscn")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const ShipLocomotion := preload("res://game/locomotion/ship_locomotion.gd")
const SHIPS := ["Frigate", "Gunship", "Destroyer", "Miner1", "Miner2", "Transporter"]
const PARK := {"Frigate": Vector2(40, 30), "Gunship": Vector2(40, 15), "Destroyer": Vector2(40, -5), "Miner1": Vector2(40, -20),
	"Miner2": Vector2(40, -32), "Transporter": Vector2(60, 50)}
const SEED := 20261014
const MISALIGNED := 2 # From the spawn this asteroid's working point is reached 43 deg off its bearing (T06 probe).
const BOW := Vector3(0.0, 0.0, -1.2) # MiningView's beam start, ship frame.

var _main: Node
var _nav: Node
var _field: Node
var _view: Node
var _dt := 1.0 / 60.0
var _failures := 0
var _checks := 0


func _initialize() -> void:
	await process_frame
	_main = MAIN.instantiate()
	root.add_child(_main)
	_nav = _main.get_node("StaticNavigation")
	_field = _main.get_node("Asteroids")
	_view = _main.get_node("MiningView")
	_main.get_node("Survey").set_physics_process(false)
	for station in _main.get_node("Stations").get_children():
		station.set_physics_process(false)
	for s in SHIPS:
		for child in _ship(s).get_children():
			child.set_physics_process(false)
	for s in SHIPS:
		while not _nav.is_ready(_n(s, "RouteFollower").planning_radius()):
			await physics_frame
	_test_align_before_extracting()
	_test_turned_away_pauses()
	_test_rates()
	_test_overrides()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(0 if _failures == 0 else 1)


# Arrival 43 deg off: no unit and no beam before the bow is within 1 deg; then it
# extracts at 20 / s, stays aligned without oscillation or drift.
func _test_align_before_extracting() -> void:
	_dt = 1.0 / 60.0
	_start(MISALIGNED)
	var mining := _mining()
	var lo := _lo()
	var ticks := 0
	while mining.status != MiningOperation.Status.MINING and ticks < 60 * 180:
		_step()
		ticks += 1
	var err0 := _error()
	var early_units := 0
	var early_beam := 0
	var turn_ticks := 0
	while not mining.extracting and turn_ticks < 60 * 10:
		_step()
		turn_ticks += 1
		if not mining.extracting:
			early_units = maxi(early_units, _cargo())
			_view._process(0.0)
			early_beam = maxi(early_beam, _view.beam_count)
	_view._process(0.0)
	var beam_now: int = _view.beam_count
	var err_at_start := _error()
	_check("arrival %.1f deg off the asteroid's bearing: nothing extracted and no beam while turning (%d units, %d beams, %.2f s), status Mining throughout"
		% [err0, early_units, early_beam, turn_ticks * _dt], err0 > 5.0 and early_units == 0 and early_beam == 0 and mining.status == MiningOperation.Status.MINING)
	_check("extraction starts once the bow is within 1 deg (%.3f deg); the beam is drawn from the bow" % err_at_start, mining.extracting and err_at_start <= 1.0 and beam_now == 1)
	var at := lo.planar_position
	var cargo0 := _cargo()
	var worst := 0.0
	var always := true
	for tick in 60 * 20:
		_step()
		worst = maxf(worst, _error())
		always = always and mining.extracting
	_check("20 s after alignment: always extracting, error at most %.4f deg, no drift (%.5f u), %d units (20 / s)" % [worst, lo.planar_position.distance_to(at), _cargo() - cargo0],
		always and worst <= 1.0 and lo.planar_position.distance_to(at) < 0.0001 and _cargo() - cargo0 == 400)
	_check("the beam's bow point lies on the bearing to the asteroid's centre (%.3f deg)" % _bow_error(), _bow_error() <= 1.0)


# Heading forced 180 deg away at the working point: extraction pauses while it turns
# back, then resumes; no units in the pause.
func _test_turned_away_pauses() -> void:
	_dt = 1.0 / 60.0
	_start(MISALIGNED)
	var mining := _mining()
	var ticks := 0
	while not mining.extracting and ticks < 60 * 180:
		_step()
		ticks += 1
	var lo := _lo()
	lo.place(lo.planar_position, wrapf(lo.heading + PI - 0.01, -PI, PI))
	var cargo0 := _cargo()
	_step()
	var paused := 1
	while not mining.extracting and paused < 60 * 10:
		_step()
		paused += 1
	var gained := _cargo() - cargo0
	_check("turned away 180 deg: extraction paused %.2f s (%d units meanwhile), Mining kept, realigned within 1 deg (%.3f deg) and extracting again"
		% [paused * _dt, gained, _error()], paused > 60 and gained <= 1 and mining.status == MiningOperation.Status.MINING and mining.extracting and _error() <= 1.0)


# The same aligned mining time gives the same units at 30, 60 and 144 Hz.
func _test_rates() -> void:
	var results: Array[String] = []
	var ok := true
	for hz: float in [30.0, 60.0, 144.0]:
		_dt = 1.0 / hz
		_start(MISALIGNED)
		var mining := _mining()
		var ticks := 0
		while not mining.extracting and ticks < int(180.0 / _dt):
			_step()
			ticks += 1
		var cargo0 := _cargo()
		var active := 0
		for tick in int(round(10.0 / _dt)):
			_step()
			active += 1 if mining.extracting else 0
		var units := _cargo() - cargo0
		results.append("%d Hz: %d units in %.3f s aligned" % [hz, units, active * _dt])
		ok = ok and active == int(round(10.0 / _dt)) and units == 200
	_check("10 s of aligned mining: %s" % ", ".join(results), ok)


# Orders and guidance override the request; an empty tank holds the ship (limitation).
func _test_overrides() -> void:
	_dt = 1.0 / 60.0
	var lo := _lo()
	_reset()
	lo.place(PARK["Miner1"], 0.0)
	_n("Miner1", "RouteFollower").order(PARK["Miner1"] + Vector2(-20, 0))
	_step()
	_check("face() refused while the ship has a destination", not lo.face(1.0))
	_reset()
	var station: Node3D = _main.get_node("Stations/Station")
	lo.place(_nav.closest_point(2.6, Vector2(station.global_position.x, station.global_position.z) + Vector2(55, 0)), 0.0)
	_n("Miner1", "Docking").dock(station)
	var ticks := 0
	while not lo.guided and ticks < 60 * 120:
		_step()
		ticks += 1
	_check("face() refused while the station guides the ship", lo.guided and not lo.face(1.0))
	_reset()
	lo.place(PARK["Miner1"], 0.0)
	lo.face(deg_to_rad(120.0))
	for tick in 20:
		_step()
	var target: Vector2 = PARK["Miner1"] + Vector2(-20, 0)
	_n("Miner1", "RouteFollower").order(target)
	for tick in 60 * 20:
		_step()
	_check("an order given mid-turn replaces the request: arrives facing its travel bearing (%.1f deg)" % rad_to_deg(lo.heading),
		not lo.has_destination and lo.planar_position.distance_to(target) < 0.05 and absf(rad_to_deg(lo.heading) - 90.0) < 0.5)
	# Documented limitation: without fuel the ship cannot turn, so a misaligned Miner does not extract.
	_start(MISALIGNED)
	var mining := _mining()
	ticks = 0
	while mining.status != MiningOperation.Status.MINING and ticks < 60 * 180:
		_step()
		ticks += 1
	for tick in 5:
		_step()
	lo.place(lo.planar_position, wrapf(lo.heading + PI / 2.0, -PI, PI))
	(_n("Miner1", "Fuel") as Node)._set_fuel(0.0)
	var cargo0 := _cargo()
	for tick in 60 * 5:
		_step()
	_check("limitation: out of fuel and turned away, it cannot turn and does not extract (%d units in 5 s, %.1f deg off)" % [_cargo() - cargo0, _error()],
		_cargo() == cargo0 and _error() > 80.0)
	(_n("Miner1", "Fuel") as Node)._set_fuel(100.0)


# ------------------------------------------------------------------ helpers
func _start(asteroid: int) -> void:
	_reset()
	_field.generate(SEED)
	_lo().place(_nav.closest_point(2.6, PARK["Miner1"]), 0.0)
	_mining().assign(asteroid)


func _error() -> float:
	var c: Vector3 = _field.center(_mining().target)
	var lo := _lo()
	return absf(rad_to_deg(wrapf(lo.bearing_heading(Vector2(c.x, c.z) - lo.planar_position) - lo.heading, -PI, PI)))


func _bow_error() -> float:
	var bow: Vector3 = _ship("Miner1").global_transform * BOW
	var c: Vector3 = _field.center(_mining().target)
	var lo := _lo()
	var to_center := Vector2(c.x, c.z) - lo.planar_position
	var to_bow := Vector2(bow.x, bow.z) - lo.planar_position
	return absf(rad_to_deg(to_bow.angle_to(to_center)))


func _cargo() -> int:
	return _n("Miner1", "Cargo").inventory.quantity()


func _step() -> void:
	for s in SHIPS:
		_n(s, "RouteFollower")._physics_process(_dt)
		_n(s, "Avoidance")._physics_process(_dt)
	for s in SHIPS:
		(_n(s, "Locomotion") as ShipLocomotion)._step(_dt)
	for s in SHIPS:
		for child in ["Mining", "Transport"]:
			var node := _ship(s).get_node_or_null(child)
			if node != null:
				node._physics_process(_dt)
		_n(s, "Docking")._physics_process(_dt)
		_n(s, "Fuel")._physics_process(_dt)
	for station in _main.get_node("Stations").get_children():
		station._physics_process(_dt)


func _reset() -> void:
	for s in SHIPS:
		var dk := _n(s, "Docking")
		dk.phase = 0
		dk.hold_command(Callable())
		(_n(s, "Locomotion") as ShipLocomotion).place(PARK[s], 0.0)
		dk.cancel()
		dk.state = 0
		dk.transfer = 0
		_n(s, "RouteFollower").clear()
		_n(s, "Avoidance").reset()
		_n(s, "Fuel")._set_fuel(_n(s, "Fuel").capacity)
		var cargo := _ship(s).get_node_or_null("Cargo")
		if cargo != null:
			cargo.inventory.amounts.clear()
	for m in ["Miner1", "Miner2"]:
		var mining := _main.get_node("Ships/%s/Mining" % m) as MiningOperation
		mining.cancel()
		mining.target = -1
		mining.status = MiningOperation.Status.NONE
		mining._route_pending = false
		mining.extracting = false
		_n(m, "Extractor").reset()
	for station in _main.get_node("Stations").get_children():
		for slot in station.slots:
			slot.ship = null
			slot.leaving = false
		for h in station.holds:
			h.ship = null
		station.queue.clear()
		station._exiting.clear()


func _ship(s: String) -> Node3D:
	return _main.get_node("Ships/" + s)


func _n(s: String, child: String) -> Node:
	return _main.get_node("Ships/%s/%s" % [s, child])


func _lo() -> ShipLocomotion:
	return _n("Miner1", "Locomotion") as ShipLocomotion


func _mining() -> MiningOperation:
	return _n("Miner1", "Mining") as MiningOperation


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-130s %s" % [label, "PASS" if ok else "FAIL"])
