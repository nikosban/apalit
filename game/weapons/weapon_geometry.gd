extends RefCounted
## Combat (migrated from the prototype v0.2): procedural low-poly weapon placeholders from Godot primitive
## meshes (no external assets). Every size is a parameter; the mount transform comes
## from the weapon node (authored in the ship scene), so a production model can replace
## the generated children without touching the simulation. All geometry points along
## the mount's −Z (forward); muzzles sit just beyond the barrel end.

const MUZZLE_GAP := 0.03 # u beyond the barrel end

static var _materials := {}


static func material(key: String) -> StandardMaterial3D:
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		match key:
			"mount":
				m.albedo_color = Color(0.3, 0.31, 0.32)
				m.metallic = 0.5
				m.roughness = 0.55
			"housing":
				m.albedo_color = Color(0.46, 0.47, 0.48)
				m.metallic = 0.5
				m.roughness = 0.5
			"barrel":
				m.albedo_color = Color(0.16, 0.16, 0.17)
				m.metallic = 0.7
				m.roughness = 0.4
			"muzzle":
				m.albedo_color = Color(0.08, 0.08, 0.08)
				m.metallic = 0.3
				m.roughness = 0.6
			"ordnance":
				m.albedo_color = Color(0.78, 0.79, 0.8)
				m.metallic = 0.3
				m.roughness = 0.45
			"plume_torpedo", "plume_missile", "rcs":
				m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
				var colors := {"plume_torpedo": Color(1.0, 0.72, 0.35, 0.85), "plume_missile": Color(0.75, 0.88, 1.0, 0.9), "rcs": Color(0.92, 0.95, 1.0, 0.85)}
				m.albedo_color = colors[key]
			"band_0", "band_1":
				m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				m.albedo_color = [Color(0.35, 0.6, 1.0), Color(1.0, 0.35, 0.3)][int(key.right(1))]
		_materials[key] = m
	return _materials[key]


## Fixed forward cannon, `length` long from the mount origin to the barrel end, housing
## `radius` wide (half). Returns the muzzle marker.
##   MountBase (hull attachment) -> Housing -> Barrel -> MuzzleBrake, Muzzle
static func build_fixed(parent: Node3D, length: float, radius: float) -> Node3D:
	_box(parent, "MountBase", Vector3(radius * 2.4, radius * 1.2, length * 0.3), Vector3(0, 0, -length * 0.15), "mount")
	_box(parent, "Housing", Vector3(radius * 2.0, radius * 1.6, length * 0.4), Vector3(0, 0, -length * 0.4), "housing")
	_tube(parent, "Barrel", radius * 0.42, length * 0.38, Vector3(0, 0, -length * 0.79), "barrel")
	_tube(parent, "MuzzleBrake", radius * 0.6, length * 0.06, Vector3(0, 0, -length * 0.97), "muzzle")
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0, -length - MUZZLE_GAP)
	parent.add_child(muzzle)
	return muzzle


## Articulated turret: base `base_diameter` wide, body `body_height` tall, one barrel
## `barrel_length` long. Returns {yaw, pitch, muzzle}.
##   MountMesh (pedestal) ; YawPivot -> TurretBodyMesh, PitchPivot -> Mantlet, BarrelMesh, Muzzle
static func build_turret(parent: Node3D, base_diameter: float, body_height: float, barrel_length: float) -> Dictionary:
	var pedestal_height := base_diameter * 0.16
	var mount := MeshInstance3D.new()
	mount.name = "MountMesh"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = base_diameter * 0.5
	cylinder.bottom_radius = base_diameter * 0.5
	cylinder.height = pedestal_height
	cylinder.radial_segments = 12
	cylinder.rings = 1
	cylinder.material = material("mount")
	mount.mesh = cylinder
	mount.position = Vector3(0, pedestal_height * 0.5, 0)
	parent.add_child(mount)

	var yaw := Node3D.new()
	yaw.name = "YawPivot"
	yaw.position = Vector3(0, pedestal_height, 0)
	parent.add_child(yaw)
	_box(yaw, "TurretBodyMesh", Vector3(base_diameter * 0.78, body_height, base_diameter * 0.86), Vector3(0, body_height * 0.5, base_diameter * 0.04), "housing")

	var pitch := Node3D.new()
	pitch.name = "PitchPivot"
	pitch.position = Vector3(0, body_height * 0.6, -base_diameter * 0.39)
	yaw.add_child(pitch)
	_box(pitch, "Mantlet", Vector3(base_diameter * 0.34, body_height * 0.55, base_diameter * 0.14), Vector3(0, 0, -base_diameter * 0.04), "mount")
	_tube(pitch, "BarrelMesh", base_diameter * 0.08, barrel_length, Vector3(0, 0, -barrel_length * 0.5), "barrel")
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0, -barrel_length - MUZZLE_GAP)
	pitch.add_child(muzzle)
	return {"yaw": yaw, "pitch": pitch, "muzzle": muzzle}


## Gatling (v0.3): a turret-style mount carrying a three-barrel rotary cluster. Returns
## {yaw, pitch, muzzle, spinner}; `spinner` turns about the barrel axis while firing
## (visual only), the muzzle stays on the pitch pivot at the cluster's front centre.
##   MountMesh ; YawPivot -> TurretBodyMesh, PitchPivot -> Cradle, BarrelCluster -> Barrel1-3, Clamp ; Muzzle
static func build_gatling(parent: Node3D, base_diameter: float, body_height: float, barrel_length: float) -> Dictionary:
	var pedestal_height := base_diameter * 0.16
	var mount := MeshInstance3D.new()
	mount.name = "MountMesh"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = base_diameter * 0.5
	cylinder.bottom_radius = base_diameter * 0.5
	cylinder.height = pedestal_height
	cylinder.radial_segments = 12
	cylinder.rings = 1
	cylinder.material = material("mount")
	mount.mesh = cylinder
	mount.position = Vector3(0, pedestal_height * 0.5, 0)
	parent.add_child(mount)
	var yaw := Node3D.new()
	yaw.name = "YawPivot"
	yaw.position = Vector3(0, pedestal_height, 0)
	parent.add_child(yaw)
	_box(yaw, "TurretBodyMesh", Vector3(base_diameter * 0.7, body_height, base_diameter * 0.7), Vector3(0, body_height * 0.5, 0), "housing")
	var pitch := Node3D.new()
	pitch.name = "PitchPivot"
	pitch.position = Vector3(0, body_height * 0.6, -base_diameter * 0.35)
	yaw.add_child(pitch)
	_box(pitch, "Cradle", Vector3(base_diameter * 0.42, body_height * 0.6, base_diameter * 0.2), Vector3(0, 0, -base_diameter * 0.05), "mount")
	var spinner := Node3D.new()
	spinner.name = "BarrelCluster"
	spinner.position = Vector3(0, 0, -base_diameter * 0.15)
	pitch.add_child(spinner)
	var spread := base_diameter * 0.075
	var barrel_radius := base_diameter * 0.04
	for i in 3:
		var angle := TAU * i / 3.0
		_tube(spinner, "Barrel%d" % (i + 1), barrel_radius, barrel_length, Vector3(cos(angle) * spread, sin(angle) * spread, -barrel_length * 0.5), "barrel")
	_tube(spinner, "Clamp", spread + barrel_radius * 1.6, barrel_length * 0.08, Vector3(0, 0, -barrel_length * 0.7), "muzzle")
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0, -base_diameter * 0.15 - barrel_length - MUZZLE_GAP)
	pitch.add_child(muzzle)
	return {"yaw": yaw, "pitch": pitch, "muzzle": muzzle, "spinner": spinner}


## Torpedo tube (v0.3): a fixed launch tube `length` long along the mount's −Z with a
## dark opening; returns the muzzle marker just beyond the opening.
##   MountBase -> Tube -> Opening, Muzzle
static func build_tube(parent: Node3D, length: float, radius: float) -> Node3D:
	_box(parent, "MountBase", Vector3(radius * 2.4, radius * 1.4, length * 0.35), Vector3(0, 0, -length * 0.175), "mount")
	_tube(parent, "Tube", radius, length * 0.75, Vector3(0, 0, -length * 0.625), "housing")
	_tube(parent, "Opening", radius * 0.72, length * 0.03, Vector3(0, 0, -length + length * 0.012), "muzzle")
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0, -length - MUZZLE_GAP)
	parent.add_child(muzzle)
	return muzzle


## Missile deck launcher (v0.3): a low box on the deck with `cells` hatches; each muzzle
## marker sits just above its hatch, its −Z pointing up (+Y of the mount): missiles leave
## vertically. Returns the muzzle markers in cell order (cell 1 first).
## v0.4: `columns` across the mount (X); cells fill rows front to back (−Z first), left to
## right. One column is the v0.3 single row along Z (unchanged); with several columns each
## cell also gets a raised frame (`Cell%d`) so the cells read as separate.
##   Housing -> Cell1.. (columns > 1), Hatch1.., Muzzle1..
static func build_cells(parent: Node3D, width: float, height: float, depth: float, cells: int, columns: int = 1) -> Array[Node3D]:
	_box(parent, "Housing", Vector3(width, height, depth), Vector3(0, height * 0.5, 0), "housing")
	var muzzles: Array[Node3D] = []
	columns = clampi(columns, 1, cells)
	var rows := ceili(float(cells) / columns)
	var pitch := depth / rows
	var span := width / columns
	for i in cells:
		var z := -depth * 0.5 + pitch * (i / columns + 0.5)
		var x := -width * 0.5 + span * (i % columns + 0.5) if columns > 1 else 0.0
		if columns > 1:
			_box(parent, "Cell%d" % (i + 1), Vector3(span * 0.86, height * 0.1, pitch * 0.86), Vector3(x, height + height * 0.03, z), "mount")
		_box(parent, "Hatch%d" % (i + 1), Vector3(span * 0.7, height * 0.08, pitch * 0.72), Vector3(x, height + height * (0.1 if columns > 1 else 0.04), z), "muzzle")
		var marker := Marker3D.new()
		marker.name = "Muzzle%d" % (i + 1)
		marker.position = Vector3(x, height * (1.14 if columns > 1 else 1.08) + MUZZLE_GAP, z)
		marker.basis = Basis(Vector3.RIGHT, PI * 0.5) # −Z -> +Y
		parent.add_child(marker)
		muzzles.append(marker)
	return muzzles


## Guided ordnance model (v0.3), centred on the node, nose toward −Z: body, nose cone,
## faction band, rear nozzle and a small rear thrust plume (+Z, behind the nozzle);
## missiles add four fins and four tiny attitude (RCS) thrusters around the nose, each
## with a puff pointing outward (hidden until lit). Returns {plume, rcs (Array: +X, −X,
## +Y, −Y puffs), nozzle}.
static func build_ordnance(parent: Node3D, kind: StringName, length: float, radius: float, faction: int) -> Dictionary:
	var body_length := length * 0.68
	var nose_length := length * 0.22
	var nozzle_length := length * 0.1
	var body_center := -length * 0.5 + nose_length + body_length * 0.5
	_tube(parent, "Body", radius, body_length, Vector3(0, 0, body_center), "ordnance")
	var nose := _cone(parent, "Nose", radius, nose_length, Vector3(0, 0, -length * 0.5 + nose_length * 0.5), -1.0, "ordnance")
	nose.name = "Nose"
	_tube(parent, "Band", radius * 1.06, length * 0.07, Vector3(0, 0, -length * 0.5 + nose_length + length * 0.06), "band_%d" % faction)
	var nozzle := _cone(parent, "Nozzle", radius * 0.85, nozzle_length, Vector3(0, 0, length * 0.5 - nozzle_length * 0.5), -1.0, "muzzle")
	var plume_length := length * (0.36 if kind == &"torpedo" else 0.5)
	var plume := _cone(parent, "Plume", radius * 0.7, plume_length, Vector3(0, 0, length * 0.5 + plume_length * 0.5), 1.0, "plume_torpedo" if kind == &"torpedo" else "plume_missile")
	plume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rcs: Array[Node3D] = []
	if kind == &"missile":
		for i in 4:
			var angle := TAU * i / 4.0 + PI * 0.25
			var fin := _box(parent, "Fin%d" % (i + 1), Vector3(radius * 0.25, radius * 1.4, length * 0.16), Vector3(cos(angle) * radius * 1.3, sin(angle) * radius * 1.3, length * 0.5 - nozzle_length - length * 0.08), "housing")
			fin.basis = Basis(Vector3.BACK, angle - PI * 0.5)
		var ring_z := -length * 0.5 + nose_length + length * 0.13
		var sides := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN]
		for i in 4:
			var side: Vector3 = sides[i]
			var block := _box(parent, "Rcs%d" % (i + 1), Vector3.ONE * radius * 0.55, side * radius * 1.05 + Vector3(0, 0, ring_z), "mount")
			var puff := _box(block, "Puff", Vector3.ONE * radius * 0.5, side * radius * 0.6, "rcs")
			puff.scale = Vector3(1.0, 1.0, 1.0) + side.abs() * 1.2
			puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			puff.visible = false
			rcs.append(puff)
	return {"plume": plume, "rcs": rcs, "nozzle": nozzle}


# A cone lying along Z, centred at `position`: tip toward +Z (`tip` 1) or −Z (`tip` −1).
static func _cone(parent: Node3D, node_name: String, radius: float, length: float, position: Vector3, tip: float, key: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.0
	cylinder.bottom_radius = radius
	cylinder.height = length
	cylinder.radial_segments = 10
	cylinder.rings = 1
	cylinder.material = material(key)
	node.mesh = cylinder
	node.basis = Basis(Vector3.RIGHT, PI * 0.5 * tip)
	node.position = position
	parent.add_child(node)
	return node


static func _box(parent: Node3D, node_name: String, size: Vector3, position: Vector3, key: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var box := BoxMesh.new()
	box.size = size
	box.material = material(key)
	node.mesh = box
	node.position = position
	parent.add_child(node)
	return node


# A cylinder lying along Z, centred at `position`.
static func _tube(parent: Node3D, node_name: String, radius: float, length: float, position: Vector3, key: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = length
	cylinder.radial_segments = 10
	cylinder.rings = 1
	cylinder.material = material(key)
	node.mesh = cylinder
	node.basis = Basis(Vector3.RIGHT, PI * 0.5)
	node.position = position
	parent.add_child(node)
	return node
