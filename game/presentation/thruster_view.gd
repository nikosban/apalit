extends Node3D
## UX round (P9, T25) propulsion effects, presentation only: reads every ship under Ships
## (produced ships included, found each tick) and never writes to them. The emitters are
## the black thruster parts of each model (Model/Thrusters: a MainEngine cylinder, its
## rear face the nozzle, and the jet boxes Retro_L/R, Bow_L/R, Lateral_L/R, Stern_L/R,
## each firing from its outer face). Every physics tick (after the ships) the ship-frame
## acceleration comes from the change of Locomotion.velocity and the turn acceleration
## from the change of angular_velocity; each jet's intensity is that acceleration as a
## share of its limit, smoothed over SMOOTH, zero without propulsion. Jets fire together
## when the motions combine (main engine and turning jets while accelerating through a
## turn). The main engine shows a plume (bright core, soft glow) in one of three states:
## BOOST while accelerating forward, THRUST while cruising forward, IDLE otherwise with
## propulsion on (stopped, braking, turning, sideways), NONE without; plume and jets are
## sized from the parts (the Miner's are the reference). Everything is drawn under this
## node, never under a ship, so picking, outlines and rings see only the parts.

enum State { NONE, IDLE, THRUST, BOOST }

const PLUME_SHADER := preload("res://game/presentation/thruster_plume.gdshader")
const SMOOTH := 0.08 # s
const THRESHOLD := 0.02 # Intensity above which a jet is drawn (and the main engine counts as firing).
const CRUISE_SPEED := 0.2 # u/s forward speed above which a ship not braking is cruising
const PLUME_BLEND := 0.15 # s to blend between plume states
const CORE_LENGTH := 0.75 # Share of the plume length.
const REFERENCE_ENGINE := 0.2 # u: the Miner's engine radius, for which PLUME is sized
const REFERENCE_JET := 0.14 # u: the Miner's jet box, for which JETS lengths are sized
# State -> [length, core radius, glow radius, intensity] for the reference engine.
const PLUME := {
	State.NONE: [0.0, 0.0, 0.0, 0.0],
	State.IDLE: [0.08, 0.12, 0.18, 0.35], # Flat: a glow on the nozzle, no cone (no active thrust).
	State.THRUST: [1.3, 0.09, 0.2, 0.75],
	State.BOOST: [2.1, 0.11, 0.25, 1.0],
}
const CORE_COLOR := Color(1.0, 0.92, 0.75)
const GLOW_COLOR := Color(1.0, 0.45, 0.12)
# Jet -> [exhaust direction (ship frame, bow -Z), length at full thrust for the reference box].
const JETS := {
	"Retro_L": [Vector3(0, 0, -1), 1.3], "Retro_R": [Vector3(0, 0, -1), 1.3],
	"Lateral_L": [Vector3(-1, 0, 0), 1.2], "Lateral_R": [Vector3(1, 0, 0), 1.2],
	"Bow_L": [Vector3(-1, 0, 0), 1.0], "Bow_R": [Vector3(1, 0, 0), 1.0],
	"Stern_L": [Vector3(-1, 0, 0), 1.0], "Stern_R": [Vector3(1, 0, 0), 1.0],
}
const JET_WIDTH := 0.16 # u for the reference box
const JET_BASE := Color(0.55, 0.8, 1.0)
const JET_END := Color(0.3, 0.5, 1.0)

@export var ships_path := NodePath("../Ships")

var _ships := {} # ship instance id -> record (see _register()); ids, as ships can be freed
var _jets_mesh := ImmediateMesh.new()

@onready var _ships_node := get_node(ships_path)


func _ready() -> void:
	process_physics_priority = 1000 # After the ships' own physics.
	var jets := MeshInstance3D.new()
	jets.name = "Jets"
	jets.mesh = _jets_mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	jets.material_override = material
	jets.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(jets)


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
	_jets_mesh.clear_surfaces()
	var drawing := false
	var flicker := 0.9 + 0.1 * sin(Time.get_ticks_msec() * 0.05)
	for id: int in _ships.keys():
		if not _alive(id):
			_forget(id) # Removed since the last physics tick.
			continue
		var record: Dictionary = _ships[id]
		if record.is_empty():
			continue
		var ship: Node3D = record.ship
		# Combat migration: nothing is drawn for a ship whose 3D presentation the scene does
		# not show (strategic zoom, or a hostile ship hidden by the fog of war); its effect
		# state is kept.
		var scene := get_parent()
		if scene.has_method("model_shown") and not scene.model_shown(ship):
			if record.get("plume") != null:
				(record.plume as Node3D).visible = false
			continue
		_update_plume(ship, record, delta)
		var to_world: Transform3D = ship.global_transform
		for jet: String in record.jets:
			var strength: float = record.intensity[jet]
			if strength <= THRESHOLD:
				continue
			if not drawing:
				_jets_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
				drawing = true
			var emitter: Array = record.jets[jet] # [position, direction, length, width]
			var origin: Vector3 = to_world * (emitter[0] as Vector3)
			var direction: Vector3 = (to_world.basis * (emitter[1] as Vector3)).normalized()
			var tip: Vector3 = origin + direction * float(emitter[2]) * strength * flicker
			var side: Vector3 = direction.cross(Vector3.UP).normalized() * float(emitter[3])
			var up: Vector3 = Vector3.UP * float(emitter[3])
			var base := Color(JET_BASE, 0.85 * strength)
			var end := Color(JET_END, 0.0)
			for offset: Vector3 in [side, up]:
				for point: Array in [[origin - offset, base], [origin + offset, base], [tip, end]]:
					_jets_mesh.surface_set_color(point[1])
					_jets_mesh.surface_add_vertex(point[0])
	if drawing:
		_jets_mesh.surface_end()


## The plume state of a ship (NONE for a ship without thrusters or not yet seen).
func state_of(ship: Node3D) -> State:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	return record.get("state", State.NONE)


## A jet's current intensity 0..1 ("Main" for the main engine).
func intensity_of(ship: Node3D, jet: String) -> float:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	return record.intensity.get(jet, 0.0) if not record.is_empty() else 0.0


## The node carrying a ship's plume (its origin at the nozzle, +Y along the exhaust), or null.
func plume_of(ship: Node3D) -> Node3D:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	return record.get("plume") if not record.is_empty() else null


## A ship's emitters in its own frame: jet name -> [position, exhaust direction], and
## "Main" -> [nozzle, direction]; empty for a ship without thrusters.
func emitters_of(ship: Node3D) -> Dictionary:
	var record: Dictionary = _ships.get(ship.get_instance_id(), {})
	if record.is_empty():
		return {}
	var result := {"Main": [record.nozzle, Vector3(0, 0, 1)]}
	for jet: String in record.jets:
		result[jet] = [record.jets[jet][0], record.jets[jet][1]]
	return result


# Reads a ship's thruster parts into a record: {ship, locomotion, nozzle, scale, jets {name:
# [position, direction, length, width]}, intensity {name: 0..1}, previous velocity / turn
# rate, state, plume node and its [length, core, glow, intensity] now}. A ship without
# Model/Thrusters gets an empty record (nothing drawn).
func _register(ship: Node3D) -> void:
	var thrusters := ship.get_node_or_null("Model/Thrusters")
	var locomotion := ship.get_node_or_null("Locomotion")
	var engine: MeshInstance3D = null
	if thrusters != null:
		engine = thrusters.get_node_or_null("MainEngine") as MeshInstance3D
	if engine == null or locomotion == null:
		_ships[ship.get_instance_id()] = {}
		return
	var to_ship := ship.global_transform.affine_inverse()
	var cylinder := engine.mesh as CylinderMesh
	var engine_transform: Transform3D = to_ship * engine.global_transform
	var record := {
		"ship": ship,
		"locomotion": locomotion,
		"nozzle": engine_transform.origin + Vector3(0, 0, cylinder.height / 2.0),
		"scale": cylinder.bottom_radius / REFERENCE_ENGINE,
		"jets": {},
		"intensity": {"Main": 0.0},
		"velocity": locomotion.velocity,
		"rate": locomotion.angular_velocity,
		"state": State.NONE,
		"now": [0.0, 0.0, 0.0, 0.0],
	}
	for jet: String in JETS:
		var part := thrusters.get_node_or_null(jet) as MeshInstance3D
		if part == null:
			continue
		var box: float = (part.mesh as BoxMesh).size.x
		var direction: Vector3 = JETS[jet][0]
		var size := box / REFERENCE_JET
		var at: Vector3 = (to_ship * part.global_transform).origin + direction * box / 2.0
		record.jets[jet] = [at, direction, float(JETS[jet][1]) * size, JET_WIDTH * size]
		record.intensity[jet] = 0.0
	record["plume"] = _make_plume()
	_ships[ship.get_instance_id()] = record


func _alive(id: int) -> bool:
	return is_instance_id_valid(id) and (instance_from_id(id) as Node).is_inside_tree()


func _forget(id: int) -> void:
	var record: Dictionary = _ships[id]
	if not record.is_empty():
		(record.plume as Node).queue_free()
	_ships.erase(id)


func _make_plume() -> Node3D:
	var plume := Node3D.new()
	plume.name = "Plume"
	for part: Array in [["Core", CORE_COLOR, 1.2], ["Glow", GLOW_COLOR, 2.5]]:
		var cone := CylinderMesh.new()
		cone.height = 1.0
		cone.bottom_radius = 1.0 # Wide end (-Y) on the nozzle, closing at +Y.
		cone.top_radius = 0.0
		cone.radial_segments = 24
		cone.rings = 4
		cone.cap_top = false
		cone.cap_bottom = false
		var material := ShaderMaterial.new()
		material.shader = PLUME_SHADER
		material.set_shader_parameter("color", part[1])
		material.set_shader_parameter("edge_power", part[2])
		var instance := MeshInstance3D.new()
		instance.name = part[0]
		instance.mesh = cone
		instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		plume.add_child(instance)
	plume.visible = false
	add_child(plume)
	return plume


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
		elif velocity.dot(forward) > CRUISE_SPEED and record.intensity.get("Retro_L", 0.0) <= THRESHOLD:
			state = State.THRUST
		else:
			state = State.IDLE
	record.state = state


# Blends the plume toward its state and places it on the nozzle (+Y along the exhaust).
func _update_plume(ship: Node3D, record: Dictionary, delta: float) -> void:
	var now: Array = record.now
	var target: Array = PLUME[record.state]
	var k := clampf(delta / PLUME_BLEND, 0.0, 1.0)
	var size: float = record.scale
	for i in 4:
		now[i] = lerpf(now[i], float(target[i]) * (size if i < 3 else 1.0), k)
	var plume: Node3D = record.plume
	var length: float = now[0]
	plume.visible = length > 0.01 * size
	if not plume.visible:
		return
	plume.global_transform = ship.global_transform * Transform3D(Basis(Vector3.RIGHT, PI / 2), record.nozzle as Vector3)
	var core: MeshInstance3D = plume.get_node("Core")
	var glow: MeshInstance3D = plume.get_node("Glow")
	var core_length := length * CORE_LENGTH
	core.transform = Transform3D(Basis.from_scale(Vector3(now[1], core_length, now[1])), Vector3(0, core_length / 2.0, 0))
	glow.transform = Transform3D(Basis.from_scale(Vector3(now[2], length, now[2])), Vector3(0, length / 2.0, 0))
	(core.material_override as ShaderMaterial).set_shader_parameter("intensity", now[3])
	(glow.material_override as ShaderMaterial).set_shader_parameter("intensity", now[3] * 0.6)
