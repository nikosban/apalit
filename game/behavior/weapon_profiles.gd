extends RefCounted
## Behavior (migrated from the behavior prototype v0.1): Weapon Profiles derived from a ship's installed weapons (no
## class tables). Each weapon belongs to one range category by its own maximum range:
## long (≥ SIEGE_RANGE: missiles 90 u, torpedoes 110 u), medium (≥ MID_RANGE: cannons 75 u),
## short (the rest: Gatlings 25 u). A profile is available when the ship has an installed,
## operational weapon of its category, and usable while one of them can still fire
## (Weapon.offensive_reach() > 0: enabled, with ammunition, a whole salvo for salvo launchers).
## A profile only chooses where the ship positions itself; it never authorizes or
## forbids a shot.
##
## Engagement band of a profile, from its usable weapons: `far` = the shortest useful
## range among them (WeaponConfig.effective(), kept RANGE_MARGIN inside the shortest
## maximum range), `station` = STATION × far (where the ship goes), `near` = NEAR × far
## (closer than this, it opens the distance). Every value is provisional.

enum Profile { SIEGE, MID, CLOSE }

const NAMES := ["Siege", "Mid-range", "Close Quarters"]
const SIEGE_RANGE := 85.0 # u
const MID_RANGE := 40.0 # u
const STATION := 0.85
const NEAR := 0.6
const RANGE_MARGIN := 4.0 # u


static func category(weapon: Node) -> int:
	var reach: float = weapon.config.weapon_range
	if reach >= SIEGE_RANGE:
		return Profile.SIEGE
	return Profile.MID if reach >= MID_RANGE else Profile.CLOSE


## Installed, operational weapons of the profile's category.
static func installed(combat: Node, profile: int) -> Array:
	return combat.weapons.filter(func(weapon: Node) -> bool: return weapon.enabled and category(weapon) == profile)


## Those of them that can still fire.
static func usable(combat: Node, profile: int) -> Array:
	return installed(combat, profile).filter(func(weapon: Node) -> bool: return weapon.offensive_reach() > 0.0)


## Profiles the player may select (installed weapons), in fallback order.
static func available(combat: Node) -> Array[int]:
	var found: Array[int] = []
	for profile: int in [Profile.SIEGE, Profile.MID, Profile.CLOSE]:
		if not installed(combat, profile).is_empty():
			found.append(profile)
	return found


## Profiles to try for a requested one: itself, then the lower ones (Siege → Mid-range
## → Close Quarters), then the higher ones nearest first (only when nothing at or below
## the request can still fire).
static func fallback_order(requested: int) -> Array[int]:
	var order: Array[int] = []
	for profile in range(requested, Profile.CLOSE + 1):
		order.append(profile)
	for profile in range(requested - 1, -1, -1):
		order.append(profile)
	return order


## {far, station, near, reach} of a profile's usable weapons ({} when none).
static func band(combat: Node, profile: int) -> Dictionary:
	var weapons := usable(combat, profile)
	if weapons.is_empty():
		return {}
	var useful := INF
	var reach := INF
	for weapon in weapons:
		useful = minf(useful, weapon.config.effective())
		reach = minf(reach, weapon.config.weapon_range)
	var far := minf(useful, reach - RANGE_MARGIN)
	return {"far": far, "station": STATION * far, "near": NEAR * far, "reach": reach}
