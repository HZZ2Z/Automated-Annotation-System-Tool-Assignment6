extends SceneTree

const MAIN_SCENE := preload("res://client/app/main.tscn")
const REVIEW := preload("res://client/domain/commands/review_frames_command.gd")
const REPOSITORY := preload("res://client/workspace/session_repository.gd")
const PACKAGE := preload("res://client/feedback/training_package.gd")


class FailingWriter extends RefCounted:
	var repository := REPOSITORY.new()
	var fail := true
	var delay_msec := 0

	func write(snapshot: Dictionary, options: Dictionary, token: Variant) -> Dictionary:
		if delay_msec > 0:
			OS.delay_msec(delay_msec)
		if fail:
			return {
				"success": false,
				"errors": ["Injected one-click save failure"],
				"session_id": snapshot.session_id,
				"revision": snapshot.revision,
			}
		return repository.save_snapshot(snapshot, options, token)


class DelayedPreview extends RefCounted:
	func preview(snapshot: Dictionary, options: Dictionary, token: Variant) -> Dictionary:
		token.report_progress({"stage": "one_click_preview_barrier"})
		OS.delay_msec(400)
		return PACKAGE.preview(snapshot, options, token)


var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var workspace := _create_workspace()
	var main = MAIN_SCENE.instantiate()
	main.review_session_root = workspace.path_join("direct-sessions")
	root.add_child(main)
	await process_frame
	_check((await main.open_workspace(workspace)).is_empty(), "legacy workspace opens")
	await _select_media(main, "VID68")
	if main._store == null:
		_finish(main)
		return
	var controller = main._review_workflow.exports.controller
	var descriptor: Dictionary = main._workspace_label_store.baseline_descriptor()
	_check(not descriptor.is_empty(), "workspace supplies a trusted original-label descriptor")
	_check(main._store.freeze_snapshot().baseline_kind == "unknown", "fixture starts as an unknown legacy session")
	_check(main._store.get_corrected_record(4).regions[0].class == "human-correction", "legacy manual correction is active")
	_check(main._history.execute(REVIEW.new([9], true), main._store).is_empty(), "one empty frame is explicitly verified")
	_check((await main._workspace_session.flush_before_context_change()).is_empty(), "fixture review is saved")

	main._workspace_label_store.set_baseline_descriptor({})
	var before_missing: Dictionary = main._store.freeze_snapshot()
	var missing: Dictionary = await controller.prepare_one_click()
	_check(not missing.get("success", false) and missing.get("error_code") == "baseline_input_required", "missing trusted descriptor has a dedicated outcome")
	_check(main._store.freeze_snapshot() == before_missing, "missing descriptor cannot mutate the active session")

	main._workspace_label_store.set_baseline_descriptor(descriptor)
	var prepared: Dictionary = await controller.prepare_one_click()
	_check(prepared.get("success", false) and prepared.get("auto_baseline_bound", false), "trusted baseline auto-binds")
	_check(prepared.get("total_frames") == 3 and prepared.get("annotated_frames") == 1, "prepare reports exact total and written counts")
	_check(prepared.get("already_verified_frames") == 1 and prepared.get("verified_empty_frames") == 1, "prepare separates prior verification and negative frames")
	_check(prepared.get("will_export_frames") == 2 and prepared.get("needs_attestation"), "prepare reports only annotated plus verified-empty coverage")
	_check(main._store.freeze_snapshot().baseline_kind == "imported_labels", "automatic binding is adopted into Main")
	_check(main._store.get_corrected_record(4).regions[0].class == "human-correction", "automatic binding preserves manual correction")

	var before_rejection: Dictionary = main._store.freeze_snapshot()
	var rejected: Dictionary = await controller.confirm_and_publish(workspace.path_join("rejected"), false)
	_check(not rejected.get("success", false) and rejected.get("error_code") == "attestation_required", "attestation is explicit")
	_check(main._store.freeze_snapshot() == before_rejection and not DirAccess.dir_exists_absolute(workspace.path_join("rejected")), "rejected attestation changes neither session nor output")

	var output := workspace.path_join("packages")
	var result: Dictionary = await controller.confirm_and_publish(output, true)
	_check(result.get("success", false) and result.get("summary", {}).get("included_frames") == 2, "non-empty plus verified negative exports")
	_check(main._store.is_verified(4) and main._store.is_verified(9) and not main._store.is_verified(15), "unverified empty frame is never promoted")
	_check(_jsonl_frames(String(result.get("output_path", "")).path_join("data/corrected_annotations.jsonl")) == [4, 9], "published package contains only attested annotation and prior negative")

	# A failed save keeps the review in memory but prevents any package attempt.
	_edit_class(main, 4, "save-failure-edit")
	prepared = await controller.prepare_one_click()
	_check(prepared.get("success", false), "changed annotation prepares before save-failure case")
	var writer := FailingWriter.new()
	main._workspace_session.set_save_worker(Callable(writer, "write"))
	var blocked_output := workspace.path_join("blocked-save-output")
	var save_failed: Dictionary = await controller.confirm_and_publish(blocked_output, true)
	_check(not save_failed.get("success", false) and save_failed.get("error_code") == "save_failed", "review save failure is distinct")
	_check(main._store.is_verified(4) and main._workspace_session.has_unsaved_changes(), "failed review save retains recoverable in-memory review")
	_check(not DirAccess.dir_exists_absolute(blocked_output), "save failure prevents publication")
	writer.fail = false
	_check((await main._workspace_session.retry_unsaved()).is_empty(), "failed review save can be retried")

	# A package publication failure happens only after the review is durable.
	prepared = await controller.prepare_one_click()
	_check(prepared.get("success", false), "saved review prepares for publication retry")
	var blocked_parent := workspace.path_join("not-a-directory")
	_write_text(blocked_parent, "occupied")
	var publication_failed: Dictionary = await controller.confirm_and_publish(blocked_parent, true)
	_check(not publication_failed.get("success", false) and publication_failed.get("error_code") == "publication_failed", "publication failure is distinct")
	_check(main._store.is_verified(4) and not main._workspace_session.has_unsaved_changes(), "publication failure retains saved reviews")
	var reopened: Dictionary = REPOSITORY.new().open_session(main._workspace_label_store.save_options().merged({
		"media_id": "VID68",
		"media_type": "image_sequence",
		"source": "VID68",
		"source_relative_path": "videos/VID68",
		"source_sha256": null,
		"frame_entries": main._store.freeze_snapshot().frame_entries,
	}, true))
	_check(reopened.get("success", false) and reopened.store.is_verified(4), "saved review survives an independent reopen after publication failure")

	# A changed Store after prepare invalidates the attested request before review or output.
	prepared = await controller.prepare_one_click()
	_check(prepared.get("success", false), "fresh one-click snapshot prepares")
	_edit_class(main, 4, "stale-after-prepare")
	var stale_output := workspace.path_join("stale-output")
	var stale: Dictionary = await controller.confirm_and_publish(stale_output, true)
	_check(not stale.get("success", false) and stale.get("error_code") == "stale_context" and stale.get("stale", false), "changed prepared revision has a stale-context outcome")
	_check(not DirAccess.dir_exists_absolute(stale_output), "stale context cannot publish")

	# A live edit while preview runs invalidates the request before publication starts.
	prepared = await controller.prepare_one_click()
	_check(prepared.get("success", false), "edited content prepares before preview race")
	controller._package = DelayedPreview.new()
	var preview_seen := [false]
	controller.progress.connect(func(update: Dictionary):
		if update.get("stage") == "one_click_preview_barrier":
			preview_seen[0] = true)
	var preview_result: Array = []
	var run_preview := func() -> void:
		preview_result.append(await controller.confirm_and_publish(
			workspace.path_join("preview-race-output"), true))
	run_preview.call()
	var deadline := Time.get_ticks_msec() + 5000
	while not preview_seen[0] and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(preview_seen[0], "preview race reaches the async preview boundary")
	_edit_class(main, 4, "edit-during-preview")
	while preview_result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not preview_result.is_empty(), "preview race settles")
	if not preview_result.is_empty():
		var preview_stale: Dictionary = preview_result[0]
		_check(not preview_stale.get("success", false) and preview_stale.get("error_code") == "stale_context" and preview_stale.get("stale", false), "edit during preview returns stale context")
	_check(not DirAccess.dir_exists_absolute(workspace.path_join("preview-race-output")), "edit during preview prevents publication from starting")
	controller._package = PACKAGE.new()

	# Cancellation during the initial save keeps request identity but marks it stale.
	writer.delay_msec = 400
	_edit_class(main, 4, "cancel-during-prepare-save")
	var cancelled_result: Array = []
	var run_prepare := func() -> void:
		cancelled_result.append(await controller.prepare_one_click())
	run_prepare.call()
	deadline = Time.get_ticks_msec() + 5000
	while not main._workspace_session.is_saving() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(main._workspace_session.is_saving(), "initial prepare save is in flight")
	controller.cancel()
	while cancelled_result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not cancelled_result.is_empty(), "cancelled initial prepare settles")
	if not cancelled_result.is_empty():
		var prepare_stale: Dictionary = cancelled_result[0]
		_check(not prepare_stale.get("success", false) and prepare_stale.get("error_code") == "stale_context", "cancelled initial save has a stale-context error code")
		_check(prepare_stale.get("stale", false) and prepare_stale.get("cancelled", false), "cancelled initial save reports stale and cancelled flags")

	_finish(main)


func _finish(main: Node) -> void:
	main._workspace_session.suspend_autosave(true)
	await main._workspace_session.settle_running()
	await main._review_workflow.exports.cancel_and_drain()
	main.queue_free()
	await process_frame
	if _failures.is_empty():
		print("PASS one-click training export orchestration")
	else:
		printerr("FAIL ", _failures)
	quit(0 if _failures.is_empty() else 1)


func _select_media(main: Node, media_id: String) -> void:
	var finished := [false]
	var launch := func() -> void:
		await main._on_workspace_media_requested(media_id)
		finished[0] = true
	launch.call()
	var deadline := Time.get_ticks_msec() + 15000
	while not finished[0] and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(finished[0], "workspace media selection settles")


func _edit_class(main: Node, frame: int, value: String) -> void:
	var record: Dictionary = main._store.get_corrected_record(frame)
	record.regions[0].class = value
	_check(main._store.replace_corrected_record(frame, record).is_empty(), "annotation edit commits")


func _create_workspace() -> String:
	var workspace := "/tmp/one-click-training-export-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var video := workspace.path_join("videos/VID68")
	DirAccess.make_dir_recursive_absolute(video)
	for item: Dictionary in [
		{"id": 4, "color": Color.RED},
		{"id": 9, "color": Color.GREEN},
		{"id": 15, "color": Color.BLUE},
	]:
		var image := Image.create(10, 8, false, Image.FORMAT_RGBA8)
		image.fill(item.color)
		image.save_png(video.path_join("%06d.png" % item.id))
	DirAccess.make_dir_recursive_absolute(workspace.path_join("labels"))
	_write_json(workspace.path_join("labels/VID68.json"), {
		"fps": 1.0,
		"categories": {"instrument": {"0": "grasper"}},
		"annotations": {"4": [[0, 0, 0, 0.1, 0.1, 0.2, 0.2, 0]], "9": [], "15": []},
	})
	DirAccess.make_dir_recursive_absolute(workspace.path_join("label"))
	_write_json(workspace.path_join("label/VID68.json"), {
		"schema_version": 1,
		"media_id": "VID68",
		"media_type": "image_sequence",
		"source_relative_path": "videos/VID68",
		"source_sha256": null,
		"frame_digits": 6,
		"frames": {
			"4": {
				"schema_version": 1,
				"source": "VID68",
				"frame": 4,
				"time_s": 4.0,
				"regions": [{"id": "human-4", "class": "human-correction", "kind": "instrument", "box": [1.0, 1.0, 3.0, 3.0]}],
			},
		},
	})
	return workspace


func _jsonl_frames(path: String) -> Array:
	var frames: Array = []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return frames
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var value: Variant = JSON.parse_string(line)
		if value is Dictionary:
			frames.append(int(value.frame))
	return frames


func _write_json(path: String, value: Variant) -> void:
	_write_text(path, JSON.stringify(value, "  ", false) + "\n")


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
