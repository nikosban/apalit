shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
// Ship sensor grid overlay (SensorGridOverlay): on one flat quad centred on the selected
// ship, a world-aligned square grid with a small rectangle at every intersection and a
// translucent fill, clipped to the sensor radius, and two concentric outlines (inner at the
// sensor boundary, outer `outer_offset` beyond it). Distances (spacing, radius, offset) and
// rectangle sizes are world units, so the rectangles scale with the grid at every zoom;
// line thicknesses are pixels at a 1080 px screen height, scaled with the viewport height
// (the project's 2D convention), anti-aliased with fwidth.
// The layers are composited over one another and the result is multiplied by
// `overall_opacity`, so with element opacities at most 1 the overlay never exceeds it.
// Obstacle cutouts (line of sight): the sensor area is the circle minus the union of the
// shadows the obstacles cast from the ship (sensor_grid_overlay.gd). A shadow is the
// obstacle's collision footprint grown by the clearance plus everything behind it between
// the two tangent rays from the ship: it pinches round the obstacle's near side and widens
// outward to past the outer outline. Circles are exact (analytic, rounded pinch); boxes are
// convex polygons built by the script (rounded corners sampled). The shadows are unioned
// (plain minimum, no seams) and meet the circle with `cutout_blend` u of rounding. One
// signed distance field drives the clip and both outlines (the outer one at `outer_offset`
// outside it), so they follow the same contour.

const int MAX_SHADOWS = 64;
const int MAX_POLYGONS = 8;
const int MAX_POLYGON_POINTS = 128;

// Set per overlay by sensor_grid_overlay.gd from Sensors.sensor_range (not edited here).
instance uniform float sensor_radius = 100.0;

group_uniforms overall;
uniform float overall_opacity : hint_range(0.0, 1.0) = 0.64;
uniform float pixel_reference_height = 1080.0; // screen height at which the px values are exact
group_uniforms;

group_uniforms grid;
uniform float grid_spacing = 9.25; // u
uniform vec2 grid_origin = vec2(0.5); // cells: 0.5 puts the ship at a cell centre, 0 on an intersection
uniform float grid_thickness = 1.0; // px
uniform vec4 grid_color : source_color = vec4(0.62, 0.62, 0.62, 1.0);
uniform float grid_opacity : hint_range(0.0, 1.0) = 0.09;
group_uniforms;

group_uniforms intersections;
uniform float rect_width = 0.8; // u
uniform float rect_height = 0.8; // u
uniform float rect_max_size = 4.0; // px: the rectangles never draw larger on screen, at any zoom
uniform vec4 rect_color : source_color = vec4(0.62, 0.62, 0.62, 1.0);
uniform float rect_opacity : hint_range(0.0, 1.0) = 0.15;
group_uniforms;

group_uniforms inner_outline;
uniform float inner_thickness = 4.0; // px, centred on the sensor radius
uniform vec4 inner_color : source_color = vec4(0.62, 0.61, 0.62, 1.0);
uniform float inner_opacity : hint_range(0.0, 1.0) = 0.27;
group_uniforms;

group_uniforms outer_outline;
uniform float outer_offset = 3.0; // u beyond the sensor radius
uniform float outer_thickness = 2.0; // px
uniform vec4 outer_color : source_color = vec4(0.62, 0.61, 0.62, 1.0);
uniform float outer_opacity : hint_range(0.0, 1.0) = 0.22;
group_uniforms;

group_uniforms fill;
uniform vec4 fill_color : source_color = vec4(0.75, 0.68, 0.55, 1.0);
uniform float fill_opacity : hint_range(0.0, 1.0) = 0.005;
group_uniforms;

group_uniforms cutouts;
uniform float cutout_clearance = 1.0; // u added around each obstacle's collision footprint
uniform float cutout_blend = 1.5; // u: rounding where a shadow meets the circle
group_uniforms;

// Runtime cutout geometry, written by sensor_grid_overlay.gd on its own copy of this
// material every frame (positions relative to the ship, u); not for editing.
group_uniforms runtime_cutouts;
uniform vec2 shadow_centers[64]; // MAX_SHADOWS: circular obstacles' centres
uniform float shadow_radii[64]; // footprint radius + clearance
uniform int shadow_count = 0;
uniform vec2 polygon_points[128]; // MAX_POLYGON_POINTS: box shadows (convex, clearance included)
uniform int polygon_first[8]; // MAX_POLYGONS: index of each hull's first point
uniform int polygon_sizes[8]; // and its point count
uniform int polygon_count = 0;
group_uniforms;

varying vec2 local; // world X/Z offset from the overlay's centre (the ship), no rotation

void vertex() {
	local = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz - MODEL_MATRIX[3].xz;
}

// Coverage (0-1) of a stroke `width_px` wide at `d_px` pixels from its centre line.
float stroke(float d_px, float width_px) {
	return clamp(width_px * 0.5 - d_px + 0.5, 0.0, 1.0) * min(width_px, 1.0);
}

// Signed distance to the shadow a disc (centre c, radius r) casts from the origin (the
// ship): the disc plus the part of the tangent cone behind its tangent points. Its
// boundary is the disc's near arc between the tangent points and the two rays beyond them.
float shadow_distance(vec2 p, vec2 c, float r) {
	float d = length(c);
	vec2 u = c / d;
	vec2 q = vec2(dot(p, u), abs(dot(p, vec2(-u.y, u.x)))); // along the axis, off it (symmetric)
	float l = sqrt(max(d * d - r * r, 1e-6)); // ship to tangent point
	vec2 ray = vec2(l, r) / d; // tangent ray direction (cos, sin)
	vec2 tangent = ray * l;
	float side = dot(q, vec2(-ray.y, ray.x)); // signed distance to the ray's line, + outside
	float to_ray = dot(q, ray) >= l ? abs(side) : length(q - tangent);
	vec2 v = q - vec2(d, 0.0);
	float lv = length(v);
	float nearest_x = d + (lv > 1e-6 ? v.x / lv : -1.0) * r; // nearest circle point's axis position
	float to_arc = nearest_x <= tangent.x ? abs(lv - r) : length(q - tangent);
	bool inside = lv <= r || (side <= 0.0 && q.x >= tangent.x);
	float dist = min(to_ray, to_arc);
	return inside ? -dist : dist;
}

// Signed distance to a convex polygon (negative inside).
float polygon_distance(vec2 p, int first, int count) {
	float d = 1e6;
	float s = 1.0;
	for (int i = 0; i < count; i++) {
		int j = i == 0 ? count - 1 : i - 1;
		vec2 vi = polygon_points[first + i];
		vec2 vj = polygon_points[first + j];
		vec2 e = vj - vi;
		vec2 w = p - vi;
		vec2 b = w - e * clamp(dot(w, e) / max(dot(e, e), 1e-6), 0.0, 1.0);
		d = min(d, dot(b, b));
		bvec3 c = bvec3(p.y >= vi.y, p.y < vj.y, e.x * w.y > e.y * w.x);
		if (all(c) || all(not(c))) {
			s = -s;
		}
	}
	return s * sqrt(d);
}

// Signed distance to the sensor area: negative inside the circle and outside every shadow.
float area_distance(vec2 p) {
	float cut = 1e6;
	for (int i = 0; i < min(shadow_count, MAX_SHADOWS); i++) {
		cut = min(cut, shadow_distance(p, shadow_centers[i], shadow_radii[i]));
	}
	for (int i = 0; i < min(polygon_count, MAX_POLYGONS); i++) {
		cut = min(cut, polygon_distance(p, polygon_first[i], polygon_sizes[i]));
	}
	float circle = length(p) - sensor_radius;
	float k = max(cutout_blend, 1e-4);
	float h = clamp(0.5 + 0.5 * (circle + cut) / k, 0.0, 1.0); // smooth max(circle, -cut)
	return mix(-cut, circle, h) + k * h * (1.0 - h);
}

vec4 over(vec4 below, vec3 color, float alpha) {
	float a = alpha + below.a * (1.0 - alpha);
	vec3 c = a > 0.0 ? (color * alpha + below.rgb * below.a * (1.0 - alpha)) / a : vec3(0.0);
	return vec4(c, a);
}

void fragment() {
	float px_scale = VIEWPORT_SIZE.y / max(pixel_reference_height, 1.0);
	float area = area_distance(local);
	// The field's own change per pixel (the blend with the circle is not an exact distance),
	// so the outlines keep their pixel width everywhere.
	float area_px = max(fwidth(area), 1e-5);
	float inside = clamp(-area / area_px + 0.5, 0.0, 1.0);

	vec2 cell = local / max(grid_spacing, 1e-3) + grid_origin;
	vec2 cell_px = max(fwidth(cell), vec2(1e-5)); // cells per pixel
	vec2 d = abs(fract(cell - 0.5) - 0.5) / cell_px; // px to the nearest line on each axis
	float line = max(stroke(d.x, grid_thickness * px_scale), stroke(d.y, grid_thickness * px_scale));
	vec2 rect_px = min(vec2(rect_width, rect_height) / (max(grid_spacing, 1e-3) * cell_px), vec2(rect_max_size * px_scale)); // world size in px here, capped
	float rect = stroke(d.x, rect_px.x) * stroke(d.y, rect_px.y);

	vec4 result = vec4(0.0);
	result = over(result, fill_color.rgb, fill_opacity * inside);
	result = over(result, grid_color.rgb, grid_opacity * line * inside);
	result = over(result, rect_color.rgb, rect_opacity * rect * inside);
	result = over(result, inner_color.rgb, inner_opacity * stroke(abs(area) / area_px, inner_thickness * px_scale));
	result = over(result, outer_color.rgb, outer_opacity * stroke(abs(area - outer_offset) / area_px, outer_thickness * px_scale));
	ALBEDO = result.rgb;
	ALPHA = result.a * overall_opacity;
}
