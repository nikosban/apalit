extends RefCounted
## UX round (P6) display identity of a ship or station: the player's name for it, kept
## as node metadata apart from the structural node name (which scene paths, selection,
## tests and Shipyard numbering use and which never changes). Without one, the node
## name is shown. Every player-facing text (panels, hover text, notices) gets names
## here. The class or type shown under it is `metadata/display_class` of the variant or
## station scene.

const META := &"display_name"
const CLASS_META := &"display_class"


## The name to show for a ship or station.
static func of(node: Node) -> String:
	return String(node.get_meta(META, String(node.name)))


## Sets the shown name; empty (or the node name) restores the node name.
static func rename(node: Node, text: String) -> void:
	text = text.strip_edges()
	if text == "" or text == String(node.name):
		if node.has_meta(META):
			node.remove_meta(META)
		return
	node.set_meta(META, text)


## The ship class or station type of its scene ("" if none is authored).
static func class_of(node: Node) -> String:
	return String(node.get_meta(CLASS_META, ""))
