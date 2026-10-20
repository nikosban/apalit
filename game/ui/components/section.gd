extends VBoxContainer
## UX round (P5) panel section: a section header (theme type SectionHeader) above the
## section's own rows, which are added as further children. Presentation only.

@export var title := "Section":
	set(value):
		title = value
		if is_node_ready():
			($Title as Label).text = title


func _ready() -> void:
	($Title as Label).text = title
