class_name ReplaceFrameCommand
extends "res://client/domain/command.gd"


var frame: int
var before: Dictionary
var after: Dictionary
var _construction_errors := PackedStringArray()
var _review_mode_initialized := false
var _auto_review := false
var _review_before: Dictionary = {}
var _review_after: Dictionary = {}
var _review_operations: Array = []


func _init(frame_index: int, old_record: Dictionary, new_record: Dictionary) -> void:
	frame = frame_index
	before = old_record.duplicate(true)
	after = new_record.duplicate(true)


func apply(store: Variant) -> PackedStringArray:
	if not _construction_errors.is_empty():
		return _construction_errors.duplicate()
	if not store is Object or not store.has_method("replace_corrected_record"):
		return PackedStringArray(["command: store must provide replace_corrected_record(frame, record)"])
	if not _review_mode_initialized:
		_review_mode_initialized = true
		_auto_review = store.has_method("sam_auto_review_enabled") \
			and store.sam_auto_review_enabled(frame)
		if _auto_review:
			if not store.has_method("replace_corrected_record_with_review_state") \
					or not store.has_method("record_value_digest"):
				return PackedStringArray(["reviewed edit: Store is missing atomic review support"])
			_review_before = store.snapshot_review_state()
			_review_operations = store.snapshot_batch_operations()
			_review_after = _review_before.duplicate(true)
			_review_after[str(frame)] = {"accepted_digest": store.record_value_digest(after)}
	if _auto_review:
		return store.replace_corrected_record_with_review_state(
			frame, after.duplicate(true), _review_before, _review_after, _review_operations)
	return store.replace_corrected_record(frame, after.duplicate(true))


func is_noop() -> bool:
	# A rejected constructor often leaves `after == before`; it is still an
	# invalid command and must surface its explanatory error instead of being
	# mistaken for a successful no-op.
	return _construction_errors.is_empty() and before == after


func revert(store: Variant) -> PackedStringArray:
	if not store is Object or not store.has_method("replace_corrected_record"):
		return PackedStringArray(["command: store must provide replace_corrected_record(frame, record)"])
	if _auto_review:
		return store.replace_corrected_record_with_review_state(
			frame, before.duplicate(true), _review_after, _review_before, _review_operations)
	return store.replace_corrected_record(frame, before.duplicate(true))


func _reject(message: String) -> void:
	_construction_errors.append(message)


func _find_region_index(record: Dictionary, region_id: String) -> int:
	var regions: Variant = record.get("regions")
	if not regions is Array:
		return -1
	for index in range(regions.size()):
		var region: Variant = regions[index]
		if region is Dictionary and region.get("id") == region_id:
			return index
	return -1
