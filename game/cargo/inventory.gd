extends RefCounted
## Resource inventory (Phase 3): a quantity per resource with one total capacity, in
## abstract units. Every unit of a resource is identical (raw minerals, ice and
## ingots), so resources are stored and transferred individually as counts. Data
## only, owned by its holder (a ship's Cargo, a station's storage); never shown to the
## survey.

## Raw resources, as mined (the six minerals use AsteroidField's names).
const RAW: Array[StringName] = [&"iron", &"nickel", &"silicon", &"cobalt", &"gold", &"titanium", &"ice"]
## Refinery output, one per mineral (same order as the minerals in RAW).
const INGOTS: Array[StringName] = [&"iron_ingot", &"nickel_ingot", &"silicon_ingot", &"cobalt_ingot", &"gold_ingot", &"titanium_ingot"]
## Every resource in its fixed order (lists, displays, and transfers of everything).
const RESOURCES: Array[StringName] = [&"iron", &"nickel", &"silicon", &"cobalt", &"gold", &"titanium", &"ice",
	&"iron_ingot", &"nickel_ingot", &"silicon_ingot", &"cobalt_ingot", &"gold_ingot", &"titanium_ingot"]

var capacity := 0
var amounts := {} # resource -> units (only resources with units)


func _init(units := 0) -> void:
	capacity = units


## Player-facing name: "Silicon", "Silicon Ingots".
static func display_name(resource: StringName) -> String:
	var text := String(resource)
	if text.ends_with("_ingot"):
		return "%s Ingots" % text.trim_suffix("_ingot").capitalize()
	return text.capitalize()


## The ingot a mineral is refined into.
static func ingot_of(mineral: StringName) -> StringName:
	return StringName("%s_ingot" % mineral)


func quantity() -> int:
	var total := 0
	for resource: StringName in amounts:
		total += amounts[resource]
	return total


func free_space() -> int:
	return maxi(0, capacity - quantity())


func quantity_of(resource: StringName) -> int:
	return amounts.get(resource, 0)


## "Silicon 300, Iron Ingots 20" (resources held, in the fixed order), or `empty`.
func describe(empty := "none") -> String:
	var parts: Array[String] = []
	for resource in RESOURCES:
		if quantity_of(resource) > 0:
			parts.append("%s %d" % [display_name(resource), quantity_of(resource)])
	return ", ".join(parts) if not parts.is_empty() else empty


## Adds up to `amount` units of one resource; never beyond the capacity. Returns the
## units added.
func add(resource: StringName, amount: int) -> int:
	var added := clampi(amount, 0, free_space())
	if added > 0:
		amounts[resource] = quantity_of(resource) + added
	return added


## Removes up to `amount` units of one resource; returns the units removed.
func remove(resource: StringName, amount: int) -> int:
	var removed := clampi(amount, 0, quantity_of(resource))
	if removed > 0:
		amounts[resource] = quantity_of(resource) - removed
		if amounts[resource] == 0:
			amounts.erase(resource)
	return removed


## Moves up to `amount` units into another inventory (only one resource if given,
## otherwise resource by resource in the fixed order), never beyond its free space.
## Returns the units moved.
func transfer_to(other, amount: int, resource := &"") -> int: # other: another Inventory
	var limit: int = mini(amount, other.free_space())
	var moved := 0
	var order: Array[StringName] = RESOURCES
	if resource != &"":
		order = [resource]
	for candidate in order:
		if moved >= limit:
			break
		var count := remove(candidate, mini(quantity_of(candidate), limit - moved))
		other.add(candidate, count)
		moved += count
	return moved
