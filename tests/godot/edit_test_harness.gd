extends RefCounted


const MAIN_SCENE := preload("res://client/app/main.tscn")
const ADD_BOX_COMMAND := preload("res://client/domain/commands/add_box_command.gd")
const ADD_POLYGON_COMMAND := preload("res://client/domain/commands/add_polygon_command.gd")
const TEMP_PREFIX := "/tmp/annotool-part2-2-real-ui-"
const GENERATED_ID_SEED := 11001
const TOOL_NODE_NAMES := {
	&"box": "Box",
	&"subtract": "Subtract",
	&"lasso": "Lasso",
	&"fill": "Fill",
	&"paint": "Paint",
	&"eraser": "Eraser",
	&"select": "Select",
}

var tree: SceneTree
var main: Control
var viewport: Control
var tool_panel: Control
var sidebar: Control
var annotation_sidebar: Control
var class_dialog: Window
var store: Variant
var history: Variant
var edit_plugin: Variant
var source_root := ""
var _allocator_state_saved := false
var _saved_add_box_allocator := 0
var _saved_add_polygon_allocator := 0
var _last_mouse_position := Vector2.ZERO


func mount(support: TestSupport, scene_tree: SceneTree, source_override := "") -> bool:
	tree = scene_tree
	# Every mounted source is a fresh test session.  Pin the process-scoped
	# allocators so full-record expectations can predict ids without reading the
	# Store produced by the operation under test.
	_save_command_allocators()
	ADD_BOX_COMMAND._next_session_id = GENERATED_ID_SEED
	ADD_POLYGON_COMMAND._next_session_id = GENERATED_ID_SEED
	source_root = _write_source(support) if source_override.is_empty() else source_override
	main = MAIN_SCENE.instantiate() as Control
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	# Start with enough room for every mounted control.  The pass below measures
	# the live chrome and calibrates the 160 x 120 fixture to an exact 4x canvas.
	main.size = Vector2(1204, 670)
	tree.root.add_child(main)
	await tree.process_frame
	await tree.process_frame
	# Calibrate against the mounted chrome instead of assuming its current
	# minimum sizes.  This keeps the image viewport at an exact 640 x 480 after
	# legitimate sidebar/toolbar layout changes and preserves exact image-space
	# geometry oracles.
	var mounted_viewport := main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport"
	) as Control
	for _attempt in range(3):
		var correction := Vector2(640, 480) - mounted_viewport.size
		if correction.is_zero_approx():
			break
		main.size += correction
		await tree.process_frame
	var errors: PackedStringArray = main.open_source(source_root)
	support.expect_equal(errors, PackedStringArray(), "real editing harness should open its image-sequence source")
	if not errors.is_empty():
		_restore_command_allocators()
		return false
	# open_source installs fresh Store/History/Edit instances; never retain the
	# catalogue objects that existed while the scene was entering the tree.
	store = main.get("_store")
	history = main.get("_history")
	edit_plugin = main.get("_edit_plugin")
	viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport") as Control
	tool_panel = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel") as Control
	annotation_sidebar = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar") as Control
	sidebar = annotation_sidebar
	class_dialog = main.get_node("ClassAssignmentDialog") as Window
	await tree.process_frame
	viewport.grab_focus()
	await tree.process_frame
	return true


func finish() -> void:
	if is_instance_valid(main):
		main.queue_free()
		await tree.process_frame
	_restore_command_allocators()


func _save_command_allocators() -> void:
	# A harness can be reused after finish().  If a caller mounts it twice
	# without finishing, preserve the process state that predated the first
	# mount rather than treating the deterministic seed as its own state.
	if _allocator_state_saved:
		_restore_command_allocators()
	_saved_add_box_allocator = ADD_BOX_COMMAND._next_session_id
	_saved_add_polygon_allocator = ADD_POLYGON_COMMAND._next_session_id
	_allocator_state_saved = true


func _restore_command_allocators() -> void:
	if not _allocator_state_saved:
		return
	ADD_BOX_COMMAND._next_session_id = _saved_add_box_allocator
	ADD_POLYGON_COMMAND._next_session_id = _saved_add_polygon_allocator
	_allocator_state_saved = false


func click_tool(tool_id: StringName) -> void:
	var node_name := str(TOOL_NODE_NAMES.get(tool_id, ""))
	var button := tool_panel.get_node_or_null("ToolGrid/%s" % node_name) as Button
	if button != null:
		await _click_control_node(button)


func click_control(node_path: String) -> void:
	var control := main.get_node_or_null(node_path) as Control
	if control != null:
		await _click_control_node(control)


func click_timeline_frame(frame_index: int) -> void:
	var timeline := main.get_node(
		"MainVBox/TimelinePanel/TimelineColumn/Timeline"
	) as Control
	var cell_width: float = float(timeline.get("cell_width"))
	var scroll_bar := timeline.get_node("ScrollBar") as HScrollBar
	var strip_bottom := maxf(1.0, timeline.size.y - scroll_bar.size.y)
	var position := timeline.get_global_rect().position + Vector2(
		(float(frame_index) + 0.5) * cell_width,
		minf(strip_bottom - 0.5, maxf(0.5, strip_bottom * 0.5)),
	)
	_parse_mouse_motion(position)
	await tree.process_frame
	_parse_mouse_button(position, true)
	await tree.process_frame
	_parse_mouse_button(position, false)
	await tree.process_frame


func click_explorer_frame(frame_index: int) -> void:
	var explorer := main.get_node(
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer"
	)
	var explorer_tree := explorer.get_node("Tree") as Tree
	var item := _find_tree_item_with_metadata(explorer_tree.get_root(), frame_index)
	if item == null:
		return
	var position := explorer_tree.get_global_rect().position \
		+ explorer_tree.get_item_area_rect(item).get_center()
	_parse_mouse_motion(position)
	await tree.process_frame
	_parse_mouse_button(position, true)
	await tree.process_frame
	_parse_mouse_button(position, false)
	await tree.process_frame


func pointer_drag(points: Array[Vector2]) -> void:
	if points.size() < 2:
		return
	_pointer_button(points[0], true)
	for index in range(1, points.size()):
		_pointer_motion(points[index], MOUSE_BUTTON_MASK_LEFT)
	_pointer_button(points[-1], false)


func pointer_click(image_position: Vector2, double_click := false) -> void:
	_pointer_button(image_position, true, double_click)
	_pointer_button(image_position, false, double_click)


func pointer_right_click(image_position: Vector2) -> void:
	var local_position: Vector2 = viewport.get_image_transform().image_to_viewport(image_position)
	var global_position := viewport.get_global_rect().position + local_position
	_parse_mouse_button(global_position, true, false, MOUSE_BUTTON_RIGHT)
	_parse_mouse_button(global_position, false, false, MOUSE_BUTTON_RIGHT)


func pointer_hover(image_position: Vector2) -> void:
	_pointer_motion(image_position, 0)


func press_key(
	keycode: Key,
	shift_pressed := false,
	ctrl_pressed := false,
	alt_pressed := false,
	unicode_value := 0,
) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.shift_pressed = shift_pressed
	event.ctrl_pressed = ctrl_pressed
	event.alt_pressed = alt_pressed
	event.unicode = unicode_value
	event.pressed = true
	Input.parse_input_event(event)
	await tree.process_frame
	var released := event.duplicate() as InputEventKey
	released.pressed = false
	Input.parse_input_event(released)
	await tree.process_frame


func focus_viewport() -> void:
	viewport.get_viewport().gui_release_focus()
	viewport.grab_focus()
	await tree.process_frame


func select_region(region_id: String) -> void:
	await click_tool(&"select")
	var point := _region_hit_point(region_id)
	pointer_click(point)
	await tree.process_frame


func record(frame := 0) -> Dictionary:
	return store.get_corrected_record(frame)


func undo_count() -> int:
	return history.get_undo_count()


func redo_count() -> int:
	return history.get_redo_count()


func selected_region_id() -> String:
	return str(main.get("_selected_region_id"))


func overlay() -> Dictionary:
	return viewport.get_edit_overlay_state()


func last_command_script() -> String:
	var commands: Array = history.get("_undo_stack")
	if commands.is_empty():
		return ""
	var command: Variant = commands.back()
	return command.get_script().resource_path if command is Object else ""


func class_dialog_control(relative_path: String) -> Control:
	return class_dialog.get_node(relative_path) as Control


func hover_annotation(region_id: String) -> void:
	var frame_tree := sidebar.get_node("FrameAnnotations/Tree") as Tree
	var item := _sidebar_item(region_id)
	if item == null:
		return
	var position := frame_tree.get_global_rect().position \
		+ frame_tree.get_item_area_rect(item).get_center()
	_parse_mouse_motion(position)
	await tree.process_frame


func clear_annotation_hover() -> void:
	_parse_mouse_motion(Vector2(2, 2))
	await tree.process_frame


func click_annotation(region_id: String) -> void:
	await _click_sidebar_annotation(region_id, false)


func double_click_annotation(region_id: String) -> void:
	await _click_sidebar_annotation(region_id, true)


func confirm_class(class_label: String, kind: String) -> Dictionary:
	var class_edit := class_dialog_control("Margin/Content/ClassLabel") as LineEdit
	var kind_edit := class_dialog_control("Margin/Content/Kind") as LineEdit
	var focus_evidence := {
		"class_focused_before_input": class_edit.has_focus(),
		"kind_focused_after_tab": false,
	}
	await _replace_focused_text(class_label)
	await press_key(KEY_TAB)
	focus_evidence["kind_focused_after_tab"] = kind_edit.has_focus()
	await _replace_focused_text(kind)
	await press_key(KEY_ENTER)
	return focus_evidence


func cancel_class() -> void:
	# Embedded Windows report the root window id under the headless display
	# driver, so Input.parse_input_event cannot target their Viewport.  Inject an
	# actual key event into the real dialog Viewport; production
	# focused-control GUI input still owns Escape and emits the public cancel
	# signal.
	await _push_dialog_key(KEY_ESCAPE)
	# Embedded subwindows leave the GUI mouse target on the closing Window until
	# the next frame; wait for that normal teardown before the next real click.
	await tree.process_frame


func sidebar_snapshot() -> Dictionary:
	return {
		"project": annotation_sidebar.get_project_rows_snapshot(),
		"frame": annotation_sidebar.get_frame_rows_snapshot(),
	}


func _click_sidebar_annotation(region_id: String, double_click: bool) -> void:
	var frame_tree := sidebar.get_node("FrameAnnotations/Tree") as Tree
	var item := _sidebar_item(region_id)
	if item == null:
		return
	var position := frame_tree.get_global_rect().position \
		+ frame_tree.get_item_area_rect(item).get_center()
	_parse_mouse_motion(position)
	await tree.process_frame
	_parse_mouse_button(position, true, double_click)
	await tree.process_frame
	_parse_mouse_button(position, false, double_click)
	await tree.process_frame


func _sidebar_item(region_id: String) -> TreeItem:
	var frame_tree := sidebar.get_node("FrameAnnotations/Tree") as Tree
	var root := frame_tree.get_root()
	if root == null:
		return null
	var item := root.get_first_child()
	while item != null:
		if str(item.get_metadata(0)) == region_id:
			return item
		item = item.get_next()
	return null


func _find_tree_item_with_metadata(item: TreeItem, value: Variant) -> TreeItem:
	if item == null:
		return null
	if item.get_metadata(0) == value:
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_tree_item_with_metadata(child, value)
		if found != null:
			return found
		child = child.get_next()
	return null


func _replace_focused_text(value: String) -> void:
	await press_key(KEY_A, false, true)
	await press_key(KEY_BACKSPACE)
	for codepoint: int in value.to_utf32_buffer():
		await press_key(codepoint as Key, false, false, false, codepoint)


func _push_dialog_key(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	class_dialog.push_input(event, true)
	await tree.process_frame
	var released := event.duplicate() as InputEventKey
	released.pressed = false
	class_dialog.push_input(released, true)
	await tree.process_frame


func _parse_mouse_motion(global_position: Vector2, button_mask := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = global_position
	event.global_position = global_position
	event.relative = global_position - _last_mouse_position
	event.button_mask = button_mask
	_last_mouse_position = global_position
	tree.root.push_input(event, true)


func _parse_mouse_button(global_position: Vector2, pressed: bool, double_click := false, button := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.button_mask = (MOUSE_BUTTON_MASK_RIGHT if button == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT) if pressed else 0
	event.pressed = pressed
	event.double_click = double_click
	event.position = global_position
	event.global_position = global_position
	tree.root.push_input(event, true)


func _click_control_node(control: Control) -> void:
	var position := control.get_global_rect().get_center()
	_parse_mouse_motion(position)
	await tree.process_frame
	_parse_mouse_button(position, true)
	await tree.process_frame
	_parse_mouse_button(position, false)
	await tree.process_frame


func _pointer_button(image_position: Vector2, pressed: bool, double_click := false) -> void:
	var local_position: Vector2 = viewport.get_image_transform().image_to_viewport(image_position)
	_parse_mouse_button(viewport.get_global_rect().position + local_position, pressed, double_click)


func _pointer_motion(image_position: Vector2, button_mask: int) -> void:
	var local_position: Vector2 = viewport.get_image_transform().image_to_viewport(image_position)
	_parse_mouse_motion(viewport.get_global_rect().position + local_position, button_mask)


func _region_hit_point(region_id: String) -> Vector2:
	match region_id:
		"box-1":
			return Vector2(30, 30)
		"box-2":
			return Vector2(100, 35)
		"poly-1":
			return Vector2(27, 75)
	var region := _find_region(record(), region_id)
	var box: Variant = region.get("box")
	if box is Array and box.size() == 4:
		return Vector2(float(box[0]) + float(box[2]) * 0.5, float(box[1]) + float(box[3]) * 0.5)
	var polygon: Variant = region.get("polygon")
	if polygon is Array and not polygon.is_empty() and polygon[0] is Array:
		return Vector2(float(polygon[0][0]) + 1.0, float(polygon[0][1]) + 1.0)
	return Vector2(5, 5)


func _find_region(record_value: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record_value.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}


func _write_source(support: TestSupport) -> String:
	var root := "%s%d-%d" % [TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := _fixture_image()
	var entries: Array = []
	for frame in range(2):
		var relative := "frames/frame_%06d.png" % frame
		support.expect_equal(image.save_png(root.path_join(relative)), OK, "real editing fixture frame should save")
		entries.append({"frame": frame, "time_s": float(frame) * 10.0, "image_path": relative})
	var manifest := {
		"schema_version": 1,
		"dataset_id": "part2-2-real-ui",
		"source_name": "part2-2-real-ui.mp4",
		"source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"width": image.get_width(),
		"height": image.get_height(),
		"frame_count": 2,
		"nominal_fps": 10.0,
		"frames": entries,
		"model_version": "model_output_v1",
		"taxonomy_version": "sample-taxonomy-v1",
	}
	_write_text(root.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n")
	var records := PackedStringArray()
	for frame in range(2):
		var value := _fixture_record(frame)
		records.append(JSON.stringify(value))
	_write_text(root.path_join("model_output_v1.jsonl"), "\n".join(records) + "\n")
	return root


func _fixture_image() -> Image:
	var image := Image.create(160, 120, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.08, 0.10, 0.14, 1.0))
	for y in range(8, 112):
		for x in range(8, 152):
			var shade := 0.12 + float(x + y) / 1600.0
			image.set_pixel(x, y, Color(shade, shade, shade, 1.0))
	for y in range(75, 96):
		for x in range(112, 133):
			image.set_pixel(x, y, Color(0.92, 0.08, 0.08, 1.0))
	for x in range(70, 145):
		image.set_pixel(x, 62, Color.WHITE)
		image.set_pixel(x, 63, Color.WHITE)
	for y in range(45, 108):
		image.set_pixel(145, y, Color.WHITE)
		image.set_pixel(146, y, Color.WHITE)
	return image


func _fixture_record(frame: int) -> Dictionary:
	if frame == 1:
		return {
			"schema_version": 1,
			"source": "part2-2-real-ui.mp4",
			"frame": 1,
			"time_s": 10.0,
			"regions": [
				{
					"id": "duct-2", "class": "cystic_duct", "kind": "anatomy",
					"box": [10, 10, 24, 18], "conf": 0.75,
				},
			],
		}
	return {
		"schema_version": 1,
		"source": "part2-2-real-ui.mp4",
		"frame": frame,
		"time_s": float(frame) * 10.0,
		"regions": [
			{
				"id": "box-1", "class": "grasper", "kind": "instrument",
				"box": [20, 20, 30, 24], "conf": 0.9, "track_id": "T01",
			},
			{
				"id": "box-2", "class": "scissors", "kind": "instrument",
				"box": [85, 20, 30, 30], "conf": 0.8,
			},
			{
				"id": "poly-1", "class": "gallbladder", "kind": "anatomy",
				"polygon": [[20, 70], [35, 70], [35, 71], [36, 71], [36, 70], [60, 70], [60, 80], [20, 80]],
				"conf": 0.85,
			},
		],
	}


func _write_text(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
