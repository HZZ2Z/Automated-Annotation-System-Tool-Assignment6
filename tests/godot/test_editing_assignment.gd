extends "res://tests/godot/test_keyboard_reachability.gd"


func _run_tests() -> void:
	_test_working_mask_keyboard_and_local_history()
	_test_gap_preview_transaction()
	_test_selection_precision()
	_test_oversized_paint_target()
	_test_draft_budget()
	await _test_mounted_history_and_repair()
	if _failures.is_empty():
		print("PASS: Assignment editing regressions")
		quit(0)
	else:
		push_error("FAIL: Assignment editing regressions\n%s" % "\n".join(_failures))
		quit(1)


func _test_working_mask_keyboard_and_local_history() -> void:
	var f := _fixture()
	if not _activate(f, "WorkingMask keyboard"):
		return
	var original := _outline_state(Rect2i(30, 20, 41, 41), 3, 37, [])
	for y in range(3, 38):
		original.mask[y * 41 + 20] = 1
	_install_working_mask(f, original)
	var before: Dictionary = f.store.get_corrected_record(0)
	f.plugin.handle_key(_key(KEY_F))
	_expect_equal(f.plugin.get("_keyboard_tool"), &"fill", "F must enter keyboard Fill on a draft")
	_expect_equal(f.plugin.get("_session").working_mask, original, "F must preserve the outline")
	_expect(not f.plugin.handle_key(_key(KEY_TAB)), "Tab must leave active keyboard Fill for its options")
	_expect(not f.plugin.handle_key(_key(KEY_TAB, true)), "Shift+Tab must leave active keyboard Fill")
	f.plugin.handle_key(_key(KEY_LEFT, true))
	f.plugin.handle_key(_key(KEY_ENTER))
	var partial: Dictionary = f.plugin.get("_session").working_mask.duplicate(true)
	_expect(partial != original, "Enter must fill the first blank component")
	_expect_equal(f.class_requests.size(), 0, "a second hole must postpone class assignment")
	_expect(f.plugin.handle_key(_key(KEY_Z, false, true)), "draft owns Ctrl+Z")
	_expect_equal(f.plugin.get("_session").working_mask, original, "draft undo restores exactly the prior outline")
	f.plugin.handle_key(_key(KEY_Z, true, true))
	_expect_equal(f.plugin.get("_session").working_mask, partial, "draft redo restores the first Fill")
	f.plugin.handle_key(_key(KEY_RIGHT, true, true))
	f.plugin.handle_key(_key(KEY_ENTER))
	_expect_equal(f.class_requests.size(), 1, "the second Fill requests class exactly once")
	_expect_equal(f.store.get_corrected_record(0), before, "drafts cannot mutate Store")
	_expect_equal(f.history.get_undo_count(), 0, "draft history is separate from committed history")
	if f.class_requests.size() == 1:
		_expect(_confirm_pending_polygon(f, "keyboard filled", "region").is_empty(), "final class commits")
		_expect_equal(f.history.get_undo_count(), 1, "the complete object is one global command")
		_expect(f.history.undo(f.store), "complete object undo succeeds")
		_expect_equal(f.store.get_corrected_record(0), before, "global undo removes the whole completed object")


func _test_gap_preview_transaction() -> void:
	var f := _fixture()
	if not _activate(f, "approximate Fill"):
		return
	var before := _with_fill_boundaries(f.store.get_corrected_record(0))
	_find_region(before, "fill-top").box[2] = 10
	before.regions.append({"id": "top-second", "class": "boundary", "kind": "region", "box": [76, 50, 14, 3]})
	_expect(f.store.replace_corrected_record(0, before).is_empty(), "gap fixture is valid")
	f.plugin.call("_fill_at_point", 0, before, Vector2(75, 60), Vector2(100, 80))
	_expect_equal(_overlay(f).get("phase"), &"candidate", "one-pixel gap must offer repair preview")
	_expect(not _overlay(f).get("repair_mask", {}).is_empty(), "preview must expose repaired pixels")
	_expect_equal(f.class_requests.size(), 0, "repair must be accepted before class dialog")
	_expect_equal(f.store.get_corrected_record(0), before, "preview is Store-free")
	f.plugin.handle_key(_key(KEY_ESCAPE))
	_expect_equal(f.store.get_corrected_record(0), before, "cancelling repair preserves Store")
	_expect_equal(f.history.get_undo_count(), 0, "cancelling repair creates no history")
	f.plugin.call("_fill_at_point", 0, before, Vector2(75, 60), Vector2(100, 80))
	f.plugin.handle_key(_key(KEY_ENTER))
	_expect_equal(f.class_requests.size(), 1, "Enter accepts repair and opens class dialog")
	if f.class_requests.size() == 1:
		_expect(_confirm_pending_polygon(f, "repaired fill", "region").is_empty(), "accepted repair is V1-valid")
		_expect_equal(f.history.get_undo_count(), 1, "repair and fill commit together")
		_assert_export_snapshot(f)


func _test_selection_precision() -> void:
	var f := _fixture()
	if not _activate(f, "precise selection"):
		return
	var tiny := {"id": "tiny", "class": "object", "kind": "region", "box": [10, 10, 4, 4]}
	_expect_equal(f.plugin.call("_region_handle_at", tiny, f.viewport.transform.image_to_viewport(Vector2(14, 14))), 4,
		"overlapping handle radii must choose the nearest handle")
	var record: Dictionary = f.store.get_corrected_record(0)
	_expect_equal(f.plugin.call("_hit_test", record, Vector2(18, 30)).get("id", ""), "box-1",
		"outside edge within six viewport pixels should remain selectable")
	f.selected[0] = "box-1"
	f.plugin.handle_key(_key(KEY_V))
	f.plugin.handle_key(_key(KEY_ESCAPE))
	_expect_equal(f.selected[0], "", "idle Select Escape makes unselected Subtract keyboard reachable")
	_expect_equal(f.history.get_undo_count(), 0, "keyboard deselection is not an edit command")


func _test_oversized_paint_target() -> void:
	var f := _fixture()
	if not _activate(f, "oversized Paint target"):
		return
	var before: Dictionary = f.store.get_corrected_record(0)
	before.regions = [{"id": "huge", "class": "object", "kind": "region", "box": [0, 0, 1500, 800]}]
	f.plugin.call("_cache_brush_regions", before, Vector2i(2000, 1200))
	var stroke := {"ok": true, "roi": Rect2i(10, 10, 2, 2), "mask": PackedByteArray([1, 1, 1, 1])}
	var result: Dictionary = f.plugin.call("_paint_operation", stroke, "huge")
	_expect(not result.get("ok", true), "a failed selected-region raster cannot become a new Paint object")
	_expect("huge" in result.get("message", ""), "raster refusal must identify its region")
	before.regions = [{"id": "tiny", "class": "object", "kind": "region", "box": [20.1, 20.1, 0.2, 0.2]}]
	f.plugin.call("_cache_brush_regions", before, Vector2i(100, 80))
	stroke = {"ok": true, "roi": Rect2i(20, 20, 2, 2), "mask": PackedByteArray([1, 1, 1, 1])}
	result = f.plugin.call("_paint_operation", stroke, "tiny")
	_expect(not result.get("ok", true), "subpixel target without covered centers must refuse instead of creating a new object")


func _test_draft_budget() -> void:
	var history = load("res://client/domain/mask_draft_history.gd").new()
	history.capacity = 2
	var states: Array[Dictionary] = []
	for n in range(4):
		states.append({"roi": Rect2i(0, 0, 3, 1), "mask": PackedByteArray([int(n > 0), int(n > 1), int(n > 2)])})
	for i in range(3):
		history.record(states[i], states[i + 1])
	_expect_equal(history.counts().undo, 2, "draft history evicts oldest entries at capacity")
	_expect_equal(history.undo(states[3]), states[2], "latest diff remains undoable")
	history.record(states[2], states[0])
	_expect_equal(history.counts().redo, 0, "a divergent fill clears draft redo")
	history.clear()
	history.byte_budget = 70
	history.record(states[0], states[1])
	history.record(states[1], states[2])
	_expect(history.counts().bytes <= 70 and history.counts().undo == 1, "mask diff history respects byte budget")


func _test_mounted_history_and_repair() -> void:
	var main = load("res://client/app/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var source := "/tmp/project6-assignment-ui-%s.png" % OS.get_process_id()
	_expect_equal(_image().save_png(source), OK, "mounted fixture image saves")
	_expect(main.open_source(source).is_empty(), "real Main opens fixture source")
	var viewport: Control = main.get("_viewport")
	var edit = main.get("_edit_plugin")
	var store = main.get("_store")
	var history = main.get("_history")
	var record: Dictionary = store.get_corrected_record(0)
	record.regions = [{"id": "target", "class": "old", "kind": "region", "box": [20, 20, 20, 20]}]
	_expect(store.replace_corrected_record(0, record).is_empty(), "mounted initial region is valid")
	main.call("_refresh_current_annotations")
	main.call("_set_selected_region", "target")
	viewport.grab_focus()
	await process_frame
	for position: Vector2 in [Vector2(30, 30), Vector2(20, 20)]:
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		down.position = viewport.get_image_transform().image_to_viewport(position)
		edit.handle_pointer(down, position)
		var kind: String = edit.get("_drag_kind")
		_expect(kind in ["move", "resize"], "fixture starts Selection drag")
		await _dispatch_mounted(_key(KEY_R))
		_expect(not main.call("_is_class_dialog_active"), "R cannot interrupt a pressed Selection gesture before motion")
		_expect_equal(edit.get("_drag_kind"), kind, "R preserves the active drag")
		edit.cancel()
	await _dispatch_mounted(_key(KEY_R))
	_expect(main.call("_is_class_dialog_active"), "R opens the selected region class dialog")
	var dialog = main.get("_class_dialog")
	var label: LineEdit = dialog.get_node("Margin/Content/ClassLabel")
	_expect_equal(label.text, "old", "R preserves the existing label for editing")
	label.text = "new"
	label.text_changed.emit("new")
	label.text_submitted.emit("new")
	await process_frame
	_expect(not main.call("_is_class_dialog_active"), "free-text confirmation closes the class dialog")
	_expect_equal(store.get_corrected_record(0).regions[0].get("class"), "new", "R dialog commits free text")
	_expect_equal(history.get_undo_count(), 1, "R relabel is one command")
	var committed: Dictionary = store.get_corrected_record(0)
	var text_field := LineEdit.new()
	root.add_child(text_field)
	text_field.grab_focus()
	await process_frame
	var letter := _key(KEY_X)
	letter.unicode = 120
	await _dispatch_mounted(letter)
	_expect_equal(text_field.text, "x", "focused text input receives typing")
	await _dispatch_mounted(_key(KEY_Z, false, true))
	_expect_equal(text_field.text, "", "Ctrl+Z belongs to the focused text input")
	_expect_equal(store.get_corrected_record(0), committed, "text undo cannot undo a region edit")
	_expect_equal(history.get_undo_count(), 1, "text undo preserves global command stack")
	text_field.queue_free()
	viewport.grab_focus()
	await process_frame
	var mask := _outline_state(Rect2i(30, 20, 41, 41), 3, 37, [])
	for y in range(3, 38):
		mask.mask[y * 41 + 20] = 1
	var session = edit.get("_session")
	session.begin(&"paint", 0, "", committed)
	session.set_working_mask(mask)
	edit.call("_push_session_overlay")
	await _dispatch_mounted(_key(KEY_F))
	await _dispatch_mounted(_key(KEY_TAB))
	_expect(root.gui_get_focus_owner() != viewport, "real Tab must leave keyboard Fill without discarding its draft")
	_expect_equal(session.working_mask, mask, "focus traversal preserves the draft")
	viewport.grab_focus()
	await _dispatch_mounted(_key(KEY_LEFT, true))
	await _dispatch_mounted(_key(KEY_ENTER))
	_expect(session.working_mask != mask, "real focused canvas can fill a draft")
	await _dispatch_mounted(_key(KEY_Z, false, true))
	_expect_equal(session.working_mask, mask, "Main dispatches Ctrl+Z to local draft history")
	_expect_equal(history.get_undo_count(), 1, "draft undo preserves the committed edit")
	await _dispatch_mounted(_key(KEY_ESCAPE))
	var gap := _with_fill_boundaries(committed)
	_find_region(gap, "fill-top").box[2] = 10
	gap.regions.append({"id": "top-second", "class": "boundary", "kind": "region", "box": [76, 50, 14, 3]})
	_expect(store.replace_corrected_record(0, gap).is_empty(), "mounted gap is valid")
	main.call("_refresh_current_annotations")
	edit.call("_fill_at_point", 0, gap, Vector2(75, 60), Vector2(100, 80))
	var panel = main.get("_tool_panel")
	var actions: HBoxContainer = panel.get_node("FillRepairActions")
	_expect(actions.visible, "mounted tool panel exposes repair confirmation")
	var args := OS.get_cmdline_user_args()
	var screenshot_index := args.find("--screenshot")
	if DisplayServer.get_name() != "headless" and screenshot_index >= 0 and screenshot_index + 1 < args.size():
		await process_frame
		await RenderingServer.frame_post_draw
		_expect_equal(root.get_texture().get_image().save_png(args[screenshot_index + 1]), OK, "visible Fill preview screenshot saves")
	(actions.get_child(1) as Button).pressed.emit()
	_expect(not session.has_fill_repair(), "real Cancel action discards only repair")
	edit.call("_fill_at_point", 0, gap, Vector2(75, 60), Vector2(100, 80))
	(actions.get_child(0) as Button).pressed.emit()
	_expect(main.call("_is_class_dialog_active"), "real Apply fill action opens class assignment")
	_expect_equal(store.get_corrected_record(0), gap, "class-pending repair remains uncommitted")
	main.queue_free()
	await process_frame


func _assert_export_snapshot(f: Dictionary) -> void:
	var directory := "/tmp/project6-editing-export-%s-%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(directory)
	var original_path := directory.path_join("model_output_v1.jsonl")
	var original := FileAccess.open(original_path, FileAccess.WRITE)
	original.store_line(JSON.stringify(_record()))
	original.close()
	var original_hash := FileAccess.get_sha256(original_path)
	var digest: String = f.store.model_digest()
	var records: Array = f.store.snapshot_corrected()
	var exporter = load("res://client/plugins/feedback/file_training_handoff/plugin.gd").new()
	var errors: PackedStringArray = exporter.export({
		"records": records, "output_path": directory.path_join("handoff"),
		"source_manifest": {"dataset_id": "editing-assignment", "source_sha256": null,
			"model_version": "model_output_v1", "taxonomy_version": "none", "frame_count": 1},
		"model_digest": digest, "dirty_frames": [0], "batch_operations": [],
	})
	_expect(errors.is_empty(), "repaired Fill exports through the real Feedback plugin")
	_expect_equal(f.store.model_digest(), digest, "export preserves immutable model digest")
	_expect_equal(FileAccess.get_sha256(original_path), original_hash, "corrected export preserves original model file bytes")
	var validator = load("res://client/domain/model_output_validator.gd").new()
	for record: Dictionary in records:
		_expect(validator.validate_record(record).is_empty(), "exported repaired geometry validates")
	var evidence := FileAccess.open("/tmp/project6-editing-export-latest.txt", FileAccess.WRITE)
	evidence.store_line(directory.path_join("handoff/data/corrected_annotations.jsonl"))


func _dispatch_mounted(event: InputEventKey) -> void:
	Input.parse_input_event(event)
	await process_frame
	var release := event.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame
