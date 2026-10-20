extends CanvasLayer
## Phase 3 station selection and station panel (bottom left, where the ship panel is;
## the two are never shown together). A left-click on a station (not over a ship or a
## GUI control, without Shift) selects it; a click elsewhere, or selecting ships,
## clears it. The station is found with AsteroidHover.station_at(), the same pick as
## the hover text; ship selection (ShipSelection) is unchanged: the click on a station
## clears the ships as any click off a ship does. The panel shows the station's
## storage (raw resources and ingots) and, for a station with a Refinery, its two
## slots: mineral choice, Enabled, status, progress of the current unit, rate and
## units refined. Phase 4: for a station with a Shipyard, the Ship Production section:
## idle, each recipe with its ingots required / held here (missing in red) and its
## construction time, and the Order buttons; waiting, the ship, required / available /
## missing per ingot and Cancel Order; constructing, progress and time remaining (no
## actions); awaiting deployment, why the finished ship waits; the last ship completed.
## UX round (P5): the refinery section is built from the reusable Section and
## RefinerySlot components. UX round (P6): the panel is the fixed-width panel shell on the
## right side (the ship panel's place; never shown together) with a header (editable
## display name, station type) and the sections Status (fuel stock, health placeholder),
## Storage (n / capacity and a tile per resource held), Refinery and Ship Production.

const ShipSelection := preload("res://game/selection/ship_selection.gd")
const AsteroidHover := preload("res://game/ui/asteroid_hover.gd")
const Inventory := preload("res://game/cargo/inventory.gd")
const Refinery := preload("res://game/refining/refinery.gd")
const Shipyard := preload("res://game/shipyard/shipyard.gd")
const RefinerySlot := preload("res://game/ui/components/refinery_slot.gd")
const DisplayName := preload("res://game/ui/display_name.gd")
const ResourceTile := preload("res://game/ui/components/resource_tile.tscn")
const MINERALS: Array[StringName] = [&"iron", &"nickel", &"silicon", &"cobalt", &"gold", &"titanium"]
const AVAILABLE_COLOR := "#7ec27e"
const MISSING_COLOR := "#e0705a"
const IDLE_NOTE := "An order starts construction as soon as every ingot is in this station's storage; construction cannot be cancelled."
const WAITING_NOTE := "Construction starts automatically once every ingot is here, and cannot be cancelled then. Nothing is reserved meanwhile."

@export var selection_path := NodePath("../Selection")
@export var hover_path := NodePath("../AsteroidHover")

var station: Node3D = null # The selected station, or null.

var _pressing := false
var _press_position := Vector2.ZERO
var _named: Node3D = null # The station the name field was filled for.

@onready var _selection := get_node(selection_path) as ShipSelection
@onready var _hover := get_node(hover_path) as AsteroidHover
@onready var _panel: Control = $Panel
@onready var _name: LineEdit = $Panel/Layout/Header/StationName
@onready var _type: Label = $Panel/Layout/Header/StationType
@onready var _fuel: Label = $Panel/Layout/Scroll/Body/Status/Fuel
@onready var _fuel_bar: ProgressBar = $Panel/Layout/Scroll/Body/Status/FuelBar
@onready var _storage: Label = $Panel/Layout/Scroll/Body/Storage/Summary
@onready var _storage_tiles: Container = $Panel/Layout/Scroll/Body/Storage/Tiles
@onready var _refinery_rows: Control = $Panel/Layout/Scroll/Body/Refinery
@onready var _slot_rows: Array[RefinerySlot] = [$Panel/Layout/Scroll/Body/Refinery/Slot1, $Panel/Layout/Scroll/Body/Refinery/Slot2]
@onready var _production: Control = $Panel/Layout/Scroll/Body/Production
@onready var _production_status: Label = $Panel/Layout/Scroll/Body/Production/Status
@onready var _production_details: RichTextLabel = $Panel/Layout/Scroll/Body/Production/Details
@onready var _production_progress: ProgressBar = $Panel/Layout/Scroll/Body/Production/Progress
@onready var _production_note: Label = $Panel/Layout/Scroll/Body/Production/Note
@onready var _order_mining: Button = $Panel/Layout/Scroll/Body/Production/Buttons/OrderMining
@onready var _order_transport: Button = $Panel/Layout/Scroll/Body/Production/Buttons/OrderTransport
@onready var _cancel_order: Button = $Panel/Layout/Scroll/Body/Production/Buttons/Cancel
@onready var _last_completed: Label = $Panel/Layout/Scroll/Body/Production/LastCompleted


func _ready() -> void:
	_selection.selection_changed.connect(func() -> void:
		if not _selection.selected.is_empty():
			select(null))
	for index in _slot_rows.size():
		var row := _slot_rows[index]
		row.setup(MINERALS)
		row.mineral_chosen.connect(func(mineral: StringName) -> void: refinery().set_mineral(index, mineral))
		row.enabled_toggled.connect(func(on: bool) -> void: refinery().set_enabled(index, on))
	_order_mining.pressed.connect(func() -> void: shipyard().order(&"mining_ship"))
	_order_transport.pressed.connect(func() -> void: shipyard().order(&"transport_ship"))
	_cancel_order.pressed.connect(func() -> void: shipyard().cancel())
	# UX round (P6): the display name is edited in the header (Enter or leaving the field
	# applies it to the station it was shown for); the node name never changes.
	_name.text_submitted.connect(func(_text: String) -> void: _name.release_focus())
	_name.focus_exited.connect(_apply_name)
	select(null)


## Selects a station (null: none) and shows or hides the panel.
func select(target: Node3D) -> void:
	station = target
	_panel.visible = station != null
	if station == null:
		return
	_named = station
	_name.text = DisplayName.of(station)
	_type.text = DisplayName.class_of(station)
	_type.visible = _type.text != ""
	var refining := refinery()
	_refinery_rows.visible = refining != null
	if refining != null:
		for index in _slot_rows.size():
			var slot: Refinery.Slot = refining.slots[index]
			_slot_rows[index].show_config(slot.mineral, slot.enabled)
	_production.visible = shipyard() != null
	_process(0.0)


## The selected station's refinery, or null.
func refinery() -> Refinery:
	return station.get_node_or_null("Refinery") as Refinery if station != null else null


## The selected station's shipyard, or null.
func shipyard() -> Shipyard:
	return station.get_node_or_null("Shipyard") as Shipyard if station != null else null


# A left press not taken by the GUI starts a possible click (seen before ShipSelection,
# which handles it; not consumed here).
func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
		_pressing = not button.shift_pressed
		_press_position = button.position


func _input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if not _pressing or button == null or button.button_index != MOUSE_BUTTON_LEFT or button.pressed:
		return
	_pressing = false
	if button.position.distance_to(_press_position) <= ShipSelection.DRAG_THRESHOLD:
		select(_hover.station_at(_press_position))


func _process(_delta: float) -> void:
	if station == null:
		return
	var storage: Inventory = station.storage
	_fuel.text = "Fuel: %d / %d" % [floori(station.fuel_stock), roundi(station.fuel_capacity)]
	_fuel_bar.value = station.fuel_stock / station.fuel_capacity if station.fuel_capacity > 0.0 else 0.0
	_storage.text = "Storage: %d / %d" % [storage.quantity(), storage.capacity]
	_show_tiles(storage)
	var refining := refinery()
	if refining != null:
		for index in _slot_rows.size():
			var slot: Refinery.Slot = refining.slots[index]
			var text := refining.status(index)
			if slot.mineral != &"":
				text += " - %s units/s, %d refined" % [str(refining.rate(index)), slot.assignment_processed] # Since this mineral was chosen.
			var tone := RefinerySlot.Tone.NORMAL
			if slot.mineral == &"" or not slot.enabled:
				tone = RefinerySlot.Tone.MUTED
			elif storage.quantity_of(slot.mineral) == 0:
				tone = RefinerySlot.Tone.WARNING # Waiting for its mineral.
			_slot_rows[index].show_state(text, slot.progress, tone)
	if shipyard() != null:
		_show_production(shipyard(), storage)


# One tile per resource held (icon above units), in Inventory's order.
func _show_tiles(storage: Inventory) -> void:
	var held := Inventory.RESOURCES.filter(func(resource: StringName) -> bool: return storage.quantity_of(resource) > 0)
	while _storage_tiles.get_child_count() < held.size():
		_storage_tiles.add_child(ResourceTile.instantiate())
	for i in _storage_tiles.get_child_count():
		var tile := _storage_tiles.get_child(i)
		tile.visible = i < held.size()
		if tile.visible:
			tile.show_amount(held[i], storage.quantity_of(held[i]))


# The name typed in the header goes to the station it was shown for; empty restores
# the node name.
func _apply_name() -> void:
	if _named != null and is_instance_valid(_named):
		DisplayName.rename(_named, _name.text)
		if station == _named:
			_name.text = DisplayName.of(_named)


func _show_production(yard: Shipyard, storage: Inventory) -> void:
	var state := yard.state
	var active := yard.recipe
	var lines: Array[String] = []
	match state:
		Shipyard.State.IDLE:
			_production_status.text = "Status: Idle"
			for id: StringName in Shipyard.RECIPE_ORDER:
				lines.append("[b]%s[/b] - %d s" % [Shipyard.RECIPES[id].name, roundi(Shipyard.RECIPES[id].duration)])
				lines.append_array(_ingot_lines(id, storage))
		Shipyard.State.WAITING:
			_production_status.text = "Status: Waiting for Materials - %s" % Shipyard.RECIPES[active].name
			lines.append_array(_ingot_lines(active, storage))
		Shipyard.State.CONSTRUCTING:
			_production_status.text = "Status: Constructing %s" % Shipyard.RECIPES[active].name
			lines.append("%d s remaining - cannot be cancelled" % ceili(yard.remaining_time()))
		Shipyard.State.AWAITING_DEPLOYMENT:
			_production_status.text = "Status: Awaiting Deployment - %s" % Shipyard.RECIPES[active].name
			lines.append("Construction finished. The deployment area is obstructed; the ship deploys automatically once it is clear.")
	var text := "\n".join(lines)
	if _production_details.text != text:
		_production_details.text = text
	_production_progress.visible = state == Shipyard.State.CONSTRUCTING or state == Shipyard.State.AWAITING_DEPLOYMENT
	_production_progress.value = yard.progress()
	_production_note.visible = state == Shipyard.State.IDLE or state == Shipyard.State.WAITING
	_production_note.text = IDLE_NOTE if state == Shipyard.State.IDLE else WAITING_NOTE
	_order_mining.visible = state == Shipyard.State.IDLE
	_order_transport.visible = state == Shipyard.State.IDLE
	_cancel_order.visible = state == Shipyard.State.WAITING
	_last_completed.visible = yard.last_completed != ""
	_last_completed.text = "Last completed: %s" % yard.last_completed


# One line per ingredient: required, held here, and missing (red) or complete (green).
static func _ingot_lines(id: StringName, storage: Inventory) -> Array[String]:
	var lines: Array[String] = []
	var ingots: Dictionary = Shipyard.RECIPES[id].ingots
	for ingot: StringName in ingots:
		var required: int = ingots[ingot]
		var held := storage.quantity_of(ingot)
		var state := "[color=%s]missing %d[/color]" % [MISSING_COLOR, required - held] if held < required else "[color=%s]available[/color]" % AVAILABLE_COLOR
		lines.append("    %s: required %d, available %d - %s" % [Inventory.display_name(ingot), required, held, state])
	return lines
