extends RefCounted

const STORE_PATH := "res://client/workspace/media_label_store.gd"
const TEMP_PREFIX := "/tmp/annotool-media-label-"


func run(support) -> void:
	var script := ResourceLoader.load(STORE_PATH, "Script") as Script
	support.expect(script != null,
		"MediaLabelStore should own one native JSON file per media")
	if script == null:
		return
	_test_native_save_restore_and_explicit_empty(script, support)
	_test_corrupt_native_file_is_strict(script, support)
	_test_failed_flush_keeps_pending_record(script, support)


func _test_native_save_restore_and_explicit_empty(script: Script, support) -> void:
	var root := _new_temp_root("native")
	var store = script.new()
	support.expect_equal(store.prepare(
		root, _media_entry("VID68"), _frame_entries()), PackedStringArray(),
		"new sequence should prepare without creating thousands of labels")
	support.expect(not store.is_explicit(16) and not store.is_explicit(23),
		"new display records should remain distinguishable from explicit labels")
	var explicit_negative: Dictionary = store.record_for_frame(16)
	support.expect_equal(explicit_negative.get("regions"), [],
		"unlabelled source frame should display as an empty in-memory record")
	support.expect_equal(store.replace_record(16, explicit_negative), PackedStringArray(),
		"committing an empty record should make it an explicit negative")
	support.expect(store.has_pending_changes(),
		"committed record should wait for automatic atomic flush")
	support.expect_equal(store.flush(), PackedStringArray(),
		"first flush should create the single media label")
	var label_path: String = root.path_join("label/VID68.json")
	support.expect(FileAccess.file_exists(label_path),
		"native label should be directly under workspace label")
	var payload := _read_json(label_path)
	support.expect(payload.get("frames", {}).has("16"),
		"explicit empty frame should be stored")
	support.expect(not payload.get("frames", {}).has("23"),
		"unlabelled frame should remain absent")

	var edited: Dictionary = store.record_for_frame(23)
	edited["regions"] = [{
		"id": "reg-23",
		"class": "grasper",
		"kind": "instrument",
		"box": [1.0, 1.0, 2.0, 2.0],
		"conf": 1.0,
		"track_id": null,
	}]
	support.expect_equal(store.replace_record(23, edited), PackedStringArray(),
		"valid sparse frame edit should update the in-memory label")
	support.expect_equal(store.flush(), PackedStringArray(),
		"existing media JSON should be atomically replaced")
	var label_directory := DirAccess.open(root.path_join("label"))
	var temp_files: Array[String] = []
	for file_name: String in label_directory.get_files():
		if ".tmp-" in file_name:
			temp_files.append(file_name)
	support.expect_equal(temp_files, [],
		"successful atomic replacement should leave no temporary files")

	var reopened = script.new()
	support.expect_equal(reopened.prepare(
		root, _media_entry("VID68"), _frame_entries()), PackedStringArray(),
		"existing native label should reopen")
	support.expect(reopened.is_explicit(16) and reopened.is_explicit(23),
		"reopened store should preserve both explicit frames")
	support.expect_equal(reopened.record_for_frame(23).get("regions"), edited["regions"],
		"reopened frame should restore its saved annotation")
	_remove_tree(root)


func _test_corrupt_native_file_is_strict(script: Script, support) -> void:
	var root := _new_temp_root("corrupt")
	DirAccess.make_dir_recursive_absolute(root.path_join("label"))
	_write_text(root.path_join("label/VID68.json"), "{broken")
	var store = script.new()
	var errors: PackedStringArray = store.prepare(
		root, _media_entry("VID68"), _frame_entries())
	support.expect(not errors.is_empty() and "VID68.json" in " ".join(errors),
		"corrupt native label should be named and refused")
	support.expect_equal(_read_text(root.path_join("label/VID68.json")), "{broken",
		"strict open must not replace corrupt data with blanks")
	_remove_tree(root)


func _test_failed_flush_keeps_pending_record(script: Script, support) -> void:
	var root := _new_temp_root("failure")
	_write_text(root.path_join("label"), "blocks label directory creation")
	var store = script.new()
	support.expect_equal(store.prepare(
		root, _media_entry("VID68"), _frame_entries()), PackedStringArray(),
		"label output failure should not prevent in-memory source preparation")
	var record: Dictionary = store.record_for_frame(16)
	support.expect_equal(store.replace_record(16, record), PackedStringArray(),
		"valid edit should remain visible before persistence")
	var errors: PackedStringArray = store.flush()
	support.expect(not errors.is_empty(),
		"unwritable label destination should report a save failure")
	support.expect(store.has_pending_changes() and store.is_explicit(16),
		"failed save should keep the edited record pending and visible")
	_remove_tree(root)


func _media_entry(media_id_value: String) -> Dictionary:
	return {
		"display_name": media_id_value,
		"media_id": media_id_value,
		"media_type": "image_sequence",
		"source_path": "/unused/videos/%s" % media_id_value,
		"relative_path": "videos/%s" % media_id_value,
		"source_sha256": null,
	}


func _frame_entries() -> Array[Dictionary]:
	return [
		{"frame": 0, "frame_id": 16, "time_s": 16.0, "image_path": "000016.png"},
		{"frame": 1, "frame_id": 23, "time_s": 23.0, "image_path": "000023.png"},
	]


func _new_temp_root(label: String) -> String:
	var root := "%s%s-%d-%d" % [
		TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _read_json(path: String) -> Dictionary:
	var value: Variant = JSON.parse_string(_read_text(path))
	return value if value is Dictionary else {}


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)


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
