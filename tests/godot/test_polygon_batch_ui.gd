extends "res://tests/godot/test_polygon_batch.gd"

func run() -> void:
	var s = SUPPORT.new()
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/poly-ui-session-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var workflow = main._batch_workflow
	s.expect(workflow.get("_algorithm") != null, "batch UI offers an explicit algorithm selector")
	if workflow.get("_algorithm") != null:
		await _persistent_ui(s, main, workflow)
	main._workspace_session.suspend_autosave(true)
	await main._workspace_session.settle_running()
	main.queue_free()
	await process_frame
	if s.failures.is_empty():
		print("PASS polygon batch UI and persistence")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _persistent_ui(s, main, workflow) -> void:
	var f := _fixture()
	var directory := "/tmp/poly-ui-source-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(directory.path_join("frames"))
	var manifest := {"schema_version":1, "dataset_id":"poly-motion-fixture", "source_name":"motion",
		"source_sha256":"a".repeat(64), "nominal_fps":25.0, "frame_count":6, "width":160, "height":120,
		"model_version":"model_output_v1", "taxonomy_version":"fixture-v1", "frames":[]}
	for index in range(6):
		var relative := "frames/%06d.png" % index
		f.source.images[index].save_png(directory.path_join(relative))
		manifest.frames.append({"frame":index, "time_s":index * 0.04, "image_path":relative})
	var file := FileAccess.open(directory.path_join("manifest.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest))
	file.close()
	file = FileAccess.open(directory.path_join("model_output_v1.jsonl"), FileAccess.WRITE)
	for record: Dictionary in f.records:
		file.store_line(JSON.stringify(record))
	file.close()
	var model_hash := FileAccess.get_sha256(directory.path_join("model_output_v1.jsonl"))
	s.expect_equal(await main.open_source(directory), PackedStringArray(), "motion fixture opens through Source and persistent review session")
	if not workflow.available():
		s.expect(false, "persistent Poly UI is available")
		return
	var providers: Dictionary = workflow.controller.get("_providers")
	var poly_provider: Variant = providers.get(&"polygon_flow")
	s.expect(poly_provider != null and poly_provider.get("service") != null, "Poly provider exposes its service to the integration fixture")
	if poly_provider == null or poly_provider.get("service") == null:
		return
	poly_provider.service.job_root = directory.path_join("jobs")
	var initial_target: Dictionary = main._store.get_corrected_record(5)
	var initial_key: Dictionary = main._store.get_corrected_record(2)
	s.expect_equal(workflow._algorithm.selected, 0, "SAM remains the product default")
	s.expect_equal(workflow._algorithm.get_item_text(1), "Poly 光流 + 边缘精修", "Poly algorithm is named explicitly")
	s.expect_equal(workflow._algorithm.get_item_text(2), "固定坐标复制", "fixed-copy remains selectable")
	workflow._algorithm.select(1)
	workflow._select_algorithm(1)
	s.expect_equal(workflow._mode.selected, 1, "Poly selects merge")
	s.expect(not workflow._mode.disabled, "Poly allows overwrite or merge")
	s.expect(workflow._threshold.editable and workflow._threshold.get_parent().visible, "Poly exposes the similarity threshold")
	s.expect_equal(workflow._threshold.value, 0.1, "visible Poly similarity threshold defaults to relaxed 0.1")
	main._edit_state["navigation_blocked"] = true
	workflow._show_tab(true)
	s.expect(main._annotation_sidebar.visible and main._tool_panel.visible and not workflow._scroll.visible, "unfinished edit keeps annotation tools visible")
	main._edit_state["navigation_blocked"] = false
	main._class_dialog_mode = &"new_region"
	workflow._show_tab(true)
	s.expect(main._annotation_sidebar.visible and main._tool_panel.visible and not workflow._scroll.visible, "class modal keeps annotation tools visible")
	main._class_dialog_mode = &""
	workflow._threshold.value = 1.0
	main.seek(2)
	workflow._show_tab(true)
	workflow.analyze()
	var started := Time.get_ticks_msec()
	while workflow.controller.is_analyzing() and Time.get_ticks_msec() - started < 30000:
		await create_timer(0.01).timeout
	var plan: Dictionary = workflow.controller.get_plan()
	s.expect(not plan.is_empty(), "mounted UI completes real Poly analysis: " + workflow.controller.last_error)
	if plan.is_empty():
		workflow.cancel()
		return
	s.expect_equal(plan.get("metric_id"), "poly-sim-flow-edge-v1", "selector dispatches edge-aware motion algorithm")
	s.expect_equal(plan.end_index, 5, "UI range includes moving final frame")
	for phrase: String in ["候选", "抽样步长", "相似度停止", "光流停止", "边缘精修", "亮区回退", "固定回退"]:
		s.expect(phrase in workflow._summary.text, "main summary includes %s" % phrase)
	main.seek(5)
	workflow._show_preview.button_pressed = true
	var proposed: Dictionary = workflow.controller.proposed_record(5)
	s.expect_equal(main._viewport.get("_record"), proposed, "canvas shows per-frame motion preview")
	s.expect(workflow._verify_current.disabled, "preview cannot be verified")
	s.expect_equal(main._store.get_corrected_record(5), initial_target, "display leaves Store unchanged")
	await process_frame
	for button: Node in workflow._scroll.find_children("*", "Button", true, false):
		if button.text == "下一待检查帧":
			s.expect(button.get_global_rect().end.y <= workflow._scroll.get_global_rect().end.y, "Poly review controls fit at the default resolution")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/output"))
		root.get_texture().get_image().save_png("res://tests/output/poly-preview.png")
	await workflow.apply()
	s.expect_equal(main._store.get_corrected_record(5), proposed, "UI commits the exact preview")
	s.expect_equal(main._store.get_corrected_record(2), initial_key, "manual keyframe stays intact")
	s.expect(main._store.is_verified(5), "atomic confirmation installs the accepted review state")
	s.expect_equal(main._history.get_undo_count(), 1, "whole UI batch has one history operation")
	var saved_path: String = main._workspace_label_store.label_path()
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(saved_path))
	s.expect_equal(saved.get("batch_operations", []).size(), 1, "auto-save includes motion marker")
	s.expect_equal(await main.open_source(directory), PackedStringArray(), "saved Poly session reopens")
	s.expect_equal(main._store.get_corrected_record(5), proposed, "reopen restores exact moving polygon")
	s.expect_equal(main._store.snapshot_batch_operations()[0].metric_id, "poly-sim-flow-edge-v1", "reopen retains algorithm audit")
	s.expect_equal(FileAccess.get_sha256(directory.path_join("model_output_v1.jsonl")), model_hash, "original model records stay unchanged")
	main.seek(5)
	workflow._auto.button_pressed = false
	await workflow.unverify_current()
	s.expect(not main._store.is_verified(5), "human can reopen a confirmed propagated frame for review")
	await workflow.verify_current()
	s.expect(main._store.is_verified(5), "human can confirm propagated geometry")
	s.expect_equal(await main.open_source(directory), PackedStringArray(), "reviewed Poly session reopens")
	s.expect(main._store.is_verified(5), "reopen restores verification tied to polygon digest")
