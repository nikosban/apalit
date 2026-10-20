extends Node3D
## Phase 2 Stage 1 asteroid resources: one deposit per asteroid mesh under this node
## (resource family, composition, finite reserves), generated once at start from a
## session seed. Deposits are keyed by each asteroid's stable `asteroid_id` (node
## metadata set in the scene), not by node names. Gameplay data only: the asteroid
## meshes, and with them navigation, collision and avoidance, are never changed.
##
## Each deposit depends only on the session seed and its asteroid id, so the same
## seed reproduces the same field whatever the scene order. Compositions are whole
## percentages; a mineral composition holds all six minerals (each at least 1 %),
## an ice composition is ice 100 %. Compositions are read-only once generated, so
## future chunks can carry them by reference.

enum Family { MINERALS, ICE }

const StaticNavigation := preload("res://game/navigation/static_navigation.gd")
const MINERALS: Array[StringName] = [&"iron", &"nickel", &"silicon", &"cobalt", &"gold", &"titanium"]
const ICE := &"ice"
const ID_META := &"asteroid_id"

@export var session_seed := 0 # 0: a new seed every session (printed at start); set it to reproduce a field.
@export var mineral_share := 0.65 # Chance of a mineral (not ice) asteroid (provisional).
@export var min_reserves := 500 # Abstract resource units (provisional).
@export var max_reserves := 5000 # Abstract resource units (provisional).

var seed_used := 0 # The session seed the current deposits were generated from.

var _deposits := {} # asteroid id -> Deposit
var _nodes := {} # asteroid id -> MeshInstance3D
var _centers := {} # asteroid id -> Vector3 (global centre)
var _radii := {} # asteroid id -> float (sphere radius, as navigation and collision read it)


class Deposit:
	var family: int # Family
	var composition: Dictionary # resource -> whole percent (sum 100), read-only
	var reserves: int # Remaining abstract resource units
	var extracted := {} # Phase 3: resource -> units extracted so far (every resource of the composition)
	var extracted_total := 0

	## Phase 3: the resource the next extracted unit is: the one furthest below its
	## share of everything extracted so far (ties: the composition's order, i.e.
	## MINERALS). Integer arithmetic, so the sequence is exact and depends only on the
	## units extracted before; each resource stays within one unit of its share.
	func next_resource() -> StringName:
		var best := &""
		var best_deficit := 0
		for resource: StringName in composition:
			var deficit: int = composition[resource] * (extracted_total + 1) - 100 * extracted[resource]
			if best == &"" or deficit > best_deficit:
				best = resource
				best_deficit = deficit
		return best


func _ready() -> void:
	for child in get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or not mesh_instance.mesh is SphereMesh:
			continue
		if not mesh_instance.has_meta(ID_META):
			push_error("Asteroid %s has no %s" % [mesh_instance.name, ID_META])
			continue
		var id: int = mesh_instance.get_meta(ID_META)
		if _nodes.has(id):
			push_error("Duplicate %s %d (%s)" % [ID_META, id, mesh_instance.name])
			continue
		_nodes[id] = mesh_instance
		_centers[id] = mesh_instance.global_position
		_radii[id] = StaticNavigation.round_radius(mesh_instance.mesh) * Vector2(mesh_instance.global_basis.x.x, mesh_instance.global_basis.x.z).length()
	var start_seed := session_seed
	if start_seed == 0:
		start_seed = randi() % 1000000 + 1
	generate(start_seed)
	print("Asteroid field seed: %d (%d asteroids)" % [seed_used, _nodes.size()])


## Generates every deposit from a session seed, replacing the current ones.
func generate(new_seed: int) -> void:
	seed_used = new_seed
	_deposits.clear()
	for id: int in _nodes:
		_deposits[id] = make_deposit(new_seed, id, mineral_share, min_reserves, max_reserves)


## One asteroid's deposit, from the session seed and its id only.
static func make_deposit(field_seed: int, id: int, share: float, reserves_min: int, reserves_max: int) -> Deposit:
	var rng := RandomNumberGenerator.new()
	rng.seed = field_seed * 1000003 + id
	var deposit := Deposit.new()
	deposit.family = Family.MINERALS if rng.randf() < share else Family.ICE
	if deposit.family == Family.ICE:
		deposit.composition = {ICE: 100}
	else:
		var weights := []
		for mineral in MINERALS:
			weights.append(rng.randf())
		deposit.composition = _whole_percents(weights)
	deposit.composition.make_read_only()
	for resource: StringName in deposit.composition:
		deposit.extracted[resource] = 0
	deposit.reserves = rng.randi_range(reserves_min, reserves_max)
	return deposit


# Six whole percentages, each at least 1, summing to exactly 100: 1 % each plus the
# remaining 94 % shared by weight (largest remainders get the leftover points).
static func _whole_percents(weights: Array) -> Dictionary:
	var total := 0.0
	for weight: float in weights:
		total += weight
	var spare := 100 - MINERALS.size()
	var shares := []
	var given := 0
	for weight: float in weights:
		var share := spare * weight / total if total > 0.0 else float(spare) / MINERALS.size()
		shares.append(share)
		given += floori(share)
	var order := range(MINERALS.size())
	order.sort_custom(func(a: int, b: int) -> bool: return shares[a] - floorf(shares[a]) > shares[b] - floorf(shares[b]))
	var composition := {}
	for i in MINERALS.size():
		composition[MINERALS[i]] = 1 + floori(shares[i])
	for k in spare - given:
		composition[MINERALS[order[k]]] += 1
	return composition


## Stable asteroid ids, ascending.
func ids() -> Array:
	var list := _nodes.keys()
	list.sort()
	return list


func deposit(id: int) -> Deposit:
	return _deposits.get(id)


## Removes up to `amount` units from an asteroid's reserves (never below zero) and
## returns them per resource ({resource: units}, Phase 3): each unit is the deposit's
## next resource in its fixed proportional sequence (Deposit.next_resource()), so the
## split depends only on how much the asteroid has given so far, not on the tick
## size or which miner extracts. The only writer of reserves; geometry is unchanged.
func extract(id: int, amount: int) -> Dictionary:
	var deposit: Deposit = _deposits[id]
	var removed := clampi(amount, 0, deposit.reserves)
	deposit.reserves -= removed
	var units := {}
	for unit in removed:
		var resource := deposit.next_resource()
		deposit.extracted[resource] += 1
		deposit.extracted_total += 1
		units[resource] = units.get(resource, 0) + 1
	return units


func node_of(id: int) -> MeshInstance3D:
	return _nodes.get(id)


func center(id: int) -> Vector3:
	return _centers[id]


func radius(id: int) -> float:
	return _radii[id]


## Distance on the X/Z plane from a point to the asteroid's outline (0 inside).
func surface_distance(id: int, point: Vector2) -> float:
	var c: Vector3 = _centers[id]
	return maxf(0.0, Vector2(c.x, c.z).distance_to(point) - _radii[id])


## Asteroid whose sphere a ray hits first, or -1.
func pick(origin: Vector3, direction: Vector3) -> int:
	var best := -1
	var best_t := INF
	for id: int in _nodes:
		var offset: Vector3 = origin - _centers[id]
		var r: float = _radii[id]
		var b := offset.dot(direction)
		var c := offset.length_squared() - r * r
		var disc := b * b - c
		if disc < 0.0:
			continue
		var t := -b - sqrt(disc)
		if t < 0.0:
			t = -b + sqrt(disc)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = id
	return best
