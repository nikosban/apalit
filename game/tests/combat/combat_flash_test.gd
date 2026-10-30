extends SceneTree
## Combat flashes (issue #4): combat_effects.gd spawning combat_flash.tscn with the shared
## presets. Every variant against the pre-extraction formula, per-instance isolation,
## preset propagation, pause and time scale, active_count(), cleanup, scene reset, fog and
## the F6 preview. Run with a fixed step:
##   <godot console> --headless --path . --fixed-fps 60 -s res://game/tests/combat/combat_flash_test.gd

const COMBAT_TEST := preload("res://game/scenes/combat_test.tscn")
const PREVIEW := preload("res://game/presentation/effects/combat_flash/combat_flash_preview.tscn")
const FLASH_SCRIPT := preload("res://game/presentation/effects/combat_flash/combat_flash.gd")
const DT := 1.0 / 60.0
const EPS := 0.00001
const BLUE := Color(0.25, 0.5, 1.0)
const RED := Color(1.0, 0.25, 0.2)
## The pre-extraction values (combat_effects.gd before issue #4): radius, growth, lifetime.
const OLD := {
	"muzzle": [0.12, 1.6, 0.09], "impact": [0.18, 3.0, 0.25], "impact_soft": [0.12, 2.0, 0.18],
	"burst": [1.0, 2.2, 0.3], "destruction": [1.0, 4.0, 0.8],
}

var scene: Node3D
var effects: Node3D
var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	await _case_variants()
	await _case_isolation()
	await _case_presets()
	await _case_pause()
	await _case_count_and_cleanup()
	await _case_reset()
	await _case_fog()
	await _case_preview()
	_free()
	print("RESULT: %s (%d of %d checks failed)" % ["PASS" if _failures == 0 else "FAIL", _failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(text: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%-118s %s" % [text, "PASS" if ok else "FAIL"])


func _free() -> void:
	Engine.time_scale = 1.0
	paused = false
	if scene != null and is_instance_valid(scene):
		root.remove_child(scene)
		scene.free()
	scene = null


func _load() -> void:
	_free()
	scene = COMBAT_TEST.instantiate()
	root.add_child(scene)
	scene.fog_reveal = true # FogView hides flashes outside coverage (case F7 checks that)
	effects = scene.get_node("Effects")
	for i in 5:
		await process_frame


func _flashes() -> Array:
	return effects.get_children().filter(func(n: Node) -> bool: return n.get_script() == FLASH_SCRIPT and not n.is_queued_for_deletion())


## Spawns one variant (from a physics tick, as in combat) and follows it to its end against
## the old formula: position, scale, colour and alpha every frame, and the frame it ends.
func _follow(label: String, kind: String, spawn: Callable, point: Vector3, size: float, color: Color) -> void:
	await physics_frame
	var before: int = effects.active_count()
	spawn.call()
	var flash: Node3D = _flashes().back()
	var old: Array = OLD[kind]
	var shape_ok := true
	var age := 0.0 # Observed at process_frame, before the flash's own _process of that frame.
	var frames := 0
	var ended_ok := false
	var last := 0.0 # The flash's age when last seen alive
	while true:
		await process_frame
		if not is_instance_valid(flash) or flash.is_queued_for_deletion():
			# It ended in the frame its age reached the lifetime (the same accumulated delta as before).
			ended_ok = last < old[2] and last + DT >= old[2] and effects.active_count() == before
			break
		var share: float = age / old[2]
		var expected := color
		expected.a = 1.0 - share
		var c: Color = flash.current_color()
		shape_ok = shape_ok and absf(flash.age() - age) < EPS and flash.global_position.distance_to(point) < EPS 			and absf(flash.scale.x - old[0] * size * lerpf(1.0, old[1], share)) < EPS 			and Vector4(c.r - expected.r, c.g - expected.g, c.b - expected.b, c.a - expected.a).length() < EPS 			and effects.active_count() == before + 1
		last = flash.age()
		age += DT
		frames += 1
		if frames > 200:
			break
	_check("%s: position, size, colour and fade every frame as before (%d frames)" % [label, frames], shape_ok and frames > 0)
	_check("%s: ends at its lifetime %.2f s and leaves active_count()" % [label, old[2]], ended_ok)


func _case_variants() -> void:
	print("\n=== F1 every variant against the pre-extraction formula")
	await _load()
	var p := Vector3(-150, 1.5, 20)
	var dir := Vector3(0.6, 0, -0.8)
	await _follow("muzzle (faction blue, size 1)", "muzzle", effects.muzzle_flash.bind(p, dir, BLUE, 1.0), p + dir * 0.08, 1.0, BLUE.lerp(Color(1, 0.95, 0.7), 0.6))
	await _follow("muzzle (faction red, size 1.4)", "muzzle", effects.muzzle_flash.bind(p, dir, RED, 1.4), p + dir * 0.08 * 1.4, 1.4, RED.lerp(Color(1, 0.95, 0.7), 0.6))
	await _follow("muzzle (size 0.6, default size argument path)", "muzzle", effects.muzzle_flash.bind(p, Vector3.UP, BLUE, 0.6), p + Vector3.UP * 0.08 * 0.6, 0.6, BLUE.lerp(Color(1, 0.95, 0.7), 0.6))
	await _follow("damaging impact (size 1.6)", "impact", effects.impact.bind(p, true, 1.6), p, 1.6, Color(1.0, 0.65, 0.25))
	await _follow("non-damaging impact (default size)", "impact_soft", effects.impact.bind(p, false), p, 1.0, Color(0.7, 0.75, 0.8))
	await _follow("burst (interception, radius 0.45)", "burst", effects.burst.bind(p, Color(1.0, 0.9, 0.6), 0.45), p, 0.45, Color(1.0, 0.9, 0.6))
	await _follow("destruction (0.5 u above the ship)", "destruction", effects.destruction.bind(p), p + Vector3(0, 0.5, 0), 1.0, Color(1.0, 0.5, 0.15))
	effects.muzzle_flash(p, dir, BLUE)
	var flash: Node3D = _flashes().back()
	_check("each flash is a child of Effects, never under Ships; no shadows; shared sphere radius 1",
		flash.get_parent() == effects and not scene.get_node("Ships").is_ancestor_of(flash)
		and flash.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		and is_equal_approx(flash.mesh.radius, 1.0) and is_equal_approx(flash.mesh.height, 2.0))
	var m := flash.material_override as StandardMaterial3D
	_check("material: unshaded, alpha-blended", m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED and m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA)


func _snapshot(style: Resource) -> Array:
	return [style.radius, style.growth, style.lifetime, style.color, style.blend_color, style.blend]


func _case_isolation() -> void:
	print("\n=== F2 per-instance isolation")
	await _load()
	var styles := [effects.muzzle_style, effects.impact_style, effects.impact_soft_style, effects.burst_style, effects.destruction_style]
	var before := styles.map(_snapshot)
	await physics_frame
	effects.muzzle_flash(Vector3(-150, 1.5, 0), Vector3.FORWARD, BLUE, 1.0)
	effects.muzzle_flash(Vector3(-148, 1.5, 0), Vector3.FORWARD, RED, 1.4)
	effects.burst(Vector3(-146, 1.5, 0), Color(0, 1, 0), 0.5)
	effects.burst(Vector3(-144, 1.5, 0), Color(1, 0, 1), 0.5)
	var f := _flashes()
	await process_frame
	await process_frame
	var materials := f.map(func(n: Node3D) -> Material: return n.material_override)
	var distinct := true
	for i in materials.size():
		for j in range(i + 1, materials.size()):
			distinct = distinct and materials[i] != materials[j]
	_check("every flash has its own material (%d flashes)" % f.size(), f.size() == 4 and distinct)
	_check("the sphere mesh is shared", f.all(func(n: Node3D) -> bool: return n.mesh == f[0].mesh))
	var c0: Color = f[0].current_color()
	var c1: Color = f[1].current_color()
	var c2: Color = f[2].current_color()
	var c3: Color = f[3].current_color()
	_check("runtime colours stay per flash (blue / red muzzle, green / magenta burst)",
		c0.b > c0.r and c1.r > c1.b and c2.g > 0.9 and c2.r < 0.1 and c3.r > 0.9 and c3.g < 0.1)
	_check("sizes stay per flash (muzzle 1 / 1.4)", is_equal_approx(f[1].scale.x / f[0].scale.x, 1.4))
	_check("playing flashes never write the shared presets", styles.map(_snapshot) == before)
	var fresh: Node3D = load("res://game/presentation/effects/combat_flash/combat_flash.tscn").instantiate()
	_check("the scene's own material is untouched by playing flashes (white, opaque)",
		(fresh.material_override as StandardMaterial3D).albedo_color == Color(1, 1, 1, 1))
	fresh.free()


func _case_presets() -> void:
	print("\n=== F3 a preset change reaches new flashes only")
	await _load()
	var style: Resource = effects.impact_style
	var saved := _snapshot(style)
	await physics_frame
	effects.impact(Vector3(-150, 1.5, 0), true)
	var old_flash: Node3D = _flashes().back()
	style.radius = 0.5
	style.lifetime = 1.0
	style.color = Color(0, 1, 0)
	effects.impact(Vector3(-148, 1.5, 0), true)
	var new_flash: Node3D = _flashes().back()
	await process_frame
	await process_frame # Both have processed one frame.
	_check("a new flash uses the edited preset (radius, colour)", absf(new_flash.scale.x - 0.5 * lerpf(1.0, 3.0, DT / 1.0)) < EPS and new_flash.current_color().g > 0.9)
	_check("a flash already playing keeps the values it started with", absf(old_flash.scale.x - 0.18 * lerpf(1.0, 3.0, DT / 0.25)) < EPS and old_flash.current_color().r > 0.9)
	_check("the scene file sets no preset: Effects uses the shared .tres files",
		effects.impact_style.resource_path == "res://game/presentation/effects/combat_flash/impact.tres"
		and effects.muzzle_style.resource_path.ends_with("muzzle.tres") and effects.burst_style.resource_path.ends_with("burst.tres")
		and effects.impact_soft_style.resource_path.ends_with("impact_soft.tres") and effects.destruction_style.resource_path.ends_with("destruction.tres"))
	style.radius = saved[0]
	style.lifetime = saved[2]
	style.color = saved[3]


func _case_pause() -> void:
	print("\n=== F4 pause and time scale")
	await _load()
	await physics_frame
	effects.destruction(Vector3(-150, 1.5, 0))
	var flash: Node3D = _flashes().back()
	await process_frame
	await process_frame
	scene.time_control.set_paused(true)
	await process_frame
	var age: float = flash.age()
	var scale: float = flash.scale.x
	for i in 30:
		await process_frame
	_check("paused: the flash neither ages nor grows over 30 frames and stays counted",
		flash.age() == age and flash.scale.x == scale and effects.active_count() == 1 and is_instance_valid(flash))
	_check("paused: the flash does not process (inherits Effects' pausable mode)", not flash.can_process())
	scene.time_control.set_paused(false)
	await process_frame
	await process_frame
	_check("resumed: it ages again", flash.age() > age)
	Engine.time_scale = 0.25
	await process_frame # The scale applies from the next frame.
	var a0: float = flash.age()
	await process_frame
	await process_frame
	_check("time scale 0.25: it ages a quarter as fast (%.5f s per frame)" % ((flash.age() - a0) / 2.0), absf((flash.age() - a0) / 2.0 - DT * 0.25) < EPS * 10)
	Engine.time_scale = 1.0


func _case_count_and_cleanup() -> void:
	print("\n=== F5 active_count() and cleanup with overlapping flashes")
	await _load()
	var children: int = effects.get_child_count()
	var orphans := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	await physics_frame
	for i in 10:
		effects.burst(Vector3(-150, 1.5, i), Color(1, 0.8, 0.5), 0.5)
	_check("10 bursts in one tick: active_count() 10", effects.active_count() == 10)
	var counts := []
	var spawned := 10
	for frame in 40:
		await physics_frame
		if frame < 20:
			effects.muzzle_flash(Vector3(-150, 1.5, -5), Vector3.FORWARD, BLUE)
			effects.impact(Vector3(-150, 1.5, -6), frame % 2 == 0)
			spawned += 2
		await process_frame
		counts.append(effects.active_count())
	_check("overlapping flashes are counted while alive (peak %d of %d spawned)" % [counts.max(), spawned], counts.max() >= 10 and counts.max() < spawned)
	for i in 60:
		await process_frame
	_check("all flashes expire: active_count() 0", effects.active_count() == 0)
	_check("every flash node is freed (Effects children back to %d)" % children, effects.get_child_count() == children)
	_check("no orphan nodes left (%d before, %d after)" % [orphans, Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)],
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == orphans)


func _case_reset() -> void:
	print("\n=== F6 scene reset with flashes alive")
	await _load()
	await physics_frame
	for i in 20:
		effects.destruction(Vector3(-150 + i, 1.5, 0))
	await process_frame
	var orphans := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var flashes := _flashes()
	_free()
	await process_frame
	_check("freeing the scene mid-flash frees every flash (%d)" % flashes.size(), flashes.size() == 20 and flashes.all(func(n) -> bool: return not is_instance_valid(n)))
	_check("no orphan nodes after the reset", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) <= orphans)
	await _load()
	_check("a reloaded scene starts with active_count() 0", effects.active_count() == 0)


func _case_fog() -> void:
	print("\n=== F7 fog of war still hides uncovered flashes")
	await _load()
	scene.fog_reveal = false
	await physics_frame
	await physics_frame
	effects.impact(Vector3(-150, 1.5, 10), true) # next to the player FF01: covered
	effects.impact(Vector3(150, 1.5, 0), true) # at the hostile, 300 u away: not covered
	var f := _flashes()
	await process_frame
	await process_frame
	_check("a covered flash is visible, an uncovered one is hidden (FogView over Effects children)", f[0].visible and not f[1].visible)


func _case_preview() -> void:
	print("\n=== F8 F6 preview uses the production spawner, scene and presets")
	_free()
	var preview: Node3D = PREVIEW.instantiate()
	root.add_child(preview)
	var preview_effects: Node3D = preview.get_node("Effects")
	await process_frame
	await process_frame
	var f: Array = preview_effects.get_children().filter(func(n: Node) -> bool: return n.get_script() == FLASH_SCRIPT)
	_check("the preview's Effects is combat_effects.gd with the shared presets",
		preview_effects.get_script() == load("res://game/combat/combat_effects.gd")
		and preview_effects.burst_style == load("res://game/presentation/effects/combat_flash/burst.tres"))
	_check("one replay fires every sample (%d flashes, one per marker)" % f.size(), f.size() == preview.get_node("Samples").get_child_count() and f.size() == 11)
	for i in 60:
		await process_frame
	_check("1 s later (before the 1.2 s replay) every sample has disappeared", preview_effects.active_count() == 0)
	var waited := 0
	while preview_effects.active_count() == 0 and waited < 30:
		await process_frame
		waited += 1
	_check("the samples replay after the interval (%d frames later)" % waited, preview_effects.active_count() == 11 and waited < 30)
	root.remove_child(preview)
	preview.free()
