extends RefCounted

const REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const MODEL_OUTPUT_VALIDATOR := preload("res://client/domain/model_output_validator.gd")
const TEMP_PREFIX := "/tmp/annotool-part1-feedback-"

var _owned_paths: Array[String] = []


func run(support) -> void:
	var registry = REGISTRY_SCRIPT.new()
	var discovery_errors: PackedStringArray = registry.discover("res://client/plugins")
	support.expect_equal(discovery_errors, PackedStringArray(), "production plugins should remain discoverable with Feedback installed")
	var plugin = registry.get_plugin("feedback", "file_training_handoff")
	support.expect(plugin != null, "registry should discover the working file-training Feedback plugin")
	if plugin == null:
		return
	_test_valid_atomic_export(plugin, support)
	_test_context_errors(plugin, support)
	_cleanup(support)


func _test_valid_atomic_export(plugin, support) -> void:
	var root := _new_temp_root("valid")
	DirAccess.make_dir_recursive_absolute(root)
	var output_path := root.path_join("corrected.jsonl")
	var records := [_model_record()]
	var original := records.duplicate(true)
	var outcomes: Array = []
	plugin.export_finished.connect(func(success: bool, detail: String): outcomes.append([success, detail]))

	var errors: PackedStringArray = plugin.export({"records": records, "output_path": output_path})
	support.expect_equal(errors, PackedStringArray(), "complete Feedback context should export")
	support.expect(FileAccess.file_exists(output_path), "successful Feedback export should publish the requested JSONL")
	var content := FileAccess.get_file_as_string(output_path)
	support.expect(content.ends_with("\n") and content.count("\n") == 1, "one-frame export should be one compact JSON object plus a final newline")
	var parsed: Variant = JSON.parse_string(content.strip_edges())
	support.expect(parsed is Dictionary, "exported JSONL line should parse as an object")
	if parsed is Dictionary:
		support.expect_equal(parsed.get("source"), "sample_v1", "Feedback must preserve the frame source")
		support.expect(not parsed.has("dataset_id") and not parsed.has("image_size"), "Feedback must not reintroduce removed model fields")
		support.expect_equal(MODEL_OUTPUT_VALIDATOR.new().validate_record(parsed), PackedStringArray(), "canonical corrected snapshot should remain structurally valid")
	support.expect_equal(records, original, "Feedback export must not mutate the model snapshot")
	support.expect_equal(outcomes, [[true, output_path]], "successful export should emit the published path")
	for file_name: String in DirAccess.get_files_at(root):
		support.expect(not ".tmp-" in file_name, "atomic export should not leave sibling temporary files")

	var valid_output := content
	var invalid := records.duplicate(true)
	invalid[0]["regions"][0]["box"] = [2, 3, -4, 5]
	errors = plugin.export({"records": invalid, "output_path": output_path})
	support.expect(not errors.is_empty(), "invalid corrected records should be refused before publication")
	support.expect_equal(FileAccess.get_file_as_string(output_path), valid_output, "failed export should preserve the prior valid output")
	support.expect(outcomes.size() == 2 and outcomes.back()[0] == false and not String(outcomes.back()[1]).is_empty(), "failed export should emit a readable error")


func _test_context_errors(plugin, support) -> void:
	var root := _new_temp_root("invalid-context")
	DirAccess.make_dir_recursive_absolute(root)
	var output_path := root.path_join("corrected.jsonl")
	var cases := [
		{"context": {"output_path": output_path}, "fragment": "records"},
		{"context": {"records": [_model_record()]}, "fragment": "output_path"},
		{"context": {"records": "wrong", "output_path": output_path}, "fragment": "records"},
		{"context": {"records": [_model_record()], "output_path": root.path_join("missing-parent/corrected.jsonl")}, "fragment": "directory"},
	]
	for case: Dictionary in cases:
		var errors: PackedStringArray = plugin.export(case.context)
		support.expect(not errors.is_empty() and _contains(errors, case.fragment), "incomplete Feedback context should identify %s" % case.fragment)


func _model_record() -> Dictionary:
	return {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"time_s": 0.0,
		"regions": [
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [2, 3, 4, 5], "conf": 0.9, "track_id": "T01"},
		],
	}


func _contains(errors: PackedStringArray, fragment: String) -> bool:
	for error: String in errors:
		if fragment.to_lower() in error.to_lower():
			return true
	return false


func _new_temp_root(label: String) -> String:
	var path := "%s%s-%d-%d" % [TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	_owned_paths.append(path)
	return path


func _cleanup(support) -> void:
	for path: String in _owned_paths:
		if not path.begins_with(TEMP_PREFIX) or path == TEMP_PREFIX:
			support.expect(false, "refusing to remove unowned Feedback fixture: %s" % path)
			continue
		_remove_tree(path)
		support.expect(not DirAccess.dir_exists_absolute(path), "Feedback fixture should be removed: %s" % path)
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
