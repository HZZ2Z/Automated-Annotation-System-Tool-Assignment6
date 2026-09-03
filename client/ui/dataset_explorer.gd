class_name DatasetExplorer
extends VBoxContainer

signal frame_requested(index: int)
signal view_model_rejected(message: String)

const MAX_MESSAGE_LENGTH := 180

@onready var _tree: Tree = $Tree

var _frame_items: Dictionary = {}
var _selected_frame := -1
var _suppress_frame_request := false
var _view_model: Dictionary = {}


func _ready() -> void:
	_tree.item_selected.connect(_on_item_selected)
	clear()


func populate(view_model: Dictionary) -> void:
	var error := _validation_error(view_model)
	if not error.is_empty():
		view_model_rejected.emit(_bounded(error))
		return
	var candidate := view_model.duplicate(true)
	_tree.clear()
	_frame_items.clear()
	_selected_frame = -1
	_view_model = candidate

	var root := _tree.create_item()
	var dataset := _tree.create_item(root)
	dataset.set_text(0, candidate["display_name"])
	dataset.set_tooltip_text(0, candidate["source_path"])
	dataset.set_selectable(0, false)
	var frames: Array = candidate["frames"]
	var frames_root := _tree.create_item(dataset)
	frames_root.set_text(0, "Frames (%d)" % frames.size())
	frames_root.set_selectable(0, false)
	for frame_value: Variant in frames:
		var frame := frame_value as Dictionary
		var item := _tree.create_item(frames_root)
		item.set_text(0, frame["label"])
		item.set_tooltip_text(0, frame["path"])
		item.set_metadata(0, frame["index"])
		_frame_items[frame["index"]] = item
	for artifact_value: Variant in candidate["artifacts"]:
		var artifact := artifact_value as Dictionary
		var item := _tree.create_item(dataset)
		item.set_text(0, artifact["label"])
		item.set_tooltip_text(0, artifact["path"])
		item.set_selectable(0, false)
	dataset.set_collapsed(false)
	frames_root.set_collapsed(false)


func select_frame(index: int) -> bool:
	if not _frame_items.has(index):
		return false
	_suppress_frame_request = true
	var item := _frame_items[index] as TreeItem
	item.select(0)
	_tree.scroll_to_item(item, true)
	_selected_frame = index
	_suppress_frame_request = false
	return true


func clear() -> void:
	if not is_instance_valid(_tree):
		return
	_tree.clear()
	_frame_items.clear()
	_selected_frame = -1
	_view_model.clear()
	var root := _tree.create_item()
	var empty := _tree.create_item(root)
	empty.set_text(0, "No dataset open")
	empty.set_selectable(0, false)


func _on_item_selected() -> void:
	if _suppress_frame_request:
		return
	var item := _tree.get_selected()
	if item == null:
		return
	var value: Variant = item.get_metadata(0)
	if typeof(value) != TYPE_INT or not _frame_items.has(value):
		return
	_selected_frame = int(value)
	frame_requested.emit(_selected_frame)


func _validation_error(view_model: Dictionary) -> String:
	for field: String in ["display_name", "source_path"]:
		var value: Variant = view_model.get(field)
		if typeof(value) != TYPE_STRING or str(value).strip_edges().is_empty():
			return "Dataset explorer %s must be a non-empty string" % field
	var frames_value: Variant = view_model.get("frames")
	if not frames_value is Array or frames_value.is_empty():
		return "Dataset explorer frames must be a non-empty Array"
	for position in range(frames_value.size()):
		var error := _entry_error(frames_value[position], position, true)
		if not error.is_empty():
			return error
	var artifacts_value: Variant = view_model.get("artifacts")
	if not artifacts_value is Array:
		return "Dataset explorer artifacts must be an Array"
	for artifact_value: Variant in artifacts_value:
		var error := _entry_error(artifact_value, -1, false)
		if not error.is_empty():
			return error
	return ""


func _entry_error(value: Variant, expected_index: int, is_frame: bool) -> String:
	if not value is Dictionary:
		return "Dataset explorer entry must be a Dictionary"
	for field: String in ["label", "path"]:
		var field_value: Variant = value.get(field)
		if typeof(field_value) != TYPE_STRING or str(field_value).strip_edges().is_empty():
			return "Dataset explorer entry %s must be a non-empty string" % field
	if is_frame:
		var index_value: Variant = value.get("index")
		if typeof(index_value) != TYPE_INT or int(index_value) != expected_index:
			return "Dataset explorer frame index must be contiguous at %d" % expected_index
	return ""


func _bounded(message: String) -> String:
	var clean := message.replace("\n", " ").replace("\r", " ").strip_edges()
	return clean if clean.length() <= MAX_MESSAGE_LENGTH else clean.left(177) + "..."
