class_name AnnotationStore
extends RefCounted


const VALIDATOR_SCRIPT := preload("res://client/domain/annotation_validator.gd")

var _model_records: Dictionary = {}
var _corrected_records: Dictionary = {}
var _dirty_frames: Dictionary = {}
var _validator = VALIDATOR_SCRIPT.new()


func load_model_records(records: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not records is Array:
		errors.append("$: expected array of annotation records")
		return errors
	var next_model := {}
	var seen_frames := {}
	for index in range(records.size()):
		var record: Variant = records[index]
		var record_errors: PackedStringArray = _validator.validate_record(record)
		for error in record_errors:
			errors.append(_prefix_record_error(index, error))
		if not record is Dictionary:
			continue
		var source: Variant = record.get("source")
		if typeof(source) == TYPE_STRING and source == "human_corrected":
			errors.append("records.%d.source: model load requires model_output_vN" % index)
		var frame_value: Variant = record.get("frame")
		if _is_logical_integer(frame_value) and frame_value >= 0:
			var frame := int(frame_value)
			if seen_frames.has(frame):
				errors.append("records.%d.frame: duplicate frame %d" % [index, frame])
			else:
				seen_frames[frame] = true
			if record_errors.is_empty() and typeof(source) == TYPE_STRING and source != "human_corrected":
				next_model[frame] = record.duplicate(true)
	if not errors.is_empty():
		return errors
	_model_records = next_model
	_corrected_records = next_model.duplicate(true)
	_dirty_frames.clear()
	return errors


func get_model_record(frame: int) -> Dictionary:
	var record: Variant = _model_records.get(frame)
	if not record is Dictionary:
		return {}
	return record.duplicate(true)


func get_corrected_record(frame: int) -> Dictionary:
	var record: Variant = _corrected_records.get(frame)
	if not record is Dictionary:
		return {}
	return record.duplicate(true)


func replace_corrected_record(frame: int, record: Variant) -> PackedStringArray:
	var errors: PackedStringArray = _validator.validate_record(record)
	if not _corrected_records.has(frame):
		errors.append("frame: frame %d does not exist" % frame)
	if record is Dictionary:
		var record_frame: Variant = record.get("frame")
		if not _is_logical_integer(record_frame) or int(record_frame) != frame:
			errors.append("frame: record frame must match key %d" % frame)
	if not errors.is_empty():
		return errors
	_corrected_records[frame] = record.duplicate(true)
	_dirty_frames[frame] = true
	return errors


func get_frame_count() -> int:
	return _model_records.size()


func get_dirty_frames() -> PackedInt64Array:
	var frames: Array = _dirty_frames.keys()
	frames.sort()
	var result := PackedInt64Array()
	for frame: int in frames:
		result.append(frame)
	return result


func clear_dirty() -> void:
	_dirty_frames.clear()


func snapshot_corrected() -> Array:
	var snapshot := _sorted_record_copies(_corrected_records)
	for record: Dictionary in snapshot:
		record["source"] = "human_corrected"
	return snapshot


func model_digest() -> String:
	var canonical_records: Array = _canonicalize(_sorted_record_copies(_model_records))
	return JSON.stringify(canonical_records).sha256_text()


func _sorted_record_copies(records: Dictionary) -> Array:
	var frames: Array = records.keys()
	frames.sort()
	var result: Array = []
	for frame: int in frames:
		result.append(records[frame].duplicate(true))
	return result


func _canonicalize(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var result := {}
		for key: Variant in keys:
			result[key] = _canonicalize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_canonicalize(item))
		return result
	return value


func _prefix_record_error(index: int, error: String) -> String:
	if error.begins_with("$:"):
		return "records.%d:%s" % [index, error.substr(2)]
	return "records.%d.%s" % [index, error]


func _is_logical_integer(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value)) and float(value) == floorf(float(value))
