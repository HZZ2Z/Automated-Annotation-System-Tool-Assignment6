class_name ReplaceFrameCommand
extends "res://client/domain/command.gd"


var frame: int
var before: Dictionary
var after: Dictionary
var _construction_errors := PackedStringArray()


func _init(frame_index: int, old_record: Dictionary, new_record: Dictionary) -> void:
	frame = frame_index
	before = old_record.duplicate(true)
	after = new_record.duplicate(true)


func apply(store: Variant) -> PackedStringArray:
	if not _construction_errors.is_empty():
		return _construction_errors.duplicate()
	if not store is Object or not store.has_method("replace_corrected_record"):
		return PackedStringArray(["command: store must provide replace_corrected_record(frame, record)"])
	return store.replace_corrected_record(frame, after.duplicate(true))


func is_noop() -> bool:
	# A rejected constructor often leaves `after == before`; it is still an
	# invalid command and must surface its explanatory error instead of being
	# mistaken for a successful no-op.
	return _construction_errors.is_empty() and before == after


func revert(store: Variant) -> void:
	if store is Object and store.has_method("replace_corrected_record"):
		store.replace_corrected_record(frame, before.duplicate(true))


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
