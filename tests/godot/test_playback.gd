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
	support.expect_equal(main.call("_format_source_time", 0.0004), "00:00:00.000",
		"source-time display should round sub-millisecond values down")
	support.expect_equal(main.call("_format_source_time", 0.0005), "00:00:00.001",
		"source-time display should round half a millisecond into milliseconds")
	support.expect_equal(main.call("_format_source_time", 59.9995), "00:01:00.000",
		"source-time display should carry rounded milliseconds into minutes")
	support.expect_equal(main.call("_format_source_time", 3599.9995), "01:00:00.000",
		"source-time display should carry rounded milliseconds into hours")

	var source_root := _make_source(support, "valid", 120, 0.01, "model_output_v1")
	var errors: PackedStringArray = main.call("open_source", source_root)
	support.expect_equal(errors, PackedStringArray(), "a normalized 120-frame directory should open")
	var export_button := main.get_node("MainVBox/TopToolbar/Export") as Button
	support.expect(not export_button.disabled, "Export should become available after a source is accepted")
	var handoff_path := source_root.path_join("training_update_v1")
	support.expect_equal(main.call("export_handoff", handoff_path), PackedStringArray(), "Main should route export through the configured Feedback plugin")
	support.expect(FileAccess.file_exists(handoff_path.path_join("manifest.json")), "Main export should publish the training handoff package")
	support.expect_equal(main.call("get_current_frame"), 0, "opening should select frame zero")
	support.expect_equal(
		_label(main, "FrameLabel"),
		"Frame 0 (120 total)  ·  Time 00:00:00.125",
		"frame status should explicitly show the current source timestamp")
	var playback_speed = main.get_node_or_null("MainVBox/TopToolbar/PlaybackSpeed")
	support.expect(playback_speed != null
		and playback_speed.call("get_selected_mode") == &"one_second",
		"every multi-frame source should open at the approved one-second default")
	support.expect_equal(_label(main, "FpsLabel"), "FPS 0",
		"a loaded but paused source should report zero actual playback FPS")
	var fps_meter = main.get("_playback_fps_meter")
	support.expect(fps_meter != null,
		"Main should own the isolated actual-delivery FPS meter")
	if fps_meter != null:
		fps_meter.start(1_000_000)
		fps_meter.record_delivery(2_000_000)
		fps_meter.record_delivery(3_000_000)
		main.call("_refresh_labels")
		support.expect_equal(_label(main, "FpsLabel"), "FPS 1",
			"the transport should render measured delivery cadence instead of target speed")
		fps_meter.stop()
		main.call("_refresh_labels")
		support.expect_equal(_label(main, "FpsLabel"), "FPS 0",
			"stopping the runtime meter should restore the paused FPS state")
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
	support.expect_equal(
		_label(main, "FrameLabel"),
		"Frame 7 (120 total)  ·  Time 00:00:14.125",
		"seek should display the selected frame's manifest timestamp")
	support.expect_equal(_selected_frame(explorer), 7,
		"direct seek should update the explorer without a second request")
	var tool_panel = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel")
	var edit_plugin = main.get("_edit_plugin")
	support.expect_equal(tool_panel.call("get_active_tool"), &"select", "Main should show Select after opening a source")
	support.expect_equal(edit_plugin.call("get_active_tool"), &"select", "the installed edit plugin should agree with the ToolPanel")
	support.expect(tool_panel.get_node_or_null("ToolGrid/Move") == null,
		"Selection should absorb direct manipulation without a separate Move / Resize button")
	main.call("_on_unavailable_tool_requested", &"future_tool")
	support.expect_equal(_status(main), "待开发",
		"a future unimplemented descriptor should remain clickable and report the exact requested message")

	(tool_panel.get_node("ToolGrid/Box") as Button).pressed.emit()
	var preview_press := InputEventMouseButton.new()
	preview_press.button_index = MOUSE_BUTTON_LEFT
	preview_press.pressed = true
	var preview_motion := InputEventMouseMotion.new()
	preview_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	var initial_viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var initial_committed_record: Dictionary = initial_viewport.get("_record").duplicate(true)
	main.call("_on_image_pointer_event", preview_press, Vector2(0.5, 0.5))
	main.call("_on_image_pointer_event", preview_motion, Vector2(2.5, 2.5))
	var initial_overlay: Dictionary = initial_viewport.call("get_edit_overlay_state")
	support.expect_equal(initial_overlay.get("phase"), &"drawing", "Main should display a Drawing overlay before Box commit")
	support.expect_equal(initial_overlay.get("path", PackedVector2Array()).size(), 5, "Main Box overlay should carry a closed image-space path")
	support.expect_equal(initial_viewport.get("_record"), initial_committed_record, "Main Box overlay must not enter the committed record")
	(tool_panel.get_node("ToolGrid/Select") as Button).pressed.emit()
	support.expect_equal(initial_viewport.call("get_edit_overlay_state"), {}, "switching tools through Main should cancel the Box overlay")
	support.expect_equal(initial_viewport.get("_record"), initial_committed_record, "tool switching should leave the committed record unchanged")
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
	support.expect_equal(_label(main, "FpsLabel"), "FPS --",
		"a new playback run should wait for real delivery samples")
	main.call("_process", 0.999)
	support.expect_equal(main.call("get_current_frame"), 2,
		"the default clock should wait for one second per frame")
	main.call("_process", 0.001)
	support.expect_equal(main.call("get_current_frame"), 3, "one timeout should advance exactly one explicit index")
	main.call("_process", 20.0)
	support.expect_equal(main.call("get_current_frame"), 4, "successive timeouts should advance indices one by one")
	main.call("_process", 0.0)
	support.expect_equal(main.call("get_current_frame"), 4,
		"late playback must discard excess time instead of catching up or skipping")
	main.call("pause")
	support.expect(not main.call("is_playing"), "pause should stop playback")
	support.expect_equal(_label(main, "FpsLabel"), "FPS 0",
		"pausing should display zero actual playback FPS")

	if playback_speed != null:
		support.expect(playback_speed.call("select_mode", &"max", 5.0, true),
			"the integrated speed bar should accept its Max stop")
		support.expect(main.call("seek", 2), "maximum-speed setup seek should succeed")
		main.call("play")
		main.call("_process", 0.0)
		support.expect_equal(main.call("get_current_frame"), 3,
			"Max should deliver the next annotated frame without a configured delay")
		main.call("_process", 0.0)
		support.expect_equal(main.call("get_current_frame"), 4,
			"Max should retain ordered one-frame-at-a-time delivery")
		support.expect(main.get("_playback_fps_meter").get("_delivery_ticks_usec").size() == 2,
			"two successful Main process commits should produce two actual-FPS samples")
		support.expect(_label(main, "FpsLabel") != "FPS --"
			and _label(main, "FpsLabel") != "FPS 0",
			"two successful Main process commits should expose their measured cadence")
		main.call("pause")
		support.expect(playback_speed.call("select_mode", &"one_second", 5.0, true),
			"tests should restore the approved default after maximum-speed playback")

	support.expect(main.call("seek", 2), "keyboard-edit playback setup seek should succeed")
	main.call("play")
	var keyboard_add := InputEventKey.new()
	keyboard_add.keycode = KEY_A
	keyboard_add.pressed = true
	main.call("_unhandled_key_input", keyboard_add)
	support.expect(not main.call("is_playing"),
		"a handled edit shortcut should pause playback before the next frame can replace its preview")
	support.expect_equal(main.call("get_current_frame"), 2,
		"starting a keyboard edit while playing should freeze the accepted frame")
	support.expect_equal(main.get("_edit_plugin").get("_drag_kind"), "keyboard_add",
		"the paused frame should retain the keyboard edit state")
	main.get("_edit_plugin").cancel()

	support.expect(main.call("seek", 118), "penultimate frame should be seekable")
	main.call("play")
	main.call("_process", 2.0)
	support.expect_equal(main.call("get_current_frame"), 119, "final timeout should select the last frame")
	support.expect(not main.call("is_playing"), "playback should pause on the last frame")
	main.call("_process", 2.0)
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
	support.expect(main.seek(116), "playback-load-failure setup should select the prior frame")
	var playback_failure_texture: Texture2D = viewport.get("_texture")
	var playback_failure_record: Dictionary = viewport.get("_record").duplicate(true)
	main.play()
	var failed_delivery_count_before: int = main.get("_playback_fps_meter").get(
		"_delivery_ticks_usec").size()
	main.call("_process", 2.0)
	support.expect_equal(main.get_current_frame(), 116,
		"a playback load failure should keep the last successfully displayed frame")
	support.expect(not main.is_playing(), "a playback load failure should pause immediately")
	support.expect(viewport.get("_texture") == playback_failure_texture,
		"a playback load failure should preserve the visible texture")
	support.expect_equal(viewport.get("_record"), playback_failure_record,
		"a playback load failure should preserve visible annotations")
	support.expect_equal(
		main.get("_playback_fps_meter").get("_delivery_ticks_usec").size(),
		failed_delivery_count_before,
		"a failed set_frame commit must not contribute an actual-FPS sample")
	support.expect(main.seek(50), "navigation-failure tests should restore the accepted frame")
	preserved_texture = viewport.get("_texture")
	preserved_record = viewport.get("_record").duplicate(true)
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
	support.expect(not main.is_playing(),
		"explorer navigation should pause even when the requested frame fails")
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
	support.expect(_confirm_main_pending_box(main).is_empty(),
		"gesture preservation setup should explicitly classify its Box")
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
	var navigation_committed_record: Dictionary = viewport.get("_record").duplicate(true)
	var navigation_overlay_snapshot: Dictionary = viewport.call("get_edit_overlay_state")
	var navigation_undo_before: int = main.get("_history").get_undo_count()
	var navigation_redo_before: int = main.get("_history").get_redo_count()
	support.expect_equal(edit_plugin.get("_drag_kind"), "add",
		"gesture preservation setup should have an active edit gesture")
	support.expect_equal(navigation_overlay_snapshot.get("phase"), &"drawing",
		"gesture preservation setup should display a Drawing overlay")
	support.expect_equal(viewport.get("_record"), navigation_store_record,
		"gesture preservation setup should keep committed content separate")
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
	support.expect_equal(viewport.get("_record"), navigation_committed_record,
		"failed explorer navigation should preserve the committed visible record")
	support.expect_equal(viewport.call("get_edit_overlay_state"), navigation_overlay_snapshot,
		"failed explorer navigation should preserve the independent edit overlay")
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
	support.expect_equal(
		_label(main, "FrameLabel"),
		"Frame 0 (1 total)  ·  Time 00:00:00.000",
		"raw image should use the same explicit frame/time UI")
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
	support.expect(_confirm_main_pending_box(main).is_empty(),
		"standalone image Box should explicitly confirm its class and kind")
	support.expect(main.get("_history").can_undo(),
		"a committed mouse edit should remain undoable through Ctrl+Z")
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
	var tool_record_before: Dictionary = image_store.get_corrected_record(main.get_current_frame())
	var tool_selection_before: String = main.call("_get_selected_region_id")
	var tool_undo_before: int = image_history.get_undo_count()
	var tool_redo_before: int = image_history.get_redo_count()
	support.expect_equal(tool_selection_before, added_region_id,
		"tool-switch setup should retain a real selected region")
	support.expect_equal(image_edit_plugin.get("_drag_kind"), "add",
		"tool-switch setup should have an active edit gesture")
	support.expect_equal(viewport.call("get_edit_overlay_state").get("phase"), &"drawing",
		"tool-switch setup should display a Drawing overlay")
	support.expect_equal(viewport.get("_record"), tool_record_before,
		"tool-switch setup should keep committed content separate")
	for tool_case: Array in [
		["Subtract", &"subtract", "Subtract"],
		["Lasso", &"lasso", "Lasso"],
		["Paint", &"paint", "Paint"],
		["Eraser", &"eraser", "Eraser"],
	]:
		(tool_panel.get_node("ToolGrid/" + tool_case[0]) as Button).pressed.emit()
		support.expect_equal(main.get_node("MainVBox/StatusBar").text, "Tool: %s" % tool_case[2],
			"%s should activate as a real tool" % tool_case[0])
		support.expect_equal(tool_panel.get_active_tool(), tool_case[1],
			"%s should become the active edit mode" % tool_case[0])
		support.expect_equal(main.call("_get_selected_region_id"), tool_selection_before,
			"%s activation should preserve region selection" % tool_case[0])
		support.expect_equal(image_store.get_corrected_record(main.get_current_frame()), tool_record_before,
			"%s activation alone should not mutate annotation data" % tool_case[0])
		support.expect_equal(image_edit_plugin.get("_drag_kind"), "",
			"%s activation should cancel the prior Box preview" % tool_case[0])
		var activation_overlay: Dictionary = viewport.call("get_edit_overlay_state")
		if tool_case[1] in [&"paint", &"eraser"]:
			support.expect_equal(activation_overlay.get("phase"), &"brush_cursor",
				"%s activation should replace the stale Box overlay with its idle brush cursor" % tool_case[0])
		else:
			support.expect_equal(activation_overlay, {},
				"%s activation should leave no stale Box overlay" % tool_case[0])
		support.expect_equal(image_history.get_undo_count(), tool_undo_before,
			"%s activation should preserve undo history" % tool_case[0])
		support.expect_equal(image_history.get_redo_count(), tool_redo_before,
			"%s activation should preserve redo history" % tool_case[0])
	image_edit_plugin.cancel()
	var refused_geometry: PackedStringArray = image_edit_plugin.invoke(&"set_selected_geometry", {
		"box": [0.5, 0.5, -1.0, 2.0],
	})
	support.expect(not refused_geometry.is_empty(),
		"the current Edit API should reject invalid selected geometry")
	support.expect(_status(main) != "Modified" and "positive" in _status(main).to_lower(), "a refused edit should remain visible even when the dataset was already modified")

	var import_input := source_root.path_join("cancel-fixture.mkv")
	_write_text(import_input, "video import fixture")
	var import_output := source_root.path_join("cancelled-video-output")
	var import_controller = main.get_node("VideoImportController")
	import_controller.python_path = "res://.venv/bin/python"
	import_controller.cli_path = "res://tests/fixtures/fake_video_import.py"
	import_controller.job_root = source_root.path_join("video-import-jobs")
	var preserved_import_frame: int = main.get_current_frame()
	var preserved_import_manifest: Dictionary = main.get("_manifest").duplicate(true)
	main.call("_begin_video_import", import_input)
	main.call("_on_video_output_parent_selected", source_root)
	var import_name := main.get_node("VideoImportDialog/Margin/Content/DirectoryName") as LineEdit
	import_name.text = import_output.get_file()
	main.call("_on_video_import_start_pressed")
	support.expect(import_controller.is_running(), "modal video import should start in the background")
	main.call("_on_video_import_cancel_pressed")
	var cancel_heartbeats := 0
	while import_controller.is_running() and cancel_heartbeats < 300:
		cancel_heartbeats += 1
		await tree.create_timer(0.01).timeout
	support.expect(cancel_heartbeats > 0, "modal cancellation should keep the UI process responsive")
	support.expect_equal(main.get_current_frame(), preserved_import_frame,
		"cancelled modal import should preserve the current frame")
	support.expect_equal(main.get("_manifest"), preserved_import_manifest,
		"cancelled modal import should preserve the active dataset")
	support.expect(FileAccess.file_exists(import_input), "cancelled modal import should preserve the input")
	support.expect(not DirAccess.dir_exists_absolute(import_output),
		"cancelled modal import should not publish its target")
	support.expect(not (main.get_node("VideoImportDialog") as Window).visible,
		"the modal should close after cancellation settles")

	var registry_renderer = main.call("get_discovered_plugin", "render", "canvas_region_renderer")
	support.expect(registry_renderer != null and viewport.get("_renderer").get_script() == registry_renderer.get_script(), "integrated Main should inject a renderer instance created by the registry")

	main.queue_free()
	await tree.process_frame
	await _test_external_source_through_main(support, tree, packed)
	_cleanup(support)


func _test_working_mask_navigation_guards(
	support,
	tree: SceneTree,
	main: Control,
	source_root: String,
	explorer: Node,
) -> void:
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var timeline = main.get_node("MainVBox/TimelinePanel/TimelineColumn/Timeline")
	var edit_plugin = main.get("_edit_plugin")
	var resolution_message := "Use Fill, Close Gaps, or Escape before changing frames"
	var history = main.get("_history")
	support.expect(history.can_undo(), "WorkingMask history-guard setup should start from one real committed edit")
	var surviving_region_id: String = main.call("_get_selected_region_id")
	support.expect(not surviving_region_id.is_empty(),
		"WorkingMask sidebar setup should retain the first real committed region")
	main.call("_on_add_box_pressed")
	var second_press := InputEventMouseButton.new()
	second_press.button_index = MOUSE_BUTTON_LEFT
	second_press.pressed = true
	var second_release := InputEventMouseButton.new()
	second_release.button_index = MOUSE_BUTTON_LEFT
	second_release.pressed = false
	main.call("_on_image_pointer_event", second_press, Vector2(2.75, 0.25))
	main.call("_on_image_pointer_event", second_release, Vector2(3.75, 1.25))
	support.expect(_confirm_main_pending_box(main).is_empty(),
		"WorkingMask history setup should explicitly classify its second Box")
	support.expect_equal(history.get_undo_count(), 2,
		"WorkingMask setup should create a second real command for a residual Redo without removing the inspected region")
	support.expect(history.undo(main.get("_store")), "history setup should create one real residual Redo command")
	support.expect_equal(history.get_undo_count(), 1, "history-guard setup should retain the first real Undo command")
	support.expect_equal(history.get_redo_count(), 1, "history-guard setup should expose one real Redo command")
	main.call("_set_selected_region", surviving_region_id)
	# These direct boundary rows supplement Task 10's mounted real-control
	# Play/Previous/Next/timeline/Explorer matrix; both routes must converge on
	# the same atomic navigation guard.
	var navigation_cases := [
		{"name": "direct set_frame", "action": func(): return main.set_frame(51), "returns_bool": true},
		{"name": "direct seek", "action": func(): return main.seek(51), "returns_bool": true},
		{"name": "direct step", "action": func(): return main.step(1), "returns_bool": true},
		{"name": "Previous wrapper", "action": func(): main.call("_on_previous_pressed"), "returns_bool": false},
		{"name": "Next wrapper", "action": func(): main.call("_on_next_pressed"), "returns_bool": false},
		{"name": "timeline request", "action": func(): timeline.frame_requested.emit(51), "returns_bool": false},
		{"name": "Explorer request", "action": func(): explorer.frame_requested.emit(51), "returns_bool": false},
		{"name": "Play", "action": func(): main.play(), "returns_bool": false},
	]
	for case: Dictionary in navigation_cases:
		_clear_main_transient(edit_plugin)
		if main.get_current_frame() != 50:
			support.expect(main.seek(50), "%s setup should return to frame 50" % case.name)
		_install_main_working_mask(main, resolution_message)
		var overlay_before: Dictionary = viewport.get_edit_overlay_state()
		var record_before: Dictionary = main.get("_store").get_corrected_record(50)
		var undo_before: int = main.get("_history").get_undo_count()
		var redo_before: int = main.get("_history").get_redo_count()
		var result: Variant = case.action.call()
		if bool(case.returns_bool):
			support.expect_equal(result, false, "%s should be refused while a WorkingMask exists" % case.name)
		support.expect_equal(main.get_current_frame(), 50, "%s should keep the accepted frame" % case.name)
		support.expect(not main.is_playing(), "%s should leave playback paused" % case.name)
		support.expect_equal(main.get("_store").get_corrected_record(50), record_before, "%s should preserve Store" % case.name)
		support.expect_equal(main.get("_history").get_undo_count(), undo_before, "%s should preserve undo history" % case.name)
		support.expect_equal(main.get("_history").get_redo_count(), redo_before, "%s should preserve redo history" % case.name)
		support.expect_equal(viewport.get_edit_overlay_state(), overlay_before, "%s should preserve every WorkingMask byte" % case.name)
		support.expect_equal(timeline.get("_current_frame"), 50, "%s should restore the timeline highlight" % case.name)
		support.expect_equal(_selected_frame(explorer), 50, "%s should restore the Explorer highlight" % case.name)
		support.expect_equal(_status(main), resolution_message, "%s should explain how to resolve the blocking edit" % case.name)

	_clear_main_transient(edit_plugin)
	if main.get_current_frame() != 50:
		support.expect(main.seek(50), "playback-tick guard setup should return to frame 50")
	var tool_panel = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel")
	(tool_panel.get_node("ToolGrid/Paint") as Button).pressed.emit()
	var radius := tool_panel.get_node("OptionRow/Value") as SpinBox
	support.expect_equal(radius.value, 8.0, "WorkingMask option setup should start from the accepted shared radius")
	_install_main_working_mask(main, resolution_message)
	var tick_overlay: Dictionary = viewport.get_edit_overlay_state()
	var option_store_before: Dictionary = main.get("_store").get_corrected_record(50)
	var option_history_before := [history.get_undo_count(), history.get_redo_count()]
	radius.value = 20.0
	support.expect_equal(radius.value, 8.0,
		"a WorkingMask-refused radius request should visibly roll back to the accepted value")
	support.expect_equal(edit_plugin.get("_brush_radius_image_px"), 8.0,
		"a WorkingMask-refused radius request must not mutate the Edit plugin")
	support.expect_equal(main.get("_store").get_corrected_record(50), option_store_before,
		"a WorkingMask-refused radius request must preserve Store bytes")
	support.expect_equal([history.get_undo_count(), history.get_redo_count()], option_history_before,
		"a WorkingMask-refused radius request must preserve both history stacks")
	support.expect_equal(viewport.get_edit_overlay_state(), tick_overlay,
		"a WorkingMask-refused radius request must preserve every overlay byte")
	support.expect(main.get("_playback_controller").play(50), "test setup should bypass Main and arm the playback controller")
	main.call("_process", 2.0)
	support.expect_equal(main.get_current_frame(), 50, "a playback tick should be refused at the same set_frame boundary")
	support.expect(not main.is_playing(), "a blocked playback tick should pause the controller")
	support.expect_equal(viewport.get_edit_overlay_state(), tick_overlay, "a blocked playback tick should preserve the WorkingMask")

	var state_before: Dictionary = edit_plugin.get_edit_state() if edit_plugin.has_method("get_edit_state") else {}
	var transform = viewport.get_image_transform()
	main.call("_on_zoom_pressed", 1.2)
	support.expect_equal(viewport.get_edit_overlay_state(), tick_overlay, "Zoom should preserve the WorkingMask overlay")
	main.call("_on_fit_pressed")
	support.expect_equal(viewport.get_edit_overlay_state(), tick_overlay, "Fit should preserve the WorkingMask overlay")
	var middle_press := InputEventMouseButton.new()
	middle_press.button_index = MOUSE_BUTTON_MIDDLE
	middle_press.pressed = true
	viewport.call("_gui_input", middle_press)
	var pan_motion := InputEventMouseMotion.new()
	pan_motion.relative = Vector2(7, -3)
	pan_motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	viewport.call("_gui_input", pan_motion)
	var middle_release := InputEventMouseButton.new()
	middle_release.button_index = MOUSE_BUTTON_MIDDLE
	middle_release.pressed = false
	viewport.call("_gui_input", middle_release)
	support.expect_equal(viewport.get_edit_overlay_state(), tick_overlay, "middle-button pan should preserve the WorkingMask overlay")
	viewport.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	support.expect_equal(viewport.get_edit_overlay_state(), tick_overlay, "focus loss should preserve the WorkingMask overlay")
	if edit_plugin.has_method("get_edit_state"):
		support.expect_equal(edit_plugin.get_edit_state(), state_before, "transform and focus changes should preserve the complete edit state")
	support.expect(transform.is_configured(), "transform preservation checks should keep the shared image transform configured")

	var old_source = main.get("_source")
	var old_store = main.get("_store")
	var old_history = main.get("_history")
	var old_manifest: Dictionary = main.get("_manifest").duplicate(true)
	var replacement_errors: PackedStringArray = main.open_source(source_root)
	support.expect(not replacement_errors.is_empty(), "source replacement should be refused while a WorkingMask exists")
	support.expect(main.get("_source") == old_source, "blocked source replacement should preserve source identity")
	support.expect(main.get("_store") == old_store, "blocked source replacement should preserve Store identity")
	support.expect(main.get("_history") == old_history, "blocked source replacement should preserve History identity")
	support.expect_equal(main.get("_manifest"), old_manifest, "blocked source replacement should preserve the accepted manifest")
	support.expect_equal(main.get_current_frame(), 50, "blocked source replacement should preserve the frame")
	support.expect_equal(viewport.get_edit_overlay_state(), tick_overlay, "candidate activation must not overwrite the old WorkingMask state")

	var sidebar_record: Dictionary = old_store.get_corrected_record(50)
	var sidebar_undo: int = old_history.get_undo_count()
	var sidebar_redo: int = old_history.get_redo_count()
	var sidebar_selection: String = main.call("_get_selected_region_id")
	var sidebar_state: Dictionary = edit_plugin.get_edit_state()
	var sidebar = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar")
	var sidebar_snapshot := {
		"project": sidebar.get_project_rows_snapshot(),
		"frame": sidebar.get_frame_rows_snapshot(),
	}
	var accepted_region := _find_region(sidebar_record, sidebar_selection).duplicate(true)
	support.expect(not accepted_region.is_empty(),
		"sidebar refusal setup should use a selected region that still exists in Store")
	main.call("_open_reclassification_dialog", sidebar_selection)
	support.expect(not main.get_node("ClassAssignmentDialog").call("is_assignment_open"),
		"reclassification should be refused before opening a modal behind WorkingMask")
	support.expect_equal({
		"project": sidebar.get_project_rows_snapshot(),
		"frame": sidebar.get_frame_rows_snapshot(),
	}, sidebar_snapshot, "a refused reclassification should preserve the complete sidebar snapshot")
	support.expect_equal(old_store.get_corrected_record(50), sidebar_record,
		"sidebar reclassification should be refused behind a WorkingMask")
	support.expect_equal(old_history.get_undo_count(), sidebar_undo,
		"sidebar refusal should not enter history")
	support.expect_equal(main.call("_get_selected_region_id"), sidebar_selection,
		"sidebar refusal should not change selection before the guard")
	support.expect_equal(edit_plugin.get_edit_state(), sidebar_state,
		"sidebar refusal should preserve the complete WorkingMask session state")
	support.expect_equal(_status(main), resolution_message,
		"sidebar refusal must not overwrite Main's WorkingMask resolution message")
	main.call("_on_redo_pressed")
	support.expect_equal(old_history.get_undo_count(), sidebar_undo, "Redo should be refused behind a WorkingMask")
	support.expect_equal(old_history.get_redo_count(), sidebar_redo, "Redo refusal should preserve a real residual redo command")
	support.expect_equal(old_store.get_corrected_record(50), sidebar_record, "Redo refusal should not replay geometry behind a WorkingMask")
	support.expect_equal(viewport.get_edit_overlay_state(), tick_overlay, "sidebar/history refusals should preserve the WorkingMask")

	var history_before_escape: int = old_history.get_undo_count()
	support.expect(edit_plugin.handle_key(_pressed_key(KEY_ESCAPE)), "Escape should resolve the guarded WorkingMask")
	support.expect_equal(viewport.get_edit_overlay_state(), {}, "Escape should clear only the transient WorkingMask")
	support.expect_equal(old_history.get_undo_count(), history_before_escape, "Escape should create zero history entries")
	(tool_panel.get_node("ToolGrid/Paint") as Button).pressed.emit()
	main.call("_on_image_pointer_event", second_press, Vector2(1.0, 1.0))
	support.expect_equal(viewport.get_edit_overlay_state().get("brush_radius"), 8.0,
		"after Escape, Paint should still render with the last accepted shared radius")
	support.expect(edit_plugin.handle_key(_pressed_key(KEY_ESCAPE)), "Paint radius verification should cancel without history")
	main.call("_set_selected_region", surviving_region_id)
	(tool_panel.get_node("ToolGrid/Eraser") as Button).pressed.emit()
	main.call("_on_image_pointer_event", second_press, Vector2(1.0, 1.0))
	support.expect_equal(viewport.get_edit_overlay_state().get("brush_radius"), 8.0,
		"after Escape, Eraser should share the unchanged accepted radius")
	support.expect(edit_plugin.handle_key(_pressed_key(KEY_ESCAPE)), "Eraser radius verification should cancel without history")
	support.expect_equal(old_history.get_undo_count(), history_before_escape,
		"Paint/Eraser radius verification previews should create zero history")
	support.expect(main.seek(51), "navigation should resume after Escape resolves the WorkingMask")
	support.expect(main.seek(50), "WorkingMask navigation test should restore its caller's accepted frame")
	await tree.process_frame


func _install_main_working_mask(main: Control, message: String) -> void:
	var edit_plugin = main.get("_edit_plugin")
	var session: Variant = edit_plugin.get("_session")
	var frame: int = main.get_current_frame()
	session.begin(&"paint", frame, "", main.get("_store").get_corrected_record(frame))
	session.set_working_mask({
		"roi": Rect2i(0, 0, 4, 3),
		"mask": PackedByteArray([1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1]),
	}, message)
	edit_plugin.call("_push_session_overlay")


func _confirm_main_pending_box(main: Control) -> PackedStringArray:
	var edit_plugin = main.get("_edit_plugin")
	var request: Dictionary = edit_plugin.get("_session").pending_request()
	var errors: PackedStringArray = edit_plugin.invoke(&"confirm_pending_region", {
		"candidate_token": request.get("candidate_token"),
		"class": "test class",
		"kind": "free kind",
	})
	if errors.is_empty():
		main.call("_refresh_after_edit", true)
	return errors


func _clear_main_transient(edit_plugin: Variant) -> void:
	if edit_plugin != null:
		edit_plugin.handle_key(_pressed_key(KEY_ESCAPE))


func _pressed_key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


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
	var node := main.get_node_or_null(path) as Label
	return str(node.text) if node != null else "<missing>"


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
