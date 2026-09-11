extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var s = SUPPORT.new()
	await _no_candidate_jump_clears_preview(s)
	await _candidate_selectors_stay_on_their_keyframe_sides(s)
	if s.failures.is_empty():
		print("PASS batch no-candidate UI")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _no_candidate_jump_clears_preview(s) -> void:
	var main = await _open_main([49, 56, 63, 609, 610, 611])
	var workflow = main._batch_workflow
	main.seek(0)
	workflow._show_tab(true)
	workflow._algorithm.select(1)
	workflow._select_algorithm(1)
	_inject_plan(workflow, 0, 0, 0, "polygon_flow", "missing original frame ID")
	workflow._process(0.0)
	var range_controls: Variant = workflow.get("_range_controls")
	s.expect(range_controls != null and not range_controls.visible, "no candidate hides misleading endpoints")
	s.expect(workflow._apply.disabled, "no candidate cannot be applied")
	s.expect("56" in workflow._summary.text and "50–55" in workflow._summary.text,
		"primary summary names the next frame and missing interval")
	var next_contiguous: Variant = workflow.get("_next_contiguous")
	s.expect(next_contiguous != null and next_contiguous.visible and not next_contiguous.disabled,
		"Poly refusal offers an enabled next continuous run action")
	var controller = workflow.controller
	s.expect_equal(controller.find_next_contiguous_run(0), Vector2i(3,5),
		"next continuous run uses playback indices and exact consecutive IDs")
	workflow._toggle_preview(true)
	s.expect(workflow._preview and workflow._verify_current.disabled, "one-frame preview is explicitly read-only before jumping")
	workflow._jump_to_next_contiguous()
	s.expect_equal(main.get_current_frame(), 3, "jump seeks the next exact-contiguous run by playback index")
	s.expect(workflow.controller.get_plan().is_empty() and workflow._range == Vector2i(-1, -1),
		"jump clears the old candidate plan and timeline range")
	s.expect(not range_controls.visible and not next_contiguous.visible, "jump removes stale range controls")
	s.expect(not workflow._preview and not workflow._show_preview.button_pressed and not workflow._verify_current.disabled,
		"jump clears read-only preview state so the new keyframe is actionable")
	s.expect("重新分析" in workflow._summary.text, "jump instructs the operator to choose or correct a keyframe before analysis")
	await _dispose_main(main)

func _candidate_selectors_stay_on_their_keyframe_sides(s) -> void:
	var main = await _open_main([49, 50, 51, 52])
	var workflow = main._batch_workflow
	main.seek(1)
	workflow._show_tab(true)
	_inject_plan(workflow, 0, 1, 3, "copy", "source boundary")
	workflow._process(0.0)
	s.expect_equal(workflow._first_entry.item_count, 2, "first selector excludes entries after the keyframe")
	s.expect_equal(workflow._first_entry.get_item_text(0), "49", "first selector starts at the exact source frame ID")
	s.expect_equal(workflow._first_entry.get_item_text(1), "50", "first selector includes the keyframe")
	s.expect_equal(workflow._last_entry.item_count, 3, "last selector excludes entries before the keyframe")
	s.expect_equal(workflow._last_entry.get_item_text(0), "50", "last selector starts at the keyframe")
	s.expect_equal(workflow._last_entry.get_item_text(2), "52", "last selector ends at the exact candidate endpoint")
	workflow._first_entry.select(1)
	workflow._last_entry.select(1)
	workflow._update_preview()
	s.expect_equal(workflow._range, Vector2i(1, 2), "selected endpoints map to their exact playback indices without frame-ID arithmetic")
	workflow.clear()
	s.expect(workflow._range_model.indices().is_empty() and workflow._first_entry.item_count == 0 and workflow._last_entry.item_count == 0,
		"clearing a source discards stale range mappings and selector items")
	s.expect(not workflow._range_controls.visible and not workflow._next_contiguous.visible, "clearing a source hides stale candidate controls")
	await _dispose_main(main)

func _open_main(frame_ids: Array) -> Variant:
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/batch-no-candidate-ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var directory := "/tmp/batch-no-candidate-source-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_make_sparse_fixture(directory, frame_ids)
	var errors: PackedStringArray = await main.open_source(directory)
	if not errors.is_empty():
		push_error("Sparse image sequence did not open: %s" % errors[0])
	return main

func _dispose_main(main: Variant) -> void:
	main._workspace_session.suspend_autosave(true)
	await main._workspace_session.settle_running()
	main.queue_free()
	await process_frame

func _make_sparse_fixture(directory: String, frame_ids: Array) -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	for frame_id: int in frame_ids:
		var image := Image.create(8, 8, false, Image.FORMAT_RGB8)
		image.fill(Color(0.2, 0.2, 0.2))
		image.save_png(directory.path_join("%06d.png" % frame_id))

func _inject_plan(workflow: Variant, start_index: int, key_index: int, end_index: int, strategy: String, right_stop: String) -> void:
	var keyframe := int(workflow._host._frame_entries[key_index].frame_id)
	workflow.controller._strategy = strategy
	workflow.controller._plan = {
		"keyframe": keyframe,
		"key_index": key_index,
		"start_index": start_index,
		"end_index": end_index,
		"left_stop": "source boundary",
		"right_stop": right_stop,
		"metric_id": "poly-sim-flow-edge-v1" if strategy == "polygon_flow" else "normalized-mad-v1",
		"threshold": 0.02,
		"max_frames": 30,
		"target_regions": {},
	}
	workflow.controller._key_record = workflow._store.get_corrected_record(keyframe)
