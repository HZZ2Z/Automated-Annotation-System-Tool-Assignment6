extends RefCounted

const MAIN_SCENE := preload("res://client/app/main.tscn")
const SOURCE_PROBE := preload("res://tests/godot/fixtures/integration_plugins/counting_source.gd")
const EDIT_PROBE := preload("res://tests/godot/fixtures/integration_plugins/probe_edit.gd")
const TEMP_PREFIX := "/tmp/annotool-task9-fix1-"

var _temp_paths: Array[String] = []


func run(support, tree: SceneTree) -> void:
	await _test_keyboard_preview_and_text_focus(support, tree)
	await _test_candidate_cleanup_and_transactional_edit(support, tree)
	await _test_source_boundary_validation(support, tree)
	await _test_configured_plugin_ids(support, tree)
	_cleanup(support)


func _test_keyboard_preview_and_text_focus(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_source(support, "keyboard", 40, 30)
	support.expect_equal(main.open_source(root), PackedStringArray(), "keyboard fixture should open")
	var viewport = main.get_node("MainVBox/Workspace/ViewportPanel/AnnotationViewport")
	viewport.grab_focus()
	await tree.process_frame
	await _dispatch_key(tree, KEY_A, 97)
	var preview := _find_region(viewport.get("_record"), "__new_box_preview")
	support.expect(not preview.is_empty(), "A dispatched through Main should keep the keyboard-add preview visible")
	var initial_box: Array = preview.get("box", []).duplicate(true)
	await _dispatch_key(tree, KEY_LEFT, 0, true)
	preview = _find_region(viewport.get("_record"), "__new_box_preview")
	support.expect(not preview.is_empty() and preview.get("box") != initial_box, "a dispatched keyboard-add arrow should update the transient preview")
	await _dispatch_key(tree, KEY_ENTER)
	support.expect(_find_region(viewport.get("_record"), "__new_box_preview").is_empty(), "Enter should replace the transient preview with a committed region")
	support.expect(not (main.get_node("MainVBox/TopToolbar/Undo") as Button).disabled, "keyboard-add commit should enable Undo")
	support.expect_equal(_status(main), "Modified", "keyboard-add commit should update the Modified indicator")

	var edit_plugin = main.get("_edit_plugin")
	var line_edit := main.get_node("MainVBox/Workspace/InspectorPanelContainer/InspectorColumn/InspectorPanel/Fields/ClassFreeText") as LineEdit
	var text_before := line_edit.text
	line_edit.grab_focus()
	line_edit.caret_column = line_edit.text.length()
	await tree.process_frame
	await _dispatch_key(tree, KEY_X, 120)
	support.expect_equal(line_edit.text, text_before + "x", "LineEdit text input should be consumed by the focused editor")
	support.expect_equal(edit_plugin.get("_drag_kind"), "", "focused LineEdit input must not arm a keyboard edit gesture")
	await _free_main(main, tree)


func _test_candidate_cleanup_and_transactional_edit(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_source(support, "transaction", 40, 30)
	SOURCE_PROBE.reset("valid_two")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	support.expect_equal(main.open_source(root), PackedStringArray(), "transaction baseline should open")
	support.expect(main.seek(1), "transaction baseline should start from old frame one")
	main.call("_set_selected_region", "old-selection")
	var viewport = main.get_node("MainVBox/Workspace/ViewportPanel/AnnotationViewport")
	var old_source = main.get("_source")
	var old_store = main.get("_store")
	var old_history = main.get("_history")
	var old_edit = main.get("_edit_plugin")
	main.call("_on_add_box_pressed")
	support.expect(old_edit.get("_add_pointer_mode"), "baseline edit should have an active transient gesture")
	var old_texture = viewport.get("_texture")
	var old_record: Dictionary = viewport.get("_record").duplicate(true)
	var old_connections: int = viewport.get_signal_connection_list("edit_cancel_requested").size()

	SOURCE_PROBE.reset("records_hole")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	var errors: PackedStringArray = main.open_source(root)
	support.expect(not errors.is_empty(), "equal-count model records with a missing frame key should be rejected")
	support.expect_equal(SOURCE_PROBE.close_count, 1, "a holey-record candidate should close exactly once")
	support.expect(main.get("_source") == old_source and main.get("_store") == old_store and main.get("_history") == old_history, "holey-record failure should preserve source, store, and history identities")
	support.expect(main.get("_edit_plugin") == old_edit and old_edit.get("_add_pointer_mode"), "holey-record failure should preserve old edit identity and gesture")
	support.expect_equal(main.get_current_frame(), 1, "holey-record failure should preserve old frame index")
	support.expect_equal(main.call("_get_selected_region_id"), "old-selection", "holey-record failure should preserve old selection")
	support.expect(viewport.get("_texture") == old_texture and viewport.get("_record") == old_record, "holey-record failure should preserve visible UI")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), old_connections, "holey-record failure should preserve signal ownership")

	SOURCE_PROBE.reset("open_error")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	errors = main.open_source(root)
	support.expect(not errors.is_empty(), "candidate open error should be returned")
	support.expect_equal(SOURCE_PROBE.close_count, 1, "a candidate returning open errors should be closed exactly once")
	support.expect(main.get("_source") == old_source and main.get("_store") == old_store and main.get("_history") == old_history, "source-open failure should preserve source, store, and history identities")
	support.expect(main.get("_edit_plugin") == old_edit and old_edit.get("_add_pointer_mode"), "source-open failure should preserve active edit identity and gesture")
	support.expect(viewport.get("_texture") == old_texture and viewport.get("_record") == old_record, "source-open failure should preserve visible UI")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), old_connections, "source-open failure should preserve edit signal ownership")

	SOURCE_PROBE.reset("valid")
	EDIT_PROBE.reset("fail_after_connect")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	var edit_prototype = EDIT_PROBE.new()
	_replace_plugin(main, "edit", "basic_edit_tools", edit_prototype)
	errors = main.open_source(root)
	support.expect(not errors.is_empty(), "candidate edit activation failure should reject replacement")
	support.expect_equal(SOURCE_PROBE.close_count, 1, "edit activation failure should close the staged source exactly once")
	support.expect_equal(EDIT_PROBE.deactivation_count, 1, "Main should invoke the explicit edit lifecycle teardown after candidate activation failure")
	support.expect(main.get("_source") == old_source and main.get("_store") == old_store and main.get("_history") == old_history, "candidate edit failure should preserve source, store, and history identities")
	support.expect(main.get("_edit_plugin") == old_edit and old_edit.get("_add_pointer_mode"), "candidate edit failure should preserve old edit identity and transient gesture")
	support.expect_equal(main.get_current_frame(), 1, "candidate edit failure should preserve old frame index")
	support.expect_equal(main.call("_get_selected_region_id"), "old-selection", "staged selection setter must not mutate the old Main selection")
	support.expect_equal(EDIT_PROBE.last_activation_frame, 0, "candidate edit activation should observe staged frame zero")
	support.expect_equal(EDIT_PROBE.last_activation_selection, "", "candidate edit activation should observe an empty staged selection")
	support.expect(viewport.get("_texture") == old_texture and viewport.get("_record") == old_record, "candidate edit failure should preserve source, store, and visible UI")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), old_connections, "failed candidate edit must release its ghost signal connection")
	support.expect("fixture edit activation failure" in _status(main), "candidate teardown must not overwrite the activation failure status")

	SOURCE_PROBE.reset("valid_two")
	EDIT_PROBE.reset("success")
	errors = main.open_source(root)
	support.expect_equal(errors, PackedStringArray(), "valid candidate edit instance should commit")
	var new_edit = main.get("_edit_plugin")
	support.expect_equal(EDIT_PROBE.last_activation_frame, 0, "successful candidate activation should observe staged frame zero")
	support.expect_equal(EDIT_PROBE.last_activation_selection, "", "successful candidate activation should observe an empty staged selection")
	support.expect_equal(main.get_current_frame(), 0, "successful replacement should commit at frame zero")
	support.expect_equal(main.call("_get_selected_region_id"), "", "successful replacement should discard staged selection writes")
	support.expect(new_edit != old_edit and new_edit != edit_prototype, "successful replacement should install a fresh candidate edit instance")
	support.expect(not old_edit.get("_active") and not old_edit.get("_add_pointer_mode"), "successful replacement should cancel and deactivate the old edit instance")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), 1, "successful replacement should leave exactly one edit cancel connection")
	viewport.edit_cancel_requested.emit()
	support.expect_equal(new_edit.get("cancel_signal_count"), 1, "only the installed edit instance should receive viewport cancel signals")
	support.expect(main.seek(1), "successful replacement should seek within the new source")
	main.call("_set_selected_region", "new-live-selection")
	support.expect_equal(new_edit.call("read_saved_frame"), 1, "candidate frame callable should switch to live Main state after commit")
	support.expect_equal(new_edit.call("read_saved_selection"), "new-live-selection", "candidate selection callable should switch to live Main state after commit")
	new_edit.call("write_saved_selection", "plugin-live-selection")
	support.expect_equal(main.call("_get_selected_region_id"), "plugin-live-selection", "candidate selection setter should route to live Main after commit")
	await _free_main(main, tree)
	support.expect_equal(EDIT_PROBE.deactivation_count, 1, "Main exit should explicitly deactivate the installed edit instance exactly once")


func _test_source_boundary_validation(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_source(support, "boundary", 40, 30)
	support.expect_equal(main.open_source(root), PackedStringArray(), "boundary baseline should open")
	var baseline_frame: int = main.get_current_frame()
	var viewport = main.get_node("MainVBox/Workspace/ViewportPanel/AnnotationViewport")
	var baseline_texture = viewport.get("_texture")
	var modes := [
		"manifest_empty",
		"manifest_bad_fps",
		"frame_count_mismatch",
		"entry_bad_time",
		"manifest_wrong_type",
		"frame_count_wrong_type",
		"records_wrong_type",
		"records_count_mismatch",
		"texture_wrong_type",
		"entry_wrong_type",
	]
	for mode: String in modes:
		SOURCE_PROBE.reset(mode)
		_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
		var errors: PackedStringArray = main.open_source(root)
		support.expect(not errors.is_empty(), "invalid candidate mode %s should be rejected" % mode)
		support.expect_equal(SOURCE_PROBE.close_count, 1, "invalid candidate mode %s should close exactly once" % mode)
		support.expect_equal(main.get_current_frame(), baseline_frame, "invalid candidate mode %s should preserve current frame" % mode)
		support.expect(viewport.get("_texture") == baseline_texture, "invalid candidate mode %s should preserve visible texture" % mode)
		support.expect(_status(main).length() <= 180 and not "SCRIPT ERROR" in _status(main), "invalid candidate mode %s should report a bounded user-facing status" % mode)

	SOURCE_PROBE.reset("valid_two")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	support.expect_equal(main.open_source(root), PackedStringArray(), "two-frame source should open for later-entry boundary tests")
	var first_texture = viewport.get("_texture")
	SOURCE_PROBE.mode = "frame_count_wrong_type"
	support.expect_equal(main.call("_active_frame_count"), 2, "active frame count should remain the validated authoritative manifest value")
	support.expect(main.step(1), "dynamic source count changes must not disable manifest-indexed navigation")
	support.expect_equal(main.get_current_frame(), 1, "manifest-indexed navigation should reach frame one")
	support.expect(main.set_frame(0), "later-entry fixture should return to frame zero")
	first_texture = viewport.get("_texture")
	for mode: String in ["entry_second_bad_frame", "entry_second_bad_time"]:
		SOURCE_PROBE.mode = mode
		support.expect(not main.set_frame(1), "malformed later entry mode %s should be rejected" % mode)
		support.expect_equal(main.get_current_frame(), 0, "malformed later entry mode %s should preserve current frame" % mode)
		support.expect(viewport.get("_texture") == first_texture, "malformed later entry mode %s should preserve visible texture" % mode)
	await _free_main(main, tree)


func _test_configured_plugin_ids(support, tree: SceneTree) -> void:
	var root := _make_source(support, "configured-ids", 40, 30)
	for setting: String in ["source_plugin_id", "render_plugin_id", "edit_plugin_id"]:
		var main = MAIN_SCENE.instantiate()
		main.set(setting, "missing-" + setting)
		var viewport = main.get_node("MainVBox/Workspace/ViewportPanel/AnnotationViewport")
		var fallback_renderer = viewport.get("_renderer")
		tree.root.add_child(main)
		await tree.process_frame
		var errors: PackedStringArray = main.open_source(root)
		support.expect(not errors.is_empty(), "configured missing %s should prevent source opening" % setting)
		support.expect_equal(main.get_current_frame(), -1, "configured missing %s should leave Main without a dataset" % setting)
		support.expect(_status(main).length() <= 180 and "missing-" in _status(main), "configured missing %s should identify the configured lookup safely" % setting)
		if setting == "render_plugin_id":
			support.expect(viewport.get("_renderer") == fallback_renderer, "missing configured renderer should retain standalone fallback but never open data")
		await _free_main(main, tree)


func _mounted_main(tree: SceneTree):
	var main = MAIN_SCENE.instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	return main


func _free_main(main: Node, tree: SceneTree) -> void:
	main.queue_free()
	await tree.process_frame


func _dispatch_key(tree: SceneTree, keycode: Key, unicode_value: int = 0, alt_pressed: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.unicode = unicode_value
	event.alt_pressed = alt_pressed
	event.pressed = true
	Input.parse_input_event(event)
	await tree.process_frame
	var released := event.duplicate() as InputEventKey
	released.pressed = false
	Input.parse_input_event(released)
	await tree.process_frame


func _replace_plugin(main: Node, stage: String, plugin_id: String, plugin: RefCounted) -> void:
	var registry = main.get("_plugin_registry")
	var plugins: Dictionary = registry.get("_plugins")
	var stage_plugins: Dictionary = plugins.get(stage, {}).duplicate()
	stage_plugins[plugin_id] = plugin
	plugins[stage] = stage_plugins
	registry.set("_plugins", plugins)


func _make_source(support, label: String, width: int, height: int) -> String:
	var root := "%s%s-%d-%d" % [TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_GREEN)
	var relative := "frames/frame_000000.png"
	support.expect_equal(image.save_png(root.path_join(relative)), OK, "boundary fixture image should save")
	var manifest := {
		"schema_version": 1,
		"dataset_id": label,
		"source_name": label + ".mp4",
		"source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"width": width,
		"height": height,
		"frame_count": 1,
		"nominal_fps": 20.0,
		"frames": [{"frame": 0, "time_s": 0.0, "image_path": relative}],
		"model_version": "none",
		"taxonomy_version": "none",
	}
	var file := FileAccess.open(root.path_join("manifest.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest, "  ") + "\n")
	return root


func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}


func _status(main: Node) -> String:
	return str(main.get_node("MainVBox/StatusBar").text)


func _cleanup(support) -> void:
	for path: String in _temp_paths:
		if not path.begins_with(TEMP_PREFIX) or path == TEMP_PREFIX:
			support.expect(false, "refusing to remove unowned boundary fixture: %s" % path)
			continue
		_remove_tree(path)
		support.expect(not DirAccess.dir_exists_absolute(path), "boundary fixture should be removed: %s" % path)
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
