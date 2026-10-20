extends VBoxContainer
## UX round (P6) resource tile: the resource's icon above its quantity, the name as the
## tooltip. Shows what it is given (show_amount()); the inventory stays the owner.

const Inventory := preload("res://game/cargo/inventory.gd")
const ResourceIcons := preload("res://game/ui/resource_icons.gd")

var resource := &""

@onready var _icon: TextureRect = $Icon
@onready var _amount: Label = $Amount


## Shows `amount` units of `resource`.
func show_amount(new_resource: StringName, amount: int) -> void:
	if new_resource != resource:
		resource = new_resource
		_icon.texture = ResourceIcons.icon(resource)
		tooltip_text = Inventory.display_name(resource)
	_amount.text = str(amount)
