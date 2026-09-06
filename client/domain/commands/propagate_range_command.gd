class_name PropagateRangeCommand
extends "res://client/domain/command.gd"


var keyframe: Variant
var start_frame: Variant
var end_frame: Variant
var mode: String

var _before: Dictionary = {}
var _after: Dictionary = {}
var _operation: Dictionary = {}
var _operation_count_before := 0
var _prepared := false


func _init(keyframe_value: Variant, start_value: Variant, end_value: Variant, propagation_mode: String) -> void:
	keyframe = keyframe_value
	start_frame = start_value
	end_frame = end_value
	mode = propagation_mode


func apply(store: Variant) -> PackedStringArray:
	if not store is Object or not store.has_method("replace_corrected_records"):
		return PackedStringArray(["command: store must provide atomic range replacement"])
	if not _prepared:
		var preparation_errors := _prepare(store)
		if not preparation_errors.is_empty():
			return preparation_errors
	return store.replace_corrected_records(_after.duplicate(true), _operation.duplicate(true))


func revert(store: Variant) -> PackedStringArray:
	if not _prepared:
		return PackedStringArray(["command: range propagation is not prepared"])
	if not store is Object or not store.has_method("restore_corrected_records"):
		return PackedStringArray(["command: store must provide atomic range restore_corrected_records"])
	return store.restore_corrected_records(_before.duplicate(true), _operation_count_before)


func _prepare(store: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _is_logical_integer(keyframe) or not _is_logical_integer(start_frame) or not _is_logical_integer(end_frame):
		return PackedStringArray(["range: keyframe, start_frame, and end_frame must be integers"])
	var source_frame := int(keyframe)
	var first := int(start_frame)
	var last := int(end_frame)
	if source_frame < 0 or first < 0 or last < first:
		return PackedStringArray(["range: expected non-negative keyframe and start_frame <= end_frame"])
	if mode not in ["overwrite", "merge"]:
		return PackedStringArray(["range.mode: expected overwrite or merge"])
	var source: Dictionary = store.get_corrected_record(source_frame)
	if source.is_empty():
		return PackedStringArray(["range.keyframe: frame %d does not exist" % source_frame])
	var source_regions: Variant = source.get("regions")
	if not source_regions is Array:
		return PackedStringArray(["range.keyframe: regions must be an Array"])
	var affected: Array[int] = []
	for frame in range(first, last + 1):
		if frame == source_frame:
			continue
		var target: Dictionary = store.get_corrected_record(frame)
		if target.is_empty():
			errors.append("range: target frame %d does not exist" % frame)
			continue
		_before[frame] = target.duplicate(true)
		var corrected := target.duplicate(true)
		corrected["regions"] = source_regions.duplicate(true) if mode == "overwrite" else _merge_regions(target.get("regions", []), source_regions)
		_after[frame] = corrected
		affected.append(frame)
	if not errors.is_empty():
		_before.clear()
		_after.clear()
		return errors
	if affected.is_empty():
		return PackedStringArray(["range: no target frames selected"])
	_operation_count_before = store.snapshot_batch_operations().size() if store.has_method("snapshot_batch_operations") else 0
	_operation = {
		"schema_version": 1,
		"type": "range_propagate",
		"keyframe": source_frame,
		"start_frame": first,
		"end_frame": last,
		"mode": mode,
		"affected_frames": affected,
	}
	_prepared = true
	return errors


func _merge_regions(target_value: Variant, source_regions: Array) -> Array:
	var result: Array = target_value.duplicate(true) if target_value is Array else []
	var positions := {}
	for index in range(result.size()):
		var region: Variant = result[index]
		if region is Dictionary:
			positions[str(region.get("id", ""))] = index
	for source_value: Variant in source_regions:
		var source_region: Dictionary = source_value.duplicate(true)
		var region_id := str(source_region.get("id", ""))
		if positions.has(region_id):
			result[int(positions[region_id])] = source_region
		else:
			positions[region_id] = result.size()
			result.append(source_region)
	return result


func _is_logical_integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) == floorf(float(value))
