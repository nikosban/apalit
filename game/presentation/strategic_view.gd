extends Node3D
## Phase C prototype: Strategic View (node `StrategicView`, added by the scene's combat
## layer, always processing). A presentation of the running simulation, not a second one:
## it owns a dedicated top-down Camera3D and Strategic-only geometry on render layer 20,
## and reads the existing ships, stations, asteroid field, survey, sensors and orders.
##
## Camera and handoff: one more outward wheel notch with the CameraRig at its maximum
## (target and rendered zoom) starts the handoff; an inward notch in Strategic returns.
## The rig's pose (transform, rendered and target zoom) is saved and the rig frozen
## (process and input off) for the whole visit, then restored exactly. The Strategic
## camera moves from the rig camera's transform to the sector framing (`progress` 0-1,
## smoothstep, `transition_time` real seconds; an opposite notch reverses it). It keeps
## the rig's yaw (orientation is preserved; Strategic itself never rotates or pans) and
## frames the sector rectangle at any aspect ratio. A dip to the background colour
## peaks at progress 0.5, where the camera's cull mask swaps the detailed 3D scene for the
## Strategic layer; the screen-space markers stay continuous throughout. During a
## handoff every mouse button is consumed and pending presses (selection, station panel)
## are cancelled, so nothing completes as a command.
##
## The sector is the prototype arena: the rig's `bounds` for framing and the scene's
## command square (`GROUND_HALF_SIZE`, the existing MOVE validity rule) for the boundary,
## which is drawn only for a moment after a right-click the command rules refuse outside it.
##
## Strategic presentation (from back to front):
##   - simplified asteroid geometry: one low-poly dark sphere per asteroid (one
##     MultiMesh, the asteroids' own transforms), lit by the scene light, no shadows cast;
##   - one transparent overlay quad (no ground surface) with very faint contour lines of
##     a smooth density field around asteroid formations and soft directional shadow bands
##     of significant formations, away from the scene's DirectionalLight3D (prototype sun);
##     the field is baked once into a texture, the shader does the rest;
##   - the fog: FogView's own material on a second quad above the geometry, so space
##     outside current sensor coverage (static geography included) is dimmed;
## Environmental prototype: the overlay's shadows take the sector profile's shadow colour
## and strength and it adds a faint dust tint over the density field (thinner in the
## shadows); the fog quad reaches far past the sector (no square edge) at the profile's
## Strategic fog strength; the handoff dip uses the profile's background.
##   - screen space: selected ships' routes, waypoint legs and Attack-Move lines, then one
##     environmental marker per asteroid cluster (screen-space single linkage at the
##     Strategic scale) and one resource marker per known resource family in it; the ship
##     and station markers are TacticalMarkers' (at full emphasis); on top, a hovered
##     resource marker's radial expansion (members, or subgroups of at most 6).
## Static geography is known everywhere (the project's rule: asteroids and stations have
## no discovery state); resource markers need survey knowledge (IDENTIFIED or better) and
## leave out asteroids analyzed as depleted. Hostile ships follow `player_sees()`.

enum State { TACTICAL, ENTERING, STRATEGIC, EXITING }

const CombatShip := preload("res://game/combat/combat_ship.gd")
const Survey := preload("res://game/survey/survey.gd")
const SurveyView := preload("res://game/survey/survey_view.gd")
const AsteroidField := preload("res://game/resources/asteroid_field.gd")
const ObjectMarkers := preload("res://game/presentation/object_markers.gd")
const RouteFollower := preload("res://game/navigation/route_follower.gd")
const Behavior := preload("res://game/behavior/ship_behavior.gd")
const LAYER := 1 << 19 # Render layer 20: Strategic-only geometry.
const DETAIL_MASK := 0xFFFFF & ~LAYER # Every other render layer (the detailed 3D scene).
const BACKGROUND := Color(0.05, 0.055, 0.06) # The scenes' environment background.
const ROUTE_COLOR := Color(0.85, 0.6, 0.25)
const WAYPOINT_COLOR := Color(0.55, 0.7, 1.0)
const ATTACK_MOVE_COLOR := Color(1.0, 0.45, 0.35)
const CLUSTER_COLOR := Color(0.7, 0.72, 0.75)
const BOUNDARY_COLOR := Color(0.95, 0.4, 0.3)
const FAMILY_NAMES := {AsteroidField.Family.MINERALS: "Minerals", AsteroidField.Family.ICE: "Ice"}
const FAMILY_COLORS := {AsteroidField.Family.MINERALS: SurveyView.MINERALS_COLOR, AsteroidField.Family.ICE: SurveyView.ICE_COLOR}
const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform sampler2D field : filter_linear, repeat_disable;
uniform vec4 rect; // world x, z of the texture's corner; its size
uniform vec2 light_dir = vec2(0.0, 1.0); // planar direction the light travels
uniform float shadow_length = 26.0;
uniform float shadow_alpha = 0.22;
uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 dust_color : source_color = vec4(0.9, 0.66, 0.45, 1.0);
uniform float dust_alpha = 0.0;
uniform float contour_alpha = 0.07;
uniform vec3 levels = vec3(0.15, 0.5, 1.2);
varying vec2 world;
void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz; }
vec2 sample_field(vec2 p) { return texture(field, (p - rect.xy) / rect.zw).rg; }
float band(float f, float level) {
	float d = abs(f - level) / max(fwidth(f), 1e-5);
	return 1.0 - clamp(d - 0.5, 0.0, 1.0);
}
void fragment() {
	vec2 here = sample_field(world);
	float line = max(band(here.r, levels.x), max(band(here.r, levels.y), band(here.r, levels.z)));
	float occlusion = 0.0;
	for (int i = 1; i <= 16; i++) {
		float t = float(i) / 16.0;
		occlusion = max(occlusion, sample_field(world - light_dir * shadow_length * t).g * (1.0 - t));
	}
	occlusion *= 1.0 - here.g;
	// Back to front: the shadow (tinted attenuation), dust (thinned where shaded), contours.
	vec3 color = shadow_color.rgb;
	float alpha = shadow_alpha * occlusion;
	float a_dust = dust_alpha * smoothstep(0.02, 0.9, here.r) * (1.0 - 0.7 * occlusion);
	color = mix(color * alpha, dust_color.rgb, a_dust) / max(a_dust + alpha * (1.0 - a_dust), 1e-5);
	alpha = a_dust + alpha * (1.0 - a_dust);
	float a_line = contour_alpha * line;
	color = mix(color * alpha, vec3(0.75, 0.78, 0.82), a_line) / max(a_line + alpha * (1.0 - a_line), 1e-5);
	ALBEDO = color;
	ALPHA = a_line + alpha * (1.0 - a_line);
}
"""

@export var transition_time := 0.45 # s (real time), each way
@export var frame_margin := 1.06 # sector framing margin
@export var cluster_distance := 22.0 # canvas units: asteroid markers closer than this share a cluster
@export var ring_radius := 32.0 # canvas units: radial expansion around a resource marker
@export var subgroup_ring_radius := 26.0 # canvas units: expansion around a subgroup marker
@export var subgroup_size := 6 # most individual targets in one ring
@export var keep_margin := 14.0 # canvas units beyond a ring that keep an expansion open
@export var marker_hit := 7.0 # canvas units: hover / click radius of Strategic asteroid markers
@export var contour_spread := 7.0 # u: how far an asteroid's influence reaches beyond its surface
@export var contour_alpha := 0.07
@export var shadow_alpha := 0.22
@export var shadow_length := 26.0 # u
@export var shadow_min_radius := 3.0 # u: a formation's equivalent radius needed for a shadow
@export var shadow_min_pixels := 5.0 # canvas units: the same radius on screen at the Strategic scale
@export var field_resolution := 256 # texels per side of the baked field
@export var boundary_time := 1.6 # s the refused-command boundary stays visible

var state := State.TACTICAL
var progress := 0.0 # 0 Tactical camera, 1 Strategic framing
var auto_hover := true # Off in tests, which give the cursor to update_hover().
var builds := 0 # Field bakes (expected once per scene).
var light_direction := Vector2.ZERO # Planar shadow direction in use (zero: no shadows).
var profile: Resource = null # The sector profile (SectorEnvironment's), when the scene has one.
var background := BACKGROUND

var _camera: Camera3D
var _saved := {} # The rig's pose at entry: transform, zoom_distance, zoom_target.
var _from := Transform3D() # The rig camera's transform the handoff starts from.
var _spheres: MultiMeshInstance3D
var _overlay: MeshInstance3D
var _overlay_material := ShaderMaterial.new()
var _fog: MeshInstance3D
var _dim: ColorRect
var _under: Control # Paths, clusters, resource markers, boundary (under the ship markers).
var _over: Control # Radial expansion (over the ship markers).
var _panel: PanelContainer
var _label: Label
var _clusters: Array = [] # {members: Array[int], center: Vector3, extent: Rect2}
var _cluster_key := Vector3.ZERO # Canvas size and framing height the clusters were built for.
var _layout: Array = [] # Per cluster: {env: Vector2, resources: [{family, ids, at}]}
var _expanded := {} # {cluster, family, sub} of the open radial expansion, or empty
var _boundary_left := 0.0
var _boundary_layer: CanvasLayer
var _casters := {} # asteroid id -> true: members of shadow-casting formations
var _field_image: Image # The baked field (R density, G shadow casters).

@onready var _arena := get_parent()
@onready var _rig: Node3D = _arena.get_node("CameraRig")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var environment = _arena.get("environment")
	if environment != null:
		profile = environment.profile
		shadow_alpha = profile.shadow_strength
		background = profile.background_color
	_camera = Camera3D.new()
	_camera.fov = (_rig.get_node("Camera3D") as Camera3D).fov
	_camera.cull_mask = DETAIL_MASK
	add_child(_camera)
	var dim_layer := CanvasLayer.new()
	dim_layer.layer = -1 # Over the 3D view, under every marker.
	_dim = ColorRect.new()
	_dim.color = Color(background, 0.0)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim_layer.add_child(_dim)
	add_child(dim_layer)
	_boundary_layer = CanvasLayer.new()
	_boundary_layer.layer = 0 # Added before TacticalMarkers: under the ship markers.
	_under = _canvas(_draw_under)
	_boundary_layer.add_child(_under)
	add_child(_boundary_layer)
	var over_layer := CanvasLayer.new()
	over_layer.layer = 1
	_over = _canvas(_draw_over)
	over_layer.add_child(_over)
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_label)
	var text_layer := CanvasLayer.new()
	text_layer.layer = 2
	text_layer.add_child(_panel)
	add_child(over_layer)
	add_child(text_layer)
	_build.call_deferred() # After the combat layer (FogView) is complete.


func _canvas(callback: Callable) -> Control:
	var canvas := Control.new()
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.draw.connect(callback)
	return canvas


## The camera showing Strategic (current from the start of the handoff until its end).
func camera() -> Camera3D:
	return _camera


## Whether the Strategic camera is in use (handoff or Strategic): Tactical rules do not apply.
func in_strategic() -> bool:
	return state != State.TACTICAL


## Whether a handoff is under way (all gameplay input is held).
func transitioning() -> bool:
	return state == State.ENTERING or state == State.EXITING


## Whether Strategic View is fully shown and takes input.
func is_active() -> bool:
	return state == State.STRATEGIC


# --- Handoff ---------------------------------------------------------------------------

## Starts (or reverses toward) Strategic. Ignored unless the rig is at its maximum zoom.
func enter() -> void:
	if state == State.TACTICAL:
		if not rig_at_limit():
			return
		_saved = {"transform": _rig.global_transform, "zoom": _rig.zoom_distance, "target": _rig.zoom_target}
		_rig.set_process(false)
		_rig.set_process_unhandled_input(false)
		_from = (_rig.get_node("Camera3D") as Camera3D).global_transform
		_camera.global_transform = _from
		_camera.cull_mask = DETAIL_MASK
		_camera.make_current()
		_cancel_presses()
		_ensure_clusters()
	if state != State.STRATEGIC:
		state = State.ENTERING


## Starts (or reverses toward) the return to Tactical.
func exit() -> void:
	if state == State.STRATEGIC or state == State.ENTERING:
		state = State.EXITING
		_expanded = {}
		_cancel_presses()


## Whether the rig is at its maximum zoom (requested and rendered): only then does an
## outward notch go to Strategic instead of the rig.
func rig_at_limit() -> bool:
	return _rig.zoom_target >= _rig.max_zoom - 0.001 and _rig.zoom_distance >= _rig.max_zoom - 0.001


func _finish_exit() -> void:
	state = State.TACTICAL
	progress = 0.0
	_rig.global_transform = _saved.transform
	_rig.zoom_distance = _saved.zoom
	_rig._apply_zoom()
	_rig.zoom_target = _saved.target
	_rig.set_process(true)
	_rig.set_process_unhandled_input(true)
	(_rig.get_node("Camera3D") as Camera3D).make_current()
	_camera.cull_mask = DETAIL_MASK


func _cancel_presses() -> void:
	for node_name in ["Selection", "StationPanel"]:
		var node := _arena.get_node_or_null(node_name)
		if node != null and node.has_method("cancel_press"):
			node.cancel_press()


## The Strategic framing: top-down over the sector centre, at the rig's yaw, far enough
## for the whole sector rectangle at the given aspect ratio (width / height).
func frame_transform(aspect: float) -> Transform3D:
	var yaw := (_rig.global_basis as Basis).get_euler().y if _saved.is_empty() else (_saved.transform as Transform3D).basis.get_euler().y
	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -PI / 2.0)
	var rect: Rect2 = sector_rect()
	var half_w := 0.0
	var half_h := 0.0
	for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		var offset := Vector3(corner.x - rect.get_center().x, 0.0, corner.y - rect.get_center().y)
		half_w = maxf(half_w, absf(offset.dot(basis.x)))
		half_h = maxf(half_h, absf(offset.dot(basis.y)))
	var tan_half := tan(deg_to_rad(_camera.fov) * 0.5)
	var distance := maxf(half_h, half_w / maxf(aspect, 0.01)) * frame_margin / tan_half
	return Transform3D(basis, Vector3(rect.get_center().x, distance, rect.get_center().y))


## The prototype sector rectangle on the X/Z plane (the rig's pan bounds; temporary).
func sector_rect() -> Rect2:
	return _rig.bounds


func _aspect() -> float:
	var size := get_viewport().get_visible_rect().size
	return size.x / maxf(size.y, 1.0)


func _input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null:
		return
	if button.button_index == MOUSE_BUTTON_WHEEL_UP or button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not button.pressed or get_viewport().gui_get_hovered_control() != null:
			return # UI panels keep the wheel.
		var outward := button.button_index == MOUSE_BUTTON_WHEEL_DOWN
		if state == State.TACTICAL:
			if outward and rig_at_limit():
				enter()
				get_viewport().set_input_as_handled()
			return
		if outward:
			enter()
		else:
			exit()
		get_viewport().set_input_as_handled() # Never reaches the frozen rig.
		return
	if transitioning():
		get_viewport().set_input_as_handled() # No click or command during a handoff.


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or not is_active():
		return
	if button.button_index == MOUSE_BUTTON_RIGHT:
		_check_boundary(button.position)
	elif button.button_index == MOUSE_BUTTON_LEFT and not button.shift_pressed and _over_asteroid_marker(button.position):
		# A click on an asteroid cluster / resource marker is not a click on empty space:
		# it keeps the selection (ships and stations under the point still come first).
		if _arena.selection().pick_any(button.position) == null and station_at(button.position) == null:
			get_viewport().set_input_as_handled()


# A right-click whose ground point the command rules refuse as outside the sector: the
# boundary is shown for a moment. Nothing about the command changes.
func _check_boundary(screen: Vector2) -> void:
	if _arena.selection().selected.is_empty():
		return
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(_camera.project_ray_origin(screen), _camera.project_ray_normal(screen))
	if hit == null:
		return
	var half: float = _arena.GROUND_HALF_SIZE
	if (absf(hit.x) > half or absf(hit.z) > half) and _arena.resolve_command(screen).is_empty():
		_boundary_left = boundary_time


## Opacity of the refused-command boundary now (0: not shown).
func boundary_alpha() -> float:
	return clampf(_boundary_left / boundary_time, 0.0, 1.0) if is_active() else 0.0


func _process(delta: float) -> void:
	if Engine.time_scale > 0.0:
		delta /= Engine.time_scale # Real time at every simulation speed.
	match state:
		State.ENTERING:
			progress = minf(1.0, progress + delta / transition_time)
			if progress >= 1.0:
				state = State.STRATEGIC
		State.EXITING:
			progress = maxf(0.0, progress - delta / transition_time)
			if progress <= 0.0:
				_finish_exit()
	if state != State.TACTICAL:
		var t := smoothstep(0.0, 1.0, progress)
		var goal := frame_transform(_aspect())
		_camera.global_transform = Transform3D(_from.basis.slerp(goal.basis, t), _from.origin.lerp(goal.origin, t))
		_camera.cull_mask = LAYER if progress >= 0.5 else DETAIL_MASK
		_ensure_clusters()
	_dim.color.a = 1.0 - smoothstep(0.0, 0.5, absf(progress - 0.5)) if state != State.TACTICAL else 0.0
	# The Strategic geometry exists only while the Strategic layer is the one rendered: a
	# Camera3D renders every layer by default, so the rig's camera would show it too.
	var shown := state != State.TACTICAL and progress >= 0.5
	for node: Node3D in [_spheres, _overlay]:
		if node != null:
			node.visible = shown
	if _fog != null:
		_fog.visible = shown and (_arena.fog_view as Node3D).visible
	_boundary_left = maxf(0.0, _boundary_left - delta)
	_layout = _compute_layout() if state != State.TACTICAL else []
	if is_active() and auto_hover:
		var viewport := get_viewport()
		update_hover(viewport.get_mouse_position(), viewport.gui_get_hovered_control() == null)
	elif not is_active():
		_expanded = {}
	_update_text(get_viewport().get_mouse_position() if is_active() else Vector2.INF)
	_under.queue_redraw()
	_over.queue_redraw()


# --- Strategic geometry, contours and shadows ---------------------------------------------

func _build() -> void:
	var field := _arena.get_node_or_null("Asteroids")
	if _arena.fog_view != null:
		_fog = MeshInstance3D.new()
		_fog.mesh = (_arena.fog_view as MeshInstance3D).mesh # Far past the sector: no edge.
		_fog.material_override = (_arena.fog_view as MeshInstance3D).material_override # FogView's live uniforms.
		_fog.layers = LAYER
		_fog.position = Vector3(0, 6.0, 0) # Above the simplified asteroids, so they dim too.
		if profile != null:
			_fog.set_instance_shader_parameter("view_strength", profile.strategic_fog_strength / maxf(profile.fog_strength, 0.001))
		_fog.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fog.visible = false
		add_child(_fog)
	if field == null or not field.has_method("ids"):
		return
	var ids: Array = field.ids()
	if _fog != null: # Above the tallest simplified asteroid, so none shows through.
		for id: int in ids:
			_fog.position.y = maxf(_fog.position.y, field.center(id).y + field.radius(id) + 0.5)
	var sphere := SphereMesh.new()
	sphere.radial_segments = 12
	sphere.rings = 6
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.16, 0.16, 0.17)
	material.roughness = 1.0
	material.disable_receive_shadows = true # The hidden detailed scene still casts into the light's shadow map.
	sphere.material = material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = sphere
	multimesh.instance_count = ids.size()
	for i in ids.size():
		multimesh.set_instance_transform(i, (field.node_of(ids[i]) as Node3D).global_transform)
	_spheres = MultiMeshInstance3D.new()
	_spheres.multimesh = multimesh
	_spheres.layers = LAYER
	_spheres.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spheres.visible = false # Shown only in Strategic (_process).
	add_child(_spheres)
	_bake_field(field, ids)


## Number of simplified asteroids drawn in Strategic.
func sphere_count() -> int:
	return _spheres.multimesh.instance_count if _spheres != null else 0


# The density field (R: smooth sum of every asteroid's influence, for the contours) and
# the shadow casters (G: coverage of the significant formations only), baked once.
func _bake_field(field: Node, ids: Array) -> void:
	builds += 1
	var light := _scene_light()
	light_direction = Vector2.ZERO
	if light != null:
		var travel := -light.global_basis.z
		var planar := Vector2(travel.x, travel.z)
		if planar.length() > 0.05:
			light_direction = planar.normalized()
	var rect := sector_rect().grow(shadow_length + contour_spread * 2.0)
	var n := field_resolution
	var texel := rect.size / float(n)
	var values := PackedFloat32Array()
	values.resize(n * n * 2)
	var formations := formations_of(field, ids)
	var scale := _strategic_scale()
	var casters := {}
	for formation: Array in formations:
		var area := 0.0
		for id: int in formation:
			area += field.radius(id) * field.radius(id)
		var radius := sqrt(area)
		if radius >= shadow_min_radius and radius * scale >= shadow_min_pixels:
			for id: int in formation:
				casters[id] = true
	for id: int in ids:
		var c: Vector3 = field.center(id)
		var r: float = field.radius(id)
		var reach := r + contour_spread
		var lo := Vector2i(floori((c.x - reach - rect.position.x) / texel.x), floori((c.z - reach - rect.position.y) / texel.y))
		var hi := Vector2i(ceili((c.x + reach - rect.position.x) / texel.x), ceili((c.z + reach - rect.position.y) / texel.y))
		for y in range(maxi(lo.y, 0), mini(hi.y, n - 1) + 1):
			for x in range(maxi(lo.x, 0), mini(hi.x, n - 1) + 1):
				var p := rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) * texel
				var d := p.distance_to(Vector2(c.x, c.z))
				if d >= reach:
					continue
				var k := 1.0 - (d / reach) * (d / reach)
				var index := (y * n + x) * 2
				values[index] += k * k * k
				if casters.has(id):
					values[index + 1] = maxf(values[index + 1], 1.0 - smoothstep(r - 1.0, r + 1.5, d))
	var image := Image.create_from_data(n, n, false, Image.FORMAT_RGF, values.to_byte_array())
	var plane := PlaneMesh.new()
	plane.size = rect.size
	_overlay = MeshInstance3D.new()
	_overlay.mesh = plane
	_overlay.position = Vector3(rect.get_center().x, 0.02, rect.get_center().y)
	_overlay.layers = LAYER
	_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_overlay.visible = false
	var shader := Shader.new()
	shader.code = SHADER
	_overlay_material.shader = shader
	_overlay_material.render_priority = -2 # Under the fog quad.
	_overlay_material.set_shader_parameter("field", ImageTexture.create_from_image(image))
	_overlay_material.set_shader_parameter("rect", Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
	_overlay_material.set_shader_parameter("light_dir", light_direction)
	_overlay_material.set_shader_parameter("shadow_length", shadow_length)
	_overlay_material.set_shader_parameter("shadow_alpha", shadow_alpha if light_direction != Vector2.ZERO else 0.0)
	if profile != null:
		_overlay_material.set_shader_parameter("shadow_color", profile.shadow_color)
		_overlay_material.set_shader_parameter("dust_color", profile.dust_color)
		_overlay_material.set_shader_parameter("dust_alpha", profile.strategic_dust_strength)
	_overlay_material.set_shader_parameter("contour_alpha", contour_alpha)
	_overlay.material_override = _overlay_material
	add_child(_overlay)
	_casters = casters
	_field_image = image


## Whether an asteroid belongs to a formation that casts a Strategic shadow.
func casts_shadow(id: int) -> bool:
	return _casters.has(id)


## The baked field at a world point: (density, shadow-caster coverage).
func field_at(point: Vector2) -> Vector2:
	if _field_image == null:
		return Vector2.ZERO
	var rect := sector_rect().grow(shadow_length + contour_spread * 2.0)
	var texel := ((point - rect.position) / rect.size * float(field_resolution)).floor()
	if texel.x < 0 or texel.y < 0 or texel.x >= field_resolution or texel.y >= field_resolution:
		return Vector2.ZERO
	var pixel := _field_image.get_pixel(int(texel.x), int(texel.y))
	return Vector2(pixel.r, pixel.g)


## Asteroid formations: asteroids whose influence areas overlap (contour spread) belong
## together (union-find over the field's ids, ascending).
func formations_of(field: Node, ids: Array) -> Array:
	var parent := {}
	for id: int in ids:
		parent[id] = id
	for i in ids.size():
		var a: int = ids[i]
		var ca: Vector3 = field.center(a)
		for j in range(i + 1, ids.size()):
			var b: int = ids[j]
			var cb: Vector3 = field.center(b)
			if Vector2(ca.x, ca.z).distance_to(Vector2(cb.x, cb.z)) < field.radius(a) + field.radius(b) + contour_spread * 2.0 * 0.8:
				parent[_root(parent, a)] = _root(parent, b)
	var groups := {}
	for id: int in ids:
		var root := _root(parent, id)
		if not groups.has(root):
			groups[root] = []
		groups[root].append(id)
	return groups.values()


static func _root(parent: Dictionary, id: int) -> int:
	while parent[id] != id:
		parent[id] = parent[parent[id]]
		id = parent[id]
	return id


func _scene_light() -> DirectionalLight3D:
	for child in _arena.get_children():
		if child is DirectionalLight3D:
			return child
	return null


# Canvas units per world unit at the Strategic framing.
func _strategic_scale() -> float:
	var goal := frame_transform(_aspect())
	var height := get_viewport().get_visible_rect().size.y
	return height / (2.0 * goal.origin.y * tan(deg_to_rad(_camera.fov) * 0.5))


# --- Asteroid clusters and resource markers ------------------------------------------------

# Clusters by screen-space proximity at the Strategic framing (built when Strategic is
# entered and again if the canvas size changes; the camera is fixed there).
func _ensure_clusters() -> void:
	var size := get_viewport().get_visible_rect().size
	var key := Vector3(size.x, size.y, frame_transform(_aspect()).origin.y)
	if key == _cluster_key and not _clusters.is_empty():
		return
	_cluster_key = key
	_clusters = []
	var field := _arena.get_node_or_null("Asteroids")
	if field == null or not field.has_method("ids"):
		return
	var keep := _camera.global_transform
	_camera.global_transform = frame_transform(_aspect())
	var ids: Array = field.ids().filter(func(id: int) -> bool: return (field.node_of(id) as Node3D).visible)
	var screen := {}
	var cells := {}
	for id: int in ids:
		var at := _camera.unproject_position(field.center(id))
		screen[id] = at
		var cell := Vector2i((at / cluster_distance).floor())
		if not cells.has(cell):
			cells[cell] = []
		cells[cell].append(id)
	_camera.global_transform = keep
	var parent := {}
	for id: int in ids:
		parent[id] = id
	for id: int in ids:
		var cell := Vector2i((screen[id] / cluster_distance).floor())
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for other: int in cells.get(cell + Vector2i(dx, dy), []):
					if other > id and (screen[id] as Vector2).distance_to(screen[other]) < cluster_distance:
						parent[_root(parent, id)] = _root(parent, other)
	var groups := {}
	for id: int in ids:
		var root := _root(parent, id)
		if not groups.has(root):
			groups[root] = []
		groups[root].append(id)
	for members: Array in groups.values():
		members.sort()
		var center := Vector3.ZERO
		var extent := Rect2()
		for k in members.size():
			var c: Vector3 = field.center(members[k])
			var r: float = field.radius(members[k])
			center += c
			var box := Rect2(Vector2(c.x - r, c.z - r), Vector2(r, r) * 2.0)
			extent = box if k == 0 else extent.merge(box)
		_clusters.append({"members": members, "center": center / members.size(), "extent": extent})
	_clusters.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.members[0] < b.members[0])


## The asteroid clusters: {members (ids, ascending), center (world), extent (world rect)}.
func clusters() -> Array:
	_ensure_clusters()
	return _clusters


## Known resource asteroids of a cluster by family: survey level IDENTIFIED or better, and
## not analyzed as depleted (unknown asteroids are never revealed).
func resources_of(cluster: Dictionary) -> Dictionary:
	var survey := _arena.get_node_or_null("Survey")
	var field := _arena.get_node("Asteroids")
	var result := {}
	if survey == null:
		return result
	for id: int in cluster.members:
		var level: int = survey.level_of(id)
		if level == Survey.Level.UNKNOWN:
			continue
		var deposit = field.deposit(id)
		if level == Survey.Level.ANALYZED and deposit.reserves <= 0:
			continue
		if not result.has(deposit.family):
			result[deposit.family] = []
		result[deposit.family].append(id)
	return result


# Screen layout now: per cluster its environmental marker and, beside it, one resource
# marker per known family (minerals first).
func _compute_layout() -> Array:
	var result := []
	for cluster: Dictionary in _clusters:
		var env := _camera.unproject_position(cluster.center)
		var resources := []
		var by_family := resources_of(cluster)
		var k := 0
		for family in [AsteroidField.Family.MINERALS, AsteroidField.Family.ICE]:
			if by_family.has(family):
				k += 1
				resources.append({"family": family, "ids": by_family[family], "at": env + Vector2(11.0 * k, 0.0)})
		result.append({"env": env, "resources": resources})
	return result


## The current marker layout: per cluster {env, resources: [{family, ids, at}]} (screen).
func layout() -> Array:
	return _layout


# --- Radial expansion ---------------------------------------------------------------------

## Opens, keeps or closes the radial expansion for a cursor position (free: not over a GUI
## control). Hovering a resource marker opens it; moving between its members keeps it;
## leaving the group's area closes it. Groups of more than `subgroup_size` show subgroup
## markers first; hovering one opens its own ring.
func update_hover(mouse: Vector2, free: bool = true) -> void:
	if not is_active() or not free:
		_expanded = {}
		return
	if not _expanded.is_empty():
		var resource := _expanded_resource()
		if resource.is_empty():
			_expanded = {}
		else:
			var inside: bool = mouse.distance_to(resource.at) <= ring_radius + keep_margin
			var subs := _subgroups(resource.ids)
			if _expanded.sub >= 0:
				inside = inside or mouse.distance_to(_ring_point(resource.at, ring_radius, _expanded.sub, subs.size())) <= subgroup_ring_radius + keep_margin
			if inside:
				if subs.size() > 1:
					for j in subs.size():
						if mouse.distance_to(_ring_point(resource.at, ring_radius, j, subs.size())) <= marker_hit:
							_expanded.sub = j
				return
			_expanded = {}
	for c in _layout.size():
		for resource: Dictionary in _layout[c].resources:
			if mouse.distance_to(resource.at) <= marker_hit:
				_expanded = {"cluster": c, "family": resource.family, "sub": -1}
				return


func _expanded_resource() -> Dictionary:
	if _expanded.is_empty() or _expanded.cluster >= _layout.size():
		return {}
	for resource: Dictionary in _layout[_expanded.cluster].resources:
		if resource.family == _expanded.family:
			return resource
	return {}


func _subgroups(ids: Array) -> Array:
	var result := []
	for start in range(0, ids.size(), subgroup_size):
		result.append(ids.slice(start, start + subgroup_size))
	return result


static func _ring_point(center: Vector2, radius: float, index: int, count: int) -> Vector2:
	return center + Vector2.from_angle(-PI / 2.0 + TAU * index / maxf(count, 1)) * radius


## The open expansion's markers: [{kind: "member" (id) or "subgroup" (index, count), at}].
func expansion() -> Array:
	var result := []
	var resource := _expanded_resource()
	if resource.is_empty():
		return result
	var subs := _subgroups(resource.ids)
	if subs.size() == 1:
		for i in resource.ids.size():
			result.append({"kind": "member", "id": resource.ids[i], "at": _ring_point(resource.at, ring_radius, i, resource.ids.size())})
		return result
	for j in subs.size():
		result.append({"kind": "subgroup", "index": j, "count": subs[j].size(), "at": _ring_point(resource.at, ring_radius, j, subs.size())})
	if _expanded.sub >= 0 and _expanded.sub < subs.size():
		var members: Array = subs[_expanded.sub]
		var around := _ring_point(resource.at, ring_radius, _expanded.sub, subs.size())
		for i in members.size():
			result.append({"kind": "member", "id": members[i], "at": _ring_point(around, subgroup_ring_radius, i, members.size())})
	return result


## The asteroid whose expanded marker is under a screen point, or -1 (Strategic only:
## individual asteroids are reached through the expansion, never through hidden geometry).
func asteroid_at(screen: Vector2) -> int:
	if not is_active():
		return -1
	var best := -1
	var best_distance := marker_hit
	for entry: Dictionary in expansion():
		if entry.kind == "member" and screen.distance_to(entry.at) <= best_distance:
			best = entry.id
			best_distance = screen.distance_to(entry.at)
	return best


## The station whose marker contains a screen point, or null (Strategic only; nearest
## centre wins). Only stations shown are considered.
func station_at(screen: Vector2) -> Node3D:
	var stations := _arena.get_node_or_null("Stations")
	if not is_active() or stations == null:
		return null
	var half: float = _arena.markers.STATION_SIZE * _arena.markers.scale_factor() * 0.92 * 0.7072 + 2.0
	var best: Node3D = null
	var best_distance := INF
	for station: Node3D in stations.get_children():
		if not station.is_visible_in_tree():
			continue
		var at := _camera.unproject_position(station.global_position)
		var offset := (screen - at).abs()
		if offset.x <= half and offset.y <= half and offset.length() < best_distance:
			best = station
			best_distance = offset.length()
	return best


func _over_asteroid_marker(screen: Vector2) -> bool:
	if asteroid_at(screen) >= 0:
		return true
	for entry: Dictionary in _layout:
		if screen.distance_to(entry.env) <= marker_hit:
			return true
		for resource: Dictionary in entry.resources:
			if screen.distance_to(resource.at) <= marker_hit:
				return true
	return false


func _update_text(mouse: Vector2) -> void:
	var text := ""
	if mouse != Vector2.INF and asteroid_at(mouse) < 0 and _arena.selection().pick_any(mouse) == null and station_at(mouse) == null:
		for c in _layout.size():
			var entry: Dictionary = _layout[c]
			for resource: Dictionary in entry.resources:
				if mouse.distance_to(resource.at) <= marker_hit:
					text = "%s: %d asteroid%s" % [FAMILY_NAMES[resource.family], resource.ids.size(), "" if resource.ids.size() == 1 else "s"]
			if text == "" and mouse.distance_to(entry.env) <= marker_hit:
				text = cluster_text(_clusters[c])
	_label.text = text
	_panel.visible = text != ""
	if _panel.visible:
		_panel.reset_size()
		var limit := get_viewport().get_visible_rect().size - _panel.size
		_panel.position = (mouse + Vector2(18, 18)).clamp(Vector2.ZERO, limit.max(Vector2.ZERO))


## Hover text of an environmental cluster marker: count and approximate extent.
func cluster_text(cluster: Dictionary) -> String:
	var size: Vector2 = cluster.extent.size
	return "Asteroid formation\n%d asteroid%s\nabout %.0f × %.0f u" % [cluster.members.size(), "" if cluster.members.size() == 1 else "s", size.x, size.y]


# --- Selected ships' orders ------------------------------------------------------------------

## A selected ship's order lines from the simulation: [{points (world X/Z), kind}], kind
## "route" (the RouteFollower's planned route still to fly, or the straight move), then
## "waypoints" (Behavior waypoint legs after the current one) or "attack_move".
func order_lines(ship: Node3D) -> Array:
	var result := []
	var locomotion = ship.get_node_or_null("Locomotion")
	var follower := ship.get_node_or_null("RouteFollower") as RouteFollower
	var end := Vector2(ship.global_position.x, ship.global_position.z)
	if locomotion != null and locomotion.has_destination:
		var points := PackedVector2Array([end])
		if follower != null and follower.status == RouteFollower.RouteStatus.ROUTE and follower.route.size() > follower.segment + 1:
			points.append_array(follower.route.slice(follower.segment + 1))
		else:
			points.append(locomotion.destination)
		end = points[points.size() - 1]
		result.append({"points": points, "kind": "route"})
	var behavior := ship.get_node_or_null("Behavior") as Behavior
	if behavior != null:
		if behavior.command == Behavior.Command.WAYPOINTS and behavior.waypoints.size() > 1:
			result.append({"points": PackedVector2Array([end]) + PackedVector2Array(behavior.waypoints.slice(1)), "kind": "waypoints"})
		elif behavior.command == Behavior.Command.ATTACK_MOVE:
			result.append({"points": PackedVector2Array([end, behavior.destination]), "kind": "attack_move"})
	return result


# --- Drawing -------------------------------------------------------------------------------

func _project(point: Vector2) -> Vector2:
	return _camera.unproject_position(Vector3(point.x, 0.0, point.y))


func _draw_under() -> void:
	if state == State.TACTICAL:
		return
	var alpha := smoothstep(0.0, 1.0, progress)
	var width := 1.6
	if boundary_alpha() > 0.0:
		var half: float = _arena.GROUND_HALF_SIZE
		var corners := PackedVector2Array()
		for corner in [Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half), Vector2(-half, -half)]:
			corners.append(_project(corner))
		_under.draw_polyline(corners, Color(BOUNDARY_COLOR, 0.8 * boundary_alpha()), 2.0)
	for ship: Node3D in _arena.selection().selected:
		if not is_instance_valid(ship):
			continue
		for line: Dictionary in order_lines(ship):
			var points := PackedVector2Array()
			for point: Vector2 in line.points:
				points.append(_project(point))
			match line.kind:
				"route":
					_under.draw_polyline(points, Color(ROUTE_COLOR, 0.9 * alpha), width)
					_under.draw_arc(points[points.size() - 1], 4.0, 0.0, TAU, 16, Color(ROUTE_COLOR, 0.9 * alpha), width)
				"waypoints":
					for i in points.size() - 1:
						_under.draw_dashed_line(points[i], points[i + 1], Color(WAYPOINT_COLOR, 0.85 * alpha), width, 5.0)
					for point in points.slice(1):
						_under.draw_circle(point, 2.5, Color(WAYPOINT_COLOR, 0.85 * alpha))
				"attack_move":
					_under.draw_dashed_line(points[0], points[1], Color(ATTACK_MOVE_COLOR, 0.85 * alpha), width, 5.0)
	for entry: Dictionary in _layout:
		_under.draw_arc(entry.env, 4.0, 0.0, TAU, 12, Color(CLUSTER_COLOR, 0.75 * alpha), 1.4)
		for resource: Dictionary in entry.resources:
			var color: Color = FAMILY_COLORS[resource.family]
			_under.draw_colored_polygon(ObjectMarkers.shape_points(ObjectMarkers.Shape.DIAMOND, resource.at, 5.0), Color(color, 0.95 * alpha))
			if resource.ids.size() > 1:
				_under.draw_string(ThemeDB.fallback_font, resource.at + Vector2(-3, 15), str(resource.ids.size()), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(color, 0.9 * alpha))


func _draw_over() -> void:
	if not is_active():
		return
	var resource := _expanded_resource()
	if resource.is_empty():
		return
	var field := _arena.get_node("Asteroids")
	var color: Color = FAMILY_COLORS[resource.family]
	_over.draw_circle(resource.at, ring_radius + keep_margin * 0.5, Color(background, 0.55))
	for entry: Dictionary in expansion():
		if entry.kind == "subgroup":
			_over.draw_circle(entry.at, 6.0, Color(color.darkened(0.5), 0.9))
			_over.draw_arc(entry.at, 6.0, 0.0, TAU, 16, Color(color, 0.95), 1.4)
			_over.draw_string(ThemeDB.fallback_font, entry.at + Vector2(-3, 4), str(entry.count), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color.WHITE)
			continue
		var actual := _camera.unproject_position(field.center(entry.id))
		_over.draw_line(entry.at, actual, Color(color, 0.3), 1.0)
		_over.draw_colored_polygon(ObjectMarkers.shape_points(ObjectMarkers.Shape.DIAMOND, entry.at, 6.0), Color(color, 0.95))
		_over.draw_polyline(ObjectMarkers.shape_points(ObjectMarkers.Shape.DIAMOND, entry.at, 6.0) + PackedVector2Array([entry.at + Vector2(6.0, 0)]), Color(0, 0, 0, 0.7), 1.0)
