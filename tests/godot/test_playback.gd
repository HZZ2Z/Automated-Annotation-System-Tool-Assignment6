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
	if not main.has_method("open_source"):
		support.expect(false, "Main should expose open_source")
		main.queue_free()
		await tree.process_frame
		return

	var source_root := _make_source(support, "valid", 120, 0.01)
	var errors: PackedStringArray = main.call("open_source", source_root)
	support.expect_equal(errors, PackedStringArray(), "a normalized 120-frame directory should open")
	support.expect_equal(main.call("get_current_frame"), 0, "opening should select frame zero")
	support.expect_equal(_label(main, "FrameLabel"), "Frame 0 (120 total)", "frame label should show zero-based current index and total frame count")
	support.expect_equal(_label(main, "TimeLabel"), "00:00.125", "initial timestamp should come from manifest entry zero")
	var tool_panel = main.get_node("MainVBox/Workspace/ToolPanel")
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
	support.expect(not _find_region(main.get_node("MainVBox/Workspace/ViewportPanel/AnnotationViewport").get("_record"), "__new_box_preview").is_empty(), "Main should display a Box preview before commit")
	(tool_panel.get_node("ToolGrid/Select") as Button).pressed.emit()
	support.expect(_find_region(main.get_node("MainVBox/Workspace/ViewportPanel/AnnotationViewport").get("_record"), "__new_box_preview").is_empty(), "switching tools through Main should cancel the Box preview")
	support.expect_equal(main.get("_history").get_undo_count(), 0, "cancelled Main preview should not create edit history")

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
	var viewport = main.get_node("MainVBox/Workspace/ViewportPanel/AnnotationViewport")
	var preserved_texture: Texture2D = viewport.get("_texture")
	var preserved_record: Dictionary = viewport.get("_record").duplicate(true)
	DirAccess.remove_absolute(source_root.path_join("frames/frame_000117.png"))
	support.expect(not main.call("set_frame", 117), "a missing uncached texture should reject the frame change")
	support.expect_equal(main.call("get_current_frame"), 50, "texture failure should preserve current frame")
	support.expect(viewport.get("_texture") == preserved_texture, "texture failure should preserve the visible texture")
	support.expect_equal(viewport.get("_record"), preserved_record, "texture failure should preserve the visible annotation record")

	var failed_root := _make_source(support, "corrupt-replacement", 1, 24.0)
	_write_text(failed_root.path_join("frames/frame_000000.png"), "not image data")
	var replacement_errors: PackedStringArray = main.call("open_source", failed_root)
	support.expect(not replacement_errors.is_empty(), "replacement with a corrupt first texture should fail")
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
	main.call("_on_geometry_requested", added_region_id, [0.5, 0.5, -1.0, 2.0])
	support.expect(_status(main) != "Modified" and "positive" in _status(main).to_lower(), "a refused edit should remain visible even when the dataset was already modified")

	var registry_renderer = main.call("get_discovered_plugin", "render", "canvas_region_renderer")
	support.expect(registry_renderer != null and viewport.get("_renderer") == registry_renderer, "integrated Main should inject the renderer instance discovered by the registry")

	main.queue_free()
	await tree.process_frame
	_cleanup(support)


func _make_source(support, label: String, frame_count: int, nominal_fps: float) -> String:
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
		"model_version": "none",
		"taxonomy_version": "none",
	}
	_write_text(root.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n")
	return root


func _label(main: Node, node_name: String) -> String:
	var path := "MainVBox/TimelinePanel/TimelineColumn/Transport/%s" % node_name
	return str(main.get_node(path).text)


func _status(main: Node) -> String:
	return str(main.get_node("MainVBox/StatusBar").text)


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
