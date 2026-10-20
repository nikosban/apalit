extends Node
## Combat (migrated from the prototype v0.2): prototype sensor contact (no sensor simulation). Every ship is
## observable to every faction unless its contact has been removed for that faction.
## Contact affects target eligibility only; ships stay visible. v0.4: in a scene with
## Sensors, contact also requires detection (and the fog of war hides what is undetected).

signal contact_changed(faction: int, ship: Node3D, observable: bool)

var _lost := {} # "faction:instance id" -> true
var sensors: Node = null # v0.4: the scene's Sensors, when it has them (E05, sensor fixtures).


## Contact of `faction` with `ship`: not removed by hand and, with sensors, detected now.
func observable(faction: int, ship: Node3D) -> bool:
	if _lost.has(_key(faction, ship)):
		return false
	return sensors == null or sensors.detected(faction, ship)


func set_contact(faction: int, ship: Node3D, value: bool) -> void:
	if observable(faction, ship) == value:
		return
	if value:
		_lost.erase(_key(faction, ship))
	else:
		_lost[_key(faction, ship)] = true
	contact_changed.emit(faction, ship, value)


func toggle(faction: int, ship: Node3D) -> bool:
	set_contact(faction, ship, not observable(faction, ship))
	return observable(faction, ship)


## Number of contacts currently removed (repeatability checks).
func lost_count() -> int:
	return _lost.size()


func forget(ship: Node3D) -> void:
	for key: String in _lost.keys():
		if key.ends_with(":%d" % ship.get_instance_id()):
			_lost.erase(key)


func _key(faction: int, ship: Node3D) -> String:
	return "%d:%d" % [faction, ship.get_instance_id()]
