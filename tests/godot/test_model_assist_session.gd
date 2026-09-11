extends SceneTree

const SESSION := preload("res://client/domain/model_assist_session.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")


func _initialize() -> void:
	var support = SUPPORT.new()
	run_suite(support)
	if support.failures.is_empty():
		print("PASS model assist session state machine")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)


static func run_suite(support) -> void:
	_test_availability_target_modes_and_initial_state(support)
	_test_prompt_history_target_freeze_and_cap(support)
	_test_request_stale_candidate_cycle_failure_and_retry(support)
	_test_commit_snapshots_and_awaiting_class(support)
	_test_snapshot_and_candidate_defensive_copies(support)


static func _test_availability_target_modes_and_initial_state(support) -> void:
	var session = SESSION.new()
	var unavailable := {"ok": false, "status": "unavailable", "message": "missing sam2", "badge": "", "device": "", "busy": false, "errors": ["missing sam2"]}
	session.begin(17, 3, _record(), "r-box", Vector2i(80, 60), unavailable)
	var snapshot: Dictionary = session.snapshot()
	support.expect_equal(snapshot.phase, &"unavailable", "failed preflight enters unavailable")
	support.expect_equal(snapshot.message, "missing sam2", "unavailable keeps the actionable preflight reason")
	support.expect(not snapshot.navigation_blocked and not snapshot.draft_active, "unavailable never traps navigation")
	support.expect_equal(_action_ids(snapshot.session_panel), [&"model_recheck"], "unavailable exposes only Recheck")

	session.begin(17, 3, _record(), "r-box", Vector2i(80, 60), _ready())
	snapshot = session.snapshot()
	support.expect_equal(snapshot.phase, &"ready", "valid preflight enters ready")
	support.expect_equal(snapshot.session_panel.badge, "SAM2 已就绪 · CPU（较慢）", "ready retains the actual device badge")
	support.expect(not snapshot.navigation_blocked and not snapshot.draft_active, "selected correction mask alone remains nonblocking")
	var first: Dictionary = session.add_point(Vector2(12, 14), true)
	support.expect(first.get("changed", false), "first prompt is accepted")
	support.expect_equal(first.request.get("target_mode"), &"correction", "selected Box starts correction mode")
	support.expect_equal(first.request.get("selected_region_id"), "r-box", "first prompt freezes the selected Box ID")
	support.expect_equal(session.snapshot().overlay.get("suppress_region_id"), "r-box", "correction draft suppresses only its frozen source region")

	session.begin(17, 3, _record(), "r-poly", Vector2i(80, 60), _ready())
	support.expect_equal(session.add_point(Vector2(12, 14), true).request.get("target_mode"), &"correction", "selected Poly also starts correction mode")
	session.begin(17, 3, _record(), "", Vector2i(80, 60), _ready())
	support.expect_equal(session.add_point(Vector2(12, 14), true).request.get("target_mode"), &"creation", "empty selection starts creation mode")


static func _test_prompt_history_target_freeze_and_cap(support) -> void:
	var session = SESSION.new()
	session.begin(17, 3, _record(), "r-box", Vector2i(80, 60), _ready())
	var positive: Dictionary = session.add_point(Vector2(10, 11), true)
	var negative: Dictionary = session.add_point(Vector2(20, 21), false)
	support.expect_equal(negative.request.prompts.points, [[10.0, 11.0], [20.0, 21.0]], "positive and negative prompts retain chronological image-space order")
	support.expect_equal(negative.request.prompts.labels, [1, 0], "prompt labels retain positive/negative semantics")
	support.expect_equal(session.snapshot().overlay.positive_points, PackedVector2Array([Vector2(10, 11)]), "positive overlay points are separated")
	support.expect_equal(session.snapshot().overlay.negative_points, PackedVector2Array([Vector2(20, 21)]), "negative overlay points are separated")
	support.expect_equal(positive.request.prompt_revision, 1, "first prompt starts revision one")
	support.expect_equal(negative.request.prompt_revision, 2, "every prompt edit advances the revision")

	var first_box := session.set_box(Rect2(Vector2(30, 25), Vector2(-10, -8)))
	support.expect_equal(first_box.request.prompts.box, [20.0, 17.0, 30.0, 25.0], "Ctrl-drag box is normalized to xyxy image coordinates")
	var replacement := session.set_box(Rect2(5, 6, 10, 12))
	support.expect_equal(replacement.request.prompts.box, [5.0, 6.0, 15.0, 18.0], "a new drag replaces the unique prompt box")
	var undone := session.undo_prompt()
	support.expect_equal(undone.request.prompts.box, [20.0, 17.0, 30.0, 25.0], "Backspace restores the prior prompt state")
	support.expect(undone.request.prompt_revision > replacement.request.prompt_revision, "undo advances rather than reuses a stale revision")

	var context := _context("r-box", undone.request.prompt_revision)
	session.begin_request(31, context)
	var changed := session.add_point(Vector2(22, 23), true)
	support.expect_equal(changed.get("cancel_token"), 31, "editing prompts invalidates the in-flight request first")
	support.expect(not session.accept(31, [_valid_candidate(1)]), "a response for the retired prompt revision is stale")
	support.expect_equal(session.request_snapshot().selected_region_id, "r-box", "prompt edits cannot switch the first-prompt target")
	var latest: Dictionary = session.request_snapshot()
	session.begin_request(32, _context("r-box", latest.prompt_revision))
	support.expect_equal(session.cancel(), 32, "Cancel returns the only in-flight token for service invalidation")
	support.expect_equal(session.snapshot().phase, &"ready", "Cancel returns the active tool to ready")
	support.expect(not session.snapshot().draft_active and not session.snapshot().navigation_blocked, "Cancel releases the target and navigation gate")
	support.expect_equal(session.request_snapshot(), {}, "Cancel clears all prompt payload")
	support.expect(not session.accept(32, [_valid_candidate(1)]), "Cancel makes every late callback stale")

	session.reset()
	session.begin(17, 3, _record(), "", Vector2i(80, 60), _ready())
	for index in range(64):
		support.expect(session.add_point(Vector2(index, 10), true).get("changed", false), "point %d stays within the 64-point cap" % index)
	var at_cap: Dictionary = session.request_snapshot()
	var refused := session.add_point(Vector2(70, 10), false)
	support.expect(not refused.get("changed", true), "the 65th prompt point is refused")
	support.expect_equal(session.request_snapshot(), at_cap, "point-cap refusal is atomic")


static func _test_request_stale_candidate_cycle_failure_and_retry(support) -> void:
	var session = SESSION.new()
	session.begin(17, 3, _record(), "r-poly", Vector2i(80, 60), _ready())
	var request: Dictionary = session.add_point(Vector2(12, 14), true).request
	session.begin_request(41, _context("r-poly", request.prompt_revision))
	support.expect_equal(session.snapshot().phase, &"requesting", "begin_request enters requesting")
	support.expect(session.snapshot().navigation_blocked and session.snapshot().draft_active, "inference draft blocks frame navigation")
	support.expect(not session.accept(40, [_valid_candidate(1)]), "wrong token cannot restore a candidate")

	var candidates := [_invalid_candidate("hole"), _valid_candidate(2), _valid_candidate(3)]
	support.expect(session.accept(41, candidates), "current token accepts bounded validated candidates")
	support.expect_equal(session.snapshot().phase, &"invalid", "an unsafe selected candidate remains visible as invalid")
	support.expect("hole" in session.snapshot().message, "invalid candidate keeps its concrete refusal")
	session.cycle(1)
	support.expect_equal(session.snapshot().phase, &"candidate", "Tab can cycle from an invalid result to a safe candidate")
	support.expect_equal(session.snapshot().overlay.candidate_polygon[0], Vector2(12, 12), "candidate cycle changes the visible safe polygon")
	session.cycle(-1)
	support.expect_equal(session.snapshot().phase, &"invalid", "reverse candidate cycling wraps deterministically")

	request = session.retry()
	support.expect(request.get("changed", false) and request.request.prompt_revision > 1, "Retry keeps prompts but creates a fresh revision")
	session.begin_request(42, _context("r-poly", request.request.prompt_revision))
	support.expect(session.fail(42, "backend unavailable"), "current worker failure is accepted")
	support.expect_equal(session.snapshot().phase, &"failed", "worker error enters failed")
	support.expect("backend unavailable" in session.snapshot().message, "failed state preserves the concrete backend reason")
	support.expect_equal(_action_ids(session.snapshot().session_panel), [&"model_retry", &"model_cancel"], "failed state offers recovery without Apply")


static func _test_commit_snapshots_and_awaiting_class(support) -> void:
	var session = SESSION.new()
	var before := _record()
	session.begin(17, 3, before, "r-box", Vector2i(80, 60), _ready())
	var request: Dictionary = session.add_point(Vector2(12, 14), true).request
	session.begin_request(51, _context("r-box", request.prompt_revision))
	session.accept(51, [_valid_candidate(1)])
	var correction: Dictionary = session.commit_snapshot()
	support.expect_equal(correction.get("mode"), &"replace", "selected-region Apply creates a replace snapshot")
	support.expect_equal(correction.get("region_id"), "r-box", "correction snapshot retains the frozen region ID")
	support.expect_equal(correction.get("frame_id"), 17, "commit snapshot retains the original frame")
	support.expect_equal(correction.get("before"), before, "correction carries the exact before-record for checked command creation")
	support.expect_equal(correction.get("polygon"), _valid_candidate(1).polygon, "correction commits only the selected safe candidate")

	session.begin(17, 3, before, "", Vector2i(80, 60), _ready())
	request = session.add_point(Vector2(12, 14), true).request
	session.begin_request(52, _context("", request.prompt_revision))
	session.accept(52, [_valid_candidate(2)])
	support.expect(session.await_class_assignment(), "creation Apply transitions to class assignment")
	support.expect_equal(session.snapshot().phase, &"awaiting_class", "creation waits for the existing class dialog")
	support.expect(session.snapshot().navigation_blocked, "awaiting class keeps navigation blocked")
	var creation: Dictionary = session.commit_snapshot()
	support.expect_equal(creation.get("mode"), &"add", "empty-selection commit snapshot creates a region")
	support.expect_equal(creation.get("region_id"), "", "creation never invents a region ID outside AddPolygonCommand")
	support.expect_equal(creation.get("polygon"), _valid_candidate(2).polygon, "awaiting-class snapshot retains the selected candidate")


static func _test_snapshot_and_candidate_defensive_copies(support) -> void:
	var session = SESSION.new()
	var record := _record()
	var preflight := _ready()
	session.begin(17, 3, record, "r-poly", Vector2i(80, 60), preflight)
	record.regions[1].polygon[0][0] = 999
	preflight.badge = "tampered"
	var request: Dictionary = session.add_point(Vector2(12, 14), true).request
	session.begin_request(61, _context("r-poly", request.prompt_revision))
	var candidate := _valid_candidate(2)
	session.accept(61, [candidate])
	candidate.polygon[0] = Vector2.ZERO
	candidate.mask.mask[0] = 0
	var first: Dictionary = session.snapshot()
	support.expect_equal(_sorted_keys(first), ["draft_active", "message", "navigation_blocked", "overlay", "phase", "session_panel"], "snapshot exposes only UI-owned state")
	support.expect_equal(_sorted_keys(first.session_panel), ["actions", "badge", "status", "summary", "tool_id"], "session panel uses the strict generic descriptor")
	for action: Dictionary in first.session_panel.actions:
		support.expect_equal(_sorted_keys(action), ["enabled", "id", "label", "primary"], "every session action has the exact declarative contract")
	support.expect_equal(first.session_panel.badge, "SAM2 已就绪 · CPU（较慢）", "begin defensively owns preflight state")
	support.expect_equal(first.overlay.candidate_polygon[0], Vector2(12, 12), "accept defensively owns candidate polygon")
	support.expect_equal(first.overlay.mask_preview.mask[0], 1, "accept defensively owns candidate mask bytes")
	first.overlay.candidate_polygon[0] = Vector2.ZERO
	first.overlay.mask_preview.mask[0] = 0
	first.session_panel.actions[0].label = "tampered"
	var second: Dictionary = session.snapshot()
	support.expect_equal(second.overlay.candidate_polygon[0], Vector2(12, 12), "overlay snapshots cannot mutate session geometry")
	support.expect_equal(second.overlay.mask_preview.mask[0], 1, "overlay snapshots cannot mutate session mask")
	support.expect(second.session_panel.actions[0].label != "tampered", "session action descriptors are defensive")
	support.expect_equal(session.commit_snapshot().before.regions[1].polygon[0][0], 10.0, "begin defensively owns the before record")


static func _ready() -> Dictionary:
	return {"ok": true, "status": "ready", "message": "SAM2 已就绪 · CPU（较慢）", "badge": "SAM2 已就绪 · CPU（较慢）", "device": "cpu", "busy": false, "errors": [], "checkpoint_sha256": "a".repeat(64)}


static func _record() -> Dictionary:
	return {
		"schema_version": 1,
		"source": "frame.png",
		"frame": 17,
		"regions": [
			{"id": "r-box", "class": "grasper", "kind": "instrument", "box": [4.0, 5.0, 20.0, 12.0], "track_id": null},
			{"id": "r-poly", "class": "hook", "kind": "instrument", "polygon": [[10.0, 10.0], [30.0, 10.0], [28.0, 25.0], [11.0, 24.0]], "track_id": "T2"},
		],
	}


static func _context(region_id: String, revision: int) -> Dictionary:
	return {
		"session_id": "session-test",
		"frame_id": 17,
		"playback_index": 3,
		"image_sha256": "a".repeat(64),
		"record_sha256": "b".repeat(64),
		"selected_region_id": region_id,
		"prompt_revision": revision,
	}


static func _valid_candidate(offset: int) -> Dictionary:
	var polygon := PackedVector2Array([
		Vector2(10 + offset, 10 + offset), Vector2(30 + offset, 10 + offset),
		Vector2(28 + offset, 25 + offset), Vector2(11 + offset, 24 + offset),
	])
	var mask := PackedByteArray()
	mask.resize(20)
	mask.fill(1)
	return {"ok": true, "polygon": polygon, "mask": {"roi": Rect2i(10, 10, 5, 4), "mask": mask}, "reason": "", "score": 0.9 - offset * 0.01}


static func _invalid_candidate(reason: String) -> Dictionary:
	return {"ok": false, "polygon": PackedVector2Array(), "mask": {"roi": Rect2i(), "mask": PackedByteArray()}, "reason": reason, "score": 0.2}


static func _action_ids(panel: Dictionary) -> Array:
	return panel.get("actions", []).map(func(action): return action.id)


static func _sorted_keys(value: Dictionary) -> Array:
	var keys: Array = value.keys()
	keys.sort()
	return keys
