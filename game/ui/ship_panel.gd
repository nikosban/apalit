extends CanvasLayer
## Selected-ship panel: with exactly one ship selected, its name, its scanner
## equipment and Scan Area with that ship's own cooldown (Phase 2 Stage 1); for a
## miner its mining target, assignment status, cargo and collected raw resources
## (Stage 2); its docking status with Undock, and for a docked ship with a cargo
## hold the station's storage, Unload Cargo, Load (resource and amount) and the
## transfer's progress (Stage 3); its fuel quantity, bar, warning and, while
## docked, refueling status (Stage 4); for a miner its base choice, what the
## automated operation is doing and Start / Resume Mining; manual Undock, Unload
## and Load cancel that operation (Stage 5); for a transporter its loading and
## unloading stations (nearest first), cargo requirements per resource (units or % of the hold), what the
## transport operation is doing, Start / Resume Transport and its cargo; manual
## Undock, Unload and Load also cancel it (Stage 6). Phase 2.5 stage 2b: Start /
## Resume Transport and Resume Mining are disabled only while the station moves the
## ship; from a docked state a valid one leaves through the controlled exit first.
## Hidden otherwise (no shared action for several ships). UX round (P6): a fixed-width
## panel shell on the right side with a header (editable display name, ship class) and
## the sections Status (operation, docking, fuel, health placeholder), Cargo (tiles of
## the actual cargo) and Actions (scanner, mining, transport, docking controls); the body
## scrolls when it is taller than the screen allows. UX round (P7): the transport
## requirements are no longer edited row by row here: Transport shows the route, the
## saved requirements and the unloading rule, and Configure Cargo opens the transport
## editor (TransportEditor) beside the panel.
## Combat migration: Status shows the hull (every ship has one; "DESTROYED" for a hulk)
## and the armor condition (armored ships only), each as a value and a bar.
## Combat (armed ships only, those with a Behavior: no empty weapon panel on an unarmed
## ship): the tactic as a selector issuing CombatOrders, the current command, the target
## and its state, and every weapon's state and ammunition.

const ShipSelection := preload("res://game/selection/ship_selection.gd")
const CombatShip := preload("res://game/combat/combat_ship.gd")
const CombatHud := preload("res://game/ui/combat_hud.gd")
const Scanner := preload("res://game/survey/scanner.gd")
const MiningOperation := preload("res://game/mining/mining_operation.gd")
const Cargo := preload("res://game/cargo/cargo.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const Docking := preload("res://game/stations/docking.gd")
const Fuel := preload("res://game/fuel/fuel.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const DisplayName := preload("res://game/ui/display_name.gd")
const ResourceTile := preload("res://game/ui/components/resource_tile.tscn")
const CHOOSE_STATION := "Choose a station"
const NEAREST_BASE := "Nearest station"

@export var selection_path := NodePath("../Selection")
@export var loss_hold := 1.0 # s (real time): window collecting one damage burst, shown at full strength.
@export var loss_fade := 0.5 # s (real time): the burst's label fades out, and each bar flash decays, over this.

var ship: Node3D = null # The single selected ship, or null.

var _named: Node3D = null # The ship the name field was filled for.

@onready var _selection := get_node(selection_path) as ShipSelection
@onready var _panel: Control = $Panel
@onready var _name: LineEdit = $Panel/Layout/Header/ShipName
@onready var _class: Label = $Panel/Layout/Header/ShipClass
@onready var _activity: Label = $Panel/Layout/Scroll/Body/Status/Activity
@onready var _dock_status: Label = $Panel/Layout/Scroll/Body/Status/Dock
@onready var _fuel: Control = $Panel/Layout/Scroll/Body/Status/Fuel
@onready var _fuel_amount: Label = $Panel/Layout/Scroll/Body/Status/Fuel/Amount
@onready var _fuel_bar: ProgressBar = $Panel/Layout/Scroll/Body/Status/Fuel/Bar
@onready var _fuel_status: Label = $Panel/Layout/Scroll/Body/Status/Fuel/Status
@onready var _cargo_section: Control = $Panel/Layout/Scroll/Body/Cargo
@onready var _cargo_summary: Label = $Panel/Layout/Scroll/Body/Cargo/Summary
@onready var _cargo_tiles: Container = $Panel/Layout/Scroll/Body/Cargo/Tiles
@onready var _equipment: Label = $Panel/Layout/Scroll/Body/Actions/Equipment
@onready var _scan: Button = $Panel/Layout/Scroll/Body/Actions/ScanArea
@onready var _mining: Control = $Panel/Layout/Scroll/Body/Actions/Mining
@onready var _target: Label = $Panel/Layout/Scroll/Body/Actions/Mining/Target
@onready var _base: OptionButton = $Panel/Layout/Scroll/Body/Actions/Mining/BaseRow/Base
@onready var _resume: Button = $Panel/Layout/Scroll/Body/Actions/Mining/Resume
@onready var _transport: Control = $Panel/Layout/Scroll/Body/Actions/Transport
@onready var _load_at: OptionButton = $Panel/Layout/Scroll/Body/Actions/Transport/LoadRow/Station
@onready var _unload_at: OptionButton = $Panel/Layout/Scroll/Body/Actions/Transport/UnloadRow/Station
@onready var _route: Label = $Panel/Layout/Scroll/Body/Actions/Transport/Route
@onready var _required: Label = $Panel/Layout/Scroll/Body/Actions/Transport/Required
@onready var _configure: Button = $Panel/Layout/Scroll/Body/Actions/Transport/Configure
@onready var _editor = $TransportEditor
@onready var _start: Button = $Panel/Layout/Scroll/Body/Actions/Transport/Start
@onready var _docking: Control = $Panel/Layout/Scroll/Body/Actions/Docking
@onready var _undock: Button = $Panel/Layout/Scroll/Body/Actions/Docking/Undock
@onready var _transfer: Control = $Panel/Layout/Scroll/Body/Actions/Docking/Transfer
@onready var _storage: Label = $Panel/Layout/Scroll/Body/Actions/Docking/Transfer/Storage
@onready var _unload: Button = $Panel/Layout/Scroll/Body/Actions/Docking/Transfer/Unload
@onready var _family: OptionButton = $Panel/Layout/Scroll/Body/Actions/Docking/Transfer/LoadRow/Family
@onready var _amount: SpinBox = $Panel/Layout/Scroll/Body/Actions/Docking/Transfer/LoadRow/Amount
@onready var _load: Button = $Panel/Layout/Scroll/Body/Actions/Docking/Transfer/LoadRow/Load
@onready var _progress: ProgressBar = $Panel/Layout/Scroll/Body/Actions/Docking/Transfer/Progress
@onready var _progress_label: Label = $Panel/Layout/Scroll/Body/Actions/Docking/Transfer/ProgressLabel
@onready var _hull: Control = $Panel/Layout/Scroll/Body/Status/Hull
@onready var _hull_amount: Label = $Panel/Layout/Scroll/Body/Status/Hull/Row/Amount
@onready var _hull_bar: ProgressBar = $Panel/Layout/Scroll/Body/Status/Hull/Bar
@onready var _armor: Control = $Panel/Layout/Scroll/Body/Status/Armor
@onready var _armor_amount: Label = $Panel/Layout/Scroll/Body/Status/Armor/Row/Amount
@onready var _armor_bar: ProgressBar = $Panel/Layout/Scroll/Body/Status/Armor/Bar
# Damage feedback per durability row: the last value seen, the current burst's total,
# when its window started and when the bar last flashed (real seconds).
@onready var _hull_loss := {"label": $Panel/Layout/Scroll/Body/Status/Hull/Row/Loss, "bar": _hull_bar}
@onready var _armor_loss := {"label": $Panel/Layout/Scroll/Body/Status/Armor/Row/Loss, "bar": _armor_bar}
@onready var _combat: Control = $Panel/Layout/Scroll/Body/Combat
@onready var _tactic: OptionButton = $Panel/Layout/Scroll/Body/Combat/TacticRow/Tactic
@onready var _command: Label = $Panel/Layout/Scroll/Body/Combat/Command
@onready var _combat_target: Label = $Panel/Layout/Scroll/Body/Combat/Target
@onready var _weapons: Label = $Panel/Layout/Scroll/Body/Combat/Weapons
@onready var _orders = get_parent().get_node_or_null("CombatOrders")

func _ready() -> void:
	# Phase 3: every resource, in Inventory's order (the item id is its index).
	for i in Inventory.RESOURCES.size():
		_family.add_item(Inventory.display_name(Inventory.RESOURCES[i]), i)
	_selection.selection_changed.connect(_on_selection_changed)
	_scan.pressed.connect(_on_scan_pressed)
	# Manual docking actions cancel an automated mining or transport operation first (its settings stay).
	_undock.pressed.connect(func() -> void:
		_cancel_automation()
		_docking_of(ship).undock())
	_unload.pressed.connect(func() -> void:
		_cancel_automation()
		_docking_of(ship).unload())
	_load.pressed.connect(func() -> void:
		_cancel_automation()
		_docking_of(ship).load_cargo(Inventory.RESOURCES[_family.get_selected_id()], int(_amount.value)))
	_start.pressed.connect(_start_transport)
	_load_at.get_popup().about_to_popup.connect(_fill_stations)
	_unload_at.get_popup().about_to_popup.connect(_fill_stations)
	_load_at.item_selected.connect(func(index: int) -> void: _transport_of(ship).set_load_station(_load_at.get_item_metadata(index)))
	_unload_at.item_selected.connect(func(index: int) -> void: _transport_of(ship).set_unload_station(_unload_at.get_item_metadata(index)))
	_configure.pressed.connect(func() -> void: _editor.open_for(ship))
	_resume.pressed.connect(_resume_mining)
	_base.get_popup().about_to_popup.connect(_fill_bases)
	_base.item_selected.connect(_on_base_selected)
	# UX round (P6): the display name is edited in the header (Enter or leaving the field
	# applies it to the ship it was shown for); the node name never changes.
	_name.text_submitted.connect(func(_text: String) -> void: _name.release_focus())
	_name.focus_exited.connect(_apply_name)
	for i in CombatShip.STANCE_NAMES.size():
		_tactic.add_item(CombatShip.STANCE_NAMES[i], i)
	_tactic.item_selected.connect(func(index: int) -> void:
		if _orders != null and ship != null:
			_orders.set_stance([ship], _tactic.get_item_id(index)))
	for state: Dictionary in [_hull_loss, _armor_loss]:
		_reset_loss(state, 0.0)
	_on_selection_changed()


func _process(_delta: float) -> void:
	if ship == null:
		return
	var scanner := scanner_of(ship)
	if scanner != null:
		_scan.disabled = scanner.cooldown_left > 0.0
		_scan.text = "Scan Area (%.1f s)" % scanner.cooldown_left if _scan.disabled else "Scan Area"
	var fuel := _fuel_of(ship)
	if fuel != null:
		_update_fuel(fuel)
	var mining := ship.get_node_or_null("Mining") as MiningOperation
	if mining != null:
		_update_mining(mining)
	var transport := _transport_of(ship)
	if transport != null:
		_update_transport(transport)
	var docking := _docking_of(ship)
	if docking != null:
		_update_docking(docking)
	var cargo := ship.get_node_or_null("Cargo") as Cargo
	if cargo != null:
		_update_cargo(cargo.inventory)
	_update_combat()


# Hull (every ship) and armor condition (armored ships only) as bars and, for an armed
# ship, its combat channels.
func _update_combat() -> void:
	var combat = CombatShip.of(ship)
	_hull.visible = combat != null
	_armor.visible = combat != null and combat.max_armor > 0.0
	if combat == null:
		return
	_hull_amount.text = CombatHud.hull_text(combat).replace("Hull ", "Hull: ")
	_hull_bar.value = combat.health / combat.max_health if combat.alive else 0.0
	var now := Time.get_ticks_msec() / 1000.0
	_track_loss(_hull_loss, combat.health, now)
	if _armor.visible:
		_armor_amount.text = "Armor condition: %d / %d" % [roundi(combat.armor), roundi(combat.max_armor)]
		_armor_bar.value = combat.armor / combat.max_armor
		_track_loss(_armor_loss, combat.armor, now)
	var behavior := ship.get_node_or_null("Behavior")
	if not _combat.visible or behavior == null:
		return
	if _tactic.selected != _tactic.get_item_index(combat.stance) and not _tactic.get_popup().visible:
		_tactic.select(_tactic.get_item_index(combat.stance))
	_command.text = behavior.describe()
	_combat_target.text = "Target: %s" % CombatHud.target_text(combat)
	_weapons.text = "\n".join(CombatHud.weapon_lines(combat))

# Damage feedback from the value seen last frame (real time, so also while paused): a
# drop flashes the bar and adds to the current burst, a fixed window of `loss_hold`
# from its first loss, then shown "−N" fading over `loss_fade`; a loss after the window
# starts a fresh burst. The final hull loss of a destroyed ship is shown the same way.
func _track_loss(state: Dictionary, current: float, now: float) -> void:
	var lost: float = state.last - current
	state.last = current
	if lost > 0.0:
		if now - state.start >= loss_hold:
			state.start = now
			state.total = 0.0
		state.total += lost
		state.flash = now
	var label: Label = state.label
	var age: float = now - state.start
	label.visible = age < loss_hold + loss_fade
	if label.visible:
		label.text = "−%d" % maxi(1, roundi(state.total))
		label.modulate.a = 1.0 if age < loss_hold else 1.0 - (age - loss_hold) / loss_fade
	var flash := clampf(1.0 - (now - state.flash) / loss_fade, 0.0, 1.0)
	(state.bar as Control).modulate = Color.WHITE.lerp(label.get_theme_color(&"font_color"), flash)


# A newly selected ship starts from its current values with no feedback shown.
func _reset_loss(state: Dictionary, current: float) -> void:
	state.last = current
	state.total = 0.0
	state.start = -INF
	state.flash = -INF
	(state.label as Label).visible = false
	(state.bar as Control).modulate = Color.WHITE


# Cargo section: "Cargo: n / capacity" and one tile per resource aboard (icon above
# units), in Inventory's order, from the ship's actual inventory.
func _update_cargo(inventory: Inventory) -> void:
	_cargo_summary.text = "Cargo: %d / %d" % [inventory.quantity(), inventory.capacity] + ("" if inventory.quantity() > 0 else " (empty)")
	var held := Inventory.RESOURCES.filter(func(resource: StringName) -> bool: return inventory.quantity_of(resource) > 0)
	while _cargo_tiles.get_child_count() < held.size():
		_cargo_tiles.add_child(ResourceTile.instantiate())
	for i in _cargo_tiles.get_child_count():
		var tile := _cargo_tiles.get_child(i)
		tile.visible = i < held.size()
		if tile.visible:
			tile.show_amount(held[i], inventory.quantity_of(held[i]))


static func scanner_of(target: Node) -> Scanner:
	return target.get_node_or_null("Scanner") as Scanner


static func _docking_of(target: Node) -> Docking:
	return target.get_node_or_null("Docking") as Docking


static func _fuel_of(target: Node) -> Fuel:
	return target.get_node_or_null("Fuel") as Fuel


static func _transport_of(target: Node) -> TransportOperation:
	return target.get_node_or_null("Transport") as TransportOperation


# UX round (P7): the loading and unloading stations with their route, the saved loading
# requirements, the unloading rule and Configure Cargo (the editor beside the panel;
# waits while the editor holds unapplied changes for another transporter).
func _update_transport(transport: TransportOperation) -> void:
	_activity.text = "Status: %s" % transport.activity()
	_start.disabled = not transport.can_resume() or _under_control()
	_required.text = "Required: %s" % transport.describe_requirements()
	if transport.load_station == null or transport.unload_station == null or transport.load_station == transport.unload_station:
		_route.text = "Route: choose two different stations"
	else:
		_route.text = "Route: %s → %s" % [DisplayName.of(transport.load_station), DisplayName.of(transport.unload_station)]
	_configure.disabled = _editor.blocks(ship)
	_configure.tooltip_text = "Apply or cancel the open configuration of another transporter first" if _configure.disabled else ""


# Station choices for the selected transporter, nearest first, in both selectors
# (rebuilt on selection and each time a list opens); the saved choices are selected.
func _fill_stations() -> void:
	var transport := _transport_of(ship)
	if transport == null:
		return
	var stations := transport.stations_by_distance()
	for pair: Array in [[_load_at, transport.load_station], [_unload_at, transport.unload_station]]:
		var selector: OptionButton = pair[0]
		selector.clear()
		selector.add_item(CHOOSE_STATION)
		selector.set_item_metadata(0, null)
		selector.select(0)
		for station: Node3D in stations:
			selector.add_item(DisplayName.of(station))
			selector.set_item_metadata(selector.item_count - 1, station)
			if station == pair[1]:
				selector.select(selector.item_count - 1)


func _update_fuel(fuel: Fuel) -> void:
	_fuel_amount.text = "Fuel: %.1f / %d (%d%%)" % [fuel.fuel, roundi(fuel.capacity), floori(fuel.ratio() * 100.0)]
	_fuel_bar.value = fuel.ratio()
	var parts: Array[String] = []
	if fuel.warning() != "":
		parts.append(fuel.warning())
	var docking := _docking_of(ship)
	if docking != null and docking.state == Docking.State.DOCKED:
		if fuel.refueling:
			parts.append("Refueling")
		elif fuel.fuel >= fuel.capacity:
			parts.append("Tank full")
		else:
			parts.append("Station out of fuel")
	_fuel_status.text = " - ".join(parts)
	_fuel_status.visible = not parts.is_empty()
	_fuel_status.theme_type_variation = &"WarningLabel" if fuel.warning() != "" else &""


func _update_mining(mining: MiningOperation) -> void:
	_target.text = "Target: %s" % ("Asteroid %d" % mining.target if mining.target >= 0 else "none")
	_activity.text = "Status: %s" % mining.activity()
	_resume.disabled = not mining.can_resume() or _under_control()


func _update_docking(docking: Docking) -> void:
	var text := "Dock: %s" % docking.state_name()
	if docking.station != null and docking.state != Docking.State.NONE:
		text += " (%s)" % DisplayName.of(docking.station)
		var position: int = docking.station.queue_position(ship)
		if position >= 0:
			text += ", queue %d" % (position + 1)
	_dock_status.text = text
	var docked := docking.state == Docking.State.DOCKED
	_undock.visible = docked
	_transfer.visible = docking.has_cargo_hold() and (docked or docking.transfer != Docking.Transfer.NONE)
	if not _transfer.visible:
		return
	var storage: Inventory = docking.station.storage
	_storage.text = "Station storage: %d / %d" % [storage.quantity(), storage.capacity]
	_unload.disabled = not docked or docking.transfer != Docking.Transfer.NONE
	_load.disabled = _unload.disabled
	var active := docking.transfer != Docking.Transfer.NONE
	_progress.visible = active
	_progress_label.visible = active
	if active:
		var done: Array = docking.progress()
		_progress.max_value = maxi(done[1], 1)
		_progress.value = done[0]
		_progress_label.text = "%s %d / %d" % ["Unloading" if docking.transfer == Docking.Transfer.UNLOAD else "Loading", done[0], done[1]]


func _on_selection_changed() -> void:
	ship = _selection.selected[0] if _selection.selected.size() == 1 else null
	_panel.visible = ship != null
	if ship == null:
		return
	_named = ship
	_name.text = DisplayName.of(ship)
	_class.text = DisplayName.class_of(ship)
	_class.visible = _class.text != ""
	_activity.visible = ship.get_node_or_null("Mining") != null or _transport_of(ship) != null
	_dock_status.visible = _docking_of(ship) != null
	_cargo_section.visible = ship.get_node_or_null("Cargo") != null
	# Combat: armed ships (with a Behavior) only.
	_combat.visible = ship.get_node_or_null("Behavior") != null and CombatShip.of(ship) != null and _orders != null
	var scanner := scanner_of(ship)
	_equipment.text = scanner.kind_name() if scanner != null else "No scanner"
	_scan.visible = scanner != null
	_fuel.visible = _fuel_of(ship) != null
	_mining.visible = ship.get_node_or_null("Mining") != null
	if _mining.visible:
		_fill_bases()
	var transport := _transport_of(ship)
	_transport.visible = transport != null
	if transport != null:
		_fill_stations()
	_docking.visible = _docking_of(ship) != null
	var combat = CombatShip.of(ship)
	_reset_loss(_hull_loss, combat.health if combat != null else 0.0)
	_reset_loss(_armor_loss, combat.armor if combat != null else 0.0)
	_process(0.0)


# Phase 2.5 stage 2b: the station is moving the selected ship (Start / Resume wait).
func _under_control() -> bool:
	var docking := _docking_of(ship)
	return docking != null and docking.under_control()


# Start / Resume Transport. Docked at another station than the loading one, a valid
# assignment leaves through the controlled exit first and starts once it has ended
# (checked again then); otherwise as before (at the loading station it loads in place).
func _start_transport() -> void:
	var transport := _transport_of(ship)
	var docking := _docking_of(ship)
	if docking != null and docking.state == Docking.State.DOCKED and transport.is_configured() and transport.load_station != docking.station:
		_leave_then(docking, transport.start)
		return
	transport.start()


# Start / Resume Mining. Docked, a resumable assignment with a reachable working
# position leaves through the controlled exit first and resumes once it has ended
# (checked again then); refused, its notice and nothing changes.
func _resume_mining() -> void:
	var mining := ship.get_node("Mining") as MiningOperation
	var docking := _docking_of(ship)
	if docking != null and docking.state == Docking.State.DOCKED and mining.can_resume() and mining.can_mine(mining.target):
		_leave_then(docking, mining.resume)
		return
	mining.resume()


func _leave_then(docking: Docking, action: Callable) -> void:
	docking.hold_command(action)
	docking.undock()
	if docking.state == Docking.State.DOCKED:
		docking.hold_command(Callable()) # No clear exit (its notice): nothing else changes.


func _cancel_automation() -> void:
	var mining := ship.get_node_or_null("Mining") as MiningOperation
	if mining != null:
		mining.cancel()
	var transport := _transport_of(ship)
	if transport != null:
		transport.cancel()


# Base choices for the selected miner: "Nearest station", then the stations it can
# dock at, nearest first (rebuilt on selection and each time the list opens); the
# current choice is selected (an explicit base it cannot dock at now is still listed).
func _fill_bases() -> void:
	var mining := ship.get_node_or_null("Mining") as MiningOperation
	_base.clear()
	_base.add_item(NEAREST_BASE)
	_base.set_item_metadata(0, null)
	if mining == null:
		return
	var stations := mining.eligible_bases()
	if mining.base != null and not stations.has(mining.base):
		stations.append(mining.base)
	for station: Node3D in stations:
		_base.add_item(DisplayName.of(station))
		_base.set_item_metadata(_base.item_count - 1, station)
		if station == mining.base:
			_base.select(_base.item_count - 1)
	if mining.base == null:
		_base.select(0)


func _on_base_selected(index: int) -> void:
	var mining := ship.get_node_or_null("Mining") as MiningOperation
	if mining != null:
		mining.set_base(_base.get_item_metadata(index))


# The name typed in the header goes to the ship it was shown for (also after a click
# that deselected it); empty restores the node name.
func _apply_name() -> void:
	if _named != null and is_instance_valid(_named):
		DisplayName.rename(_named, _name.text)
		if ship == _named:
			_name.text = DisplayName.of(_named)


func _on_scan_pressed() -> void:
	if ship != null and scanner_of(ship) != null:
		scanner_of(ship).activate()
