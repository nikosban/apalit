extends SceneTree
## Environmental lighting prototype: the sector profile, the asteroid environment and the
## fog presentation on the playable main scene (presentation only; gameplay data and the
## fog-of-war rule are compared before and after).
## Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/sector_environment_test.gd

const MAIN := preload("res://main.tscn")
const FogView := preload("res://game/presentation/fog_view.gd")

var scene: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	var first := await _load()
	var env = scene.environment
	var profile: Resource = env.profile
	var light: DirectionalLight3D = scene.get_node("DirectionalLight3D")
	var world: Environment = (scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	_check("Profile: the scene light takes the key colour and energy, its direction is kept",
		light.light_color == profile.key_color and is_equal_approx(light.light_energy, profile.key_energy)
		and light.global_basis.is_equal_approx(Basis(Vector3(0.866025, 0, -0.5), Vector3(-0.433013, 0.5, -0.75), Vector3(0.25, 0.866025, 0.433013))))
	_check("Profile: ambient fill and background from the profile",
		world.ambient_light_color == profile.ambient_color and is_equal_approx(world.ambient_light_energy, profile.ambient_energy)
		and world.background_color == profile.background_color)

	# Asteroid environment: placement around asteroids, stable, apart from gameplay data.
	var field := scene.get_node("Asteroids")
	_check("Debris: %d rocks, %d fine fragments, %d dust clouds, one instance each" % [env.rock_count, env.fine_count, env.dust_count],
		env.rock_count > 0 and env.fine_count > 0 and env.dust_count > 0 and env._rocks.multimesh.instance_count == first.rocks.size()
		and env._fine.multimesh.instance_count == first.fine.size() and env._dust.multimesh.instance_count == first.dust.size())
	var outside := true
	var reach := 0.0 # The widest scatter the placement allows: 2 + 1.45 r of the largest asteroid.
	var farthest := 0.0
	for id: int in field.ids():
		reach = maxf(reach, 2.0 + 1.45 * field.radius(id))
	var placed: Dictionary = env.placement(field) # MultiMesh transforms do not read back headless.
	for list: Array in [placed.rocks, placed.fine]:
		for t: Transform3D in list:
			var p := t.origin
			var best := INF
			for id: int in field.ids():
				var c: Vector3 = field.center(id)
				best = minf(best, Vector2(p.x - c.x, p.z - c.z).length() - field.radius(id))
			outside = outside and best >= 0.0
			farthest = maxf(farthest, best)
	_check("Debris: every fragment within %.1f u of an asteroid surface (farthest %.1f; none scattered across the arena)" % [reach, farthest], farthest <= reach)
	_check("Debris: no fragment centre inside an asteroid", outside)
	var nodes_ok := true
	for node in env.get_children():
		nodes_ok = nodes_ok and not (node is CollisionObject3D) and not field.is_ancestor_of(node)
	_check("Debris: no collision objects, nothing added under the asteroid field (%d asteroids)" % field.ids().size(),
		nodes_ok and field.ids().size() == first.ids)
	var second := await _load()
	_check("Debris: identical placement on a second load", second.rocks == first.rocks and second.fine == first.fine and second.dust == first.dust)

	# Tactical emphasis reduces the environment.
	env = scene.environment
	field = scene.get_node("Asteroids")
	var rig := scene.get_node("CameraRig")
	var close_alpha: float = env._dust_material.albedo_color.a
	rig.zoom_target = 150.0
	rig.zoom_distance = 150.0
	rig._apply_zoom()
	await process_frame
	await process_frame
	_check("Tactical: fine debris hidden, dust thinned (%.3f -> %.3f)" % [close_alpha, env._dust_material.albedo_color.a],
		not env._fine.visible and env._dust_material.albedo_color.a < close_alpha * 0.5 and env._rocks.visible)

	# Fog presentation: the same material, tinted, edgeless; the rule itself is untouched.
	var fog: MeshInstance3D = scene.fog_view
	var material := fog.material_override as ShaderMaterial
	_check("Fog: profile colour and strength, quad far past the arena (%.0f u)" % (fog.mesh as PlaneMesh).size.x,
		material.get_shader_parameter("fog_color") == profile.fog_color and is_equal_approx(material.get_shader_parameter("strength"), profile.fog_strength)
		and (fog.mesh as PlaneMesh).size.x >= 3000.0)
	var view = scene.strategic
	_check("Strategic: its fog quad is FogView's material and mesh, lighter by the profile; tinted shadows and dust",
		view._fog.material_override == material and view._fog.mesh == fog.mesh
		and is_equal_approx(view._fog.get_instance_shader_parameter("view_strength"), profile.strategic_fog_strength / profile.fog_strength)
		and view._overlay_material.get_shader_parameter("shadow_color") == profile.shadow_color
		and is_equal_approx(view._overlay_material.get_shader_parameter("dust_alpha"), profile.strategic_dust_strength))
	_check("Strategic: the fog quad is above every simplified asteroid",
		view._fog.position.y > _tallest(field))
	var sensors := scene.get_node("Sensors")
	sensors.evaluate()
	var agree := true
	for x in range(-150, 151, 15):
		for z in range(-150, 151, 15):
			var point := Vector3(x, 0, z)
			agree = agree and fog.covered(point) == sensors.covered(0, point)
	_check("Fog: coverage queries are the Sensors' rule", agree)

	_unload()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _load() -> Dictionary:
	_unload()
	scene = MAIN.instantiate()
	root.add_child(scene)
	for i in 3:
		await process_frame
	var field := scene.get_node("Asteroids")
	var record: Dictionary = scene.environment.placement(field)
	record.ids = field.ids().size()
	return record


func _tallest(field: Node) -> float:
	var top := 0.0
	for id: int in field.ids():
		top = maxf(top, field.center(id).y + field.radius(id))
	return top


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _unload() -> void:
	if scene != null:
		root.remove_child(scene)
		scene.free()
		scene = null
