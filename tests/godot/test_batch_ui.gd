extends SceneTree

var completed := false

const SUPPORT := preload("res://tests/godot/test_support.gd")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var s = SUPPORT.new()
	var main = load("res://client/app/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	s.expect(main.get("_batch_workflow") != null, "main must mount the batch workflow")
	if main.get("_batch_workflow") != null:
		var workflow = main.get("_batch_workflow")
		s.expect(not workflow.available(), "batch is disabled without a persistent workspace")
		s.expect_equal(main.open_source("res://sample/assignment_v1"), PackedStringArray(), "direct source still opens")
		s.expect(not workflow.available(), "direct source cannot pretend to persist reviews")
		await _end_to_end(s, main, workflow)
	s.expect(completed, "end-to-end test must reach final checkpoint")
	main.queue_free()
	await process_frame
	if s.failures.is_empty():
		print("PASS batch UI")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _end_to_end(s, main, workflow) -> void:
	var directory := "/tmp/part3-demo-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var output: Array = []
	var code := OS.execute(ProjectSettings.globalize_path("res://.venv/bin/python"), [
		ProjectSettings.globalize_path("res://python/make_batch_demo.py"),
		"--source", ProjectSettings.globalize_path("res://sample/assignment_v1"), "--output", directory], output, true)
	s.expect_equal(code, 0, "derived demo generated without modifying original")
	if code != 0:
		return
	var model_path := directory.path_join("batch_clip/model_output_v1.jsonl")
	var model_hash := FileAccess.get_sha256(model_path)
	s.expect_equal(main.open_workspace(directory), PackedStringArray(), "persistent workspace opens")
	main._on_workspace_media_requested("batch_clip")
	s.expect(workflow.available(), "workspace batch is enabled")
	if not workflow.available():
		return
	s.expect(main.seek(50), "keyframe navigable")
	var store = main._store
	var truth: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("batch_demo_truth.json")))
	var corrected: Dictionary = store.get_corrected_record(50)
	corrected.regions[0] = truth.truth_regions["50"]
	var edit = load("res://client/domain/commands/replace_frame_command.gd").new(50, store.get_corrected_record(50), corrected)
	s.expect_equal(main._history.execute(edit, store), PackedStringArray(), "keyframe correction uses normal undo history")
	workflow._show_tab(true)
	var button_texts: Array[String] = []
	for button: Node in workflow._scroll.find_children("*", "Button", true, false):
		button_texts.append(button.text)
	s.expect("首帧" in button_texts and "末帧" in button_texts, "batch keeps only range endpoints as navigation buttons")
	for redundant in ["Before", "After", "Key", "First", "Last"]:
		s.expect(not redundant in button_texts, "redundant English navigation removed: " + redundant)
	var advanced: Variant = workflow.get("_advanced")
	s.expect(advanced != null and not advanced.visible, "technical details collapsed by default")
	for button: Node in workflow._scroll.find_children("*", "Button", true, false):
		if button.text == "高级设置":
			button.button_pressed = true
			s.expect(advanced.visible, "advanced settings can be expanded")
			button.button_pressed = false
	var started := Time.get_ticks_usec()
	workflow.analyze()
	var ticks := 0
	while workflow.controller.is_analyzing() and ticks < 100:
		await process_frame
		ticks += 1
	var analysis_ms := (Time.get_ticks_usec() - started) / 1000.0
	var plan: Dictionary = workflow.controller.get_plan()
	s.expect_equal(plan.get("threshold"), 0.02, "UI default threshold is exactly 0.02")
	s.expect_equal(plan.get("start_index"), 40, "UI analyzes first frame 40")
	s.expect_equal(plan.get("end_index"), 59, "UI analyzes last frame 59")
	if plan.is_empty():
		return
	workflow._boundary("last")
	s.expect_equal(main.get_current_frame(), 59, "last-boundary button navigates")
	s.expect_equal(workflow.controller.get_plan().get("keyframe"), 50, "navigation keeps pinned keyframe")
	workflow._show_preview.button_pressed = true
	s.expect(workflow._preview_note.visible, "preview has explicit unsaved indication")
	s.expect(workflow._verify_current.disabled and workflow._verify_range.disabled, "confirmation controls disabled in preview")
	s.expect_equal(main._viewport.get("_record").regions[0], corrected.regions[0], "canvas renders proposed boundary")
	s.expect_equal(store.get_corrected_record(59).regions[0]["class"], "batch_demo_wrong", "preview does not mutate store")
	if DisplayServer.get_name() != "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		for button: Node in workflow._scroll.find_children("*", "Button", true, false):
			if button.text == "下一待检查帧":
				s.expect(button.get_global_rect().end.y <= workflow._scroll.get_global_rect().end.y,
					"main review action fits visible batch panel without scrolling at default resolution")
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/output"))
		root.get_texture().get_image().save_png("res://tests/output/part3-batch.png")
	workflow.verify_current()
	workflow.verify_range()
	s.expect(not store.is_verified(40), "range verification also refuses proposed preview")
	s.expect(not store.is_verified(59), "cannot verify stored data while a different proposed preview is shown")
	s.expect_equal(main.get_current_frame(), 59, "preview verification refusal does not advance")
	workflow._show_preview.button_pressed = false
	var apply_started := Time.get_ticks_usec()
	workflow.apply()
	var apply_ms := (Time.get_ticks_usec() - apply_started) / 1000.0
	s.expect_equal(store.get_corrected_record(40).regions[0], truth.truth_regions["40"], "first boundary matches synthetic truth")
	s.expect_equal(store.get_corrected_record(59).regions[0], truth.truth_regions["59"], "last boundary matches synthetic truth")
	s.expect(not store.is_verified(40), "propagation never implies verification")
	s.expect_equal(store.snapshot_batch_operations().size(), 1, "one batch marker")
	s.expect_equal(main._history.get_undo_count(), 2, "keyframe edit and batch are two operations")
	var path: String = main._workspace_label_store.label_path()
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	s.expect_equal(saved.get("schema_version"), 2, "batch saved in V2 envelope")
	s.expect_equal(saved.get("batch_operations", []).size(), 1, "marker persisted with geometry")
	workflow.verify_range()
	s.expect_equal(main.get_current_frame(), 60, "verify range saves then advances to next unverified")
	for i in range(40, 60):
		s.expect(store.is_verified(i), "range verification frame %d" % i)
	main._run_history_undo()
	s.expect(not store.is_verified(40), "undo range verification")
	main._run_history_redo()
	s.expect(store.is_verified(40), "redo range verification")
	s.expect_equal(main._flush_workspace_changes(), PackedStringArray(), "flush after history")
	var marker: Dictionary = store.snapshot_batch_operations()[0]
	s.expect(marker.has("metric_id") and marker.has("threshold"), "auditable metric metadata")
	main._on_workspace_media_requested("batch_clip")
	s.expect(main._store.is_verified(59), "reopen restores accepted digest")
	s.expect_equal(main._store.snapshot_batch_operations().size(), 1, "reopen restores batch marker")
	s.expect_equal(FileAccess.get_sha256(model_path), model_hash, "original prediction bytes preserved")
	var export_path := directory.path_join("handoff")
	s.expect_equal(main.export_handoff(export_path), PackedStringArray(), "export reviewed batch")
	var exported: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(export_path.path_join("manifest.json")))
	s.expect(exported.get("review_state", {}).has("59"), "export retains accepted review metadata")
	main.seek(61)
	var label_store = main._workspace_label_store
	var original_path: String = label_store.label_path()
	var blocked := FileAccess.open(directory.path_join("blocked"), FileAccess.WRITE)
	blocked.store_string("occupied")
	blocked.close()
	label_store.set("_label_path", directory.path_join("blocked/labels.json"))
	workflow.verify_current()
	s.expect_equal(main.get_current_frame(), 61, "failed save blocks automatic advance")
	s.expect(not main._workspace_session.can_replace_context(), "failed review-only save blocks source replacement")
	label_store.set("_label_path", original_path)
	workflow.retry_save()
	s.expect(main._workspace_session.can_replace_context(), "successful retry restores navigation")
	var retry_payload: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(original_path))
	s.expect(retry_payload.review_state.has("61"), "retry really persisted review-only change")
	var measurements := {"recorded_at_utc": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info().string,
		"source_annotations_sha256": truth.source_annotations_sha256,
		"derived_predictions_sha256": model_hash,
"metric_id": plan.metric_id, "threshold": plan.threshold,
		"keyframe": 50, "range": [40,59], "covered_frames": 20, "changed_targets": 19,
		"manual_repeated_corrections": 20, "batch_keyframe_corrections": 1,
		"analysis_ms": analysis_ms, "apply_and_save_ms": apply_ms,
		"human_time_measured": false, "boundary_truth_match": true,
		"left_stop": plan.left_stop, "right_stop": plan.right_stop, "scores": plan.scores}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/output"))
	var file := FileAccess.open("res://tests/output/part3_batch_measurement.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(measurements, "  ") + "\n")
	file.close()
	completed = true
	print("Batch measurement: ", JSON.stringify(measurements))
