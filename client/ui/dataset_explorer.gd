class_name DatasetExplorer
extends VBoxContainer

signal frame_requested(index: int)
signal media_requested(media_id: String)
signal view_model_rejected(message: String)

const MAX_MESSAGE_LENGTH := 180
const MAX_MATERIALIZED_FRAMES := 500

@onready var _tree: Tree = $Tree

var _frame_items: Dictionary = {}
var _selected_frame := -1
var _suppress_frame_request := false
var _view_model: Dictionary = {}
var _summary_mode := false
var _summary_item: TreeItem
var _mode: StringName = &"empty"
var _media_items: Dictionary = {}
var _folder_items: Dictionary = {}
var _selected_media := ""


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
	_mode = &"source"
	_media_items.clear()
	_folder_items.clear()
	_selected_media = ""
	_summary_mode = false
	_summary_item = null

	var root := _tree.create_item()
	var dataset := _tree.create_item(root)
	dataset.set_text(0, candidate["display_name"])
	dataset.set_tooltip_text(0, candidate["source_path"])
	dataset.set_selectable(0, false)
	var frames: Array = candidate["frames"]
	var frames_root := _tree.create_item(dataset)
	frames_root.set_text(0, "Frames (%d)" % frames.size())
	frames_root.set_selectable(0, false)
	_summary_mode = frames.size() > MAX_MATERIALIZED_FRAMES
	if _summary_mode:
		_summary_item = _tree.create_item(frames_root)
		_update_summary_item(0)
	else:
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


func populate_workspace(view_model: Dictionary) -> void:
	var error := _workspace_validation_error(view_model)
	if not error.is_empty():
		view_model_rejected.emit(_bounded(error))
		return
	var candidate := view_model.duplicate(true)
	_tree.clear()
	_frame_items.clear()
	_media_items.clear()
	_folder_items.clear()
	_selected_frame = -1
	_selected_media = ""
	_view_model = candidate
	_summary_mode = false
	_summary_item = null
	_mode = &"workspace"

	var root := _tree.create_item()
	var workspace_item := _tree.create_item(root)
	workspace_item.set_text(0, candidate["display_name"])
	workspace_item.set_tooltip_text(0, candidate["root_path"])
	workspace_item.set_selectable(0, false)
	for media_value: Variant in candidate["media"]:
		_insert_media_path(workspace_item, media_value as Dictionary)
	workspace_item.set_collapsed(false)


func validate_view_model(value: Variant) -> PackedStringArray:
	if not value is Dictionary:
		return PackedStringArray(["Dataset explorer view model must be a Dictionary"])
	var error := _validation_error(value)
	return PackedStringArray() if error.is_empty() else PackedStringArray([_bounded(error)])


func select_frame(index: int) -> bool:
	if _summary_mode:
		var frames: Array = _view_model.get("frames", [])
		if index < 0 or index >= frames.size():
			return false
		_update_summary_item(index)
	if not _frame_items.has(index):
		return false
	_suppress_frame_request = true
	var item := _frame_items[index] as TreeItem
	item.select(0)
	_tree.scroll_to_item(item, true)
	_selected_frame = index
	_suppress_frame_request = false
	return true


func select_media(media_id: String) -> bool:
	if _mode != &"workspace" or not _media_items.has(media_id):
		return false
	_suppress_frame_request = true
	var item := _media_items[media_id] as TreeItem
	item.select(0)
	_tree.scroll_to_item(item, true)
	_selected_media = media_id
	_suppress_frame_request = false
	return true


func clear() -> void:
	if not is_instance_valid(_tree):
		return
	_tree.clear()
	_frame_items.clear()
	_media_items.clear()
	_folder_items.clear()
	_selected_frame = -1
	_selected_media = ""
	_view_model.clear()
	_summary_mode = false
	_summary_item = null
	_mode = &"empty"
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
	if value is Dictionary and value.get("kind") == "media":
		var media_id_value: Variant = value.get("media_id")
		if (
			typeof(media_id_value) == TYPE_STRING
			and _media_items.has(media_id_value)
		):
			_selected_media = media_id_value
			media_requested.emit(media_id_value)
		return
	if typeof(value) != TYPE_INT or not _frame_items.has(value):
		return
	_selected_frame = int(value)
	frame_requested.emit(_selected_frame)


func _update_summary_item(index: int) -> void:
	if not is_instance_valid(_summary_item):
		return
	var frames: Array = _view_model.get("frames", [])
	if index < 0 or index >= frames.size():
		return
	var frame := frames[index] as Dictionary
	_frame_items.clear()
	_summary_item.set_text(0, "Current: %s" % frame["label"])
	_summary_item.set_tooltip_text(0, frame["path"])
	_summary_item.set_metadata(0, frame["index"])
	_frame_items[index] = _summary_item


func _insert_media_path(workspace_item: TreeItem, media: Dictionary) -> void:
	var parts := String(media["relative_path"]).split("/", false)
	var parent := workspace_item
	var cumulative := ""
	for index in range(maxi(0, parts.size() - 1)):
		cumulative = (
			String(parts[index])
			if cumulative.is_empty()
			else cumulative.path_join(parts[index])
		)
		if not _folder_items.has(cumulative):
			var folder := _tree.create_item(parent)
			folder.set_text(0, parts[index])
			folder.set_selectable(0, false)
			folder.set_collapsed(false)
			_folder_items[cumulative] = folder
		parent = _folder_items[cumulative] as TreeItem
	var item := _tree.create_item(parent)
	item.set_text(0, media["display_name"])
	item.set_tooltip_text(0, media["source_path"])
	item.set_metadata(0, {
		"kind": "media",
		"media_id": media["media_id"],
	})
	_media_items[media["media_id"]] = item


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


func _workspace_validation_error(view_model: Dictionary) -> String:
	if view_model.get("kind") != "workspace":
		return "Dataset explorer workspace kind must be workspace"
	for field: String in ["display_name", "root_path"]:
		var value: Variant = view_model.get(field)
		if typeof(value) != TYPE_STRING or value.strip_edges().is_empty():
			return "Dataset explorer workspace %s must be a non-empty string" % field
	var media_value: Variant = view_model.get("media")
	if not media_value is Array or media_value.is_empty():
		return "Dataset explorer workspace media must be a non-empty Array"
	var ids := {}
	for position in range(media_value.size()):
		var entry: Variant = media_value[position]
		if not entry is Dictionary:
			return "Dataset explorer media %d must be a Dictionary" % position
		for field: String in [
			"display_name", "media_id", "media_type", "source_path", "relative_path"
		]:
			var field_value: Variant = entry.get(field)
			if typeof(field_value) != TYPE_STRING or field_value.strip_edges().is_empty():
				return "Dataset explorer media %d %s must be non-empty text" % [
					position, field]
		if entry["media_type"] not in ["image", "video", "image_sequence"]:
			return "Dataset explorer media %d has an unsupported media_type" % position
		if ids.has(entry["media_id"]):
			return "Dataset explorer media_id must be unique: %s" % entry["media_id"]
		ids[entry["media_id"]] = true
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
