class_name AnnotationSidebar
extends VBoxContainer

signal region_hovered(region_id: String)
signal region_selected(region_id: String)
signal region_reclassify_requested(region_id: String)

@onready var _project_tree: Tree = $ProjectLabels/Tree
@onready var _frame_tree: Tree = $FrameAnnotations/Tree

var _project_rows: Array[Dictionary] = []
var _frame_rows: Array[Dictionary] = []
var _hovered_region_id := ""
var _syncing := false
var _panel_layout_pending := true


func _ready() -> void:
	_project_tree.set_column_title(0, "Color")
	_project_tree.set_column_title(1, "Class")
	_project_tree.set_column_title(2, "This Frame")
	_frame_tree.set_column_title(0, "Color")
	_frame_tree.set_column_title(1, "Class")
	_frame_tree.set_column_title(2, "Kind")
	_frame_tree.set_column_title(3, "Geometry")
	_project_tree.mouse_filter = Control.MOUSE_FILTER_STOP
	_frame_tree.mouse_filter = Control.MOUSE_FILTER_STOP
	_frame_tree.gui_input.connect(_on_frame_gui_input)
	_frame_tree.mouse_exited.connect(clear_hover)
	_frame_tree.item_selected.connect(_on_frame_item_selected)
	resized.connect(_queue_panel_layout)
	($ProjectLabels as PanelContainer).resized.connect(_queue_panel_layout)
	($FrameAnnotations as PanelContainer).resized.connect(_queue_panel_layout)
	_queue_panel_layout()


func _queue_panel_layout() -> void:
	_panel_layout_pending = true
	call_deferred("_layout_panels")


func _process(_delta: float) -> void:
	if _panel_layout_pending:
		_layout_panels()
		call_deferred("_layout_panels")


func _layout_panels() -> void:
	_layout_panel($ProjectLabels as PanelContainer, $ProjectLabels/Title as Label, $ProjectLabels/Tree as Tree)
	_layout_panel($FrameAnnotations as PanelContainer, $FrameAnnotations/Title as Label, $FrameAnnotations/Tree as Tree)


func _layout_panel(panel: PanelContainer, title: Label, tree: Tree) -> void:
	if panel == null or title == null or tree == null:
		return
	var width := maxf(0.0, panel.size.x)
	var title_height := maxf(24.0, title.get_combined_minimum_size().y)
	title.set_deferred("position", Vector2(0.0, 0.0))
	title.set_deferred("size", Vector2(width, title_height))
	tree.set_deferred("position", Vector2(0.0, title_height))
	tree.set_deferred("size", Vector2(width, maxf(0.0, panel.size.y - title_height)))
	if panel.size.x > 0.0 and panel.size.y > title_height:
		_panel_layout_pending = false


func populate(project_rows: Array, frame_rows: Array, selected_region_id: String) -> void:
	# The sidebar owns a private immutable-ish rendering snapshot. Main remains the
	# owner of the records and can safely reuse or mutate its dictionaries.
	_project_rows.clear()
	_frame_rows.clear()
	for value: Variant in project_rows:
		if value is Dictionary:
			_project_rows.append((value as Dictionary).duplicate(true))
	for value: Variant in frame_rows:
		if value is Dictionary:
			_frame_rows.append((value as Dictionary).duplicate(true))
	_rebuild_trees()
	_set_selected_region_id(selected_region_id)
	_clear_hover_silently()


func set_selected_region_id(region_id: String) -> void:
	_set_selected_region_id(region_id)


func clear_hover() -> void:
	_set_hovered_region_id("")


func clear() -> void:
	_project_rows.clear()
	_frame_rows.clear()
	_rebuild_trees()
	_clear_hover_silently()
	_syncing = true
	_frame_tree.deselect_all()
	_syncing = false


# These snapshots are intentionally small read-only test/diagnostic surfaces;
# callers receive deep copies and cannot mutate the sidebar's view state.
func get_project_rows_snapshot() -> Array[Dictionary]:
	return _project_rows.duplicate(true)


func get_frame_rows_snapshot() -> Array[Dictionary]:
	return _frame_rows.duplicate(true)


func _rebuild_trees() -> void:
	_project_tree.clear()
	_frame_tree.clear()
	var project_root := _project_tree.create_item()
	for row: Dictionary in _project_rows:
		_append_project_row(project_root, row)
	var frame_root := _frame_tree.create_item()
	for row: Dictionary in _frame_rows:
		_append_frame_row(frame_root, row)


func _append_project_row(root: TreeItem, row: Dictionary) -> void:
	var item := _project_tree.create_item(root)
	item.set_text(0, "●")
	if row.get("color") is Color:
		item.set_custom_color(0, row["color"] as Color)
	item.set_text(1, str(row.get("class", "")))
	item.set_text(2, str(row.get("current_count", 0)))


func _append_frame_row(root: TreeItem, row: Dictionary) -> void:
	var item := _frame_tree.create_item(root)
	item.set_text(0, "●")
	if row.get("color") is Color:
		item.set_custom_color(0, row["color"] as Color)
	item.set_text(1, str(row.get("class", "")))
	item.set_text(2, str(row.get("kind", "")))
	item.set_text(3, "Box" if StringName(row.get("geometry", &"")) == &"box" else "Polygon")
	item.set_metadata(0, str(row.get("region_id", "")))


func _set_selected_region_id(region_id: String) -> void:
	_syncing = true
	_frame_tree.deselect_all()
	if not region_id.is_empty():
		var item := _find_frame_item(region_id)
		if item != null:
			item.select(0)
			_frame_tree.ensure_cursor_is_visible()
	_syncing = false


func _find_frame_item(region_id: String) -> TreeItem:
	var root := _frame_tree.get_root()
	if root == null:
		return null
	var item := root.get_first_child()
	while item != null:
		if str(item.get_metadata(0)) == region_id:
			return item
		item = item.get_next()
	return null


func _on_frame_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var item := _frame_tree.get_item_at_position((event as InputEventMouseMotion).position)
		_set_hovered_region_id(_region_id_for_item(item))
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.double_click:
			var item := _frame_tree.get_item_at_position(mouse_event.position)
			if item != null:
				var region_id := _region_id_for_item(item)
				if not region_id.is_empty():
					region_reclassify_requested.emit(region_id)
			return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and _frame_tree.has_focus() and (key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER):
			var item := _frame_tree.get_selected()
			var region_id := _region_id_for_item(item)
			if not region_id.is_empty():
				region_reclassify_requested.emit(region_id)


func _on_frame_item_selected() -> void:
	if _syncing:
		return
	var item := _frame_tree.get_selected()
	var region_id := _region_id_for_item(item)
	if not region_id.is_empty():
		region_selected.emit(region_id)


func _region_id_for_item(item: TreeItem) -> String:
	if item == null:
		return ""
	return str(item.get_metadata(0))


func _set_hovered_region_id(region_id: String) -> void:
	if region_id == _hovered_region_id:
		return
	_hovered_region_id = region_id
	region_hovered.emit(region_id)


func _clear_hover_silently() -> void:
	_hovered_region_id = ""
