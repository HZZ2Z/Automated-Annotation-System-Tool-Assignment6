extends SceneTree


const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const REPLACE_SCRIPT := preload("res://client/domain/commands/replace_frame_command.gd")
const PROPAGATE_SCRIPT := preload("res://client/domain/commands/propagate_range_command.gd")
const TEST_SUPPORT := preload("res://tests/godot/test_support.gd")


class InvalidRevertCommand extends RefCounted:
	func apply(_store) -> PackedStringArray:
		return PackedStringArray()

	func revert(_store) -> bool:
		return true


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var support = TEST_SUPPORT.new()
	_test_failed_frame_undo_preserves_store_and_both_stacks(support)
	_test_failed_frame_apply_and_redo_preserve_store_and_both_stacks(support)
	_test_range_failures_are_atomic(support)
	_test_noop_and_bounded_round_trip(support)
	_test_invalid_revert_contract(support)
	_test_revert_reports_missing_capabilities(support)
	if support.failures.is_empty():
		print("PASS: checked command history")
		quit(0)
		return
	push_error("FAIL: checked command history\n%s" % support.failure_report())
	quit(1)


static func _test_failed_frame_undo_preserves_store_and_both_stacks(support) -> void:
	var store = STORE_SCRIPT.new()
	support.expect(store.load_model_records([_record(0, "original")]).is_empty(), "frame fixture should load")
	var history = HISTORY_SCRIPT.new()
	var first = REPLACE_SCRIPT.new(0, _record(0, "original"), _record(0, "first"))
	var second = REPLACE_SCRIPT.new(0, _record(0, "first"), _record(0, "second"))
	support.expect(history.execute(first, store).is_empty(), "first frame command should apply")
	support.expect(history.execute(second, store).is_empty(), "second frame command should apply")
	support.expect(history.undo(store), "valid frame undo should prepare both history stacks")
	# 损坏保留的恢复快照，触发真实 Store 的 Schema 拒绝路径。
	first.before.regions[0].erase("class")
	store.clear_dirty()
	var digest: String = store.model_digest()
	var changed_frames: Array = []
	store.corrected_records_replaced.connect(func(frames): changed_frames.append(frames))

	support.expect(not history.undo(store), "failed real frame restoration must return false")
	support.expect_equal(store.get_corrected_record(0), _record(0, "first"), "failed real frame restoration must preserve the current record")
	support.expect_equal(history.get_undo_count(), 1, "failed real frame restoration must retain the undo entry")
	support.expect_equal(history.get_redo_count(), 1, "failed real frame restoration must retain the existing redo entry")
	support.expect(store.get_dirty_frames().is_empty(), "failed restoration must not mark frames dirty")
	support.expect(changed_frames.is_empty(), "failed restoration must not emit a replacement signal")
	support.expect_equal(store.model_digest(), digest, "failed restoration must preserve immutable model records")
	if not _has_checked_undo(history, support):
		return
	_expect_errors(history.try_undo(store), "class", "checked frame undo should expose the schema path", support)
	support.expect_equal(history.get_undo_count(), 1, "repeated failed checked undo must retain its source entry")
	support.expect_equal(history.get_redo_count(), 1, "repeated failed checked undo must preserve redo history")
	first.before = _record(0, "original")
	support.expect(history.try_undo(store).is_empty(), "repaired restoration should remain retryable")
	support.expect_equal(store.get_corrected_record(0), _record(0, "original"), "retry should restore the original snapshot")
	support.expect_equal(history.get_undo_count(), 0, "successful checked undo should consume its source entry")
	support.expect_equal(history.get_redo_count(), 2, "successful checked undo should append after the existing redo entry")
	support.expect(history.redo(store).is_empty(), "first retained command should redo")
	support.expect_equal(store.get_corrected_record(0), _record(0, "first"), "redo order should retain the first command")
	support.expect(history.redo(store).is_empty(), "second retained command should redo")
	support.expect_equal(store.get_corrected_record(0), _record(0, "second"), "redo order should retain the second command")
	support.expect_equal(store.model_digest(), digest, "undo and redo retries must preserve immutable model records")


static func _test_failed_frame_apply_and_redo_preserve_store_and_both_stacks(support) -> void:
	var store = STORE_SCRIPT.new()
	store.load_model_records([_record(0, "original")])
	var history = HISTORY_SCRIPT.new()
	history.execute(REPLACE_SCRIPT.new(0, _record(0, "original"), _record(0, "first")), store)
	var second = REPLACE_SCRIPT.new(0, _record(0, "first"), _record(0, "second"))
	history.execute(second, store)
	history.undo(store)
	store.clear_dirty()
	var changed_frames: Array = []
	store.corrected_records_replaced.connect(func(frames): changed_frames.append(frames))
	var invalid := _record(0, "invalid")
	invalid.regions[0].erase("class")
	var failed = REPLACE_SCRIPT.new(0, _record(0, "first"), invalid)
	_expect_errors(history.execute(failed, store), "class", "failed frame apply should expose the schema path", support)
	support.expect_equal(store.get_corrected_record(0), _record(0, "first"), "failed frame apply must preserve the current record")
	support.expect_equal(history.get_undo_count(), 1, "failed frame apply must retain undo history")
	support.expect_equal(history.get_redo_count(), 1, "failed frame apply must retain redo history")
	second.after.regions[0].erase("class")
	_expect_errors(history.redo(store), "class", "failed frame redo should expose the schema path", support)
	support.expect_equal(store.get_corrected_record(0), _record(0, "first"), "failed frame redo must preserve the current record")
	support.expect_equal(history.get_undo_count(), 1, "failed frame redo must retain undo history")
	support.expect_equal(history.get_redo_count(), 1, "failed frame redo must retain its source entry")
	support.expect(store.get_dirty_frames().is_empty(), "failed apply and redo must not mark frames dirty")
	support.expect(changed_frames.is_empty(), "failed apply and redo must not emit replacement signals")
	second.after = _record(0, "second")
	support.expect(history.redo(store).is_empty(), "failed redo should be retryable after its snapshot is repaired")
	support.expect_equal(store.get_corrected_record(0), _record(0, "second"), "redo retry should apply the retained command")


static func _test_range_failures_are_atomic(support) -> void:
	var store = STORE_SCRIPT.new()
	store.load_model_records([_record(0, "source"), _record(1, "one"), _record(2, "two")])
	var digest: String = store.model_digest()
	var history = HISTORY_SCRIPT.new()
	history.execute(REPLACE_SCRIPT.new(0, _record(0, "source"), _record(0, "keyframe")), store)
	var command = PROPAGATE_SCRIPT.new(0, 1, 2, "overwrite")
	support.expect(history.execute(command, store).is_empty(), "range fixture should propagate")
	history.execute(REPLACE_SCRIPT.new(0, _record(0, "keyframe"), _record(0, "later")), store)
	history.undo(store)
	var before: Array = store.snapshot_corrected()
	var operations: Array = store.snapshot_batch_operations()
	# 后一帧无效时，前一帧也不能提前恢复。
	command._before[2].regions[0].erase("class")
	store.clear_dirty()
	var notifications: Array = []
	var on_replaced := func(frames): notifications.append({
		"frames": frames,
		"records": store.snapshot_corrected(),
		"operations": store.snapshot_batch_operations(),
	})
	store.corrected_records_replaced.connect(on_replaced)
	support.expect(not history.undo(store), "failed range restoration must return false")
	support.expect_equal(store.snapshot_corrected(), before, "invalid later frame must refuse the entire range restoration")
	support.expect_equal(store.snapshot_batch_operations(), operations, "failed range restoration must retain operation provenance")
	support.expect_equal(history.get_undo_count(), 2, "failed range restoration must retain all undo entries")
	support.expect_equal(history.get_redo_count(), 1, "failed range restoration must preserve the existing redo entry")
	support.expect(store.get_dirty_frames().is_empty(), "failed range restoration must not mark any frame dirty")
	support.expect(notifications.is_empty(), "failed range restoration must not emit any notification")
	if not _has_checked_undo(history, support):
		store.corrected_records_replaced.disconnect(on_replaced)
		return
	_expect_errors(history.try_undo(store), "replacements.2.regions.0.class", "checked range undo should expose the failing frame and schema path", support)
	command._before[2] = _record(2, "two")
	support.expect(history.try_undo(store).is_empty(), "failed range restoration should remain retryable")
	var restored := [_record(0, "keyframe"), _record(1, "one"), _record(2, "two")]
	support.expect_equal(store.snapshot_corrected(), restored, "range retry should restore every target frame")
	support.expect_equal(store.snapshot_batch_operations(), [], "range retry should restore operation provenance")
	support.expect_equal(notifications, [{"frames": PackedInt64Array([1, 2]), "records": restored, "operations": []}], "range notification should expose the complete restored state")
	var valid_after: Dictionary = command._after[2].duplicate(true)
	command._after[2].regions[0].erase("class")
	store.clear_dirty()
	notifications.clear()
	_expect_errors(history.redo(store), "replacements.2.regions.0.class", "failed range redo should expose the failing frame and schema path", support)
	support.expect_equal(store.snapshot_corrected(), restored, "invalid later frame must refuse the entire range redo")
	support.expect_equal(store.snapshot_batch_operations(), [], "failed range redo must not append operation provenance")
	support.expect_equal(history.get_undo_count(), 1, "failed range redo must retain existing undo history")
	support.expect_equal(history.get_redo_count(), 2, "failed range redo must retain both redo entries")
	support.expect(store.get_dirty_frames().is_empty(), "failed range redo must not mark any frame dirty")
	support.expect(notifications.is_empty(), "failed range redo must not emit any notification")
	command._after[2] = valid_after
	support.expect(history.redo(store).is_empty(), "failed range redo should remain retryable")
	support.expect_equal(store.snapshot_corrected(), before, "range redo retry should reapply every target frame")
	support.expect_equal(store.snapshot_batch_operations(), operations, "range redo retry should reapply operation provenance")
	support.expect(history.redo(store).is_empty(), "redo after range retry should retain the later frame command")
	support.expect_equal(store.get_corrected_record(0), _record(0, "later"), "range failure must not reorder the later redo command")
	support.expect_equal(store.model_digest(), digest, "range apply and restore failures must preserve immutable model records")
	store.corrected_records_replaced.disconnect(on_replaced)


static func _test_noop_and_bounded_round_trip(support) -> void:
	var store = STORE_SCRIPT.new()
	store.load_model_records([_record(0, "original")])
	var history = HISTORY_SCRIPT.new(2)
	for label in ["one", "two", "three"]:
		support.expect(history.execute(REPLACE_SCRIPT.new(0, store.get_corrected_record(0), _record(0, label)), store).is_empty(), "bounded fixture should apply")
	support.expect_equal(history.get_undo_count(), 2, "history capacity should discard only the oldest command")
	support.expect(history.undo(store), "latest bounded command should undo")
	store.clear_dirty()
	var changed_frames: Array = []
	store.corrected_records_replaced.connect(func(frames): changed_frames.append(frames))
	var no_op = REPLACE_SCRIPT.new(0, _record(0, "two"), _record(0, "two"))
	support.expect(history.execute(no_op, store).is_empty(), "no-op frame replacement should succeed")
	support.expect_equal(history.get_undo_count(), 1, "no-op must not consume bounded undo capacity")
	support.expect_equal(history.get_redo_count(), 1, "no-op must retain the redo branch")
	support.expect(store.get_dirty_frames().is_empty(), "no-op must not mark a frame dirty")
	support.expect(changed_frames.is_empty(), "no-op must not emit a replacement signal")
	support.expect(history.undo(store), "remaining bounded command should undo")
	support.expect_equal(store.get_corrected_record(0), _record(0, "one"), "bounded history should stop at the state before its retained commands")
	support.expect(not history.undo(store), "empty history bool wrapper should refuse undo")
	if _has_checked_undo(history, support):
		_expect_errors(history.try_undo(store), "nothing to undo", "empty checked history should explain its refusal", support)
	support.expect(history.redo(store).is_empty(), "first bounded command should redo")
	support.expect_equal(store.get_corrected_record(0), _record(0, "two"), "first bounded redo should restore its saved snapshot")
	support.expect(history.redo(store).is_empty(), "second bounded command should redo")
	support.expect_equal(store.get_corrected_record(0), _record(0, "three"), "second bounded redo should restore its saved snapshot")
	support.expect_equal(history.get_undo_count(), 2, "redo should respect undo capacity")
	support.expect_equal(history.get_redo_count(), 0, "successful redos should consume both source entries")


static func _test_invalid_revert_contract(support) -> void:
	var store = STORE_SCRIPT.new()
	store.load_model_records([_record(0, "original")])
	var history = HISTORY_SCRIPT.new()
	history.execute(InvalidRevertCommand.new(), store)
	if not _has_checked_undo(history, support):
		return
	_expect_errors(history.try_undo(store), "revert must return PackedStringArray", "malformed revert return should explain the command contract", support)
	support.expect_equal(history.get_undo_count(), 1, "malformed revert return must not consume the undo entry")
	support.expect_equal(history.get_redo_count(), 0, "malformed revert return must not create a redo entry")
	support.expect_equal(store.get_corrected_record(0), _record(0, "original"), "malformed revert return must leave unmodified store state intact")


static func _test_revert_reports_missing_capabilities(support) -> void:
	var replacement = REPLACE_SCRIPT.new(0, _record(0, "before"), _record(0, "after"))
	_expect_errors(replacement.call("revert", null), "replace_corrected_record", "frame revert should explain a missing store capability", support)
	var propagation = PROPAGATE_SCRIPT.new(0, 1, 2, "overwrite")
	_expect_errors(propagation.call("revert", STORE_SCRIPT.new()), "not prepared", "unprepared range revert should explain its refusal", support)
	var store = STORE_SCRIPT.new()
	store.load_model_records([_record(0, "source"), _record(1, "one"), _record(2, "two")])
	propagation.apply(store)
	_expect_errors(propagation.call("revert", null), "restore", "range revert should explain a missing atomic restore capability", support)


static func _has_checked_undo(history, support) -> bool:
	var available: bool = history.has_method("try_undo")
	support.expect(available, "history must provide checked try_undo(store)")
	return available


static func _expect_errors(value: Variant, fragment: String, message: String, support) -> void:
	support.expect(value is PackedStringArray, "%s: result must be PackedStringArray" % message)
	if value is PackedStringArray:
		support.expect(" ".join(value).contains(fragment), "%s: expected %s in %s" % [message, fragment, str(value)])


static func _record(frame: int, class_label: String) -> Dictionary:
	return {
		"schema_version": 1,
		"source": "checked-history",
		"frame": frame,
		"regions": [{"id": "region-%d" % frame, "class": class_label, "kind": "instrument", "box": [10, 20, 30, 40]}],
	}
