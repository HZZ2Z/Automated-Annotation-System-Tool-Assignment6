class_name ReviewFramesCommand
extends "res://client/domain/command.gd"

var _frame_ids: Variant
var _verified: bool
var _before: Dictionary = {}
var _after: Dictionary = {}
var _prepared := false

func _init(frame_ids: Variant, verified: bool) -> void:
	_frame_ids = frame_ids.duplicate() if frame_ids is Array or frame_ids is PackedInt64Array or frame_ids is PackedInt32Array else frame_ids
	_verified = verified

func apply(store: Variant) -> PackedStringArray:
	if not _prepared:
		if not (_frame_ids is Array or _frame_ids is PackedInt64Array or _frame_ids is PackedInt32Array) or _frame_ids.is_empty():
			return PackedStringArray(["review: expected nonempty frame IDs"])
		_before = store.snapshot_review_state()
		_after = _before.duplicate(true)
		var seen := {}
		for frame: Variant in _frame_ids:
			if typeof(frame) != TYPE_INT or seen.has(frame) or store.get_corrected_record(frame).is_empty():
				return PackedStringArray(["review: invalid or duplicate frame ID"])
			seen[frame] = true
			if _verified:
				_after[str(frame)] = {"accepted_digest": store.record_digest(frame)}
			else:
				_after.erase(str(frame))
		if _after == _before:
			return PackedStringArray(["review: no changed review state"])
		_prepared = true
	return store.load_workflow_state(_after, store.snapshot_batch_operations())

func revert(store: Variant) -> PackedStringArray:
	if not _prepared:
		return PackedStringArray(["review: command is not prepared"])
	return store.load_workflow_state(_before, store.snapshot_batch_operations())
