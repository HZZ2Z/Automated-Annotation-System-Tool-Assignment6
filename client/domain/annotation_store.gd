class_name AnnotationStore
extends RefCounted


signal corrected_records_replaced(frames: PackedInt64Array)


const VALIDATOR_SCRIPT := preload("res://client/domain/model_output_validator.gd")

var _model_records: Dictionary = {}
var _corrected_records: Dictionary = {}
var _dirty_frames: Dictionary = {}
var _batch_operations: Array[Dictionary] = []
var _validator = VALIDATOR_SCRIPT.new()


func load_model_records(records: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not records is Array:
		errors.append("$: expected array of model output records")
		return errors
	var next_model := {}
	var seen_frames := {}
	for index in range(records.size()):
		var record: Variant = records[index]
		var record_errors: PackedStringArray = _validator.validate_record(record)
		for error: String in record_errors:
			errors.append(_prefix_record_error(index, error))
		if not record is Dictionary:
			continue
		var frame_value: Variant = record.get("frame")
		if _is_logical_integer(frame_value) and frame_value >= 0:
			var frame := int(frame_value)
			if seen_frames.has(frame):
				errors.append("records.%d.frame: duplicate frame %d" % [index, frame])
			else:
				seen_frames[frame] = true
			if record_errors.is_empty() and not next_model.has(frame):
				next_model[frame] = record.duplicate(true)
	if not errors.is_empty():
		return errors
	_model_records = next_model
	_corrected_records = next_model.duplicate(true)
	_dirty_frames.clear()
	_batch_operations.clear()
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


func _model_output_projection(record: Variant) -> Variant:
	if not record is Dictionary:
		return record
	var result: Dictionary = record.duplicate(true)
	var regions: Variant = result.get("regions")
	if regions is Array:
		for value: Variant in regions:
			if value is Dictionary:
				value.erase("filled")
	return result


func replace_corrected_record(frame: int, record: Variant) -> PackedStringArray:
	var errors := _validate_replacement(frame, record)
	if not errors.is_empty():
		return errors
	_corrected_records[frame] = record.duplicate(true)
	_dirty_frames[frame] = true
	corrected_records_replaced.emit(PackedInt64Array([frame]))
	return errors


func replace_corrected_records(replacements: Dictionary, operation: Dictionary = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	if replacements.is_empty():
		return PackedStringArray(["replacements: expected at least one frame"])
	var frames: Array[int] = []
	for frame_value: Variant in replacements:
		if not _is_logical_integer(frame_value):
			errors.append("replacements.%s: frame key must be an integer" % str(frame_value))
		else:
			frames.append(int(frame_value))
	if not errors.is_empty():
		return errors
	frames.sort()
	for frame: int in frames:
		for error: String in _validate_replacement(frame, replacements[frame]):
			errors.append("replacements.%d.%s" % [frame, error])
	if not errors.is_empty():
		return errors
	for frame: int in frames:
		_corrected_records[frame] = (replacements[frame] as Dictionary).duplicate(true)
		_dirty_frames[frame] = true
	if not operation.is_empty():
		_batch_operations.append(operation.duplicate(true))
	corrected_records_replaced.emit(PackedInt64Array(frames))
	return errors


func restore_corrected_records(replacements: Dictionary, operation_count: int) -> void:
	var errors := replace_corrected_records(replacements)
	if not errors.is_empty():
		return
	_batch_operations.resize(clampi(operation_count, 0, _batch_operations.size()))


func snapshot_batch_operations() -> Array:
	return _batch_operations.duplicate(true)


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
	var result: Array = []
	for record: Dictionary in _sorted_record_copies(_corrected_records):
		result.append(_model_output_projection(record))
	return result


func model_digest() -> String:
	var canonical_records: Array = _canonicalize(_sorted_record_copies(_model_records))
	return JSON.stringify(canonical_records).sha256_text()


func _validate_replacement(frame: int, record: Variant) -> PackedStringArray:
	var errors: PackedStringArray = _validator.validate_record(_model_output_projection(record))
	if not _corrected_records.has(frame):
		errors.append("frame: frame %d does not exist" % frame)
	if record is Dictionary:
		var record_frame: Variant = record.get("frame")
		if not _is_logical_integer(record_frame) or int(record_frame) != frame:
			errors.append("frame: record frame must match key %d" % frame)
	return errors


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
