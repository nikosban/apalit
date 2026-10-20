extends RefCounted
## UX round (P5) placeholder resource icons, the one source for every UI that shows a
## resource: generated once per resource and cached, no image assets. Shape by kind
## (raw mineral: diamond, ingot: bar, ice: hexagon), colour by mineral, dark outline.
## Placeholder art, to be replaced by authored icons.

const Inventory := preload("res://game/cargo/inventory.gd")
const SIZE := 16 # px
const SAMPLES := 4 # Per axis, for smooth edges.
const OUTLINE := Color(0.05, 0.06, 0.07, 0.9)
const COLORS := {&"iron": Color(0.62, 0.64, 0.68), &"nickel": Color(0.70, 0.74, 0.58), &"silicon": Color(0.48, 0.58, 0.78),
	&"cobalt": Color(0.30, 0.45, 0.88), &"gold": Color(0.93, 0.76, 0.30), &"titanium": Color(0.82, 0.84, 0.90), &"ice": Color(0.62, 0.86, 1.0)}

static var _cache := {} # resource -> ImageTexture


## The icon of a resource (raw mineral, ingot or ice).
static func icon(resource: StringName) -> Texture2D:
	if not _cache.has(resource):
		_cache[resource] = ImageTexture.create_from_image(_draw(resource))
	return _cache[resource]


static func _draw(resource: StringName) -> Image:
	var mineral := StringName(String(resource).trim_suffix("_ingot"))
	var color: Color = COLORS.get(mineral, Color(0.7, 0.7, 0.7))
	var shape := _shape(resource, mineral)
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var inner := _shrink(shape, 1.25)
	for y in SIZE:
		for x in SIZE:
			var fill := 0
			var edge := 0
			for sy in SAMPLES:
				for sx in SAMPLES:
					var p := Vector2(x + (sx + 0.5) / SAMPLES, y + (sy + 0.5) / SAMPLES)
					if Geometry2D.is_point_in_polygon(p, inner):
						fill += 1
					elif Geometry2D.is_point_in_polygon(p, shape):
						edge += 1
			var total := float(SAMPLES * SAMPLES)
			var pixel := Color(OUTLINE, OUTLINE.a * edge / total)
			if fill > 0:
				pixel = color.lerp(OUTLINE, edge / float(fill + edge))
				pixel.a = (fill + edge) / total
			image.set_pixel(x, y, pixel)
	return image


# Outline of the icon in pixel space (16 x 16).
static func _shape(resource: StringName, mineral: StringName) -> PackedVector2Array:
	var c := SIZE * 0.5
	if mineral == &"ice":
		var points := PackedVector2Array()
		for i in 6:
			points.append(Vector2(c, c) + Vector2.from_angle(TAU * i / 6.0 + PI / 6.0) * 7.5)
		return points
	if Inventory.INGOTS.has(resource):
		return PackedVector2Array([Vector2(1, 5), Vector2(15, 5), Vector2(15, 11), Vector2(1, 11)])
	return PackedVector2Array([Vector2(c, 0.5), Vector2(15.5, c), Vector2(c, 15.5), Vector2(0.5, c)])


# The polygon pulled toward its centre by `by` px (outline width).
static func _shrink(shape: PackedVector2Array, by: float) -> PackedVector2Array:
	var result := Geometry2D.offset_polygon(shape, -by)
	return result[0] if not result.is_empty() else shape
