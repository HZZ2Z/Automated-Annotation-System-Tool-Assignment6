extends RefCounted

const MAIN_SCENE_PATH := "res://client/app/main.tscn"
const TEMP_PREFIX := "/tmp/annotool-task9-"

var _temp_paths: Array[String] = []


func run(support, tree: SceneTree) -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	support.expect(packed != null, "Main scene should load for playback tests")
	if packed == null:
		return
	var main := packed.instantiate() as Control
	tree.root.add_child(main)
	await tree.process_frame
	support.expect_equal(main.get("source_plugin_id"), "", "default source routing should honor manifest priority instead of pinning the generic directory source")
	if not main.has_method("open_source"):
		support.expect(false, "Main should expose open_source")
		main.queue_free()
		await tree.process_frame
		return

	var source_root := _make_source(support, "valid", 120, 0.01, "model_output_v1")
	var errors: PackedStringArray = main.call("open_source", source_root)
	support.expect_equal(errors, PackedStringArray(), "a normalized 120-frame directory should open")
	var export_button := main.get_node("MainVBox/TopToolbar/Export") as Button
	support.expect(not export_button.disabled, "Export should become available after a source is accepted")
	var handoff_path := source_root.path_join("training_update_v1")
	support.expect_equal(main.call("export_handoff", handoff_path), PackedStringArray(), "Main should route export through the configured Feedback plugin")
	support.expect(FileAccess.file_exists(handoff_path.path_join("manifest.json")), "Main export should publish the training handoff package")
	support.expect_equal(main.call("get_current_frame"), 0, "opening should select frame zero")
	support.expect_equal(_label(main, "FrameLabel"), "Frame 0 (120 total)", "frame label should show zero-based current index and total frame count")
	support.expect_equal(_label(main, "TimeLabel"), "00:00.125", "initial timestamp should come from manifest entry zero")
	var explorer = main.get_node(
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer"
	)
	support.expect_equal(explorer.get("_view_model").get("display_name"), "valid",
		"successful open should populate the accepted dataset")
	support.expect_equal(explorer.get("_view_model").get("frames", []).size(), 120,
		"explorer should contain every accepted manifest frame")
	support.expect_equal(explorer.get("_view_model").get("artifacts"), [
		{"label": "manifest.json", "path": source_root.path_join("manifest.json")},
		{"label": "model_output_v1.jsonl", "path": source_root.path_join("model_output_v1.jsonl")},
	], "explorer should show the versioned model output selected by the accepted manifest")
	support.expect_equal(_selected_frame(explorer), 0,
		"successful open should highlight frame zero")

	explorer.frame_requested.emit(5)
	support.expect_equal(main.get_current_frame(), 5,
		"explorer navigation should seek through AnnotationMain")
	support.expect_equal(_selected_frame(explorer), 5,
		"explorer highlight should agree with the accepted frame")
	support.expect(main.seek(7), "direct seek should succeed")
	support.expect_equal(_selected_frame(explorer), 7,
		"direct seek should update the explorer without a second request")
	var tool_panel = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel")
	var edit_plugin = main.get("_edit_plugin")
	support.expect_equal(tool_panel.call("get_active_tool"), &"select", "Main should show Select after opening a source")
	support.expect_equal(edit_plugin.call("get_active_tool"), &"select", "the installed edit plugin should agree with the ToolPanel")
	(tool_panel.get_node("ToolGrid/Move") as Button).pressed.emit()
	support.expect_equal(edit_plugin.call("get_active_tool"), &"move", "ToolPanel Move should update the edit plugin")
	support.expect("Move" in _status(main), "tool changes should be visible in the status bar")

	(tool_panel.get_node("ToolGrid/Box") as Button).pressed.emit()
	var preview_press := InputEventMouseButton.new()
	preview_press.button_index = MOUSE_BUTTON_LEFT
	preview_press.pressed = true
	var preview_motion := InputEventMouseMotion.new()
	preview_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	main.call("_on_image_pointer_event", preview_press, Vector2(0.5, 0.5))
	main.call("_on_image_pointer_event", preview_motion, Vector2(2.5, 2.5))
	support.expect(not _find_region(main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport").get("_record"), "__new_box_preview").is_empty(), "Main should display a Box preview before commit")
	(tool_panel.get_node("ToolGrid/Select") as Button).pressed.emit()
	support.expect(_find_region(main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport").get("_record"), "__new_box_preview").is_empty(), "switching tools through Main should cancel the Box preview")
	support.expect_equal(main.get("_history").get_undo_count(), 0, "cancelled Main preview should not create edit history")

	support.expect(main.call("seek", 0), "lower-bound setup seek should succeed")
	support.expect(not main.call("step", -1), "previous at frame zero should be a clamped no-op")
	support.expect_equal(main.call("get_current_frame"), 0, "lower-bound step should retain frame zero")
	support.expect(main.call("step", 1), "next should select frame one")
	support.expect_equal(main.call("get_current_frame"), 1, "next should advance one explicit index")
	support.expect(main.call("seek", 119), "last frame should be seekable")
	support.expect(not main.call("step", 1), "next at frame 119 should be a clamped no-op")
	support.expect_equal(main.call("get_current_frame"), 119, "upper-bound step should retain frame 119")
	support.expect(not main.call("seek", -1), "negative seek should be rejected")
	support.expect(not main.call("seek", 120), "past-end seek should be rejected")
	support.expect_equal(main.call("get_current_frame"), 119, "invalid seeks should not change current frame")

	support.expect(main.call("seek", 2), "playback setup seek should succeed")
	main.call("play")
	support.expect(main.call("is_playing"), "play should start before the last frame")
	main.call("_on_playback_timeout")
	support.expect_equal(main.call("get_current_frame"), 3, "one timeout should advance exactly one explicit index")
	support.expect_equal(_label(main, "TimeLabel"), "00:06.125", "displayed timestamp must use manifest time_s rather than index divided by FPS")
	main.call("_on_playback_timeout")
	support.expect_equal(main.call("get_current_frame"), 4, "successive timeouts should advance indices one by one")
	main.call("pause")
	support.expect(not main.call("is_playing"), "pause should stop playback")

	support.expect(main.call("seek", 118), "penultimate frame should be seekable")
	main.call("play")
	main.call("_on_playback_timeout")
	support.expect_equal(main.call("get_current_frame"), 119, "final timeout should select the last frame")
	support.expect(not main.call("is_playing"), "playback should pause on the last frame")
	main.call("_on_playback_timeout")
	support.expect_equal(main.call("get_current_frame"), 119, "timeout at the end should never wrap")
	main.call("play")
	support.expect(not main.call("is_playing"), "play at the final frame should remain stopped")

	support.expect(main.call("seek", 50), "state-preservation setup seek should succeed")
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var preserved_texture: Texture2D = viewport.get("_texture")
	var preserved_record: Dictionary = viewport.get("_record").duplicate(true)
	DirAccess.remove_absolute(source_root.path_join("frames/frame_000117.png"))
	support.expect(not main.call("set_frame", 117), "a missing uncached texture should reject the frame change")
	support.expect_equal(main.call("get_current_frame"), 50, "texture failure should preserve current frame")
	support.expect(viewport.get("_texture") == preserved_texture, "texture failure should preserve the visible texture")
	support.expect_equal(viewport.get("_record"), preserved_record, "texture failure should preserve the visible annotation record")
	var missing_frame_item := _frame_item(explorer, 117)
	support.expect(missing_frame_item != null,
		"missing-frame navigation should exercise a real explorer TreeItem")
	main.play()
	support.expect(main.is_playing(), "missing-frame playback setup should be active")
	if missing_frame_item != null:
		missing_frame_item.select(0)
	await tree.process_frame
	support.expect_equal(main.get_current_frame(), 50,
		"failed explorer navigation should preserve the accepted frame")
	support.expect(viewport.get("_texture") == preserved_texture,
		"failed explorer navigation should preserve the visible texture")
	support.expect_equal(viewport.get("_record"), preserved_record,
		"failed explorer navigation should preserve the visible record")
	support.expect_equal(_selected_frame(explorer), 50,
		"failed explorer navigation should restore the accepted highlight")
	support.expect(main.is_playing(),
		"failed explorer navigation should preserve active playback")
	main.pause()
	support.expect(explorer.select_frame(50),
		"gesture preservation setup should select the accepted frame")

	var commit_press := InputEventMouseButton.new()
	commit_press.button_index = MOUSE_BUTTON_LEFT
	commit_press.pressed = true
	var commit_release := InputEventMouseButton.new()
	commit_release.button_index = MOUSE_BUTTON_LEFT
	commit_release.pressed = false
	main.call("_on_add_box_pressed")
	main.call("_on_image_pointer_event", commit_press, Vector2(0.5, 0.5))
	main.call("_on_image_pointer_event", commit_release, Vector2(2.5, 2.5))
	var navigation_selection_before: String = main.call("_get_selected_region_id")
	support.expect(not navigation_selection_before.is_empty(),
		"gesture preservation setup should have a real selected region")
	main.call("_on_add_box_pressed")
	var gesture_press := InputEventMouseButton.new()
	gesture_press.button_index = MOUSE_BUTTON_LEFT
	gesture_press.pressed = true
	var gesture_motion := InputEventMouseMotion.new()
	gesture_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	main.call("_on_image_pointer_event", gesture_press, Vector2(0.25, 0.25))
	main.call("_on_image_pointer_event", gesture_motion, Vector2(1.5, 1.5))
	var navigation_store_record: Dictionary = main.get("_store").get_corrected_record(50)
	var navigation_visible_preview: Dictionary = viewport.get("_record").duplicate(true)
	var navigation_undo_before: int = main.get("_history").get_undo_count()
	var navigation_redo_before: int = main.get("_history").get_redo_count()
	support.expect_equal(edit_plugin.get("_drag_kind"), "add",
		"gesture preservation setup should have an active edit gesture")
	support.expect(not _find_region(navigation_visible_preview, "__new_box_preview").is_empty(),
		"gesture preservation setup should display a transient preview")
	if missing_frame_item != null:
		missing_frame_item.select(0)
	await tree.process_frame
	support.expect_equal(main.get_current_frame(), 50,
		"failed explorer navigation should retain the gesture frame")
	support.expect_equal(_selected_frame(explorer), 50,
		"failed explorer navigation with a gesture should restore the accepted highlight")
	support.expect_equal(main.call("_get_selected_region_id"), navigation_selection_before,
		"failed explorer navigation should preserve region selection")
	support.expect_equal(main.get("_store").get_corrected_record(50), navigation_store_record,
		"failed explorer navigation should preserve annotation data")
	support.expect_equal(viewport.get("_record"), navigation_visible_preview,
		"failed explorer navigation should preserve the visible edit preview")
	support.expect_equal(edit_plugin.get("_drag_kind"), "add",
		"failed explorer navigation should preserve the active edit gesture")
	support.expect_equal(main.get("_history").get_undo_count(), navigation_undo_before,
		"failed explorer navigation should preserve undo history")
	support.expect_equal(main.get("_history").get_redo_count(), navigation_redo_before,
		"failed explorer navigation should preserve redo history")
	edit_plugin.cancel()
	preserved_record = viewport.get("_record").duplicate(true)

	var explorer_before: Dictionary = explorer.get("_view_model").duplicate(true)
	var selected_before: int = _selected_frame(explorer)
	var failed_root := _make_source(support, "corrupt-replacement", 1, 24.0)
	_write_text(failed_root.path_join("frames/frame_000000.png"), "not image data")
	var replacement_errors: PackedStringArray = main.call("open_source", failed_root)
	support.expect(not replacement_errors.is_empty(), "replacement with a corrupt first texture should fail")
	support.expect_equal(explorer.get("_view_model"), explorer_before,
		"failed source replacement should preserve the explorer tree")
	support.expect_equal(_selected_frame(explorer), selected_before,
		"failed source replacement should preserve explorer selection")
	support.expect_equal(main.call("get_current_frame"), 50, "failed replacement should preserve current frame")
	support.expect(viewport.get("_texture") == preserved_texture, "failed replacement should preserve current texture")
	support.expect_equal(viewport.get("_record"), preserved_record, "failed replacement should preserve current record")
	support.expect(main.call("seek", 51), "the prior source should remain usable after a failed replacement")
	preserved_texture = viewport.get("_texture")
	preserved_record = viewport.get("_record").duplicate(true)

	var raw_file := source_root.path_join("frames/frame_000000.png")
	main.call("_on_file_selected", raw_file)
	support.expect_equal(main.call("get_current_frame"), 0, "raw image selection should become a one-frame source")
	support.expect(viewport.get("_texture") != null and viewport.get("_texture").get_width() == 4, "raw image selection should display its decoded texture")
	support.expect_equal(_label(main, "FrameLabel"), "Frame 0 (1 total)", "raw image should use the same indexed frame UI")
	support.expect("Loaded" in _status(main), "raw image selection should report a successful load")
	var image_model: Dictionary = explorer.get("_view_model")
	support.expect_equal(image_model.get("frames", []).size(), 1,
		"a standalone image should expose one frame")
	support.expect_equal(image_model.get("display_name"), raw_file.get_file(),
		"a standalone image should identify the real opened file")
	var image_frames: Array = image_model.get("frames", [])
	var image_label: Variant = image_frames[0].get("label") if not image_frames.is_empty() else null
	support.expect_equal(image_label, raw_file.get_file(),
		"a standalone image should show its real file name")
	support.expect_equal(image_model.get("artifacts"), [],
		"a standalone image should not invent disk metadata")
	main.call("_on_add_box_pressed")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	main.call("_on_image_pointer_event", press, Vector2(0.5, 0.5))
	main.call("_on_image_pointer_event", release, Vector2(2.5, 2.5))
	support.expect(not (main.get_node("MainVBox/TopToolbar/Undo") as Button).disabled, "a committed mouse edit should enable Undo")
	support.expect_equal(_status(main), "Modified", "a committed mouse edit should show in-memory Modified state")
	var added_region_id: String = main.call("_get_selected_region_id")
	var image_edit_plugin = main.get("_edit_plugin")
	main.call("_on_add_box_pressed")
	var reserved_press := InputEventMouseButton.new()
	reserved_press.button_index = MOUSE_BUTTON_LEFT
	reserved_press.pressed = true
	var reserved_motion := InputEventMouseMotion.new()
	reserved_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	main.call("_on_image_pointer_event", reserved_press, Vector2(0.25, 0.25))
	main.call("_on_image_pointer_event", reserved_motion, Vector2(1.5, 1.5))
	var image_store = main.get("_store")
	var image_history = main.get("_history")
	var reserved_record_before: Dictionary = image_store.get_corrected_record(main.get_current_frame())
	var reserved_visible_before: Dictionary = viewport.get("_record").duplicate(true)
	var reserved_selection_before: String = main.call("_get_selected_region_id")
	var reserved_active_before: StringName = tool_panel.get_active_tool()
	var reserved_undo_before: int = image_history.get_undo_count()
	var reserved_redo_before: int = image_history.get_redo_count()
	support.expect_equal(reserved_selection_before, added_region_id,
		"reserved-tool setup should retain a real selected region")
	support.expect_equal(image_edit_plugin.get("_drag_kind"), "add",
		"reserved-tool setup should have an active edit gesture")
	support.expect(not _find_region(reserved_visible_before, "__new_box_preview").is_empty(),
		"reserved-tool setup should display a transient preview")
	(tool_panel.get_node("ToolGrid/Subtract") as Button).pressed.emit()
	support.expect_equal(main.get_node("MainVBox/StatusBar").text, "待开发",
		"reserved tools should produce the exact approved status")
	support.expect_equal(tool_panel.get_active_tool(), reserved_active_before,
		"reserved tools should preserve active edit mode")
	support.expect_equal(main.call("_get_selected_region_id"), reserved_selection_before,
		"reserved tools should preserve region selection")
	support.expect_equal(image_store.get_corrected_record(main.get_current_frame()), reserved_record_before,
		"reserved tools should not mutate annotation data")
	support.expect_equal(viewport.get("_record"), reserved_visible_before,
		"reserved tools should preserve the visible edit preview")
	support.expect_equal(image_edit_plugin.get("_drag_kind"), "add",
		"reserved tools should preserve the active edit gesture")
	support.expect_equal(image_history.get_undo_count(), reserved_undo_before,
		"reserved tools should preserve exact undo history")
	support.expect_equal(image_history.get_redo_count(), reserved_redo_before,
		"reserved tools should preserve exact redo history")
	image_edit_plugin.cancel()
	main.call("_on_geometry_requested", added_region_id, [0.5, 0.5, -1.0, 2.0])
	support.expect(_status(main) != "Modified" and "positive" in _status(main).to_lower(), "a refused edit should remain visible even when the dataset was already modified")

	var registry_renderer = main.call("get_discovered_plugin", "render", "canvas_region_renderer")
	support.expect(registry_renderer != null and viewport.get("_renderer").get_script() == registry_renderer.get_script(), "integrated Main should inject a renderer instance created by the registry")

	main.queue_free()
	await tree.process_frame
	await _test_external_source_through_main(support, tree, packed)
	_cleanup(support)


func _test_external_source_through_main(support, tree: SceneTree, packed: PackedScene) -> void:
	var main := packed.instantiate() as Control
	var has_plugin_roots := false
	for property: Dictionary in main.get_property_list():
		if property.get("name") == "plugin_roots":
			has_plugin_roots = true
			break
	support.expect(has_plugin_roots, "Main should expose startup plugin roots without requiring core edits")
	if not has_plugin_roots:
		main.free()
		return
	main.set("plugin_roots", PackedStringArray([
		"res://client/plugins",
		"res://tests/godot/fixtures/extension_plugins",
	]))
	tree.root.add_child(main)
	await tree.process_frame
	var errors: PackedStringArray = main.call("open_source", "case.fixture")
	support.expect_equal(errors, PackedStringArray(), "a non-filesystem Source dropped into an additional root should open through Main")
	support.expect_equal(main.call("get_current_frame"), 0, "the external Source should use the same indexed-frame client path")
	var explorer = main.get_node("MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer")
	var view_model: Dictionary = explorer.get("_view_model")
	support.expect_equal(view_model.get("display_name"), "Non-filesystem fixture", "Source-owned presentation metadata should reach the explorer unchanged")
	support.expect_equal(view_model.get("source_path"), "fixture://case.fixture", "Main must not rewrite a server-style Source locator as a filesystem path")
	main.queue_free()
	await tree.process_frame


func _make_source(
	support,
	label: String,
	frame_count: int,
	nominal_fps: float,
	model_version: String = "none",
) -> String:
	var root := "%s%s-%d-%d" % [TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(4, 3, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.4, 0.6, 1.0))
	var entries: Array = []
	for index in range(frame_count):
		var relative := "frames/frame_%06d.png" % index
		support.expect_equal(image.save_png(root.path_join(relative)), OK, "playback fixture frame %d should save" % index)
		var timestamp := 0.125 + float(index) * 2.0
		entries.append({"frame": index, "time_s": timestamp, "image_path": relative})
	var manifest := {
		"schema_version": 1,
		"dataset_id": label,
		"source_name": "%s.mp4" % label,
		"source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"width": 4,
		"height": 3,
		"frame_count": frame_count,
		"nominal_fps": nominal_fps,
		"frames": entries,
		"model_version": model_version,
		"taxonomy_version": "none",
	}
	_write_text(root.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n")
	if model_version != "none":
		var model_records := PackedStringArray()
		for index in range(frame_count):
			model_records.append(JSON.stringify({
				"schema_version": 1,
				"source": manifest["source_name"],
				"frame": index,
				"regions": [],
			}))
		_write_text(root.path_join("%s.jsonl" % model_version), "\n".join(model_records) + "\n")
	return root


func _label(main: Node, node_name: String) -> String:
	var path := "MainVBox/TimelinePanel/TimelineColumn/Transport/%s" % node_name
	return str(main.get_node(path).text)


func _status(main: Node) -> String:
	return str(main.get_node("MainVBox/StatusBar").text)


func _selected_frame(explorer: Node) -> int:
	var tree := explorer.get_node("Tree") as Tree
	var item := tree.get_selected()
	if item == null:
		return -1
	var value: Variant = item.get_metadata(0)
	return int(value) if typeof(value) == TYPE_INT else -1


func _frame_item(explorer: Node, frame_index: int) -> TreeItem:
	var tree := explorer.get_node("Tree") as Tree
	return _find_frame_item(tree.get_root(), frame_index)


func _find_frame_item(item: TreeItem, frame_index: int) -> TreeItem:
	if item == null:
		return null
	var value: Variant = item.get_metadata(0)
	if typeof(value) == TYPE_INT and int(value) == frame_index:
		return item
	var child := item.get_first_child()
	while child != null:
		var match := _find_frame_item(child, frame_index)
		if match != null:
			return match
		child = child.get_next()
	return null


func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)


func _cleanup(support) -> void:
	for path: String in _temp_paths:
		if not path.begins_with(TEMP_PREFIX) or path == TEMP_PREFIX:
			support.expect(false, "refusing to remove unowned playback fixture path: %s" % path)
			continue
		_remove_tree(path)
		support.expect(not DirAccess.dir_exists_absolute(path), "playback fixture should be removed: %s" % path)
	_temp_paths.clear()


func _remove_tree(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for child_name: String in directory.get_directories():
		_remove_tree(path.path_join(child_name))
	DirAccess.remove_absolute(path)
