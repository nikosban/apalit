extends Control
## UX round (P7) transport configuration editor: the loading requirements of one
## transporter, edited as a draft beside the ship panel and applied all at once.
## Ore (the six raw minerals and Ice), Ingots (the six ingots and the same Ice) and
## Components (not implemented: disabled). Every row: resource, units aboard, requested
## amount, Units / %, Clear. Edits change only the draft (kept when switching tabs, when
## the selection changes and when the ship panel shows another ship); Apply hands the
## whole draft to TransportOperation.apply_requirements(), which accepts all of it or
## nothing (rejected: its notice, the saved configuration unchanged, the draft kept for
## correction); Cancel closes without applying. Unloading is not configurable: the whole
## cargo aboard is unloaded at the destination (shown as information).

const Inventory := preload("res://game/cargo/inventory.gd")
const Cargo := preload("res://game/cargo/cargo.gd")
const TransportOperation := preload("res://game/transport/transport_operation.gd")
const DisplayName := preload("res://game/ui/display_name.gd")
const ResourceRow := preload("res://game/ui/components/resource_row.tscn")
const ORE := 0
const INGOTS := 1
const COMPONENTS := 2

var ship: Node3D = null # The transporter being configured (null: closed).
var draft := {} # resource -> amount
var draft_percent := {} # resource -> true where the amount is a percentage of the hold

var _rows: Array = [] # Every resource row (Ice twice: one per tab).

@onready var _panel: Control = $Panel
@onready var _title: Label = $Panel/Layout/Header/Title
@onready var _tabs = $Panel/Layout/Header/Tabs # SegmentedControl
@onready var _ore_rows: Control = $Panel/Layout/Scroll/Body/Ore
@onready var _ingot_rows: Control = $Panel/Layout/Scroll/Body/Ingots
@onready var _components: Control = $Panel/Layout/Scroll/Body/Components
@onready var _total: Label = $Panel/Layout/Footer/Total
@onready var _message: Label = $Panel/Layout/Footer/Message
@onready var _apply: Button = $Panel/Layout/Footer/Buttons/Apply
@onready var _cancel: Button = $Panel/Layout/Footer/Buttons/Cancel


func _ready() -> void:
	_tabs.setup(["Ore", "Ingots", "Components"])
	_tabs.set_segment_disabled(COMPONENTS, true, "Components: not implemented yet")
	_tabs.selected_changed.connect(_show_tab)
	for resource: StringName in Inventory.RAW:
		_add_row(_ore_rows, resource)
	for resource: StringName in Inventory.INGOTS + [&"ice"]:
		_add_row(_ingot_rows, resource)
	_apply.pressed.connect(apply)
	_cancel.pressed.connect(close)
	_panel.visible = false


## Opens the editor for a transporter with its saved requirements as the draft (an
## open, unapplied draft for the same ship is kept).
func open_for(target: Node3D) -> void:
	if target != ship or not _panel.visible:
		ship = target
		_reset_draft()
		_message.text = ""
	_panel.visible = true
	_show_tab(_tabs.selected)


func close() -> void:
	ship = null
	_panel.visible = false


func is_open() -> bool:
	return _panel.visible


## The draft differs from the saved requirements.
func is_dirty() -> bool:
	var transport := _transport()
	if transport == null:
		return false
	for resource in Inventory.RESOURCES:
		if draft[resource] != transport.required[resource] or draft_percent[resource] != transport.percent[resource]:
			return true
	return false


## The editor holds unapplied changes for another transporter than `target` (the ship
## panel's Configure then waits until they are applied or cancelled).
func blocks(target: Node3D) -> bool:
	return is_open() and ship != target and is_dirty()


## Hands the whole draft to the transport: all of it is saved, or nothing.
func apply() -> bool:
	var transport := _transport()
	if transport == null:
		return false
	if transport.apply_requirements(draft, draft_percent):
		_message.theme_type_variation = &"MutedLabel"
		_message.text = "Applied."
		_reset_draft()
		return true
	_message.theme_type_variation = &"WarningLabel"
	_message.text = "Not applied: together the requirements exceed the cargo hold (%d / %d). Nothing was changed; correct the draft and apply again." % [
		_draft_total(), _capacity()]
	return false


## The row of a resource in a tab (ORE or INGOTS), or null.
func row(tab: int, resource: StringName) -> Node:
	for candidate in (_ore_rows if tab == ORE else _ingot_rows).get_children():
		if candidate.resource == resource:
			return candidate
	return null


func _process(_delta: float) -> void:
	if not _panel.visible:
		return
	if ship == null or not is_instance_valid(ship):
		close()
		return
	_title.text = "Cargo to load: %s" % DisplayName.of(ship)
	var inventory: Inventory = (ship.get_node("Cargo") as Cargo).inventory
	for each in _rows:
		each.show_onboard(inventory.quantity_of(each.resource))
	_total.text = "Requested: %d / %d units%s" % [_draft_total(), _capacity(), " - unapplied changes" if is_dirty() else ""]
	_apply.disabled = not is_dirty()


func _add_row(parent: Node, resource: StringName) -> void:
	var each := ResourceRow.instantiate()
	parent.add_child(each)
	each.setup(resource, 1000)
	each.edited.connect(func(amount: int, as_percent: bool) -> void:
		draft[resource] = amount
		draft_percent[resource] = as_percent
		_message.text = ""
		_show_twins(each))
	each.cleared.connect(func() -> void:
		draft[resource] = 0
		draft_percent[resource] = false
		_message.text = ""
		each.show_request(0, false)
		_show_twins(each))
	_rows.append(each)


# The same resource's row in the other tab (Ice) shows the shared draft value.
func _show_twins(source: Node) -> void:
	for each in _rows:
		if each != source and each.resource == source.resource:
			each.show_request(draft[each.resource], draft_percent[each.resource])


func _show_tab(tab: int) -> void:
	_ore_rows.visible = tab == ORE
	_ingot_rows.visible = tab == INGOTS
	_components.visible = tab == COMPONENTS


func _reset_draft() -> void:
	var transport := _transport()
	for resource in Inventory.RESOURCES:
		draft[resource] = transport.required[resource] if transport != null else 0
		draft_percent[resource] = transport.percent[resource] if transport != null else false
	for each in _rows:
		each.setup(each.resource, _capacity())
		each.show_request(draft[each.resource], draft_percent[each.resource])


func _draft_total() -> int:
	var total := 0
	for resource in Inventory.RESOURCES:
		total += _capacity() * draft[resource] / 100 if draft_percent[resource] else draft[resource]
	return total


func _capacity() -> int:
	return (ship.get_node("Cargo") as Cargo).capacity if ship != null else 1000


func _transport() -> TransportOperation:
	return ship.get_node_or_null("Transport") as TransportOperation if ship != null else null
