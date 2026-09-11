## 提交已经预览过的逐帧候选；此命令不重新推理，也不修改关键帧。
extends "res://client/domain/command.gd"

const POLYGONS := preload("res://client/domain/polygon_ops.gd")

var _key: Dictionary
var _expected: Dictionary
var _before: Dictionary = {}
var _after: Dictionary = {}
var _operation: Dictionary
var _operation_count := -1
var _review_before: Dictionary = {}
var _review_after: Dictionary = {}
var _operations_before: Array = []
var _operations_after: Array = []
var _errors := PackedStringArray()
var _initial_preconditions := false

func _init(key_record: Dictionary, before: Dictionary, after: Dictionary, metadata: Dictionary) -> void:
	_key = key_record.duplicate(true)
	_expected = before.duplicate(true)
	_operation = metadata.duplicate(true)
	var schema: Variant = _operation.get("schema_version")
	if typeof(schema) != TYPE_INT or schema not in [1, 2, 3]:
		_errors.append("Batch preview: explicit schema_version 1, 2 or 3 is required")
	_initial_preconditions = _operation.get("expected_review_state") is Dictionary and _operation.get("expected_batch_operations") is Array
	if _initial_preconditions:
		_review_before = _operation.expected_review_state.duplicate(true)
		_operations_before = _operation.expected_batch_operations.duplicate(true)
	_operation.erase("expected_review_state")
	_operation.erase("expected_batch_operations")
	if schema == 3 and not _initial_preconditions:
		_errors.append("Batch preview: SAM requires review and batch history snapshots")
	if not _key.has("frame") or before.is_empty() or before.keys().size() != after.keys().size():
		_errors.append("Batch preview: incomplete frame snapshots")
		return
	for frame: Variant in before:
		if typeof(frame) != TYPE_INT or frame == _key.frame or not after.has(frame) or not before[frame] is Dictionary or not after[frame] is Dictionary:
			_errors.append("Batch preview: invalid target frame")
			continue
		var old_identity: Dictionary = before[frame].duplicate()
		var new_identity: Dictionary = after[frame].duplicate()
		old_identity.erase("regions")
		new_identity.erase("regions")
		if old_identity != new_identity or old_identity.get("frame") != frame or old_identity.get("source") != _key.get("source"):
			_errors.append("Batch preview: frame/source/time identity changed")
			continue
		if not after[frame].get("regions") is Array:
			_errors.append("Batch preview: missing regions")
			continue
		for region: Variant in after[frame].regions:
			if not region is Dictionary:
				_errors.append("Batch preview: invalid region")
			elif region.has("polygon") and region not in before[frame].get("regions", []):
				if not region.polygon is Array or region.polygon.size() > 2048 or not POLYGONS.validate_simple_polygon(region.polygon):
					_errors.append("Batch preview: polygon must be one simple nondegenerate ring")
		# v3 确认的是完整生成前缀；字节相同的目标仍需写入审核摘要和原子历史。
		if schema == 3 or before[frame] != after[frame]:
			_before[frame] = before[frame].duplicate(true)
			_after[frame] = after[frame].duplicate(true)
	if schema != 3 and _after.is_empty():
		_errors.append("Annotations already match; no batch was created")
	var mode: Variant = _operation.get("mode")
	if mode not in ["overwrite", "merge"]:
		_errors.append("Batch preview: invalid apply mode")
	var affected: Array = _after.keys()
	affected.sort()
	if schema == 3:
		if mode != "merge" or _operation.get("keyframe") != _key.get("frame") or not _same_sam_targets(_operation.get("affected_frames")) or _operation.get("generated_count") != _after.size() or _after.size() != before.size():
			_errors.append("Batch preview: SAM audit must match every generated target in region merge mode")
		for frame: int in _after:
			if not _valid_sam_region_change(_before[frame], _after[frame]):
				_errors.append("Batch preview: SAM may only replace selected geometry or append its key metadata")
	else:
		_operation.merge({"type": "range_propagate", "mode": mode,
			"keyframe": _key.get("frame", -1), "affected_frames": affected,
			"changed_count": _after.size()}, true)
	if schema != 3 and not _operation.has("created_at"):
		_operation["created_at"] = Time.get_datetime_string_from_system(true)

func apply(store: Variant) -> PackedStringArray:
	if not _errors.is_empty():
		return _errors.duplicate()
	if store.get_corrected_record(int(_key.frame)) != _key:
		return PackedStringArray(["Keyframe changed; analyze again"])
	for frame: int in _expected:
		if store.get_corrected_record(frame) != _expected[frame]:
			return PackedStringArray(["Target changed; analyze again"])
		if store.is_verified(frame):
			return PackedStringArray(["Batch preview: verified target is protected"])
	var current_operations: Array = store.snapshot_batch_operations()
	if _operation_count >= 0 or _initial_preconditions:
		if current_operations != _operations_before:
			return PackedStringArray(["Batch preview: batch history changed"])
		if store.snapshot_review_state() != _review_before:
			return PackedStringArray(["Batch preview: review state changed"])
	if _operation.get("schema_version") == 3:
		if _operation.get("keyframe_digest") != store.record_digest(int(_key.frame)):
			return PackedStringArray(["Batch preview: keyframe digest changed"])
	else:
		_operation["keyframe_digest"] = store.record_digest(int(_key.frame))
	var affected: Array = _after.keys()
	affected.sort()
	var review_before: Dictionary = store.snapshot_review_state()
	var errors: PackedStringArray = store.replace_corrected_records_with_reviews(_after, _operation, affected)
	if errors.is_empty():
		if _operation_count < 0:
			_operation_count = current_operations.size()
			_review_before = review_before
			_operations_before = current_operations
		_review_after = store.snapshot_review_state()
		_operations_after = store.snapshot_batch_operations()
	return errors

func revert(store: Variant) -> PackedStringArray:
	if _operation_count < 0:
		return PackedStringArray(["Batch preview: command has not been applied"])
	if store.get_corrected_record(int(_key.frame)) != _key:
		return PackedStringArray(["Batch preview: keyframe changed before undo"])
	for frame: int in _after:
		if store.get_corrected_record(frame) != _after[frame]:
			return PackedStringArray(["Batch preview: result changed before undo"])
	if store.snapshot_review_state() != _review_after:
		return PackedStringArray(["Batch preview: review state changed before undo"])
	var operations: Array = store.snapshot_batch_operations()
	if operations != _operations_after:
		return PackedStringArray(["Batch preview: batch history changed before undo"])
	return store.restore_corrected_records_with_reviews(_before, _operation_count, _review_before)

func _same_sam_targets(affected: Variant) -> bool:
	if not affected is Array or affected.size() != _after.size(): return false
	var seen := {}
	for frame: Variant in affected:
		if typeof(frame) != TYPE_INT or not _after.has(frame) or seen.has(frame): return false
		seen[frame] = true
	return true

func _valid_sam_region_change(before: Dictionary, after: Dictionary) -> bool:
	var region_id: Variant = _operation.get("region_id")
	var anchor := {}
	if not _key.get("regions") is Array or not before.get("regions") is Array: return false
	for region: Variant in _key.regions:
		if not region is Dictionary: return false
		if region.get("id") == region_id:
			if not anchor.is_empty(): return false
			anchor = region
	if anchor.is_empty() or anchor.has("box") == anchor.has("polygon"): return false
	var expected: Array = before.get("regions", []).duplicate(true)
	var selected := -1
	for index in range(expected.size()):
		if not expected[index] is Dictionary: return false
		if expected[index].get("id") == region_id:
			if selected >= 0: return false
			selected = index
	var shell := {}
	if selected >= 0:
		shell = expected[selected].duplicate(true)
	else:
		shell = anchor.duplicate(true)
		selected = expected.size()
	var actual: Array = after.get("regions", [])
	if selected >= actual.size() or not actual[selected] is Dictionary or not actual[selected].get("polygon") is Array: return false
	shell.erase("box")
	shell["polygon"] = actual[selected].polygon.duplicate(true)
	if selected < expected.size(): expected[selected] = shell
	else: expected.append(shell)
	return expected == actual
