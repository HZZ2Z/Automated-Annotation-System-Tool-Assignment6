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
	var output_path := root.path_join("training_update_v1")
	var records := [_model_record()]
	var original := records.duplicate(true)
	var outcomes: Array = []
	plugin.export_finished.connect(func(success: bool, detail: String): outcomes.append([success, detail]))

	var errors: PackedStringArray = plugin.export(_context(records, output_path))
	support.expect_equal(errors, PackedStringArray(), "complete Feedback context should export")
	var corrected_path := output_path.path_join("data/corrected_annotations.jsonl")
	var manifest_path := output_path.path_join("manifest.json")
	support.expect(DirAccess.dir_exists_absolute(output_path), "successful Feedback export should publish a package directory")
	support.expect(FileAccess.file_exists(corrected_path) and FileAccess.file_exists(manifest_path), "handoff package should contain manifest and corrected dataset")
	var content := FileAccess.get_file_as_string(corrected_path)
	support.expect(content.ends_with("\n") and content.count("\n") == 1, "one-frame export should be one compact JSON object plus a final newline")
	var parsed: Variant = JSON.parse_string(content.strip_edges())
	support.expect(parsed is Dictionary, "exported JSONL line should parse as an object")
	if parsed is Dictionary:
		support.expect_equal(parsed.get("source"), "sample_v1", "Feedback must preserve the frame source")
		support.expect(not parsed.has("dataset_id") and not parsed.has("image_size"), "Feedback must not reintroduce removed model fields")
		support.expect_equal(MODEL_OUTPUT_VALIDATOR.new().validate_record(parsed), PackedStringArray(), "canonical corrected snapshot should remain structurally valid")
	support.expect_equal(records, original, "Feedback export must not mutate the model snapshot")
	support.expect_equal(outcomes, [[true, output_path]], "successful export should emit the published path")
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	support.expect(manifest is Dictionary, "handoff manifest should parse")
	if manifest is Dictionary:
		support.expect_equal(manifest.get("schema_version"), 1, "handoff manifest should be versioned")
		support.expect_equal(manifest.get("package_type"), "annotool_training_handoff", "manifest should identify the handoff contract")
		support.expect_equal(manifest.get("source_dataset", {}).get("id"), "sample", "manifest should identify the source dataset")
		support.expect_equal(manifest.get("frame_count"), 1, "manifest should state corrected coverage")
		var artifact: Dictionary = manifest.get("artifacts", [])[0]
		support.expect_equal(artifact.get("path"), "data/corrected_annotations.jsonl", "manifest should use portable artifact paths")
		support.expect_equal(artifact.get("sha256"), FileAccess.get_sha256(corrected_path), "artifact checksum should match published bytes")
		support.expect_equal(artifact.get("bytes"), FileAccess.get_file_as_bytes(corrected_path).size(), "artifact byte count should match published bytes")
	for file_name: String in DirAccess.get_files_at(root):
		support.expect(not ".tmp-" in file_name, "atomic export should not leave sibling temporary files")
	for directory_name: String in DirAccess.get_directories_at(root):
		support.expect(not ".tmp-" in directory_name, "atomic export should not leave sibling temporary directories")

	var valid_output := FileAccess.get_file_as_string(manifest_path)
	errors = plugin.export(_context(records, output_path))
	support.expect(not errors.is_empty(), "an existing package should never be overwritten")
	support.expect_equal(FileAccess.get_file_as_string(manifest_path), valid_output, "failed export should preserve the prior valid package")
	support.expect(outcomes.size() == 2 and outcomes.back()[0] == false and not String(outcomes.back()[1]).is_empty(), "failed export should emit a readable error")


func _test_context_errors(plugin, support) -> void:
	var root := _new_temp_root("invalid-context")
	DirAccess.make_dir_recursive_absolute(root)
	var output_path := root.path_join("training_update_v1")
	var cases := [
		{"context": {"output_path": output_path}, "fragment": "records"},
		{"context": {"records": [_model_record()]}, "fragment": "output_path"},
		{"context": _context("wrong", output_path), "fragment": "records"},
		{"context": _context([_model_record()], root.path_join("missing-parent/training_update_v1")), "fragment": "parent"},
	]
	for case: Dictionary in cases:
		var errors: PackedStringArray = plugin.export(case.context)
		support.expect(not errors.is_empty() and _contains(errors, case.fragment), "incomplete Feedback context should identify %s" % case.fragment)


func _context(records: Variant, output_path: String) -> Dictionary:
	return {
		"records": records,
		"output_path": output_path,
		"source_manifest": {
			"dataset_id": "sample",
			"source_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			"model_version": "model_output_v1",
			"taxonomy_version": "v1",
			"frame_count": 1,
		},
		"model_digest": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
		"dirty_frames": [0],
		"batch_operations": [],
	}


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
