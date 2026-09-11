extends RefCounted

class RejectingWriter extends RefCounted:
	var reject_records := false
	var reject_metadata := false
	var repository = preload("res://client/workspace/session_repository.gd").new()
	func write(snapshot: Dictionary, options: Dictionary, token: Variant) -> Dictionary:
		if reject_records or reject_metadata:
			return {"success":false,"errors":["injected persistence rejection"],"session_id":snapshot.session_id,"revision":snapshot.revision}
		return repository.save_snapshot(snapshot,options,token)

func run(support) -> void:
	var root := "/tmp/batch-recovery-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(root)
	var media := {"media_id": "clip", "media_type": "image_sequence", "relative_path": "clip", "source_sha256": null}
	var entries := [{"frame_id": 0, "time_s": 0.0}, {"frame_id": 1, "time_s": 1.0}]
	var records := []
	for frame in range(2):
		records.append({"schema_version": 1, "source": "clip", "frame": frame, "time_s": float(frame), "regions": [{"id": "r", "kind": "instrument", "class": "tool", "box": [frame, 0, 10, 10]}]})
	var label = load("res://client/workspace/media_label_store.gd").new()
	var writer := RejectingWriter.new()
	support.expect_equal(label.prepare(root, media, entries, records), PackedStringArray(), "recovery fixture prepares")
	support.expect_equal(label.flush(), PackedStringArray(), "baseline persisted")
	var store = load("res://client/domain/annotation_store.gd").new()
	store.load_model_records(records)
	var session = load("res://client/workspace/workspace_session.gd").new()
	Engine.get_main_loop().root.add_child(session)
	session.set_save_worker(Callable(writer,"write"))
	session.bind(store, label, Callable(), Callable())
	writer.reject_records = true
	var edited: Dictionary = store.get_corrected_record(0)
	edited.regions[0].box[0] = 4
	support.expect_equal(store.replace_corrected_record(0, edited), PackedStringArray(), "authoritative edit accepted")
	support.expect(not session.can_replace_context(), "ingestion failure blocks replacement")
	support.expect(not (await session.retry_unsaved()).is_empty(), "retry cannot forget rejected ingestion")
	support.expect(not session.can_replace_context(), "still rejected remains blocked")
	writer.reject_records = false
	support.expect_equal(await session.retry_unsaved(), PackedStringArray(), "ingestion retry replays authoritative content")
	var reopened = load("res://client/workspace/media_label_store.gd").new()
	reopened.prepare(root, media, entries)
	support.expect_equal(reopened.record_for_frame(0).regions[0].box[0], edited.regions[0].box[0], "retried record persisted")
	writer.reject_metadata = true
	var review = load("res://client/domain/commands/review_frames_command.gd").new([0], true)
	support.expect_equal(review.apply(store), PackedStringArray(), "authoritative review accepted")
	support.expect(not (await session.retry_unsaved()).is_empty(), "retry cannot forget rejected metadata")
	support.expect(not session.can_replace_context(), "metadata ingestion failure remains blocked")
	writer.reject_metadata = false
	support.expect_equal(await session.retry_unsaved(), PackedStringArray(), "metadata ingestion retries")
	reopened.prepare(root, media, entries)
	support.expect_equal(reopened.workflow_state().review_state, store.snapshot_review_state(), "retried review persisted")
	# Editing tools add transient fill display state. Persist only Model Output V1.
	edited.regions[0]["filled"] = true
	edited.regions[0].box[0] = 8
	support.expect_equal(store.replace_corrected_record(0, edited), PackedStringArray(), "filled edit accepted")
	var propagate = load("res://client/domain/commands/propagate_range_command.gd").new(0, 0, 1, "overwrite")
	support.expect_equal(propagate.apply(store), PackedStringArray(), "filled propagation accepted")
	support.expect_equal(await session.flush_before_context_change(), PackedStringArray(), "filled edits and batch save")
	support.expect(session.can_replace_context(), "filled data fully persisted")
	reopened.prepare(root, media, entries)
	support.expect_equal(reopened.record_for_frame(0).regions[0].box[0], 8, "filled edit geometry persisted")
	support.expect_equal(reopened.record_for_frame(1).regions[0].box[0], 8, "filled propagation geometry persisted")
	support.expect(not reopened.record_for_frame(1).regions[0].has("filled"), "filled never enters V1 persisted records")
	support.expect_equal(reopened.workflow_state().batch_operations.size(), 1, "filled propagation marker persisted")
	# 同一持久化管线必须在写失败后保留完整 v3 记录、审核和历史，再一次恢复保存。
	var target_before: Dictionary = store.get_corrected_record(1)
	var target_after: Dictionary = target_before.duplicate(true)
	target_after.regions[0].erase("box")
	target_after.regions[0]["polygon"] = [[9,0],[19,0],[19,10],[9,10]]
	var marker := {"schema_version":3,"type":"range_propagate","mode":"merge","provider_id":"sam_video","metric_id":"sam-video-v1",
		"keyframe":0,"keyframe_playback_index":0,"keyframe_digest":store.record_digest(0),"region_id":"r","direction":"forward",
		"requested_count":1,"generated_count":1,"start_frame":0,"end_frame":1,"affected_frames":[1],"target_playback_indices":[1],
		"stop_frame":null,"stop_reason":"","checkpoint_sha256":"b".repeat(64),"device":"cpu","model_version":"1.1.0","elapsed_ms":23,
		"risk_summary":[],"created_at":"2026-09-11T01:02:03","expected_review_state":store.snapshot_review_state(),"expected_batch_operations":store.snapshot_batch_operations()}
	var command = load("res://client/domain/commands/apply_propagation_command.gd").new(store.get_corrected_record(0),{1:target_before},{1:target_after},marker)
	writer.reject_metadata = true
	support.expect_equal(command.apply(store),PackedStringArray(),"v3 accepted batch installs atomically before persistence")
	var accepted: Dictionary = store.freeze_snapshot()
	support.expect(not (await session.retry_unsaved()).is_empty(),"v3 write failure remains actionable")
	support.expect(not session.can_replace_context(),"v3 unsaved batch blocks context replacement")
	support.expect_equal(store.freeze_snapshot(),accepted,"write failure preserves accepted records/reviews/history")
	reopened.prepare(root,media,entries)
	support.expect_equal(reopened.workflow_state().batch_operations.size(),1,"failed v3 save preserves prior complete disk history")
	support.expect_equal(reopened.record_for_frame(1).regions[0].box[0],8,"failed v3 save preserves prior disk record")
	writer.reject_metadata = false
	support.expect_equal(await session.retry_unsaved(),PackedStringArray(),"v3 retry persists authoritative batch")
	reopened.prepare(root,media,entries)
	var restored = load("res://client/domain/annotation_store.gd").new()
	restored.load_model_records(reopened.all_display_records())
	support.expect_equal(restored.configure_session(reopened.prepared_store().freeze_snapshot()),PackedStringArray(),"recovery Store receives trusted persisted playback entries")
	var workflow: Dictionary = reopened.workflow_state()
	support.expect_equal(restored.load_workflow_state(workflow.review_state,workflow.batch_operations),PackedStringArray(),"v3 retry reopens valid workflow")
	support.expect_equal(restored.snapshot_batch_operations()[1],accepted.batch_operations[1],"v3 exact marker survives failed-save recovery")
	support.expect(restored.is_verified(1),"v3 accepted target remains verified after retry and reopen")
	session.unbind()
	session.free()
