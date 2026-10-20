extends Node
## Phase 2 Stage 1 fleet survey: the one owner of what the player's fleet knows about
## each asteroid (UNKNOWN, IDENTIFIED: family, ANALYZED: family, composition and
## current reserves) and of the scans still delivering it. Shared by every ship,
## kept for the session, never downgraded. Never touches ships or their orders.
##
## A scan (start_scan, called by a ship's Scanner) is fixed at its activation point:
## its pulse front grows at `pulse_speed` up to the scan radius, and an asteroid is
## detected when the front reaches its outline (asteroids with any part inside the
## radius). A detected asteroid is analyzed only when the scan would raise what is
## known or already being analyzed: ANALYZING for `analysis_time`, then UPLOADING for
## `upload_time`, then the level is committed (`surveyed`). A higher-level scan
## arriving during ANALYZING raises that analysis in place; during UPLOADING it
## follows as a new analysis once the upload is committed.

enum Level { UNKNOWN, IDENTIFIED, ANALYZED }
enum Phase { ANALYZING, UPLOADING }

signal scan_started(origin: Vector2, radius: float)
signal analysis_started(id: int)
signal surveyed(id: int, level: int)

@export var pulse_speed := 30.0 # u/s (provisional)
@export var analysis_time := 2.5 # s (provisional)
@export var upload_time := 1.2 # s, DATA UPLOADED before the data is revealed (provisional)
@export var field_path := NodePath("../Asteroids")

var _levels := {} # asteroid id -> Level (absent: UNKNOWN)
var _scans: Array[Dictionary] = [] # {origin, radius, level, front, pending: [[reach, id], ...] by reach}
var _analyses := {} # asteroid id -> {level, progress, phase, upload_left, next_level}

@onready var _field := get_node(field_path)


func _physics_process(delta: float) -> void:
	advance(delta)


func level_of(id: int) -> int:
	return _levels.get(id, Level.UNKNOWN)


## The analysis in progress for an asteroid ({level, progress 0-1, phase,
## upload_left}), or empty. Read-only for presentation.
func analysis(id: int) -> Dictionary:
	return _analyses.get(id, {})


func analyzing_ids() -> Array:
	return _analyses.keys()


func active_scans() -> int:
	return _scans.size()


## Starts an area scan at a fixed point. level: IDENTIFIED (Generic Scanner) or
## ANALYZED (Mining Scanner).
func start_scan(origin: Vector2, radius: float, level: int) -> void:
	var pending := []
	for id: int in _field.ids():
		var reach: float = _field.surface_distance(id, origin)
		if reach <= radius:
			pending.append([reach, id])
	pending.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	_scans.append({"origin": origin, "radius": radius, "level": level, "front": 0.0, "pending": pending})
	scan_started.emit(origin, radius)


func advance(delta: float) -> void:
	for scan: Dictionary in _scans.duplicate():
		scan.front = minf(scan.front + pulse_speed * delta, scan.radius)
		var pending: Array = scan.pending
		while not pending.is_empty() and pending[0][0] <= scan.front:
			_detect(pending.pop_front()[1], scan.level)
		if pending.is_empty() and scan.front >= scan.radius:
			_scans.erase(scan)
	for id: int in _analyses.keys():
		var entry: Dictionary = _analyses[id]
		if entry.phase == Phase.ANALYZING:
			entry.progress = minf(1.0, entry.progress + delta / analysis_time)
			if entry.progress >= 1.0:
				entry.phase = Phase.UPLOADING
				entry.upload_left = upload_time
		else:
			entry.upload_left -= delta
			if entry.upload_left <= 0.0:
				_commit(id, entry)


func _detect(id: int, level: int) -> void:
	if _analyses.has(id):
		var entry: Dictionary = _analyses[id]
		if level <= entry.level:
			return
		if entry.phase == Phase.ANALYZING:
			entry.level = level
		else:
			entry.next_level = maxi(entry.next_level, level)
		return
	if level <= level_of(id):
		return # Already known at this level: no new analysis.
	_start_analysis(id, level)


func _start_analysis(id: int, level: int) -> void:
	_analyses[id] = {"level": level, "progress": 0.0, "phase": Phase.ANALYZING, "upload_left": 0.0, "next_level": Level.UNKNOWN}
	analysis_started.emit(id)


func _commit(id: int, entry: Dictionary) -> void:
	_analyses.erase(id)
	var level := maxi(level_of(id), entry.level)
	_levels[id] = level
	surveyed.emit(id, level)
	if entry.next_level > level:
		_start_analysis(id, entry.next_level)
