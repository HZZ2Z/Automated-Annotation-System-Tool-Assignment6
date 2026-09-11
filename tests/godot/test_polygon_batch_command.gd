extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const REVIEW := preload("res://client/domain/commands/review_frames_command.gd")
const COMMAND_PATH := "res://client/domain/commands/apply_propagation_command.gd"

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var s = SUPPORT.new()
	s.expect(ResourceLoader.exists(COMMAND_PATH), "prepared polygon propagation command exists")
	if ResourceLoader.exists(COMMAND_PATH):
		var command = load(COMMAND_PATH)
		_test_commit_history(s, command)
		_test_sampled_frame_step_roundtrip(s, command)
		_test_historical_audit_survives_keyframe_edits(s, command)
		_test_rejections(s, command)
	if s.failures.is_empty():
		print("PASS polygon batch command")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _record(frame: int, offset := 0) -> Dictionary:
	return {"schema_version": 1, "source": "polygon-test", "frame": frame, "time_s": frame * 0.1,
		"regions": [{"id": "poly", "class": "grasper", "kind": "instrument", "track_id": "T1",
			"polygon": [[20 + offset,20],[60 + offset,20],[60 + offset,30],[35 + offset,30],[35 + offset,60],[20 + offset,60]]},
			{"id": "keep", "class": "anatomy", "kind": "anatomy", "box": [90,90,10,10]}]}

func _fixture() -> Dictionary:
	var store = STORE.new()
	store.load_model_records([_record(0), _record(1), _record(2)])
	return {"store": store, "before": {1: _record(1), 2: _record(2)},
		"after": {1: _record(1, 4), 2: _record(2, 8)}}

func _marker(mode := "merge") -> Dictionary:
	return {"schema_version": 2, "mode": mode, "metric_id": "poly-sim-flow-edge-v1", "threshold": 0.02, "max_frames": 30,
		"start_index": 0, "end_index": 2, "start_frame": 0, "end_frame": 2,
		"left_stop": "source boundary", "right_stop": "source boundary", "covered_count": 3,
		"edge_refinement": {"attempted": 2, "accepted": 1, "fallback": 1, "items": [
			{"frame_id": 1, "region_id": "poly", "accepted": true, "reason": "accepted", "raw_edge_score": 0.2, "refined_edge_score": 0.3},
			{"frame_id": 2, "region_id": "poly", "accepted": false, "reason": "edge gain below 0.01", "raw_edge_score": 0.2, "refined_edge_score": 0.2},
		]}}

func _test_sampled_frame_step_roundtrip(s, script) -> void:
	var root := "/tmp/poly-sampled-audit-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var path := root.path_join("label/clip.json")
	var records := [_record(5850), _record(5875)]
	var options := {
		"path": path, "media_id": "clip", "media_type": "image_sequence", "source": "polygon-test",
		"source_relative_path": "clip", "source_sha256": null, "round_id": "initial",
		"model_revision": "fixture", "taxonomy_version": "v1", "baseline_kind": "model",
		"seed_records": records,
		"frame_entries": [
			{"frame": 0, "frame_id": 5850, "time_s": 585.0, "image_path": "5850.png"},
			{"frame": 1, "frame_id": 5875, "time_s": 587.5, "image_path": "5875.png"},
		],
	}
	var repository = load("res://client/workspace/session_repository.gd").new()
	var opened: Dictionary = repository.open_session(options)
	s.expect(bool(opened.get("success", false)), "sampled frame fixture opens")
	if not bool(opened.get("success", false)):
		return
	var store = opened.store
	var edge := {"attempted": 1, "accepted": 0, "fallback": 1, "items": [
		{"frame_id": 5875, "region_id": "poly", "accepted": false, "reason": "Hausdorff above 6", "raw_edge_score": 0.04, "refined_edge_score": 0.09},
	]}
	var marker := {"schema_version": 2, "mode": "merge", "metric_id": "poly-sim-flow-edge-v1", "threshold": 0.7,
		"max_frames": 30, "frame_step": 25, "start_index": 0, "end_index": 1,
		"start_frame": 5850, "end_frame": 5875, "left_stop": "source boundary",
		"right_stop": "motion leaves image bounds", "covered_count": 2,
		"edge_refinement": edge}
	var command = script.new(_record(5850), {5875: _record(5875)}, {5875: _record(5875, 4)}, marker)
	s.expect_equal(HISTORY.new().execute(command, store), PackedStringArray(), "frame_step 25 batch applies atomically")
	var saved: Dictionary = repository.save_snapshot(store.freeze_snapshot(), {"path": path, "expected_sha256": opened.disk_sha256})
	s.expect(bool(saved.get("success", false)), "frame_step 25 batch saves: %s" % str(saved.get("errors", [])))
	if not bool(saved.get("success", false)):
		return
	opened = repository.open_session(options)
	s.expect(bool(opened.get("success", false)), "frame_step 25 batch reopens")
	if bool(opened.get("success", false)):
		var operations: Array = opened.store.snapshot_batch_operations()
		s.expect_equal(operations.size(), 1, "sampled batch audit roundtrips")
		if operations.size() == 1:
			s.expect_equal(operations[0].get("frame_step"), 25, "sampled batch keeps declared frame step")

func _test_commit_history(s, script) -> void:
	var f := _fixture()
	var history = HISTORY.new()
	s.expect_equal(REVIEW.new([0], true).apply(f.store), PackedStringArray(), "existing keyframe review is prepared")
	var reviews_before: Dictionary = f.store.snapshot_review_state()
	var command = script.new(_record(0), f.before, f.after, _marker())
	s.expect_equal(history.execute(command, f.store), PackedStringArray(), "prepared per-frame polygons commit")
	s.expect_equal(f.store.get_corrected_record(1), _record(1, 4), "frame 1 uses preview geometry and identity")
	s.expect_equal(f.store.get_corrected_record(2), _record(2, 8), "frame 2 uses its distinct preview geometry")
	s.expect_equal(f.store.get_corrected_record(0), _record(0), "manual keyframe is unchanged")
	s.expect_equal(history.get_undo_count(), 1, "batch is one undo item")
	s.expect(f.store.is_verified(1) and f.store.is_verified(2), "all changed predictions are verified in the same command")
	var reviews_after: Dictionary = f.store.snapshot_review_state()
	s.expect_equal(reviews_after.get("0"), reviews_before.get("0"), "batch preserves unrelated review state")
	s.expect_equal(f.store.snapshot_batch_operations().size(), 1, "one persistent audit marker")
	s.expect_equal(f.store.snapshot_batch_operations()[0].schema_version, 2, "command persists v2 audit")
	s.expect_equal(f.store.snapshot_batch_operations()[0].edge_refinement, _marker().edge_refinement, "edge audit remains exact")
	s.expect_equal(history.try_undo(f.store), PackedStringArray(), "atomic undo succeeds")
	s.expect_equal(f.store.get_corrected_record(2), _record(2), "undo restores original geometry")
	s.expect_equal(f.store.snapshot_review_state(), reviews_before, "undo restores exact pre-apply reviews")
	s.expect_equal(f.store.snapshot_batch_operations().size(), 0, "undo restores marker list")
	s.expect_equal(history.redo(f.store), PackedStringArray(), "redo reuses same per-frame result")
	s.expect_equal(f.store.get_corrected_record(2), _record(2, 8), "redo does not copy keyframe")
	s.expect_equal(f.store.snapshot_review_state(), reviews_after, "redo restores exact post-apply reviews")
	var overwrite_fixture := _fixture()
	var overwrite_after: Dictionary = overwrite_fixture.after.duplicate(true)
	for frame: int in overwrite_after:
		overwrite_after[frame].regions = [overwrite_after[frame].regions[0]]
	var overwrite = script.new(_record(0), overwrite_fixture.before, overwrite_after, _marker("overwrite"))
	s.expect_equal(HISTORY.new().execute(overwrite, overwrite_fixture.store), PackedStringArray(), "overwrite command commits")
	s.expect_equal(overwrite_fixture.store.get_corrected_record(2).regions.size(), 1, "overwrite removes target-only region")
	s.expect_equal(overwrite_fixture.store.snapshot_batch_operations()[0].mode, "overwrite", "overwrite marker preserves mode")

func _test_historical_audit_survives_keyframe_edits(s, script) -> void:
	var root := "/tmp/poly-keyframe-audit-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var path := root.path_join("label/clip.json")
	var records := [_record(0), _record(1), _record(2)]
	var options := {
		"path": path, "media_id": "clip", "media_type": "image_sequence", "source": "polygon-test",
		"source_relative_path": "clip", "source_sha256": null, "round_id": "initial",
		"model_revision": "fixture", "taxonomy_version": "v1", "baseline_kind": "model",
		"seed_records": records,
		"frame_entries": [
			{"frame": 0, "frame_id": 0, "time_s": 0.0, "image_path": "0.png"},
			{"frame": 1, "frame_id": 1, "time_s": 0.1, "image_path": "1.png"},
			{"frame": 2, "frame_id": 2, "time_s": 0.2, "image_path": "2.png"},
		],
	}
	var repository = load("res://client/workspace/session_repository.gd").new()
	var opened: Dictionary = repository.open_session(options)
	s.expect(bool(opened.get("success", false)), "historical-audit fixture opens")
	if not bool(opened.get("success", false)):
		return
	var store = opened.store
	var command = script.new(_record(0), {1: _record(1), 2: _record(2)}, {1: _record(1, 4), 2: _record(2, 8)}, _marker())
	s.expect_equal(HISTORY.new().execute(command, store), PackedStringArray(), "historical-audit batch applies")
	var added: Dictionary = store.get_corrected_record(0)
	added.regions.append({"id": "later", "class": "clip", "kind": "anatomy", "polygon": [[5,5],[10,5],[10,10],[5,10]]})
	s.expect_equal(store.replace_corrected_record(0, added), PackedStringArray(), "later keyframe Poly addition is accepted")
	var saved: Dictionary = repository.save_snapshot(store.freeze_snapshot(), {"path": path, "expected_sha256": ""})
	s.expect(bool(saved.get("success", false)), "historical audit saves after adding a keyframe Poly: %s" % str(saved.get("errors", [])))
	if not bool(saved.get("success", false)):
		return
	opened = repository.open_session(options)
	s.expect(bool(opened.get("success", false)), "historical audit reopens after adding a keyframe Poly")
	if not bool(opened.get("success", false)):
		return
	store = opened.store
	var deleted: Dictionary = store.get_corrected_record(0)
	for index in range(deleted.regions.size() - 1, -1, -1):
		if deleted.regions[index].get("id") == "poly":
			deleted.regions.remove_at(index)
	s.expect_equal(store.replace_corrected_record(0, deleted), PackedStringArray(), "later keyframe reference deletion is accepted")
	saved = repository.save_snapshot(store.freeze_snapshot(), {"path": path, "expected_sha256": opened.disk_sha256})
	s.expect(bool(saved.get("success", false)), "historical audit saves after deleting the former reference Poly: %s" % str(saved.get("errors", [])))
	if bool(saved.get("success", false)):
		opened = repository.open_session(options)
		s.expect(bool(opened.get("success", false)), "historical audit reopens independently of current keyframe membership")

func _test_rejections(s, script) -> void:
	for reason: String in ["target", "keyframe", "verified", "identity", "polygon", "marker"]:
		var f := _fixture()
		var metadata := _marker()
		if reason == "target":
			f.store.replace_corrected_record(2, _record(2, 2))
		elif reason == "keyframe":
			f.store.replace_corrected_record(0, _record(0, 1))
		elif reason == "verified":
			REVIEW.new([2], true).apply(f.store)
		elif reason == "identity":
			f.after[2].time_s = 100.0
		elif reason == "polygon":
			f.after[2].regions[0].polygon = [[10,10],[30,30],[10,30],[30,10]]
		elif reason == "marker":
			metadata.end_frame = 1
		var before1: Dictionary = f.store.get_corrected_record(1)
		var before2: Dictionary = f.store.get_corrected_record(2)
		var state_before: Dictionary = f.store.freeze_snapshot()
		var history = HISTORY.new()
		var command = script.new(_record(0), f.before, f.after, metadata)
		s.expect(not history.execute(command, f.store).is_empty(), "%s conflict rejects entire preview" % reason)
		s.expect_equal(f.store.get_corrected_record(1), before1, "%s conflict leaves earlier frame untouched" % reason)
		s.expect_equal(f.store.get_corrected_record(2), before2, "%s conflict leaves later frame untouched" % reason)
		s.expect_equal(f.store.freeze_snapshot(), state_before, "%s conflict leaves records, reviews and revision untouched" % reason)
		s.expect_equal(history.get_undo_count(), 0, "%s conflict leaves history untouched" % reason)
		s.expect_equal(f.store.snapshot_batch_operations().size(), 0, "%s conflict leaves audits untouched" % reason)
