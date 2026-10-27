extends RefCounted
## Stage 4 avoidance prototype scenarios, shared by the lab's scenario keys and
## tests/avoidance_test.gd. Each scenario: movers (ship, start, target), parked ships
## (ship, point) and the scenario centre; ships not named are parked far away.
## Encounters are laid out in the open area east of the obstacles (x 85-145).

const PARKING := [Vector2(-135, 135), Vector2(-135, -135), Vector2(-135, 0)]
const CROSSING_TIME := 9.0 # s; both crossing ships reach the crossing point at about this time.


## The lab's scenario keys 4-9, 0 and -, in that order.
static func lab_presets(profiles: Dictionary) -> Array:
	return [
		head_on("Miner", "Transporter", 0.0),
		crossing("Miner", "Transporter", true, profiles),
		crossing("Miner", "Transporter", false, profiles),
		overtake("Miner", "Transporter"),
		parked("Transporter", "FF01", 0.0),
		parked("Transporter", "FF01", 3.0),
		combined(),
		crossing("Transporter", "FF01", true, profiles),
	]


## Reciprocal courses along X = 115 (+ lateral offset for the second ship).
static func head_on(a: String, b: String, lateral: float) -> Dictionary:
	return {"name": "head-on %s vs %s" % [a, b], "center": Vector2(115, 0), "parked": [], "movers": [
		{"ship": a, "start": Vector2(115, 45), "target": Vector2(115, -45)},
		{"ship": b, "start": Vector2(115 + lateral, -45), "target": Vector2(115 + lateral, 45)}]}


## a travels -Z through (115, 0); b crosses along X from a's left (from_left) or right,
## both timed to reach the crossing point at about CROSSING_TIME.
static func crossing(a: String, b: String, from_left: bool, profiles: Dictionary) -> Dictionary:
	var center := Vector2(115, 0)
	var da := _approach(profiles[a])
	var db := _approach(profiles[b])
	var sign := -1.0 if from_left else 1.0
	return {"name": "crossing %s vs %s from %s" % [a, b, "left" if from_left else "right"], "center": center,
		"parked": [], "movers": [
			{"ship": a, "start": center + Vector2(0, da), "target": center + Vector2(0, -da)},
			{"ship": b, "start": center + Vector2(sign * db, 0), "target": center + Vector2(-sign * db, 0)}]}


## fast starts 15 u behind slow on the same line, both heading -Z; slow stops first.
static func overtake(fast: String, slow: String) -> Dictionary:
	return {"name": "overtake %s past %s" % [fast, slow], "center": Vector2(115, 0), "parked": [], "movers": [
		{"ship": slow, "start": Vector2(115, 105), "target": Vector2(115, -110)},
		{"ship": fast, "start": Vector2(115, 120), "target": Vector2(115, -135)}]}


## mover heads -Z past a parked ship at (115, 0), its line `lateral` u to the side.
static func parked(mover: String, blocker: String, lateral: float) -> Dictionary:
	return {"name": "%s past parked %s%s" % [mover, blocker, " offset %.0f u" % lateral if lateral != 0.0 else " centred"],
		"center": Vector2(115, 0), "parked": [{"ship": blocker, "point": Vector2(115, 0)}], "movers": [
			{"ship": mover, "start": Vector2(115 + lateral, 50), "target": Vector2(115 + lateral, -50)}]}


## Shallow convergence: a and b start 14 u apart heading -Z on courses about 18°
## apart that cross at (115, 0); b starts on a's right (from_right) or left.
static func converging(a: String, b: String, from_right: bool) -> Dictionary:
	var s := 1.0 if from_right else -1.0
	return {"name": "converging %s vs %s from %s" % [a, b, "right" if from_right else "left"], "center": Vector2(115, 0),
		"parked": [], "movers": [
			{"ship": a, "start": Vector2(115 - 7 * s, 45), "target": Vector2(115 + 7 * s, -45)},
			{"ship": b, "start": Vector2(115 + 7 * s, 45), "target": Vector2(115 - 7 * s, -45)}]}


## Miner and Transporter head-on beside a parked FF01 on the Miner's starboard side.
static func combined() -> Dictionary:
	return {"name": "combined head-on beside parked FF01", "center": Vector2(115, 0),
		"parked": [{"ship": "FF01", "point": Vector2(122, 0)}], "movers": [
			{"ship": "Miner", "start": Vector2(110, 45), "target": Vector2(110, -45)},
			{"ship": "Transporter", "start": Vector2(110, -45), "target": Vector2(110, 45)}]}


# Distance covered in CROSSING_TIME from rest at full forward acceleration, then top speed.
# profile = [max speed, forward acceleration].
static func _approach(profile: Array) -> float:
	var speed: float = profile[0]
	var accel: float = profile[1]
	return speed * (CROSSING_TIME - speed / (2.0 * accel))
