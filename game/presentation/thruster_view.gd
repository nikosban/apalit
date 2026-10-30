extends Node3D
## UX round (P9, T25) propulsion effects, presentation only: reads every ship under Ships
## (produced ships included, found each tick) and never writes to them. The emitters are
## the black thruster parts of each model (Model/Thrusters: MainEngine cylinders (MainEngine,
## MainEngine2, ...), each rear face a nozzle with its own plume, and the jet boxes Retro_L/R, Bow_L/R, Lateral_L/R, Stern_L/R,
## each firing from its outer face). Every physics tick (after the ships) the ship-frame
## acceleration comes from the change of Locomotion.velocity and the turn acceleration
## from the change of angular_velocity; each jet's intensity is that acceleration as a
## share of its limit, smoothed over SMOOTH, zero without propulsion. Jets fire together
## when the motions combine (main engine and turning jets while accelerating through a
## turn). The main engine's state: BOOST while accelerating forward, THRUST while cruising
## forward (Stage 6B.2: also through minor braking below CRUISE_BRAKE, its plume dimming
## with the braking), IDLE otherwise with propulsion on (stopped, braking, turning,
## sideways), NONE without. The effects are the reusable thruster scenes (game/presentation/effects/thrusters/):
## one main_thruster_fx per main engine, driven by the state's thrust (MAIN_THRUST; BOOST
## 0.5 + 0.5 x the main intensity), and one directional_thruster_fx per jet, driven by the
## jet's intensity; both sized from the parts (the Miner's are the reference). Everything
## is placed under this node, never under a ship, so picking, outlines and rings see only
## the parts.

enum State { NONE, IDLE, THRUST, BOOST }

const MAIN_FX := preload("res://game/presentation/effects/thrusters/main_thruster_fx.tscn")
const JET_FX := preload("res://game/presentation/effects/thrusters/directional_thruster_fx.tscn")
const SMOOTH := 0.08 # s
const THRESHOLD := 0.02 # Intensity above which a jet fires (and the main engine counts as firing).
const CRUISE_SPEED := 0.2 # u/s forward speed above which a ship not braking is cruising
const PLUME_BLEND := 0.15 # s to blend the main thrust between states
const CRUISE_BRAKE := 0.35 # Stage 6B.2: retro intensity up to which a ship cruising forward keeps its plume (fading toward it)
const REFERENCE_ENGINE := 0.2 # u: the Miner's engine radius (main_thruster_fx nozzle_scale 1)
const REFERENCE_JET := 0.14 # u: the Miner's jet box (directional_thruster_fx nozzle_scale 1)
# Main engine thrust per state (BOOST: 0.5 + 0.5 x the main intensity). IDLE keeps the
# nozzle glow without exhaust; NONE turns the glow off too.
const MAIN_THRUST := {State.NONE: 0.0, State.IDLE: 0.0, State.THRUST: 0.5}
# Jet -> [exhaust direction (ship frame, bow -Z), length multiplier].
const JETS := {
	"Retro_L": [Vector3(0, 0, -1), 1.3], "Retro_R": [Vector3(0, 0, -1), 1.3],
	"Lateral_L": [Vector3(-1, 0, 0), 1.2], "Lateral_R": [Vector3(1, 0, 0), 1.2],
	"Bow_L": [Vector3(-1, 0, 0), 1.0], "Bow_R": [Vector3(1, 0, 0), 1.0],
	"Stern_L": [Vector3(-1, 0, 0), 1.0], "Stern_R": [Vector3(1, 0, 0), 1.0],
}

@export var ships_path := NodePath("../Ships")

var _ships := {} # ship instance id -> record (see _register()); ids, as ships can be freed

@onready var _ships_node := get_node(ships_path)


func _ready() -> void:
	process_physics_priority = 1000 # After the ships' own physics.


func _physics_process(delta: float) -> void:
	for id: int in _ships.keys():
		if not _alive(id):
			_forget(id)
	for ship: Node in _ships_node.get_children():
		if not _ships.has(ship.get_instance_id()):
			_register(ship as Node3D)
	for id: int in _ships:
		_sample(_ships[id], delta)


func _process(delta: float) -> void:
	for id: int in _ships.keys():
		if not _alive(id):
			_forget(id) # Removed since the last physics tick.
			continue
		var record: Dictionary = _ships[id]
		if record.is_empty():
			continue
		var ship: Node3D = record.ship
		# Combat migration: nothing is drawn for a ship whose 3D presentation the scene does
		# not show (a hostile ship hidden by the fog of war); its effect state is kept.
		var scene := get_parent()
		var shown: bool = not scene.has_method("model_shown") or scene.model_shown(ship)
		for effect: Node3D in _effects(record):
			effect.visible = shown
		if not shown:
			continue
		for engine: Dictionary in record.engines:
			_update_main(ship, record, engine, delta)
		for jet: String in record.jets:
			var emitter: Array = record.jets[jet] # [position, direction, effect]
			var effect: Node3D = emitter[2]
			effect.global_transform = ship.global_transform * Transform3D(Basis.looking_at(emitter[1] as Vector3), emitter[0] as Vector3)
			var strength: float = record.intensity[jet]
			effect.thrust = strength if strength > THRESHOLD else 0.0


## The plume state of a ship (NONE for a ship without thrusters or not yet seen).
func state_of(ship: Node3D) -> State:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	return record.get("state", State.NONE)


## A jet's current intensity 0..1 ("Main" for the main engine).
func intensity_of(ship: Node3D, jet: String) -> float:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	return record.intensity.get(jet, 0.0) if not record.is_empty() else 0.0


## A ship's first main engine effect (main_thruster_fx: origin on the nozzle, -Z along the
## exhaust), or null.
func plume_of(ship: Node3D) -> Node3D:
	var plumes := plumes_of(ship)
	return plumes[0] if not plumes.is_empty() else null


## Every main engine effect of a ship, in Model/Thrusters order.
func plumes_of(ship: Node3D) -> Array[Node3D]:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	var plumes: Array[Node3D] = []
	for engine: Dictionary in record.get("engines", []):
		plumes.append(engine.effect)
	return plumes


## A jet's effect (directional_thruster_fx: origin on the jet's outer face, -Z along the
## exhaust), or null.
func jet_of(ship: Node3D, jet: String) -> Node3D:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	var emitter: Array = record.get("jets", {}).get(jet, [])
	return emitter[2] if not emitter.is_empty() else null


## A ship's emitters in its own frame: jet name -> [position, exhaust direction], and
## "Main" -> [nozzle, direction] of the first main engine; empty for a ship without thrusters.
func emitters_of(ship: Node3D) -> Dictionary:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	if record.is_empty():
		return {}
	var result := {"Main": [record.nozzle, Vector3(0, 0, 1)]}
	for jet: String in record.jets:
		result[jet] = [record.jets[jet][0], record.jets[jet][1]]
	return result


# Reads a ship's thruster parts into a record: {ship, locomotion, nozzle (the first
# engine's), engines [{nozzle, effect, thrust now}], jets {name: [position, direction,
# effect]}, intensity {name: 0..1}, previous velocity / turn rate, state}. A ship without
# a MainEngine cylinder under Model/Thrusters gets an empty record (nothing drawn).
func _register(ship: Node3D) -> void:
	var thrusters := ship.get_node_or_null("Model/Thrusters")
	var locomotion := ship.get_node_or_null("Locomotion")
	var cylinders: Array[MeshInstance3D] = []
	if thrusters != null:
		for part: Node in thrusters.get_children():
			if String(part.name).begins_with("MainEngine") and part is MeshInstance3D:
				cylinders.append(part)
	if cylinders.is_empty() or locomotion == null:
		_ships[ship.get_instance_id()] = {}
		return
	var to_ship := ship.global_transform.affine_inverse()
	var engines: Array[Dictionary] = []
	for engine: MeshInstance3D in cylinders:
		var cylinder := engine.mesh as CylinderMesh
		var engine_transform: Transform3D = to_ship * engine.global_transform
		var effect: Node3D = MAIN_FX.instantiate()
		effect.nozzle_scale = cylinder.bottom_radius / REFERENCE_ENGINE
		effect.powered = false
		add_child(effect)
		engines.append({
			"nozzle": engine_transform.origin + Vector3(0, 0, cylinder.height / 2.0),
			"effect": effect,
			"thrust": 0.0,
		})
	var record := {
		"ship": ship,
		"locomotion": locomotion,
		"nozzle": engines[0].nozzle,
		"engines": engines,
		"jets": {},
		"intensity": {"Main": 0.0},
		"velocity": locomotion.velocity,
		"rate": locomotion.angular_velocity,
		"state": State.NONE,
	}
	for jet: String in JETS:
		var part := thrusters.get_node_or_null(jet) as MeshInstance3D
		if part == null:
			continue
		var box: float = (part.mesh as BoxMesh).size.x
		var direction: Vector3 = JETS[jet][0]
		var effect: Node3D = JET_FX.instantiate()
		effect.nozzle_scale = box / REFERENCE_JET
		effect.length_multiplier = JETS[jet][1]
		add_child(effect)
		var at: Vector3 = (to_ship * part.global_transform).origin + direction * box / 2.0
		record.jets[jet] = [at, direction, effect]
		record.intensity[jet] = 0.0
	_ships[ship.get_instance_id()] = record


func _alive(id: int) -> bool:
	return is_instance_id_valid(id) and (instance_from_id(id) as Node).is_inside_tree()


func _forget(id: int) -> void:
	var record: Dictionary = _ships[id]
	if not record.is_empty():
		for effect: Node3D in _effects(record):
			effect.queue_free()
	_ships.erase(id)


# Every effect node of a record: its main engines', then its jets'.
func _effects(record: Dictionary) -> Array[Node3D]:
	var effects: Array[Node3D] = []
	for engine: Dictionary in record.engines:
		effects.append(engine.effect)
	for jet: String in record.jets:
		effects.append(record.jets[jet][2])
	return effects


# One tick: the jets' intensities from the change of velocity and turn rate, then the
# plume state.
func _sample(record: Dictionary, delta: float) -> void:
	if record.is_empty() or delta <= 0.0:
		return
	var locomotion: Node = record.locomotion
	var velocity: Vector2 = locomotion.velocity
	var rate: float = locomotion.angular_velocity
	var heading: float = locomotion.heading
	var forward := Vector2(-sin(heading), -cos(heading))
	var right := Vector2(cos(heading), -sin(heading))
	var accel: Vector2 = (velocity - (record.velocity as Vector2)) / delta
	var turn: float = (rate - float(record.rate)) / delta / deg_to_rad(locomotion.turn_accel_deg)
	record.velocity = velocity
	record.rate = rate
	var along := accel.dot(forward)
	var across := accel.dot(right)
	var lateral := clampf(across / locomotion.lateral_accel, 0.0, 1.0)
	var retro := clampf(-along / locomotion.reverse_accel, 0.0, 1.0)
	var target := {
		"Main": clampf(along / locomotion.forward_accel, 0.0, 1.0),
		"Retro_L": retro, "Retro_R": retro,
		# Accelerating to the right: the left jet fires (exhaust to the left).
		"Lateral_L": lateral, "Lateral_R": clampf(-across / locomotion.lateral_accel, 0.0, 1.0),
		# Positive turn acceleration turns the bow left: bow right + stern left fire.
		"Bow_R": clampf(turn, 0.0, 1.0), "Stern_L": clampf(turn, 0.0, 1.0),
		"Bow_L": clampf(-turn, 0.0, 1.0), "Stern_R": clampf(-turn, 0.0, 1.0),
	}
	var k := clampf(delta / SMOOTH, 0.0, 1.0)
	var on: bool = locomotion.propulsion
	for jet: String in record.intensity:
		record.intensity[jet] = lerpf(record.intensity[jet], target[jet] if on else 0.0, k)
	var state := State.NONE
	if on:
		if record.intensity.Main > THRESHOLD:
			state = State.BOOST
		elif velocity.dot(forward) > CRUISE_SPEED and record.intensity.get("Retro_L", 0.0) < CRUISE_BRAKE:
			state = State.THRUST
		else:
			state = State.IDLE
	record.state = state


# Blends one engine's thrust toward the ship's state and places its effect on that
# engine's nozzle (-Z along the exhaust, the ship's +Z).
func _update_main(ship: Node3D, record: Dictionary, engine: Dictionary, delta: float) -> void:
	var target: float = MAIN_THRUST.get(record.state, 0.5 + 0.5 * float(record.intensity.Main))
	if record.state == State.THRUST:
		# Stage 6B.2: minor braking while cruising dims the plume instead of putting it out.
		target *= 1.0 - clampf(float(record.intensity.get("Retro_L", 0.0)) / CRUISE_BRAKE, 0.0, 1.0)
	var thrust := lerpf(engine.thrust, target, clampf(delta / PLUME_BLEND, 0.0, 1.0))
	engine.thrust = thrust if thrust > THRESHOLD or target > 0.0 else 0.0
	var effect: Node3D = engine.effect
	effect.global_transform = ship.global_transform * Transform3D(Basis.looking_at(Vector3(0, 0, 1)), engine.nozzle as Vector3)
	effect.thrust = engine.thrust
	effect.powered = record.state != State.NONE
