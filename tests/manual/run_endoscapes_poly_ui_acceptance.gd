extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var support = SUPPORT.new()
	var fixture := OS.get_environment("PROJECT6_ENDOSCAPES_FIXTURE")
	var evidence := OS.get_environment("PROJECT6_ENDOSCAPES_EVIDENCE")
	support.expect(not fixture.is_empty() and not evidence.is_empty(),
		"fixture and evidence environment paths are required")
	if fixture.is_empty() or evidence.is_empty():
		_finish(support)
		return
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/endoscapes-poly-ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var model_path := fixture.path_join("model_output_v1.jsonl")
	var model_hash := FileAccess.get_sha256(model_path)
	support.expect_equal(await main.open_source(fixture), PackedStringArray(),
		"copied Endoscapes fixture opens in Main")
	var workflow = main._batch_workflow
	var providers: Dictionary = workflow.controller.get("_providers")
	var provider: Variant = providers.get(&"polygon_flow")
	support.expect(provider != null and provider.get("service") != null,
		"mounted Batch exposes the Poly service")
	if provider == null or provider.get("service") == null:
		await _close(main)
		_finish(support)
		return
	provider.service.job_root = evidence.path_join("ui-jobs")
	main.seek(1)
	workflow._show_tab(true)
	support.expect_equal(workflow._algorithm.get_item_text(workflow._algorithm.selected),
		"Poly 光流 + 边缘精修", "mounted Batch defaults to edge-aware Poly")
	support.expect_equal(workflow._threshold.value, 0.1,
		"mounted Batch shows the acceptance threshold")
	workflow.analyze()
	var started := Time.get_ticks_msec()
	while workflow.controller.is_analyzing() and Time.get_ticks_msec() - started < 30000:
		await create_timer(0.01).timeout
	var plan: Dictionary = workflow.controller.get_plan()
	support.expect(not plan.is_empty(), "real Endoscapes analysis completes: %s" % workflow.controller.last_error)
	if plan.is_empty():
		await _close(main)
		_finish(support)
		return
	support.expect_equal([plan.start_index, plan.end_index], [1, 2],
		"real mounted proposal range matches the direct worker evidence")
	support.expect_equal(plan.target_regions.keys(), [2],
		"real mounted UI exposes only original frame 11825 as a target")
	for phrase: String in ["候选", "相似度停止", "光流停止", "边缘精修", "光流回退"]:
		support.expect(phrase in workflow._summary.text,
			"mounted summary names %s" % phrase)
	main.seek(2)
	workflow._show_preview.button_pressed = true
	var before: Dictionary = main._store.get_corrected_record(2)
	var proposed: Dictionary = workflow.controller.proposed_record(2)
	support.expect_equal(main._viewport.get("_record"), proposed,
		"Endoscapes canvas displays the exact read-only proposal")
	support.expect_equal(before.regions, [], "target remains empty before Apply")
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		support.expect_equal(root.get_texture().get_image().save_png(
			evidence.path_join("ui-batch-preview.png")), OK,
			"mounted preview screenshot is saved")
	await workflow.apply()
	support.expect_equal(main._store.get_corrected_record(2), proposed,
		"Apply commits the exact Endoscapes proposal")
	support.expect_equal(main._history.get_undo_count(), 1,
		"real Endoscapes batch is one undo item")
	main._run_history_undo()
	support.expect_equal(main._store.get_corrected_record(2), before,
		"one undo restores the empty target")
	support.expect_equal(await main._flush_workspace_changes(), PackedStringArray(),
		"undone state saves before redo")
	main._run_history_redo()
	support.expect_equal(main._store.get_corrected_record(2), proposed,
		"one redo restores the exact proposal")
	support.expect_equal(await main._flush_workspace_changes(), PackedStringArray(),
		"redone state saves before reopen")
	support.expect_equal(await main.open_source(fixture), PackedStringArray(),
		"saved Endoscapes session reopens")
	support.expect_equal(main._store.get_corrected_record(2), proposed,
		"reopen restores the exact proposal")
	support.expect_equal(main._store.snapshot_batch_operations().size(), 1,
		"reopen restores the v2 Poly audit marker")
	support.expect_equal(FileAccess.get_sha256(model_path), model_hash,
		"UI acceptance leaves the fixture model baseline unchanged")
	main.seek(2)
	workflow._auto.button_pressed = true
	await workflow.verify_current()
	support.expect(main._store.is_verified(2),
		"reviewer confirmation marks the propagated target verified")
	support.expect_equal(main.get_current_frame(), 3,
		"auto-next advances from the confirmed target")
	var auto_next_frame: int = main.get_current_frame()
	await main._workspace_session.settle_running()
	support.expect_equal(await main.open_source(fixture), PackedStringArray(),
		"confirmed Endoscapes session reopens")
	support.expect(main._store.is_verified(2),
		"reopen restores verification bound to the proposal digest")
	var report_path := evidence.path_join("ui-report.json")
	var report := {"schema_version":1, "status":"passed" if support.failures.is_empty() else "failed",
		"fixture":"endoscapes-65-11775-11875", "key_playback_index":1,
		"proposal_indices":[2], "apply":true, "undo":true, "redo":true,
		"save_reopen":true, "confirm":true, "auto_next_frame":auto_next_frame,
		"failures":support.failures}
	var stream := FileAccess.open(report_path, FileAccess.WRITE)
	if stream != null:
		stream.store_string(JSON.stringify(report, "  ") + "\n")
		stream.close()
	else:
		support.expect(false, "could not save mounted UI report")
	await _close(main)
	_finish(support)


func _close(main: Variant) -> void:
	main._workspace_session.suspend_autosave(true)
	await main._workspace_session.settle_running()
	main.queue_free()
	await process_frame


func _finish(support: Variant) -> void:
	if support.failures.is_empty():
		print("PASS Endoscapes mounted Poly UI acceptance")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)
