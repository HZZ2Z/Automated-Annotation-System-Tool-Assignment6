class_name MediaLabelStore
extends RefCounted


signal saved(path: String)
signal save_failed(frame_ids: PackedInt64Array, path: String, message: String)

const PATHS_SCRIPT := preload("res://client/workspace/workspace_paths.gd")
const VALIDATOR_SCRIPT := preload("res://client/domain/model_output_validator.gd")
const MEDIA_TYPES := {"image": true, "video": true, "image_sequence": true}
const TOP_LEVEL_FIELDS := {
	"schema_version": true,
	"media_id": true,
	"media_type": true,
	"source_relative_path": true,
	"source_sha256": true,
	"frame_digits": true,
	"frames": true,
}


var _validator = VALIDATOR_SCRIPT.new()
var _workspace_root := ""
var _media_entry: Dictionary = {}
var _frame_entries_by_id: Dictionary = {}
var _frame_order: Array[int] = []
var _display_records: Dictionary = {}
var _explicit_records: Dictionary = {}
var _dirty_frames: Dictionary = {}
var _label_path := ""


func prepare(
	workspace_root: String,
	media_entry: Dictionary,
	frame_entries: Array,
	seed_records: Variant = []
) -> PackedStringArray:
	var errors := PackedStringArray()
	var root := ProjectSettings.globalize_path(workspace_root).simplify_path().trim_suffix("/")
	if root.is_empty() or not DirAccess.dir_exists_absolute(root):
		errors.append("Workspace directory does not exist: %s" % root)
		return errors
	var media_id_value: Variant = media_entry.get("media_id")
	var media_type: Variant = media_entry.get("media_type")
	var relative_path: Variant = media_entry.get("relative_path")
	if typeof(media_id_value) != TYPE_STRING or not PATHS_SCRIPT.is_portable_media_id(media_id_value):
		errors.append("Media label requires a portable media_id")
	if typeof(media_type) != TYPE_STRING or not MEDIA_TYPES.has(media_type):
		errors.append("Media label requires image, video, or image_sequence media_type")
	if typeof(relative_path) != TYPE_STRING or relative_path.is_empty() or _unsafe_relative_path(relative_path):
		errors.append("Media label source_relative_path must be a contained POSIX path")

	var frame_map := {}
	var frame_order: Array[int] = []
	for playback_index in range(frame_entries.size()):
		var entry: Variant = frame_entries[playback_index]
		if not entry is Dictionary:
			errors.append("Frame entry %d must be a Dictionary" % playback_index)
			continue
		var frame_value: Variant = entry.get("frame_id", entry.get("frame"))
		if typeof(frame_value) != TYPE_INT or frame_value < 0 or frame_value > 999999:
			errors.append("Frame entry %d has an invalid original frame ID" % playback_index)
			continue
		var frame_id := int(frame_value)
		if frame_map.has(frame_id):
			errors.append("Frame entries contain duplicate original frame ID %d" % frame_id)
			continue
		frame_map[frame_id] = (entry as Dictionary).duplicate(true)
		frame_order.append(frame_id)
	if frame_order.is_empty():
		errors.append("Media label requires at least one source frame")
	if not errors.is_empty():
		return errors

	var candidate_label_path := PATHS_SCRIPT.label_path(root, media_id_value)
	var explicit := {}
	var label_exists := FileAccess.file_exists(candidate_label_path)
	if label_exists:
		if _path_is_link(candidate_label_path):
			return PackedStringArray(["Media label must not be a symbolic link: %s" % candidate_label_path])
		var read_result := _read_json(candidate_label_path)
		if not read_result["errors"].is_empty():
			return read_result["errors"]
		var payload := read_result["value"] as Dictionary
		errors = _validate_payload(payload, media_entry, frame_map)
		if not errors.is_empty():
			return _prefix_errors(candidate_label_path, errors)
		for key: Variant in payload["frames"]:
			explicit[int(key)] = (payload["frames"][key] as Dictionary).duplicate(true)
	else:
		errors = _collect_seed_records(seed_records, media_id_value, frame_map, explicit)
		if not errors.is_empty():
			return errors

	var display := {}
	for frame_id: int in frame_order:
		if explicit.has(frame_id):
			display[frame_id] = explicit[frame_id].duplicate(true)
		else:
			var entry := frame_map[frame_id] as Dictionary
			display[frame_id] = _empty_record(
				media_id_value, frame_id, float(entry.get("time_s", frame_id)))

	_workspace_root = root
	_media_entry = media_entry.duplicate(true)
	_frame_entries_by_id = frame_map
	_frame_order = frame_order
	_display_records = display
	_explicit_records = explicit
	_dirty_frames.clear()
	_label_path = candidate_label_path
	if not label_exists and not explicit.is_empty():
		for frame_id: int in explicit:
			_dirty_frames[frame_id] = true
	return PackedStringArray()


func record_for_frame(frame_id: int) -> Dictionary:
	var value: Variant = _display_records.get(frame_id)
	return value.duplicate(true) if value is Dictionary else {}


func all_display_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for frame_id: int in _frame_order:
		result.append((_display_records[frame_id] as Dictionary).duplicate(true))
	return result


func replace_record(frame_id: int, record: Variant) -> PackedStringArray:
	var errors := _validate_record_for_frame(frame_id, record)
	if not errors.is_empty():
		return errors
	var copy := (record as Dictionary).duplicate(true)
	_display_records[frame_id] = copy
	_explicit_records[frame_id] = copy.duplicate(true)
	_dirty_frames[frame_id] = true
	return PackedStringArray()


func is_explicit(frame_id: int) -> bool:
	return _explicit_records.has(frame_id)


func has_pending_changes() -> bool:
	return not _dirty_frames.is_empty()


func dirty_frame_ids() -> PackedInt64Array:
	var frames: Array = _dirty_frames.keys()
	frames.sort()
	return PackedInt64Array(frames)


func label_path() -> String:
	return _label_path


func flush() -> PackedStringArray:
	if not has_pending_changes():
		return PackedStringArray()
	var label_directory := _label_path.get_base_dir()
	if FileAccess.file_exists(label_directory):
		return _flush_failure("Label directory path is occupied by a file: %s" % label_directory)
	if not DirAccess.dir_exists_absolute(label_directory):
		var make_error := DirAccess.make_dir_recursive_absolute(label_directory)
		if make_error != OK:
			return _flush_failure(
				"Cannot create label directory %s (%s)" % [
					label_directory, error_string(make_error)])
	if _path_is_link(label_directory):
		return _flush_failure("Label directory must not be a symbolic link: %s" % label_directory)

	var payload := _payload()
	var payload_errors := _validate_payload(payload, _media_entry, _frame_entries_by_id)
	if not payload_errors.is_empty():
		return _flush_failure(payload_errors[0])
	var temporary_path := "%s.tmp-%d-%d" % [
		_label_path, OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _flush_failure("Cannot open temporary media label: %s" % temporary_path)
	file.store_string(JSON.stringify(payload, "  ", false) + "\n")
	file.flush()
	file = null

	var read_result := _read_json(temporary_path)
	if not read_result["errors"].is_empty():
		DirAccess.remove_absolute(temporary_path)
		return _flush_failure(read_result["errors"][0])
	var verify_errors := _validate_payload(
		read_result["value"], _media_entry, _frame_entries_by_id)
	if not verify_errors.is_empty():
		DirAccess.remove_absolute(temporary_path)
		return _flush_failure("Temporary media label is invalid: %s" % verify_errors[0])
	var rename_error := DirAccess.rename_absolute(temporary_path, _label_path)
	if rename_error != OK:
		DirAccess.remove_absolute(temporary_path)
		return _flush_failure(
			"Cannot publish media label %s (%s)" % [
				_label_path, error_string(rename_error)])
	_dirty_frames.clear()
	saved.emit(_label_path)
	return PackedStringArray()


func clear() -> void:
	_workspace_root = ""
	_media_entry.clear()
	_frame_entries_by_id.clear()
	_frame_order.clear()
	_display_records.clear()
	_explicit_records.clear()
	_dirty_frames.clear()
	_label_path = ""


func _payload() -> Dictionary:
	var frames := {}
	var keys: Array = _explicit_records.keys()
	keys.sort()
	for frame_id: int in keys:
		frames[str(frame_id)] = (_explicit_records[frame_id] as Dictionary).duplicate(true)
	return {
		"schema_version": 1,
		"media_id": _media_entry["media_id"],
		"media_type": _media_entry["media_type"],
		"source_relative_path": _media_entry["relative_path"],
		"source_sha256": _media_entry.get("source_sha256"),
		"frame_digits": 6,
		"frames": frames,
	}


func _validate_payload(
	payload: Variant,
	expected_media: Dictionary,
	frame_map: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not payload is Dictionary:
		return PackedStringArray(["$: media label must be a JSON object"])
	for key: Variant in payload:
		if typeof(key) != TYPE_STRING or not TOP_LEVEL_FIELDS.has(key):
			errors.append("%s: additional field is not allowed" % str(key))
	for field: String in TOP_LEVEL_FIELDS:
		if not payload.has(field):
			errors.append("%s: required field is missing" % field)
	if not errors.is_empty():
		return errors
	if payload.get("schema_version") != 1:
		errors.append("schema_version: expected 1")
	if payload.get("frame_digits") != 6:
		errors.append("frame_digits: expected 6")
	for field: String in ["media_id", "media_type", "source_relative_path"]:
		var expected_field := "relative_path" if field == "source_relative_path" else field
		if payload.get(field) != expected_media.get(expected_field):
			errors.append("%s: does not match selected media" % field)
	if payload.get("source_sha256") != expected_media.get("source_sha256"):
		errors.append("source_sha256: does not match selected media")
	var frames: Variant = payload.get("frames")
	if not frames is Dictionary:
		errors.append("frames: expected object")
		return errors
	for key: Variant in frames:
		if typeof(key) != TYPE_STRING or not _is_decimal(key):
			errors.append("frames.%s: expected unpadded decimal frame key" % str(key))
			continue
		var frame_id := int(key)
		if str(frame_id) != key or not frame_map.has(frame_id):
			errors.append("frames.%s: frame is not present in the selected source" % key)
			continue
		for error: String in _validate_record_for_map(
			frame_id, frames[key], expected_media["media_id"], frame_map):
			errors.append("frames.%s.%s" % [key, error])
	return errors


func _validate_record_for_frame(frame_id: int, record: Variant) -> PackedStringArray:
	return _validate_record_for_map(
		frame_id, record, _media_entry.get("media_id", ""), _frame_entries_by_id)


func _validate_record_for_map(
	frame_id: int,
	record: Variant,
	media_id_value: String,
	frame_map: Dictionary
) -> PackedStringArray:
	var errors := _validator.validate_record(record)
	if not frame_map.has(frame_id):
		errors.append("frame: original frame ID %d is not in the source" % frame_id)
	if record is Dictionary:
		if record.get("frame") != frame_id:
			errors.append("frame: record frame must equal original frame ID %d" % frame_id)
		if record.get("source") != media_id_value:
			errors.append("source: record source must equal media ID %s" % media_id_value)
		if frame_map.has(frame_id):
			var expected_time := float((frame_map[frame_id] as Dictionary).get("time_s", frame_id))
			var actual_time: Variant = record.get("time_s")
			if (
				typeof(actual_time) != TYPE_INT
				and typeof(actual_time) != TYPE_FLOAT
			) or not is_finite(float(actual_time)) or absf(float(actual_time) - expected_time) > 0.000001:
				errors.append("time_s: record timestamp must match source frame")
	return errors


func _collect_seed_records(
	seed_records: Variant,
	media_id_value: String,
	frame_map: Dictionary,
	output: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	var values: Array = []
	if seed_records is Array:
		values = seed_records
	elif seed_records is Dictionary:
		values = seed_records.values()
	else:
		return PackedStringArray(["Seed records must be an Array or Dictionary"])
	for position in range(values.size()):
		var record: Variant = values[position]
		if not record is Dictionary or typeof(record.get("frame")) != TYPE_INT:
			errors.append("Seed record %d has no integer frame" % position)
			continue
		var frame_id := int(record["frame"])
		var record_errors := _validate_record_for_map(
			frame_id, record, media_id_value, frame_map)
		for error: String in record_errors:
			errors.append("Seed record %d.%s" % [position, error])
		if record_errors.is_empty():
			output[frame_id] = (record as Dictionary).duplicate(true)
	return errors


func _empty_record(
	media_id_value: String,
	frame_id: int,
	time_s: float
) -> Dictionary:
	return {
		"schema_version": 1,
		"source": media_id_value,
		"frame": frame_id,
		"time_s": time_s,
		"regions": [],
	}


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"value": {},
			"errors": PackedStringArray(["Cannot read media label: %s" % path]),
		}
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	if parse_error != OK or not parser.data is Dictionary:
		return {
			"value": {},
			"errors": PackedStringArray([
				"Media label is malformed: %s (line %d)" % [
					path, parser.get_error_line()]]),
		}
	return {"value": parser.data, "errors": PackedStringArray()}


func _prefix_errors(path: String, errors: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()
	for error: String in errors:
		result.append("%s: %s" % [path, error])
	return result


func _flush_failure(message: String) -> PackedStringArray:
	var errors := PackedStringArray([message])
	save_failed.emit(dirty_frame_ids(), _label_path, message)
	return errors


func _unsafe_relative_path(value: String) -> bool:
	return (
		value.begins_with("/")
		or value.contains("\\")
		or value == ".."
		or value.begins_with("../")
		or value.contains("/../")
	)


func _path_is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


func _is_decimal(value: String) -> bool:
	if value.is_empty():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true
