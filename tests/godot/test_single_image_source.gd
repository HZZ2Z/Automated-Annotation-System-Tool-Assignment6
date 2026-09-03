extends RefCounted

const SOURCE_PATH := "res://client/plugins/source/single_image_source/plugin.gd"
const VALIDATOR_SCRIPT := preload("res://client/domain/annotation_validator.gd")
const TEMP_PREFIX := "/tmp/annotool-part1-single-image-"

var _owned_paths: Array[String] = []


func run(support) -> void:
	var source_script := ResourceLoader.load(SOURCE_PATH, "Script") as Script
	support.expect(source_script != null, "single-image Source plugin should load")
	if source_script == null:
		return
	for extension: String in ["png", "jpg", "jpeg"]:
		_test_supported_extension(source_script, extension, support)
	_test_invalid_inputs_leave_closed(source_script, support)
	_cleanup(support)


func _test_supported_extension(source_script: Script, extension: String, support) -> void:
	var root := _new_temp_root(extension)
	DirAccess.make_dir_recursive_absolute(root)
	var path := root.path_join("Surgical Frame.%s" % extension)
	var image := Image.create(11, 7, false, Image.FORMAT_RGB8)
	image.fill(Color(0.2, 0.4, 0.7))
	var save_error := image.save_png(path) if extension == "png" else image.save_jpg(path, 0.9)
	support.expect_equal(save_error, OK, "%s fixture should be created" % extension)

	var source = source_script.new()
	var errors: PackedStringArray = source.open(path)
	support.expect_equal(errors, PackedStringArray(), "%s should open through the single-image Source" % extension)
	support.expect_equal(source.get_frame_count(), 1, "%s should expose exactly one frame" % extension)
	support.expect_equal(source.get_frame_entry(0), {"frame": 0, "time_s": 0.0, "image_path": path.get_file()}, "%s frame metadata should use explicit frame zero" % extension)
	var manifest: Dictionary = source.get_manifest()
	support.expect_equal([manifest.get("width"), manifest.get("height")], [11, 7], "%s manifest should match decoded image dimensions" % extension)
	support.expect_equal(manifest.get("source_sha256"), FileAccess.get_sha256(path), "%s manifest should contain the actual source hash" % extension)
	var records: Array = source.get_model_records()
	support.expect_equal(records.size(), 1, "%s should synthesize one model record" % extension)
	if records.size() == 1:
		support.expect_equal(records[0].get("source"), "model_output_v1", "%s record should use the shared model-output source" % extension)
		support.expect_equal(records[0].get("image_size"), [11, 7], "%s record should match image dimensions" % extension)
		support.expect_equal(records[0].get("regions"), [], "%s record should begin without annotations" % extension)
		support.expect_equal(VALIDATOR_SCRIPT.new().validate_record(records[0]), PackedStringArray(), "%s synthesized record should satisfy the shared schema" % extension)
	var texture: Texture2D = source.load_texture(0)
	support.expect(texture != null and texture.get_width() == 11 and texture.get_height() == 7, "%s texture should load visibly" % extension)
	support.expect(source.load_texture(-1) == null and "range" in source.last_error, "%s negative frame should fail readably" % extension)
	support.expect(source.load_texture(1) == null and "range" in source.last_error, "%s past-end frame should fail readably" % extension)

	manifest["width"] = 999
	records[0]["regions"].append({"id": "mutation"})
	support.expect_equal(source.get_manifest().get("width"), 11, "%s manifest getter should return a defensive copy" % extension)
	support.expect_equal(source.get_model_records()[0].get("regions"), [], "%s record getter should return a defensive copy" % extension)
	source.close()
	support.expect_equal(source.get_frame_count(), 0, "%s close should clear the frame" % extension)
	support.expect_equal(source.get_manifest(), {}, "%s close should clear the manifest" % extension)
	support.expect_equal(source.get_model_records(), [], "%s close should clear records" % extension)


func _test_invalid_inputs_leave_closed(source_script: Script, support) -> void:
	var root := _new_temp_root("invalid")
	DirAccess.make_dir_recursive_absolute(root)
	var corrupt := root.path_join("corrupt.png")
	_write_text(corrupt, "not image data")
	var unsupported := root.path_join("frame.bmp")
	_write_text(unsupported, "not a supported source")
	var cases := [
		{"name": "missing", "path": root.path_join("missing.png")},
		{"name": "corrupt", "path": corrupt},
		{"name": "directory", "path": root},
		{"name": "unsupported", "path": unsupported},
	]
	for case: Dictionary in cases:
		var source = source_script.new()
		var errors: PackedStringArray = source.open(case.path)
		support.expect(not errors.is_empty(), "%s single-image input should be rejected" % case.name)
		support.expect_equal(source.get_frame_count(), 0, "%s rejection should leave the Source closed" % case.name)
		support.expect_equal(source.get_manifest(), {}, "%s rejection should not expose partial metadata" % case.name)
		support.expect_equal(source.get_model_records(), [], "%s rejection should not expose a partial record" % case.name)


func _new_temp_root(label: String) -> String:
	var path := "%s%s-%d-%d" % [TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	_owned_paths.append(path)
	return path


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)


func _cleanup(support) -> void:
	for path: String in _owned_paths:
		if not path.begins_with(TEMP_PREFIX) or path == TEMP_PREFIX:
			support.expect(false, "refusing to remove unowned single-image fixture: %s" % path)
			continue
		_remove_tree(path)
		support.expect(not DirAccess.dir_exists_absolute(path), "single-image fixture should be removed: %s" % path)
	_owned_paths.clear()


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
