extends RefCounted

class RejectingLabelStore extends "res://client/workspace/media_label_store.gd":
	var reject_records := false
	var reject_metadata := false
	func replace_record(frame_id: int, record: Variant) -> PackedStringArray:
		if reject_records:
			return PackedStringArray(["injected ingestion rejection"])
		return super.replace_record(frame_id, record)
	func replace_workflow_state(reviews: Variant, operations: Variant) -> PackedStringArray:
		if reject_metadata:
			return PackedStringArray(["injected metadata rejection"])
		return super.replace_workflow_state(reviews, operations)

func run(support) -> void:
	var root := "/tmp/batch-recovery-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(root)
	var media := {"media_id": "clip", "media_type": "image_sequence", "relative_path": "clip", "source_sha256": null}
	var entries := [{"frame_id": 0, "time_s": 0.0}, {"frame_id": 1, "time_s": 1.0}]
	var records := []
	for frame in range(2):
		records.append({"schema_version": 1, "source": "clip", "frame": frame, "time_s": float(frame), "regions": [{"id": "r", "kind": "instrument", "class": "tool", "box": [frame, 0, 10, 10]}]})
	var label := RejectingLabelStore.new()
	support.expect_equal(label.prepare(root, media, entries, records), PackedStringArray(), "recovery fixture prepares")
	support.expect_equal(label.flush(), PackedStringArray(), "baseline persisted")
	var store = load("res://client/domain/annotation_store.gd").new()
	store.load_model_records(records)
	var session = load("res://client/workspace/workspace_session.gd").new()
	session.bind(store, label, Callable(), Callable())
	label.reject_records = true
	var edited: Dictionary = store.get_corrected_record(0)
	edited.regions[0].box[0] = 4
	support.expect_equal(store.replace_corrected_record(0, edited), PackedStringArray(), "authoritative edit accepted")
	support.expect(not session.can_replace_context(), "ingestion failure blocks replacement")
	support.expect(not session.retry_unsaved().is_empty(), "retry cannot forget rejected ingestion")
	support.expect(not session.can_replace_context(), "still rejected remains blocked")
	label.reject_records = false
	support.expect_equal(session.retry_unsaved(), PackedStringArray(), "ingestion retry replays authoritative content")
	var reopened = load("res://client/workspace/media_label_store.gd").new()
	reopened.prepare(root, media, entries)
	support.expect_equal(reopened.record_for_frame(0).regions[0].box[0], edited.regions[0].box[0], "retried record persisted")
	label.reject_metadata = true
	var review = load("res://client/domain/commands/review_frames_command.gd").new([0], true)
	support.expect_equal(review.apply(store), PackedStringArray(), "authoritative review accepted")
	support.expect(not session.retry_unsaved().is_empty(), "retry cannot forget rejected metadata")
	support.expect(not session.can_replace_context(), "metadata ingestion failure remains blocked")
	label.reject_metadata = false
	support.expect_equal(session.retry_unsaved(), PackedStringArray(), "metadata ingestion retries")
	reopened.prepare(root, media, entries)
	support.expect_equal(reopened.workflow_state().review_state, store.snapshot_review_state(), "retried review persisted")
	# Editing tools add transient fill display state. Persist only Model Output V1.
	edited.regions[0]["filled"] = true
	edited.regions[0].box[0] = 8
	support.expect_equal(store.replace_corrected_record(0, edited), PackedStringArray(), "filled edit accepted")
	var propagate = load("res://client/domain/commands/propagate_range_command.gd").new(0, 0, 1, "overwrite")
	support.expect_equal(propagate.apply(store), PackedStringArray(), "filled propagation accepted")
	support.expect_equal(session.flush_before_context_change(), PackedStringArray(), "filled edits and batch save")
	support.expect(session.can_replace_context(), "filled data fully persisted")
	reopened.prepare(root, media, entries)
	support.expect_equal(reopened.record_for_frame(0).regions[0].box[0], 8, "filled edit geometry persisted")
	support.expect_equal(reopened.record_for_frame(1).regions[0].box[0], 8, "filled propagation geometry persisted")
	support.expect(not reopened.record_for_frame(1).regions[0].has("filled"), "filled never enters V1 persisted records")
	support.expect_equal(reopened.workflow_state().batch_operations.size(), 1, "filled propagation marker persisted")
	session.unbind()
	session.free()
