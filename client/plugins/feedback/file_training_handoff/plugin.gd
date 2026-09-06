extends "res://client/pipeline/stages/feedback_stage.gd"


signal export_finished(success: bool, path_or_error: String)

const VALIDATOR_SCRIPT := preload("res://client/domain/model_output_validator.gd")
const PACKAGE_TYPE := "annotool_training_handoff"
const CORRECTED_PATH := "data/corrected_annotations.jsonl"


func export(context: Dictionary) -> PackedStringArray:
	var errors := _validate_context(context)
	if not errors.is_empty():
		return _finish(false, errors)
	var destination := ProjectSettings.globalize_path(String(context["output_path"])).simplify_path().trim_suffix("/")
	var staging := destination.get_base_dir().path_join(
		".%s.tmp-%d-%d" % [destination.get_file(), OS.get_process_id(), Time.get_ticks_usec()]
	)
	var make_error := DirAccess.make_dir_recursive_absolute(staging.path_join("data"))
	if make_error != OK:
		return _finish(false, PackedStringArray(["cannot create staging package: %s" % error_string(make_error)]))

	var corrected_path := staging.path_join(CORRECTED_PATH)
	errors = _write_corrected_jsonl(context["records"], corrected_path)
	if not errors.is_empty():
		_remove_tree(staging)
		return _finish(false, errors)
	var corrected_sha256 := FileAccess.get_sha256(corrected_path)
	var corrected_bytes := FileAccess.get_file_as_bytes(corrected_path).size()
	var manifest := _build_manifest(context, corrected_sha256, corrected_bytes)
	errors = _write_json(staging.path_join("manifest.json"), manifest)
	if errors.is_empty():
		errors = _validate_staged_package(staging, manifest)
	if not errors.is_empty():
		_remove_tree(staging)
		return _finish(false, errors)
	var rename_error := DirAccess.rename_absolute(staging, destination)
	if rename_error != OK:
		_remove_tree(staging)
		return _finish(false, PackedStringArray(["could not publish handoff package atomically: %s" % error_string(rename_error)]))
	export_finished.emit(true, destination)
	return PackedStringArray()


func _validate_context(context: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var records: Variant = context.get("records")
	var seen_frames := {}
	if not records is Array or records.is_empty():
		errors.append("records: expected a non-empty Array")
	else:
		var validator = VALIDATOR_SCRIPT.new()
		var previous_frame := -1
		for index in range(records.size()):
			if not records[index] is Dictionary:
				errors.append("records.%d: expected a Dictionary" % index)
				continue
			for error: String in validator.validate_record(records[index]):
				errors.append("records.%d.%s" % [index, error])
			var frame: Variant = records[index].get("frame")
			if _is_logical_integer(frame):
				var frame_id := int(frame)
				if seen_frames.has(frame_id):
					errors.append(
					"records.%d.frame: duplicate frame %d" % [index, frame_id])
				elif frame_id <= previous_frame:
					errors.append(
					"records.%d.frame: expected strictly increasing frame IDs"
					% index)
				seen_frames[frame_id] = true
				previous_frame = frame_id
	var output_value: Variant = context.get("output_path")
	if typeof(output_value) != TYPE_STRING or String(output_value).strip_edges().is_empty():
		errors.append("output_path: expected a non-empty String")
	else:
		var output_path := ProjectSettings.globalize_path(String(output_value)).simplify_path().trim_suffix("/")
		if FileAccess.file_exists(output_path) or DirAccess.dir_exists_absolute(output_path):
			errors.append("output_path: destination already exists")
		elif not DirAccess.dir_exists_absolute(output_path.get_base_dir()):
			errors.append("output_path parent directory does not exist: %s" % output_path.get_base_dir())
	var source_manifest: Variant = context.get("source_manifest")
	if not source_manifest is Dictionary:
		errors.append("source_manifest: expected a Dictionary")
	else:
		for field: String in ["dataset_id", "source_sha256", "model_version", "taxonomy_version", "frame_count"]:
			if not source_manifest.has(field):
				errors.append("source_manifest.%s: required field missing" % field)
		for field: String in ["dataset_id", "model_version", "taxonomy_version"]:
			var value: Variant = source_manifest.get(field)
			if typeof(value) != TYPE_STRING or String(value).is_empty():
				errors.append("source_manifest.%s: expected non-empty String" % field)
		if not _is_logical_integer(source_manifest.get("frame_count")) or int(source_manifest.get("frame_count", 0)) <= 0:
			errors.append("source_manifest.frame_count: expected positive integer")
		if records is Array and source_manifest.get("frame_count") != records.size():
			errors.append("source_manifest.frame_count: must match corrected records")
		var source_sha256: Variant = source_manifest.get("source_sha256")
		if source_sha256 != null and not _is_sha256(source_sha256):
			errors.append(
				"source_manifest.source_sha256: expected SHA-256 or null")
	var model_digest: Variant = context.get("model_digest")
	if not _is_sha256(model_digest):
		errors.append("model_digest: expected SHA-256")
	var dirty_frames: Variant = context.get("dirty_frames", [])
	if not dirty_frames is Array:
		errors.append("dirty_frames: expected an Array")
	else:
		var previous := -1
		for index in range(dirty_frames.size()):
			var frame: Variant = dirty_frames[index]
			if not _is_logical_integer(frame) or int(frame) < 0:
				errors.append(
					"dirty_frames.%d: expected a non-negative frame ID" % index)
			elif not seen_frames.has(int(frame)):
				errors.append(
					"dirty_frames.%d: expected an existing record frame ID" % index)
			elif int(frame) <= previous:
				errors.append(
					"dirty_frames.%d: expected strictly increasing frame IDs" % index)
			else:
				previous = int(frame)
	var batch_operations: Variant = context.get("batch_operations", [])
	if not batch_operations is Array:
		errors.append("batch_operations: expected an Array")
	else:
		for index in range(batch_operations.size()):
			if not batch_operations[index] is Dictionary:
				errors.append("batch_operations.%d: expected a Dictionary" % index)
	return errors


func _build_manifest(context: Dictionary, corrected_sha256: String, corrected_bytes: int) -> Dictionary:
	var source_manifest: Dictionary = context["source_manifest"]
	var identity_fields := {
		"corrected_sha256": corrected_sha256,
		"dataset_id": source_manifest["dataset_id"],
		"model_digest": context["model_digest"],
		"source_sha256": source_manifest.get("source_sha256"),
	}
	var identity := JSON.stringify(identity_fields, "", true, true)
	return {
		"schema_version": 1,
		"package_type": PACKAGE_TYPE,
		"package_id": identity.sha256_text(),
		"source_dataset": {"id": source_manifest["dataset_id"], "sha256": source_manifest["source_sha256"]},
		"model_baseline": {"version": source_manifest["model_version"], "annotations_sha256": context["model_digest"]},
		"taxonomy_version": source_manifest["taxonomy_version"],
		"frame_count": source_manifest["frame_count"],
		"corrected_frame_count": context["records"].size(),
		"dirty_frames": context.get("dirty_frames", []).duplicate(),
		"batch_operations": context.get("batch_operations", []).duplicate(true),
		"artifacts": [{"role": "corrected_annotations", "path": CORRECTED_PATH, "bytes": corrected_bytes, "sha256": corrected_sha256}],
	}


func _write_corrected_jsonl(records: Array, path: String) -> PackedStringArray:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return PackedStringArray(["cannot create corrected dataset: %s" % error_string(FileAccess.get_open_error())])
	for record: Dictionary in records:
		file.store_string(JSON.stringify(record, "", true, true) + "\n")
	file.flush()
	var write_error := file.get_error()
	file = null
	return PackedStringArray() if write_error == OK else PackedStringArray(["could not write corrected dataset: %s" % error_string(write_error)])


func _write_json(path: String, value: Dictionary) -> PackedStringArray:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return PackedStringArray(["cannot create handoff manifest: %s" % error_string(FileAccess.get_open_error())])
	file.store_string(JSON.stringify(value, "  ", true, true) + "\n")
	file.flush()
	var write_error := file.get_error()
	file = null
	return PackedStringArray() if write_error == OK else PackedStringArray(["could not write handoff manifest: %s" % error_string(write_error)])


func _validate_staged_package(staging: String, expected_manifest: Dictionary) -> PackedStringArray:
	var manifest_path := staging.path_join("manifest.json")
	var corrected_path := staging.path_join(CORRECTED_PATH)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not parsed is Dictionary:
		return PackedStringArray(["staged handoff manifest failed round-trip validation"])
	if parsed.get("schema_version") != 1 or parsed.get("package_type") != PACKAGE_TYPE or parsed.get("package_id") != expected_manifest["package_id"]:
		return PackedStringArray(["staged handoff manifest identity mismatch"])
	var artifacts: Variant = parsed.get("artifacts")
	if not artifacts is Array or artifacts.size() != 1 or not artifacts[0] is Dictionary:
		return PackedStringArray(["staged handoff manifest artifacts are invalid"])
	var artifact: Dictionary = artifacts[0]
	if FileAccess.get_sha256(corrected_path) != artifact["sha256"]:
		return PackedStringArray(["staged corrected dataset checksum mismatch"])
	if FileAccess.get_file_as_bytes(corrected_path).size() != artifact["bytes"]:
		return PackedStringArray(["staged corrected dataset byte count mismatch"])
	return PackedStringArray()


func _finish(success: bool, errors: PackedStringArray) -> PackedStringArray:
	export_finished.emit(success, "; ".join(errors))
	return errors


func _is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING or String(value).length() != 64:
		return false
	for index in range(64):
		var code := String(value).to_lower().unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true


func _is_logical_integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) == floorf(float(value))


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
