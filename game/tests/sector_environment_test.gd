extends SceneTree
## Environmental lighting prototype: the sector profile, the asteroid environment and the
## fog presentation on the Test Arena (main.tscn; presentation only; gameplay data and the
## fog-of-war rule are compared before and after). Sector Showcase round: the Showcase
## scene's sector, fuel scale, missing ground and backdrop, the Test Arena's unchanged
## defaults, formation-level dust and the fog's occluder-cap report.
## Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/sector_environment_test.gd

const MAIN := preload("res://main.tscn")
const SHOWCASE := preload("res://game/scenes/sector_showcase.tscn")
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
	var reach: float = env.formation_gap # Fine debris also fills gaps up to this wide.
	var farthest := 0.0
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
	_check("Test Arena: sector half-size 150 (navigation, camera bounds), no tactical grid, local fuel scale 1, ships charged in full",
		is_equal_approx(scene.sector_half_size(), 150.0) and rig.bounds == Rect2(-150, -150, 300, 300)
		and scene.grid == null and not scene.has_node("TacticalGrid") and is_equal_approx(scene.local_fuel_scale, 1.0)
		and is_equal_approx(scene.get_node("Ships/Miner1/Fuel").local_scale, 1.0) and scene.has_node("Ground"))
	_check("Test Arena: environment unchanged (flat background A, no environment lighting, Strategic depth or god rays; sun 60 degrees up)",
		env.sky_mode == 0 and not env.lighting_d and env.god_rays == null and not scene.strategic.e_enabled
		and is_equal_approx(rad_to_deg(asin((scene.get_node("DirectionalLight3D") as DirectionalLight3D).global_basis.z.y)), 60.0))
	var formations: Array = env.formations(field)
	_check("Dust: by formation (%d formations, %d clouds for %d asteroids), not one cloud set per rock" % [formations.size(), env.dust_count, field.ids().size()],
		formations.size() < field.ids().size() and env.dust_count < field.ids().size())

	await _case_showcase()
	await _case_sky()
	await _case_experiments()
	await _case_overflow()
	_unload()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


## The Sector Showcase: its own sector everywhere, cheap local fuel, no ground, a backdrop
## that is no gameplay object, every asteroid drawn as a fog occluder.
func _case_showcase() -> void:
	_unload()
	scene = SHOWCASE.instantiate()
	root.add_child(scene)
	for i in 3:
		await process_frame
	var half: float = scene.sector_half_size()
	var field := scene.get_node("Asteroids")
	_check("Showcase: sector half-size %.0f shared by navigation, camera bounds and Strategic framing; no tactical grid" % half,
		half > 150.0 and is_equal_approx(scene.get_node("StaticNavigation").map_half_size, half)
		and scene.get_node("CameraRig").bounds == Rect2(-half, -half, 2.0 * half, 2.0 * half)
		and scene.grid == null and not scene.has_node("TacticalGrid") and scene.strategic.sector_rect() == scene.get_node("CameraRig").bounds)
	var transporter: Node3D = scene.ship("Transporter")
	var inside: bool = scene._intent_valid(transporter, {"kind": scene.CommandKind.MOVE, "point": Vector2(half - 5.0, 0.0)})
	var outside: bool = scene._intent_valid(transporter, {"kind": scene.CommandKind.MOVE, "point": Vector2(half + 5.0, 0.0)})
	var radius: float = transporter.get_node("RouteFollower").planning_radius()
	var navigation := scene.get_node("StaticNavigation")
	_check("Showcase: MOVE valid inside the sector, refused outside it; navigation's map ends at the same bound",
		inside and not outside and navigation.segment_clear(Vector2(half - radius - 2.0, -300), Vector2(half - radius - 2.0, -290), radius)
		and not navigation.segment_clear(Vector2(half - 1.0, -300), Vector2(half - 1.0, -290), radius))
	_check("Showcase: local fuel scale 0.1 applied to every ship's Fuel (tanks unchanged)",
		is_equal_approx(scene.local_fuel_scale, 0.1) and scene.get_node("Ships").get_children().all(func(s: Node) -> bool:
			return is_equal_approx(s.get_node("Fuel").local_scale, 0.1)) and is_equal_approx(scene.get_node("Ships/Miner1/Fuel").capacity, 100.0))
	var backdrop := scene.get_node("Backdrop") as MultiMeshInstance3D
	var below: bool = backdrop.placement().all(func(t: Transform3D) -> bool: return t.origin.y < -50.0)
	_check("Showcase: no ground; backdrop (%d rocks) far below the plane, in no obstacle group, not under the asteroid field, not on the Strategic layer" % backdrop.multimesh.instance_count,
		not scene.has_node("Ground") and below and not backdrop.is_in_group(&"static_obstacle") and backdrop.get_parent() != field
		and (backdrop.layers & scene.strategic.LAYER) == 0 and backdrop.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_check("Showcase: %d asteroids, all drawn as fog occluders (no overflow)" % field.ids().size(),
		field.ids().size() <= FogView.MAX_ASTEROIDS and scene.fog_view.overflow == "")


## Skybox experiment: B and C use the panorama as described; A restores every
## baseline value; the sun is never touched; F8 cycles A -> B -> C -> A.
func _case_sky() -> void:
	_unload()
	scene = SHOWCASE.instantiate()
	root.add_child(scene)
	for i in 3:
		await process_frame
	var env = scene.environment
	var world: Environment = (scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	var light: DirectionalLight3D = scene.get_node("DirectionalLight3D")
	var sun := [light.global_transform, light.light_color, light.light_energy]
	env.set_environment_lighting(false) # The Showcase starts in B with environment lighting: compare from A.
	env.set_sky_mode(0)
	var baseline := [world.background_mode, world.background_color, world.ambient_light_source, world.ambient_light_color, world.ambient_light_energy, world.reflected_light_source, world.sky]
	_check("Sky: A is the flat background, colour ambient, background reflections, no sky",
		env.sky_mode == 0 and world.background_mode == Environment.BG_COLOR and world.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR
		and world.reflected_light_source == Environment.REFLECTION_SOURCE_BG and world.sky == null)
	env.set_sky_mode(1)
	var panorama := (world.sky.sky_material as PanoramaSkyMaterial).panorama if world.sky != null else null
	_check("Sky B: the panorama (%s) is the visible sky; ambient stays the profile colour; reflections off" % (str(panorama.get_size()) if panorama != null else "none"),
		world.background_mode == Environment.BG_SKY and panorama != null and panorama.resource_path.ends_with("multi_nebulae_2.png")
		and world.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and world.ambient_light_color == env.profile.ambient_color
		and world.reflected_light_source == Environment.REFLECTION_SOURCE_DISABLED)
	env.set_sky_mode(2)
	_check("Sky C: the same sky, ambient and reflections sampled from it",
		world.background_mode == Environment.BG_SKY and world.ambient_light_source == Environment.AMBIENT_SOURCE_SKY
		and world.reflected_light_source == Environment.REFLECTION_SOURCE_SKY)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_F8
	key.keycode = KEY_F8
	key.pressed = true
	root.push_input(key, true)
	await process_frame
	_check("Sky A again (F8 from C): every baseline value restored",
		env.sky_mode == 0 and [world.background_mode, world.background_color, world.ambient_light_source, world.ambient_light_color, world.ambient_light_energy, world.reflected_light_source, world.sky] == baseline)
	_check("Sky: the sun is unchanged throughout (transform, colour, energy) and still the only DirectionalLight3D",
		[light.global_transform, light.light_color, light.light_energy] == sun
		and scene.find_children("*", "DirectionalLight3D", true, false).size() == 1)
	var fresh := SHOWCASE.instantiate()
	var shared: Environment = (fresh.get_node("WorldEnvironment") as WorldEnvironment).environment
	fresh.free()
	_check("Sky: the running scene works on its own Environment copy; the scene file's resource is untouched (still A)",
		world != shared and shared.background_mode == Environment.BG_COLOR and shared.sky == null)


## The Showcase's environment (B + environment lighting + Strategic depth + god rays) and
## its development switches: each off restores what it changed; none changes the sun,
## the fog-of-war rule or what hidden ships show.
func _case_experiments() -> void:
	_unload()
	scene = SHOWCASE.instantiate()
	# A hostile FF-01 where the Showcase's hostile fleet used to start (beyond sensor range).
	var added: Node3D = load("res://game/ships/ff01_unit.tscn").instantiate()
	added.name = "HostileFF01"
	added.transform = Transform3D(Basis(Vector3.UP, -PI / 2), Vector3(214, 1.5, -58))
	added.get_node("Combat").faction = 1
	scene.get_node("Ships").add_child(added)
	root.add_child(scene)
	for i in 3:
		await process_frame
	var env = scene.environment
	var world: Environment = (scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	var light: DirectionalLight3D = scene.get_node("DirectionalLight3D")
	var view = scene.strategic
	var travel := -light.global_basis.z
	_check("Showcase defaults: B sky, environment lighting, Strategic depth, god rays; one sun at %.1f degrees elevation" % rad_to_deg(asin(-travel.y)),
		env.sky_mode == 1 and env.lighting_d and view.e_enabled and env.god_rays != null and is_equal_approx(rad_to_deg(asin(-travel.y)), 30.0)
		and scene.find_children("*", "DirectionalLight3D", true, false).size() == 1)
	var sun := [light.global_transform, light.light_color, light.light_energy, light.directional_shadow_max_distance]
	var d_material := world.sky.sky_material as ShaderMaterial
	_check("Environment lighting: a sky shader for the panorama background, designed radiance for ambient and reflections",
		d_material != null and d_material.get_shader_parameter("source_panorama") != null and d_material.shader.code.contains("AT_CUBEMAP_PASS")
		and world.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and world.reflected_light_source == Environment.REFLECTION_SOURCE_SKY
		and world.sky.process_mode == Sky.PROCESS_MODE_QUALITY)
	_check("Environment lighting: its warm lobe follows the scene light's direction (world space)",
		(d_material.get_shader_parameter("sun_dir") as Vector3).is_equal_approx(light.global_basis.z.normalized()))
	env.set_environment_lighting(false)
	_check("Environment lighting off: plain B (panorama material, profile ambient, reflections off)",
		world.sky.sky_material is PanoramaSkyMaterial and world.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR
		and world.reflected_light_source == Environment.REFLECTION_SOURCE_DISABLED)
	env.set_environment_lighting(true)
	var overlay: ShaderMaterial = view._overlay_material
	_check("Strategic depth: formation environment on; Strategic fog leaves the sky untouched and subdues geometry at half strength; Local / Tactical fog unchanged",
		overlay.get_shader_parameter("e_enabled") == 1.0 and is_equal_approx(view._fog.get_instance_shader_parameter("protect_sky"), 1.0)
		and is_equal_approx(view._fog.get_instance_shader_parameter("geometry_share"), 0.5)
		and scene.fog_view.get_instance_shader_parameter("protect_sky") in [null, 0.0]
		and overlay.get_shader_parameter("asteroid_count") == (scene.fog_view.material_override as ShaderMaterial).get_shader_parameter("asteroid_count"))
	view.set_environment_depth(false)
	_check("Strategic depth off: overlay and Strategic fog as without it", overlay.get_shader_parameter("e_enabled") == 0.0
		and is_equal_approx(view._fog.get_instance_shader_parameter("protect_sky"), 0.0) and is_equal_approx(view._fog.get_instance_shader_parameter("geometry_share"), 1.0))
	view.set_environment_depth(true)
	# God rays: bounded, along the light, clear of rock, not in Strategic, deterministic.
	var rays = env.god_rays
	var field := scene.get_node("Asteroids")
	var aligned := true
	var clear := true
	for shaft: Dictionary in rays.shafts + rays.shadows:
		var axis: Vector3 = (shaft.end - shaft.start).normalized()
		aligned = aligned and axis.is_equal_approx(travel.normalized())
		for k in 11:
			var p: Vector3 = (shaft.start as Vector3).lerp(shaft.end, k / 10.0)
			for id: int in field.ids():
				clear = clear and p.distance_to(field.center(id)) >= field.radius(id) + 0.9
	var kinds := {}
	for shaft: Dictionary in rays.shafts:
		kinds[shaft.kind] = kinds.get(shaft.kind, 0) + 1
	_check("God rays: %d light shafts %s (1 to %d) and %d shadow bands (at most %d), each along the light's travel" % [rays.shafts.size(), str(kinds), rays.max_shafts, rays.shadows.size(), rays.max_shadows],
		rays.shafts.size() > 0 and rays.shafts.size() <= rays.max_shafts and rays.shadows.size() > 0 and rays.shadows.size() <= rays.max_shadows and aligned)
	_check("God rays: no band starts on, ends in or passes through an asteroid", clear)
	var shade: MultiMeshInstance3D = rays.get_node("Shadows")
	_check("God rays: two MultiMeshes (light, shade), one quad per band, no shadows cast, not on the Strategic layer",
		rays.multimesh.instance_count == rays.shafts.size() and shade.multimesh.instance_count == rays.shadows.size()
		and rays.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and shade.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		and (rays.layers & view.LAYER) == 0 and (shade.layers & view.LAYER) == 0)
	var again: Array = rays.placement(field, travel.normalized())
	_check("God rays: placement is deterministic", again.size() == rays.shafts.size()
		and range(again.size()).all(func(k: int) -> bool: return (again[k].start as Vector3).is_equal_approx(rays.shafts[k].start) and is_equal_approx(again[k].width, rays.shafts[k].width)))
	env.set_god_rays(false)
	await process_frame
	_check("God rays off: the node is freed (no GPU work left)", env.god_rays == null and not env.has_node("GodRays"))
	env.set_god_rays(true)
	# Everything on together: gameplay information is unchanged.
	var sensors := scene.get_node("Sensors")
	sensors.evaluate()
	var hostile: Node3D = scene.ship("HostileFF01")
	var camera := scene.get_viewport().get_camera_3d()
	var screen := camera.unproject_position(hostile.global_position)
	var agree := true
	for x in range(-360, 361, 40):
		for z in range(-360, 361, 40):
			agree = agree and scene.fog_view.covered(Vector3(x, 0, z)) == sensors.covered(0, Vector3(x, 0, z))
	_check("All on: the hidden hostile stays hidden (no model, marker or pick); fog coverage is still the Sensors' rule; the sun is unchanged",
		not scene.player_sees(hostile) and not hostile.visible and scene.markers.marker_at(screen) == null and scene.selection().pick_any(screen) == null
		and agree and [light.global_transform, light.light_color, light.light_energy, light.directional_shadow_max_distance] == sun)


## More asteroids than the fog shader holds: FogView says so instead of failing silently.
func _case_overflow() -> void:
	_unload()
	scene = MAIN.instantiate()
	var field := scene.get_node("Asteroids")
	var template: MeshInstance3D = field.get_child(0)
	for i in FogView.MAX_ASTEROIDS:
		var rock := MeshInstance3D.new()
		rock.mesh = template.mesh
		rock.transform = Transform3D(Basis.IDENTITY, Vector3(-140.0 + (i % 12) * 2.0, 1.5, 140.0 - (i / 12) * 2.0))
		rock.set_meta("asteroid_id", 2000 + i)
		field.add_child(rock)
	root.add_child(scene)
	await process_frame
	_check("Fog: %d asteroids over the %d-occluder cap are reported ('%s')" % [field.ids().size(), FogView.MAX_ASTEROIDS, scene.fog_view.overflow],
		scene.fog_view.overflow != "")


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
