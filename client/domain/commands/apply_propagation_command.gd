## 提交已经预览过的逐帧候选；此命令不重新推理，也不修改关键帧。
extends "res://client/domain/command.gd"

const POLYGONS := preload("res://client/domain/polygon_ops.gd")

var _key: Dictionary
var _expected: Dictionary
var _before: Dictionary = {}
var _after: Dictionary = {}
var _operation: Dictionary
var _operation_count := -1
var _errors := PackedStringArray()

func _init(key_record: Dictionary, before: Dictionary, after: Dictionary, metadata: Dictionary) -> void:
	_key = key_record.duplicate(true)
	_expected = before.duplicate(true)
	_operation = metadata.duplicate(true)
	if not _key.has("frame") or before.is_empty() or before.keys().size() != after.keys().size():
		_errors.append("Poly preview: incomplete frame snapshots")
		return
	for frame: Variant in before:
		if typeof(frame) != TYPE_INT or frame == _key.frame or not after.has(frame) or not before[frame] is Dictionary or not after[frame] is Dictionary:
			_errors.append("Poly preview: invalid target frame")
			continue
		var old_identity: Dictionary = before[frame].duplicate()
		var new_identity: Dictionary = after[frame].duplicate()
		old_identity.erase("regions")
		new_identity.erase("regions")
		if old_identity != new_identity or old_identity.get("frame") != frame or old_identity.get("source") != _key.get("source"):
			_errors.append("Poly preview: frame/source/time identity changed")
			continue
		if not after[frame].get("regions") is Array:
			_errors.append("Poly preview: missing regions")
			continue
		for region: Variant in after[frame].regions:
			if not region is Dictionary:
				_errors.append("Poly preview: invalid region")
			elif region.has("polygon") and region not in before[frame].get("regions", []):
				if not region.polygon is Array or region.polygon.size() > 2048 or not POLYGONS.validate_simple_polygon(region.polygon):
					_errors.append("Poly preview: polygon must be one simple nondegenerate ring")
		if before[frame] != after[frame]:
			_before[frame] = before[frame].duplicate(true)
			_after[frame] = after[frame].duplicate(true)
	if _after.is_empty():
		_errors.append("Annotations already match; no batch was created")
	_operation.merge({"schema_version": 1, "type": "range_propagate", "mode": "merge",
		"keyframe": _key.get("frame", -1), "affected_frames": _after.keys(),
		"changed_count": _after.size(), "created_at": Time.get_datetime_string_from_system(true)}, true)

func apply(store: Variant) -> PackedStringArray:
	if not _errors.is_empty():
		return _errors.duplicate()
	if store.get_corrected_record(int(_key.frame)) != _key:
		return PackedStringArray(["Keyframe changed; analyze again"])
	for frame: int in _expected:
		if store.get_corrected_record(frame) != _expected[frame]:
			return PackedStringArray(["Target changed; analyze again"])
		if store.is_verified(frame):
			return PackedStringArray(["Poly preview: verified target is protected"])
	var current_operations: int = store.snapshot_batch_operations().size()
	if _operation_count >= 0 and current_operations != _operation_count:
		return PackedStringArray(["Poly preview: batch history changed"])
	_operation["keyframe_digest"] = store.record_digest(int(_key.frame))
	var errors: PackedStringArray = store.replace_corrected_records(_after, _operation)
	if errors.is_empty():
		_operation_count = current_operations
	return errors

func revert(store: Variant) -> PackedStringArray:
	if _operation_count < 0:
		return PackedStringArray(["Poly preview: command has not been applied"])
	for frame: int in _after:
		if store.get_corrected_record(frame) != _after[frame]:
			return PackedStringArray(["Poly preview: result changed before undo"])
	var operations: Array = store.snapshot_batch_operations()
	if operations.size() != _operation_count + 1 or operations[-1] != _operation:
		return PackedStringArray(["Poly preview: batch history changed before undo"])
	return store.restore_corrected_records(_before, _operation_count)
