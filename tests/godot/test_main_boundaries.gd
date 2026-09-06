extends RefCounted

const MAIN_SCENE := preload("res://client/app/main.tscn")
const SOURCE_PROBE := preload("res://tests/godot/fixtures/integration_plugins/counting_source.gd")
const EDIT_PROBE := preload("res://tests/godot/fixtures/integration_plugins/probe_edit.gd")
const TEMP_PREFIX := "/tmp/annotool-task9-fix1-"

var _temp_paths: Array[String] = []


class CancelCountingEdit extends RefCounted:
	var cancel_count := 0
	var deactivate_count := 0

	func cancel() -> void:
		cancel_count += 1

	func deactivate() -> void:
		deactivate_count += 1

	func get_active_tool() -> StringName:
		return &"select"


class PointerStoreProbe extends RefCounted:
	var reads := 0
	var record := {
		"schema_version": 1,
		"source": "pointer-store",
		"frame": 0,
		"regions": [],
	}

	func get_corrected_record(_frame: int) -> Dictionary:
		reads += 1
		return record.duplicate(true)


class PointerEditProbe extends RefCounted:
	var pointer_events := 0
	var active_tool: StringName = &"select"

	func handle_pointer(_event: InputEvent, _image_position: Vector2) -> void:
		pointer_events += 1

	func get_active_tool() -> StringName:
		return active_tool


class RecordingSourceFactory extends RefCounted:
	var delegate: Variant
	var preferred_ids: Array[String] = []

	func _init(source_factory: Variant) -> void:
		delegate = source_factory

	func open(locator: String, preferred_id: String = "") -> Dictionary:
		preferred_ids.append(preferred_id)
		return delegate.open(locator, preferred_id)


func run(support, tree: SceneTree) -> void:
	await _test_main_owns_the_only_history_ui_entrypoints(support, tree)
	await _test_pointer_reads_only_at_commit_boundaries(support, tree)
	await _test_catalog_sidebar_and_failed_open_are_transactional(support, tree)
	await _test_sidebar_intents_and_reclassification(support, tree)
	await _test_modal_guards_all_main_entrypoints(support, tree)
	await _test_keyboard_preview_and_text_focus(support, tree)
	await _test_candidate_class_requests_are_transactional(support, tree)
	await _test_candidate_cleanup_and_transactional_edit(support, tree)
	await _test_tool_option_without_plugin_rolls_back(support, tree)
	await _test_navigation_wrappers_have_one_cancel_owner(support, tree)
	await _test_source_boundary_validation(support, tree)
	await _test_numeric_sequence_uses_sparse_source_mapping(support, tree)
	await _test_workspace_forwards_configured_source_plugin(support, tree)
	await _test_source_dialog_routes_plugin_owned_locators(support, tree)
	await _test_configured_plugin_ids(support, tree)
	_cleanup(support)


func _test_main_owns_the_only_history_ui_entrypoints(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	support.expect(main.has_method("_input"), "Main should expose the early global-input history boundary")
	support.expect(not main.has_method("_on_undo_pressed"),
		"obsolete Undo button handler should be removed with the Undo button")
	support.expect(main.get_node_or_null("MainVBox/TopToolbar/Undo") == null,
		"Main history surface should not recreate a redundant Undo control")
	var redo := main.get_node_or_null("MainVBox/TopToolbar/Redo") as Button
	support.expect(redo != null, "Main history surface should retain the explicit Redo control")
	var redo_is_wired := false
	if redo != null:
		for connection: Dictionary in redo.pressed.get_connections():
			var callback: Callable = connection.get("callable", Callable())
			if callback.is_valid() and callback.get_method() == "_on_redo_pressed":
				redo_is_wired = true
	support.expect(redo_is_wired, "retained Redo control should remain wired to Main's history boundary")
	await _free_main(main, tree)


func _test_pointer_reads_only_at_commit_boundaries(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var store := PointerStoreProbe.new()
	var edit := PointerEditProbe.new()
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var visible_record := {
		"schema_version": 1,
		"source": "visible-sentinel",
		"frame": 9,
		"regions": [],
	}
	viewport.call("set_record", visible_record)
	main.set("_store", store)
	main.set("_edit_plugin", edit)
	main.set("_current_frame", 0)

	var hover := InputEventMouseMotion.new()
	main.call("_on_image_pointer_event", hover, Vector2(5, 5))
	support.expect_equal(store.reads, 0,
		"hover/motion should perform no committed-record snapshot reads")
	support.expect_equal(edit.pointer_events, 1, "hover should still reach the Edit plugin once")
	support.expect_equal(viewport.get("_record"), visible_record,
		"hover should not refresh committed viewport annotations")

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	main.call("_on_image_pointer_event", press, Vector2(5, 5))
	support.expect_equal(store.reads, 0,
		"ordinary left gesture start should pause without snapshot comparison")
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	main.call("_on_image_pointer_event", release, Vector2(5, 5))
	support.expect_equal(store.reads, 2,
		"ordinary release should compare exactly one before/after Store pair")
	support.expect_equal(viewport.get("_record"), visible_record,
		"an unchanged commit boundary should not refresh viewport annotations")

	edit.active_tool = &"fill"
	main.call("_on_image_pointer_event", press, Vector2(5, 5))
	support.expect_equal(store.reads, 4,
		"Fill press should compare exactly one before/after Store pair because Fill completes on press")
	support.expect_equal(viewport.get("_record"), visible_record,
		"an unchanged immediate Fill should not refresh committed viewport annotations")
	main.call("_on_image_pointer_event", release, Vector2(5, 5))
	support.expect_equal(store.reads, 4,
		"Fill release should be inert after the press-owned operation")
	await _free_main(main, tree)


func _test_catalog_sidebar_and_failed_open_are_transactional(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_catalog_source(support, "catalog-transaction")
	support.expect_equal(main.open_source(root), PackedStringArray(),
		"the real two-frame catalog source should open")
	var sidebar = main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar"
	)
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var project_rows: Array[Dictionary] = sidebar.get_project_rows_snapshot()
	support.expect_equal(_project_counts(project_rows), {
		"cystic_duct": 1,
		"gallbladder": 0,
		"grasper": 1,
	}, "source open must index all frames while counts describe frame zero")
	support.expect_equal(sidebar.get_frame_rows_snapshot().size(), 2,
		"frame zero should populate both current annotations")

	main.call("_set_selected_region", "duct-0")
	sidebar.region_hovered.emit("duct-0")
	var old_source = main.get("_source")
	var old_store = main.get("_store")
	var old_catalog = main.get("_class_catalog")
	var old_resolver = main.get("_color_resolver")
	var old_project_rows: Array[Dictionary] = sidebar.get_project_rows_snapshot()
	var old_frame_rows: Array[Dictionary] = sidebar.get_frame_rows_snapshot()
	var old_viewport := _viewport_snapshot(viewport)
	var errors: PackedStringArray = main.open_source("/tmp/annotool-task9-source-does-not-exist")
	support.expect(not errors.is_empty(), "failed source replacement should report an error")
	support.expect(main.get("_source") == old_source and main.get("_store") == old_store,
		"failed source replacement must preserve source and Store identity")
	support.expect(main.get("_class_catalog") == old_catalog and main.get("_color_resolver") == old_resolver,
		"failed source replacement must preserve catalog and resolver identity")
	support.expect_equal(sidebar.get_project_rows_snapshot(), old_project_rows,
		"failed source replacement must preserve project rows exactly")
	support.expect_equal(sidebar.get_frame_rows_snapshot(), old_frame_rows,
		"failed source replacement must preserve frame rows exactly")
	support.expect_equal(main.call("_get_selected_region_id"), "duct-0",
		"failed source replacement must preserve authoritative selection")
	support.expect_equal(viewport.get_hovered_region_id(), "duct-0",
		"failed source replacement must preserve transient hover")
	support.expect_equal(_viewport_snapshot(viewport), old_viewport,
		"failed source replacement must preserve the visible frame exactly")
	await _free_main(main, tree)


func _test_sidebar_intents_and_reclassification(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_catalog_source(support, "sidebar-intents")
	support.expect_equal(main.open_source(root), PackedStringArray(), "sidebar intent source should open")
	var sidebar = main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar"
	)
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var store = main.get("_store")
	var history = main.get("_history")

	sidebar.region_selected.emit("duct-0")
	support.expect_equal(main.call("_get_selected_region_id"), "duct-0",
		"sidebar click intent should use Main's authoritative selection")
	support.expect_equal(viewport.get("_selected_id"), "duct-0",
		"sidebar click intent should synchronize canvas selection")
	var record_before: Dictionary = store.get_corrected_record(0)
	var undo_before: int = history.get_undo_count()
	sidebar.region_hovered.emit("duct-0")
	support.expect_equal(viewport.get_hovered_region_id(), "duct-0",
		"sidebar hover should use the viewport's optional hover channel")
	support.expect_equal(store.get_corrected_record(0), record_before,
		"hover must not mutate Store")
	support.expect_equal(history.get_undo_count(), undo_before,
		"hover must not mutate History")
	support.expect_equal(main.call("_get_selected_region_id"), "duct-0",
		"hover must not mutate selection")
	sidebar.region_hovered.emit("")
	support.expect_equal(viewport.get_hovered_region_id(), "", "mouse exit intent should clear hover")

	sidebar.call("_set_hovered_region_id", "duct-0")
	var renderer = viewport.get("_renderer")
	support.expect_equal(sidebar.get("_hovered_region_id"), "duct-0",
		"reclassification fixture should establish real sidebar hover state")
	support.expect_equal(viewport.get_hovered_region_id(), "duct-0",
		"reclassification fixture should establish viewport hover state")
	support.expect_equal(str(renderer.get("_hovered_id")), "duct-0",
		"reclassification fixture should establish renderer hover state")
	var expected_record: Dictionary = record_before.duplicate(true)
	var expected_region := _find_region(expected_record, "duct-0")
	expected_region["class"] = "new lesion"
	expected_region["kind"] = "pathology custom"
	sidebar.region_reclassify_requested.emit("duct-0")
	var dialog = main.get_node("ClassAssignmentDialog")
	support.expect(dialog.is_assignment_open(), "row activation should open reclassification")
	support.expect_equal(main.get("_class_dialog_mode"), &"reclassify",
		"existing-region activation should use reclassification mode")
	support.expect_equal((dialog.get_node("Margin/Content/ClassLabel") as LineEdit).text, "cystic_duct",
		"reclassification should present the selected region's exact class")
	support.expect_equal((dialog.get_node("Margin/Content/Kind") as LineEdit).text, "anatomy",
		"reclassification should present the selected region's exact free-form kind")
	(dialog.get_node("Margin/Content/ClassLabel") as LineEdit).text = " new lesion "
	(dialog.get_node("Margin/Content/Kind") as LineEdit).text = " pathology custom "
	(dialog.get_node("Margin/Content/Actions/Confirm") as Button).pressed.emit()
	await tree.process_frame
	var changed := _find_region(store.get_corrected_record(0), "duct-0")
	support.expect_equal([changed.get("class"), changed.get("kind")], ["new lesion", "pathology custom"],
		"dialog confirmation must atomically forward exact class and kind")
	support.expect_equal(store.get_corrected_record(0), expected_record,
		"reclassification plus hover teardown must mutate only the intended class and kind")
	support.expect_equal(history.get_undo_count(), undo_before + 1,
		"reclassification should create exactly one History command")
	support.expect_equal(sidebar.get("_hovered_region_id"), "",
		"authoritative sidebar rebuild must clear sidebar hover")
	support.expect_equal(viewport.get_hovered_region_id(), "",
		"authoritative sidebar rebuild must clear viewport hover")
	support.expect_equal(str(renderer.get("_hovered_id")), "",
		"authoritative sidebar rebuild must clear renderer hover")
	support.expect(not dialog.is_assignment_open() and StringName(main.get("_class_dialog_mode")) == &"",
		"successful reclassification should close the dialog once")
	support.expect_equal(_project_counts(sidebar.get_project_rows_snapshot()), {
		"gallbladder": 0,
		"grasper": 1,
		"new lesion": 1,
	}, "reclassification should refresh project union and current-frame counts")

	var delete_key := InputEventKey.new()
	delete_key.keycode = KEY_DELETE
	delete_key.pressed = true
	support.expect(main.call("_route_edit_key", delete_key),
		"Delete should continue through the selected Edit tool")
	support.expect(_find_region(store.get_corrected_record(0), "duct-0").is_empty(),
		"whole-region Delete should remove the selected annotation")
	support.expect_equal(sidebar.get_frame_rows_snapshot().size(), 1,
		"deletion should refresh current-frame rows")
	main.call("_run_history_undo")
	support.expect(not _find_region(store.get_corrected_record(0), "duct-0").is_empty(),
		"undo should restore the deleted region")
	support.expect_equal(sidebar.get_frame_rows_snapshot().size(), 2,
		"undo should refresh current-frame rows")
	main.call("_run_history_redo")
	support.expect(_find_region(store.get_corrected_record(0), "duct-0").is_empty(),
		"redo should reapply deletion")
	support.expect_equal(sidebar.get_frame_rows_snapshot().size(), 1,
		"redo should refresh current-frame rows")
	await _free_main(main, tree)


func _test_modal_guards_all_main_entrypoints(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_catalog_source(support, "modal-guards")
	support.expect_equal(main.open_source(root), PackedStringArray(), "modal guard source should open")
	main.call("_set_selected_region", "duct-0")
	var edit = main.get("_edit_plugin")
	support.expect_equal(edit.invoke(&"relabel_selected", {
		"class": "guard baseline",
		"kind": "guard kind",
	}), PackedStringArray(), "modal history setup should create one undoable command")
	main.call("_refresh_after_edit", true)
	var viewport := main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport"
	) as Control
	viewport.grab_focus()
	await tree.process_frame
	main.call("_open_reclassification_dialog", "duct-0")
	var dialog = main.get_node("ClassAssignmentDialog")
	support.expect(dialog.is_assignment_open(), "modal guard setup should open the dialog")
	var source_before = main.get("_source")
	var record_before: Dictionary = main.get("_store").get_corrected_record(0)
	var undo_before: int = main.get("_history").get_undo_count()
	var redo_before: int = main.get("_history").get_redo_count()
	var tool_before: StringName = edit.get_active_tool()
	var token_before: int = int(main.get("_class_dialog_token"))

	main.play()
	support.expect(not main.is_playing(), "Play must be refused while class assignment is active")
	support.expect(not main.step(1) and not main.seek(1) and not main.set_frame(1),
		"Previous/Next, seek, and direct frame commit must be refused while modal")
	main.call("_on_timeline_frame_requested", 1)
	main.call("_on_explorer_frame_requested", 1)
	main.call("_on_tool_requested", &"box")
	main.call("_run_history_undo")
	main.call("_run_history_redo")
	var export_errors: PackedStringArray = main.export_handoff(
		"/tmp/annotool-task9-modal-export-%d" % OS.get_process_id())
	var open_errors: PackedStringArray = main.open_source(root)
	main.call("_on_file_selected", "/tmp/annotool-task9-modal-video.mp4")
	support.expect(not export_errors.is_empty() and not open_errors.is_empty(),
		"export and source replacement must report modal refusal")
	support.expect(main.get("_source") == source_before and main.get_current_frame() == 0,
		"modal navigation attempts must preserve source and frame")
	support.expect_equal(main.get("_store").get_corrected_record(0), record_before,
		"modal undo/redo attempts must preserve Store")
	support.expect_equal([main.get("_history").get_undo_count(), main.get("_history").get_redo_count()],
		[undo_before, redo_before], "modal undo/redo attempts must preserve History depth")
	support.expect_equal(edit.get_active_tool(), tool_before,
		"modal tool changes must be refused")
	support.expect(dialog.is_assignment_open() and int(main.get("_class_dialog_token")) == token_before,
		"all refused paths must retain the same dialog transaction")
	support.expect(not (main.get_node("VideoImportDialog") as Window).visible,
		"video import setup must not open behind class assignment")
	for path in [
		"MainVBox/TopToolbar/Open",
		"MainVBox/TopToolbar/Redo",
		"MainVBox/TopToolbar/Export",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Previous",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Next",
	]:
		support.expect((main.get_node(path) as BaseButton).disabled,
			"modal toolbar control must be disabled: %s" % path)

	var cancellations := [0]
	dialog.assignment_cancelled.connect(func(): cancellations[0] += 1)
	(dialog.get_node("Margin/Content/ClassLabel") as LineEdit).grab_focus()
	await tree.process_frame
	await _dispatch_viewport_key(dialog, KEY_ESCAPE, tree)
	support.expect_equal(cancellations[0], 1,
		"focused real Escape must cancel existing-region reclassification exactly once")
	support.expect(not dialog.is_assignment_open() and main.get("_class_dialog_mode") == &"",
		"focused real Escape should close and clear existing-region reclassification")
	support.expect(viewport.has_focus(),
		"focused real Escape should restore the AnnotationViewport focus owner")
	support.expect_equal(main.get("_store").get_corrected_record(0), record_before,
		"reclassification Escape must preserve exact Store bytes")
	support.expect_equal([main.get("_history").get_undo_count(), main.get("_history").get_redo_count()],
		[undo_before, redo_before], "reclassification Escape must preserve both History depths")
	main.call("_run_history_undo")
	support.expect_equal(_find_region(main.get("_store").get_corrected_record(0), "duct-0").get("class"),
		"cystic_duct", "global undo should work again after modal cancellation")
	support.expect(main.seek(1), "frame navigation should work again after modal cancellation")
	await _free_main(main, tree)


func _test_keyboard_preview_and_text_focus(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_source(support, "keyboard", 40, 30)
	support.expect_equal(main.open_source(root), PackedStringArray(), "keyboard fixture should open")
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	viewport.grab_focus()
	await tree.process_frame
	var committed_count_before: int = viewport.get("_record").get("regions", []).size()
	await _dispatch_key(tree, KEY_A, 97)
	var overlay: Dictionary = viewport.call("get_edit_overlay_state")
	support.expect_equal(overlay.get("phase"), &"drawing", "A dispatched through Main should keep the keyboard-add overlay visible")
	var initial_path: PackedVector2Array = overlay.get("path", PackedVector2Array()).duplicate()
	support.expect_equal(viewport.get("_record").get("regions", []).size(), committed_count_before, "keyboard-add overlay should not enter committed content")
	await _dispatch_key(tree, KEY_LEFT, 0, true)
	overlay = viewport.call("get_edit_overlay_state")
	support.expect_equal(overlay.get("phase"), &"drawing", "a dispatched keyboard-add arrow should retain Drawing phase")
	support.expect(overlay.get("path", PackedVector2Array()) != initial_path, "a dispatched keyboard-add arrow should update the transient overlay path")
	await _dispatch_key(tree, KEY_ENTER)
	var pending_overlay: Dictionary = viewport.call("get_edit_overlay_state")
	support.expect_equal(pending_overlay.get("phase"), &"awaiting_class", "Enter should retain keyboard Box geometry until class assignment")
	support.expect_equal(pending_overlay.get("candidate_polygon", PackedVector2Array()).size(), 4,
		"Main without the Task 9 dialog wiring should still display the pending Box")
	support.expect_equal(viewport.get("_record").get("regions", []).size(), committed_count_before,
		"keyboard geometry completion must not write a placeholder region")
	support.expect(not main.get("_history").can_undo(), "pending keyboard Box must not enter global History")
	var class_dialog: Window = main.get_node_or_null("ClassAssignmentDialog") as Window
	if class_dialog == null:
		await _free_main(main, tree)
		return
	support.expect(class_dialog.is_assignment_open(),
		"Main should open the real class-assignment dialog for a completed keyboard Box")
	support.expect_equal(main.get("_class_dialog_mode"), &"new_region",
		"new geometry should be owned as a token-only Main dialog transaction")
	await _dispatch_key(tree, KEY_Z, 0, false, true)
	support.expect_equal(viewport.call("get_edit_overlay_state"), pending_overlay,
		"Ctrl+Z inside the modal must not cancel or commit AwaitingClass")
	support.expect(not main.get("_history").can_undo(),
		"modal Ctrl+Z must remain outside global Store history")
	var edit_plugin = main.get("_edit_plugin")
	(class_dialog.get_node("Margin/Content/ClassLabel") as LineEdit).text = " keyboard class "
	(class_dialog.get_node("Margin/Content/Kind") as LineEdit).text = " free kind "
	(class_dialog.get_node("Margin/Content/Actions/Confirm") as Button).pressed.emit()
	await tree.process_frame
	support.expect_equal(viewport.get("_record").get("regions", []).size(), committed_count_before + 1,
		"dialog confirmation should replace the pending overlay with one committed region")
	support.expect(main.get("_history").can_undo(), "confirmed keyboard Box should enter global History exactly once")
	support.expect(edit_plugin.set_active_tool(&"select").is_empty(), "text-focus check should leave Box mode after pending confirmation")
	await _free_main(main, tree)


func _test_candidate_cleanup_and_transactional_edit(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_source(support, "transaction", 40, 30)
	SOURCE_PROBE.reset("valid_two")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	support.expect_equal(main.open_source(root), PackedStringArray(), "transaction baseline should open")
	support.expect(main.seek(1), "transaction baseline should start from old frame one")
	main.call("_set_selected_region", "old-selection")
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var old_source = main.get("_source")
	var old_store = main.get("_store")
	var old_history = main.get("_history")
	var old_edit = main.get("_edit_plugin")
	main.call("_on_add_box_pressed")
	support.expect(old_edit.get("_add_pointer_mode"), "baseline edit should have an active transient gesture")
	var old_texture = viewport.get("_texture")
	var old_record: Dictionary = viewport.get("_record").duplicate(true)
	var old_connections: int = viewport.get_signal_connection_list("edit_cancel_requested").size()

	SOURCE_PROBE.reset("records_hole")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	var errors: PackedStringArray = main.open_source(root)
	support.expect(not errors.is_empty(), "equal-count model records with a missing frame key should be rejected")
	support.expect_equal(SOURCE_PROBE.close_count, 1, "a holey-record candidate should close exactly once")
	support.expect(main.get("_source") == old_source and main.get("_store") == old_store and main.get("_history") == old_history, "holey-record failure should preserve source, store, and history identities")
	support.expect(main.get("_edit_plugin") == old_edit and old_edit.get("_add_pointer_mode"), "holey-record failure should preserve old edit identity and gesture")
	support.expect_equal(main.get_current_frame(), 1, "holey-record failure should preserve old frame index")
	support.expect_equal(main.call("_get_selected_region_id"), "old-selection", "holey-record failure should preserve old selection")
	support.expect(viewport.get("_texture") == old_texture and viewport.get("_record") == old_record, "holey-record failure should preserve visible UI")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), old_connections, "holey-record failure should preserve signal ownership")

	SOURCE_PROBE.reset("open_error")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	errors = main.open_source(root)
	support.expect(not errors.is_empty(), "candidate open error should be returned")
	support.expect_equal(SOURCE_PROBE.close_count, 1, "a candidate returning open errors should be closed exactly once")
	support.expect(main.get("_source") == old_source and main.get("_store") == old_store and main.get("_history") == old_history, "source-open failure should preserve source, store, and history identities")
	support.expect(main.get("_edit_plugin") == old_edit and old_edit.get("_add_pointer_mode"), "source-open failure should preserve active edit identity and gesture")
	support.expect(viewport.get("_texture") == old_texture and viewport.get("_record") == old_record, "source-open failure should preserve visible UI")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), old_connections, "source-open failure should preserve edit signal ownership")

	SOURCE_PROBE.reset("valid")
	EDIT_PROBE.reset("fail_after_hostile_viewport")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	var edit_prototype = EDIT_PROBE.new()
	_replace_plugin(main, "edit", "basic_edit_tools", edit_prototype)
	var failed_viewport_before := _viewport_snapshot(viewport)
	errors = main.open_source(root)
	support.expect(not errors.is_empty(), "candidate edit activation failure should reject replacement")
	support.expect_equal(SOURCE_PROBE.close_count, 1, "edit activation failure should close the staged source exactly once")
	support.expect_equal(EDIT_PROBE.deactivation_count, 1, "Main should invoke the explicit edit lifecycle teardown after candidate activation failure")
	support.expect(main.get("_source") == old_source and main.get("_store") == old_store and main.get("_history") == old_history, "candidate edit failure should preserve source, store, and history identities")
	support.expect(main.get("_edit_plugin") == old_edit and old_edit.get("_add_pointer_mode"), "candidate edit failure should preserve old edit identity and transient gesture")
	support.expect_equal(main.get_current_frame(), 1, "candidate edit failure should preserve old frame index")
	support.expect_equal(main.call("_get_selected_region_id"), "old-selection", "staged selection setter must not mutate the old Main selection")
	support.expect_equal(EDIT_PROBE.last_activation_frame, 0, "candidate edit activation should observe staged frame zero")
	support.expect_equal(EDIT_PROBE.last_activation_selection, "", "candidate edit activation should observe an empty staged selection")
	support.expect(viewport.get("_texture") == old_texture and viewport.get("_record") == old_record, "candidate edit failure should preserve source, store, and visible UI")
	support.expect_equal(_viewport_snapshot(viewport), failed_viewport_before,
		"hostile activate and teardown writes must never reach the live viewport before source commit")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), old_connections, "failed candidate edit must release its ghost signal connection")
	support.expect("fixture edit activation failure" in _status(main), "candidate teardown must not overwrite the activation failure status")

	SOURCE_PROBE.reset("valid")
	EDIT_PROBE.reset("success_with_hostile_viewport")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	_install_boundary_working_mask(old_edit, old_store, main.get_current_frame(), "Resolve the accepted WorkingMask")
	var refused_viewport_before := _viewport_snapshot(viewport)
	support.expect_equal(refused_viewport_before.overlay.get("phase"), &"working_mask",
		"source-refusal setup should use a real plugin-owned WorkingMask overlay")
	errors = main.open_source(root)
	support.expect(not errors.is_empty(), "a valid candidate should still be refused behind the active WorkingMask")
	support.expect_equal(SOURCE_PROBE.close_count, 1, "a WorkingMask-refused candidate source should close exactly once")
	support.expect_equal(EDIT_PROBE.deactivation_count, 1, "a WorkingMask-refused candidate edit should deactivate exactly once")
	support.expect(main.get("_source") == old_source and main.get("_edit_plugin") == old_edit,
		"a WorkingMask-refused candidate should preserve the installed source and edit identities")
	support.expect_equal(_viewport_snapshot(viewport), refused_viewport_before,
		"hostile candidate activation and teardown must preserve every live WorkingMask viewport byte")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), old_connections,
		"a WorkingMask-refused candidate must not attach directly to the live cancel signal")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	support.expect(old_edit.handle_key(escape), "source-refusal WorkingMask should resolve through the real Escape path")

	SOURCE_PROBE.reset("valid_two")
	EDIT_PROBE.reset("success_with_hostile_viewport")
	errors = main.open_source(root)
	support.expect_equal(errors, PackedStringArray(), "valid candidate edit instance should commit")
	var new_edit = main.get("_edit_plugin")
	support.expect_equal(EDIT_PROBE.last_activation_frame, 0, "successful candidate activation should observe staged frame zero")
	support.expect_equal(EDIT_PROBE.last_activation_selection, "", "successful candidate activation should observe an empty staged selection")
	support.expect_equal(main.get_current_frame(), 0, "successful replacement should commit at frame zero")
	support.expect_equal(main.call("_get_selected_region_id"), "", "successful replacement should discard staged selection writes")
	support.expect_equal(viewport.get("_record"), {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"time_s": 1.25,
		"regions": [],
	}, "successful source commit should display candidate source data, never staged hostile viewport writes")
	support.expect_equal(viewport.call("get_edit_overlay_state"), {},
		"successful source commit should discard activation-time candidate overlays")
	support.expect(new_edit != old_edit and new_edit != edit_prototype, "successful replacement should install a fresh candidate edit instance")
	support.expect(not old_edit.get("_active") and not old_edit.get("_add_pointer_mode"), "successful replacement should cancel and deactivate the old edit instance")
	support.expect_equal(viewport.get_signal_connection_list("edit_cancel_requested").size(), 1, "successful replacement should leave exactly one edit cancel connection")
	viewport.edit_cancel_requested.emit()
	support.expect_equal(new_edit.get("cancel_signal_count"), 1, "only the installed edit instance should receive viewport cancel signals")
	support.expect(main.seek(1), "successful replacement should seek within the new source")
	main.call("_set_selected_region", "new-live-selection")
	support.expect_equal(new_edit.call("read_saved_frame"), 1, "candidate frame callable should switch to live Main state after commit")
	support.expect_equal(new_edit.call("read_saved_selection"), "new-live-selection", "candidate selection callable should switch to live Main state after commit")
	new_edit.call("write_saved_selection", "plugin-live-selection")
	support.expect_equal(main.call("_get_selected_region_id"), "plugin-live-selection", "candidate selection setter should route to live Main after commit")
	var live_record := {
		"schema_version": 1,
		"source": "accepted-plugin",
		"frame": 1,
		"regions": [],
	}
	var live_overlay := {"phase": &"drawing", "path": PackedVector2Array([Vector2(3, 4), Vector2(5, 6)])}
	new_edit.call("write_saved_viewport", live_record, "accepted-viewport-selection", live_overlay)
	support.expect_equal(viewport.get("_record"), live_record,
		"the committed candidate viewport facade should proxy record writes after switch_to_live")
	support.expect_equal(viewport.get("_selected_id"), "accepted-viewport-selection",
		"the committed candidate viewport facade should proxy selection-facing writes after switch_to_live")
	support.expect_equal(viewport.call("get_edit_overlay_state"), live_overlay,
		"the committed candidate viewport facade should proxy overlay writes after switch_to_live")
	await _free_main(main, tree)
	support.expect_equal(EDIT_PROBE.deactivation_count, 1, "Main exit should explicitly deactivate the installed edit instance exactly once")


func _test_candidate_class_requests_are_transactional(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_catalog_source(support, "candidate-class-request")
	support.expect_equal(main.open_source(root), PackedStringArray(),
		"candidate class-request baseline should open")
	main.call("_set_selected_region", "duct-0")
	var sidebar = main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar"
	)
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	sidebar.call("_set_hovered_region_id", "duct-0")
	var old_source = main.get("_source")
	var old_store = main.get("_store")
	var old_history = main.get("_history")
	var old_catalog = main.get("_class_catalog")
	var old_resolver = main.get("_color_resolver")
	var old_record: Dictionary = old_store.get_corrected_record(0)
	var old_project_rows: Array[Dictionary] = sidebar.get_project_rows_snapshot()
	var old_frame_rows: Array[Dictionary] = sidebar.get_frame_rows_snapshot()
	var old_viewport: Dictionary = _viewport_snapshot(viewport)
	var old_hover := {
		"sidebar": str(sidebar.get("_hovered_region_id")),
		"viewport": viewport.get_hovered_region_id(),
		"renderer": str(viewport.get("_renderer").get("_hovered_id")),
	}
	var old_dialog: Dictionary = _dialog_snapshot(main)

	EDIT_PROBE.reset("fail_after_hostile_viewport_and_class_request")
	_replace_plugin(main, "edit", "basic_edit_tools", EDIT_PROBE.new())
	var errors: PackedStringArray = main.open_source(root)
	support.expect(not errors.is_empty(),
		"candidate Edit activation must fail after its hostile class request")
	await tree.process_frame
	await tree.process_frame
	support.expect_equal(EDIT_PROBE.class_request_count, 1,
		"hostile candidate should issue exactly one activation-time class request")
	support.expect(main.get("_source") == old_source and main.get("_store") == old_store,
		"failed activation-time class request must preserve source and Store identities")
	support.expect(main.get("_history") == old_history and main.get("_class_catalog") == old_catalog,
		"failed activation-time class request must preserve History and catalog identities")
	support.expect(main.get("_color_resolver") == old_resolver,
		"failed activation-time class request must preserve resolver identity")
	support.expect_equal(main.get_current_frame(), 0,
		"failed activation-time class request must preserve the accepted frame")
	support.expect_equal(main.call("_get_selected_region_id"), "duct-0",
		"failed activation-time class request must preserve selection")
	support.expect_equal(old_store.get_corrected_record(0), old_record,
		"failed activation-time class request must preserve Store bytes")
	support.expect_equal(sidebar.get_project_rows_snapshot(), old_project_rows,
		"failed activation-time class request must preserve project rows")
	support.expect_equal(sidebar.get_frame_rows_snapshot(), old_frame_rows,
		"failed activation-time class request must preserve frame rows")
	support.expect_equal(_viewport_snapshot(viewport), old_viewport,
		"failed activation-time class request must preserve the complete visible viewport")
	support.expect_equal({
		"sidebar": str(sidebar.get("_hovered_region_id")),
		"viewport": viewport.get_hovered_region_id(),
		"renderer": str(viewport.get("_renderer").get("_hovered_id")),
	}, old_hover, "failed activation-time class request must preserve hover exactly")
	support.expect_equal(_dialog_snapshot(main), old_dialog,
		"failed activation-time class request must not mutate or later open the dialog")

	EDIT_PROBE.reset("success_with_hostile_viewport_and_class_request")
	errors = main.open_source(root)
	support.expect_equal(errors, PackedStringArray(),
		"accepted activation-time class request should commit with its candidate source")
	await tree.process_frame
	var dialog = main.get_node("ClassAssignmentDialog")
	support.expect(dialog.is_assignment_open(),
		"accepted staged class request should open only after source ownership commits")
	support.expect_equal(main.get("_class_dialog_mode"), &"new_region",
		"accepted staged request should enter new-region mode")
	support.expect_equal(int(main.get("_class_dialog_token")), EDIT_PROBE.CLASS_REQUEST_TOKEN,
		"accepted staged request must retain the candidate plugin's exact token")
	support.expect_equal(main.get("_edit_plugin").get("_pending_class_token"), EDIT_PROBE.CLASS_REQUEST_TOKEN,
		"the installed candidate Edit must still own the forwarded token")
	(dialog.get_node("Margin/Content/Actions/Cancel") as Button).pressed.emit()
	await tree.process_frame
	support.expect_equal(EDIT_PROBE.cancel_pending_count, 1,
		"cancelling an accepted staged request must consume its token in the installed Edit")
	support.expect(not dialog.is_assignment_open() and StringName(main.get("_class_dialog_mode")) == &"",
		"accepted staged request cancellation must leave no orphan dialog or Main token")
	support.expect_equal(main.get("_history").get_undo_count(), 0,
		"cancelling the accepted staged request must create zero commands")
	await _free_main(main, tree)


func _test_tool_option_without_plugin_rolls_back(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var panel = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel")
	var radius := panel.get_node("OptionRow/Value") as SpinBox
	support.expect(panel.set_active_tool(&"paint"),
		"no-plugin boundary setup should expose Paint without bypassing ToolPanel state")
	support.expect_equal(radius.value, 8.0, "no-source option setup should expose the accepted default radius")
	radius.value = 20.0
	support.expect_equal(radius.value, 8.0,
		"a real option request with no installed Edit plugin must visibly roll back")
	(panel.get_node("ToolGrid/Eraser") as Button).pressed.emit()
	support.expect_equal(radius.value, 8.0,
		"a refused no-plugin request must not leak into the Paint/Eraser shared value")
	await _free_main(main, tree)


func _test_navigation_wrappers_have_one_cancel_owner(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_source(support, "single-owner", 40, 30)
	SOURCE_PROBE.reset("valid_two")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	support.expect_equal(main.open_source(root), PackedStringArray(), "single-owner navigation fixture should open")
	var probe := CancelCountingEdit.new()
	main.set("_edit_plugin", probe)
	var timeline = main.get_node("MainVBox/TimelinePanel/TimelineColumn/Timeline")
	var explorer = main.get_node("MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer")

	probe.cancel_count = 0
	main.call("_on_next_pressed")
	support.expect_equal(main.get_current_frame(), 1, "Next wrapper should advance through set_frame")
	support.expect_equal(probe.cancel_count, 1, "Next wrapper and set_frame must share one cancellation owner")
	probe.cancel_count = 0
	main.call("_on_previous_pressed")
	support.expect_equal(main.get_current_frame(), 0, "Previous wrapper should return through set_frame")
	support.expect_equal(probe.cancel_count, 1, "Previous wrapper and set_frame must share one cancellation owner")

	probe.cancel_count = 0
	timeline.frame_requested.emit(1)
	support.expect_equal(main.get_current_frame(), 1, "timeline wrapper should navigate through set_frame")
	support.expect_equal(probe.cancel_count, 1, "timeline, seek, and set_frame must not double-cancel")
	probe.cancel_count = 0
	explorer.frame_requested.emit(0)
	support.expect_equal(main.get_current_frame(), 0, "Explorer wrapper should navigate through set_frame")
	support.expect_equal(probe.cancel_count, 1, "Explorer, seek, and set_frame must not double-cancel")

	probe.cancel_count = 0
	support.expect(main.step(1), "direct step should reach frame one")
	support.expect_equal(probe.cancel_count, 1, "step should delegate its sole cancellation to set_frame")
	probe.cancel_count = 0
	support.expect(main.seek(0), "direct seek should return to frame zero")
	support.expect_equal(probe.cancel_count, 1, "seek should delegate its sole cancellation to set_frame")
	probe.cancel_count = 0
	main.play()
	support.expect(main.is_playing(), "Play should start from frame zero")
	support.expect_equal(probe.cancel_count, 1, "Play should prepare edit navigation exactly once")
	main.pause()

	probe.cancel_count = 0
	support.expect(main.get("_playback_controller").play(0), "playback-tick setup should arm the controller directly")
	main.call("_process", 1.0)
	support.expect_equal(main.get_current_frame(), 1, "playback tick should commit one explicit next frame")
	support.expect_equal(probe.cancel_count, 1, "playback tick should use set_frame's single cancellation boundary")
	await _free_main(main, tree)


func _test_source_boundary_validation(support, tree: SceneTree) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_source(support, "boundary", 40, 30)
	support.expect_equal(main.open_source(root), PackedStringArray(), "boundary baseline should open")
	var explorer = main.get_node(
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer"
	)
	var accepted_model: Dictionary = explorer.get("_view_model").duplicate(true)
	explorer.populate({"display_name": "broken"})
	support.expect("Dataset explorer" in _status(main),
		"invalid explorer data should produce a user-facing status")
	support.expect(_status(main).length() <= 180,
		"invalid explorer data should produce a bounded status")
	support.expect_equal(explorer.get("_view_model"), accepted_model,
		"invalid explorer data should preserve the accepted tree")
	var baseline_frame: int = main.get_current_frame()
	var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var baseline_texture = viewport.get("_texture")
	var modes := [
		"manifest_empty",
		"manifest_bad_fps",
		"frame_count_mismatch",
		"entry_bad_time",
		"manifest_wrong_type",
		"frame_count_wrong_type",
		"records_wrong_type",
		"records_count_mismatch",
		"texture_wrong_type",
		"entry_wrong_type",
	]
	for mode: String in modes:
		SOURCE_PROBE.reset(mode)
		_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
		var errors: PackedStringArray = main.open_source(root)
		support.expect(not errors.is_empty(), "invalid candidate mode %s should be rejected" % mode)
		support.expect_equal(SOURCE_PROBE.close_count, 1, "invalid candidate mode %s should close exactly once" % mode)
		support.expect_equal(main.get_current_frame(), baseline_frame, "invalid candidate mode %s should preserve current frame" % mode)
		support.expect(viewport.get("_texture") == baseline_texture, "invalid candidate mode %s should preserve visible texture" % mode)
		support.expect(_status(main).length() <= 180 and not "SCRIPT ERROR" in _status(main), "invalid candidate mode %s should report a bounded user-facing status" % mode)

	SOURCE_PROBE.reset("valid_two")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	support.expect_equal(main.open_source(root), PackedStringArray(), "two-frame source should open for later-entry boundary tests")
	var first_texture = viewport.get("_texture")
	SOURCE_PROBE.mode = "frame_count_wrong_type"
	support.expect_equal(main.call("_active_frame_count"), 2, "active frame count should remain the validated authoritative manifest value")
	support.expect(main.step(1), "dynamic source count changes must not disable manifest-indexed navigation")
	support.expect_equal(main.get_current_frame(), 1, "manifest-indexed navigation should reach frame one")
	support.expect(main.set_frame(0), "later-entry fixture should return to frame zero")
	first_texture = viewport.get("_texture")
	for mode: String in ["entry_second_bad_frame", "entry_second_bad_time"]:
		SOURCE_PROBE.mode = mode
		support.expect(not main.set_frame(1), "malformed later entry mode %s should be rejected" % mode)
		support.expect_equal(main.get_current_frame(), 0, "malformed later entry mode %s should preserve current frame" % mode)
		support.expect(viewport.get("_texture") == first_texture, "malformed later entry mode %s should preserve visible texture" % mode)

	SOURCE_PROBE.reset("valid_sparse")
	_replace_plugin(main, "source", "image_sequence_source", SOURCE_PROBE.new())
	support.expect_equal(main.open_source(root), PackedStringArray(),
		"sparse mutable-source fixture should pass initial session validation")
	support.expect_equal(main.call("_current_record_frame"), 16,
		"accepted sparse session should start with original frame 16")
	var sparse_texture = viewport.get("_texture")
	SOURCE_PROBE.mode = "entry_second_remapped"
	support.expect(not main.set_frame(1),
		"runtime Source remapping must be rejected after session validation")
	support.expect_equal(main.get_current_frame(), 0,
		"rejected runtime remapping should preserve the accepted playback index")
	support.expect_equal(main.call("_current_record_frame"), 16,
		"rejected runtime remapping should preserve the accepted record mapping")
	support.expect(viewport.get("_texture") == sparse_texture,
		"rejected runtime remapping should preserve the accepted texture")
	await _free_main(main, tree)


func _test_configured_plugin_ids(support, tree: SceneTree) -> void:
	var root := _make_source(support, "configured-ids", 40, 30)
	for setting: String in ["source_plugin_id", "render_plugin_id", "edit_plugin_id"]:
		var main = MAIN_SCENE.instantiate()
		main.set(setting, "missing-" + setting)
		var viewport = main.get_node("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
		var fallback_renderer = viewport.get("_renderer")
		tree.root.add_child(main)
		await tree.process_frame
		var errors: PackedStringArray = main.open_source(root)
		support.expect(not errors.is_empty(), "configured missing %s should prevent source opening" % setting)
		support.expect_equal(main.get_current_frame(), -1, "configured missing %s should leave Main without a dataset" % setting)
		support.expect(_status(main).length() <= 180 and "missing-" in _status(main), "configured missing %s should identify the configured lookup safely" % setting)
		if setting == "render_plugin_id":
			support.expect(viewport.get("_renderer") == fallback_renderer, "missing configured renderer should retain standalone fallback but never open data")
		await _free_main(main, tree)


func _test_numeric_sequence_uses_sparse_source_mapping(
	support,
	tree: SceneTree
) -> void:
	var main: Variant = await _mounted_main(tree)
	var root := _make_numeric_sequence(support, "VID68")
	support.expect_equal(main.open_source(root), PackedStringArray(),
		"direct Source opening should accept a registered numeric image sequence")
	support.expect_equal(main.get_current_frame(), 0,
		"numeric sequence should start at continuous playback index zero")
	support.expect_equal(main.call("_current_record_frame"), 16,
		"playback index zero should map to original frame 16")
	support.expect(main.set_frame(1),
		"numeric sequence should advance through the common frame boundary")
	support.expect_equal(main.call("_current_record_frame"), 23,
		"playback index one should map to original frame 23")
	var viewport = main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	support.expect_equal(viewport.get("_record").get("frame"), 23,
		"direct sparse playback should display the record for original frame 23")
	await _free_main(main, tree)


func _test_workspace_forwards_configured_source_plugin(
	support,
	tree: SceneTree
) -> void:
	var main: Variant = await _mounted_main(tree)
	var recording_factory := RecordingSourceFactory.new(main.get("_source_factory"))
	main.set("_source_factory", recording_factory)
	main.set("source_plugin_id", "numeric_image_sequence_source")
	var root := _make_numeric_workspace(support, "VID70")
	support.expect_equal(main.open_workspace(root), PackedStringArray(),
		"configured Source forwarding fixture should open its workspace")
	main.call("_on_workspace_media_requested", "VID70")
	support.expect_equal(recording_factory.preferred_ids,
		["numeric_image_sequence_source"],
		"workspace Source routing should honor Main's configured preferred plugin")
	await _free_main(main, tree)


func _test_source_dialog_routes_plugin_owned_locators(
	support,
	tree: SceneTree
) -> void:
	var main: Variant = await _mounted_main(tree)
	var registry: Variant = main.get("_plugin_registry")
	support.expect_equal(registry.discover_roots(PackedStringArray([
		"res://client/plugins",
		"res://tests/godot/fixtures/extension_plugins",
	])), PackedStringArray(),
		"UI routing fixture should discover beside production plugins")
	var file_path := "%sui-route-%d-%d.fixture" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(file_path)
	_write_text(file_path, "plugin-owned locator")
	main.call("_on_file_selected", file_path)
	support.expect_equal(main.get_current_frame(), 0,
		"file selection should route a plugin-owned extension through SourceFactory")
	support.expect_equal(main.get("_manifest").get("dataset_id"), "fixture",
		"file selection should commit the Source plugin session")
	var import_dialog := main.get_node("VideoImportDialog") as Window
	support.expect(not import_dialog.visible,
		"a Source-claimed file must not fall through to FFmpeg import")

	var directory_path := "%sui-route-directory-%d-%d.fixture" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(directory_path)
	DirAccess.make_dir_recursive_absolute(directory_path)
	main.call("_on_directory_selected", directory_path)
	support.expect_equal(main.get_current_frame(), 0,
		"directory selection should route a plugin-owned locator through SourceFactory")
	support.expect_equal(main.get("_manifest").get("dataset_id"), "fixture",
		"directory selection should commit the claimed Source session")

	var workspace_root := "%sui-route-workspace-%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(workspace_root)
	DirAccess.make_dir_recursive_absolute(workspace_root)
	_write_text(workspace_root.path_join("custom.fixture"), "workspace locator")
	support.expect_equal(main.open_workspace(workspace_root), PackedStringArray(),
		"workspace should catalog a plugin-owned locator")
	main.call("_on_workspace_media_requested", "custom")
	support.expect_equal(main.get_current_frame(), 0,
		"workspace selection should open a plugin-owned locator through SourceFactory")
	support.expect_equal(main.get("_workspace_media_id"), "custom",
		"workspace selection should commit the plugin-owned logical media")
	await _free_main(main, tree)


func _mounted_main(tree: SceneTree):
	var main = MAIN_SCENE.instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	return main


func _free_main(main: Node, tree: SceneTree) -> void:
	main.queue_free()
	await tree.process_frame


func _dispatch_key(
	tree: SceneTree,
	keycode: Key,
	unicode_value: int = 0,
	alt_pressed: bool = false,
	ctrl_pressed: bool = false,
) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.unicode = unicode_value
	event.alt_pressed = alt_pressed
	event.ctrl_pressed = ctrl_pressed
	event.pressed = true
	Input.parse_input_event(event)
	await tree.process_frame
	var released := event.duplicate() as InputEventKey
	released.pressed = false
	Input.parse_input_event(released)
	await tree.process_frame


func _dispatch_viewport_key(viewport: Viewport, keycode: Key, tree: SceneTree) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	viewport.push_input(event, true)
	await tree.process_frame
	var released := event.duplicate() as InputEventKey
	released.pressed = false
	viewport.push_input(released, true)
	await tree.process_frame


func _replace_plugin(main: Node, stage: String, plugin_id: String, plugin: RefCounted) -> void:
	var registry = main.get("_plugin_registry")
	var plugins: Dictionary = registry.get("_plugins")
	var stage_plugins: Dictionary = plugins.get(stage, {}).duplicate()
	stage_plugins[plugin_id] = plugin
	plugins[stage] = stage_plugins
	registry.set("_plugins", plugins)


func _make_source(support, label: String, width: int, height: int) -> String:
	var root := "%s%s-%d-%d" % [TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_GREEN)
	var relative := "frames/frame_000000.png"
	support.expect_equal(image.save_png(root.path_join(relative)), OK, "boundary fixture image should save")
	var manifest := {
		"schema_version": 1,
		"dataset_id": label,
		"source_name": label + ".mp4",
		"source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"width": width,
		"height": height,
		"frame_count": 1,
		"nominal_fps": 20.0,
		"frames": [{"frame": 0, "time_s": 0.0, "image_path": relative}],
		"model_version": "none",
		"taxonomy_version": "none",
	}
	var file := FileAccess.open(root.path_join("manifest.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest, "  ") + "\n")
	return root


func _make_catalog_source(support, label: String) -> String:
	var root := "%s%s-%d-%d" % [TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var frames: Array[Dictionary] = []
	for frame in range(2):
		var relative := "frames/frame_%06d.png" % frame
		var image := Image.create(48, 36, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.08 + float(frame) * 0.04, 0.18, 0.12, 1.0))
		support.expect_equal(image.save_png(root.path_join(relative)), OK,
			"catalog fixture frame should save")
		frames.append({"frame": frame, "time_s": float(frame) * 0.05, "image_path": relative})
	var manifest := {
		"schema_version": 1,
		"dataset_id": label,
		"source_name": label + ".mp4",
		"source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"width": 48,
		"height": 36,
		"frame_count": 2,
		"nominal_fps": 20.0,
		"frames": frames,
		"model_version": "model_output_v1",
		"taxonomy_version": "task9-test",
	}
	var manifest_file := FileAccess.open(root.path_join("manifest.json"), FileAccess.WRITE)
	manifest_file.store_string(JSON.stringify(manifest, "  ") + "\n")
	var records := [
		{
			"schema_version": 1,
			"source": label + ".mp4",
			"frame": 0,
			"time_s": 0.0,
			"regions": [
				{"id": "duct-0", "class": "cystic_duct", "kind": "anatomy", "box": [2, 2, 12, 10]},
				{"id": "grasper-0", "class": "grasper", "kind": "instrument", "box": [20, 3, 10, 9]},
			],
		},
		{
			"schema_version": 1,
			"source": label + ".mp4",
			"frame": 1,
			"time_s": 0.05,
			"regions": [
				{
					"id": "gallbladder-1",
					"class": "gallbladder",
					"kind": "anatomy",
					"polygon": [[8, 8], [18, 6], [22, 18], [10, 22]],
				},
			],
		},
	]
	var records_file := FileAccess.open(root.path_join("model_output_v1.jsonl"), FileAccess.WRITE)
	for record: Dictionary in records:
		records_file.store_line(JSON.stringify(record))
	return root


func _make_numeric_sequence(support, label: String) -> String:
	var fixture_root := "%snumeric-%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(fixture_root)
	var root := fixture_root.path_join(label)
	DirAccess.make_dir_recursive_absolute(root)
	for frame_id: int in [16, 23]:
		var image := Image.create(48, 36, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.08, 0.12 + float(frame_id) * 0.002, 0.18, 1.0))
		support.expect_equal(
			image.save_png(root.path_join("%06d.png" % frame_id)), OK,
			"numeric Source fixture frame should save")
	return root


func _make_numeric_workspace(support, media_id_value: String) -> String:
	var root := "%sworkspace-%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	_temp_paths.append(root)
	var sequence := root.path_join("videos").path_join(media_id_value)
	DirAccess.make_dir_recursive_absolute(sequence)
	for frame_id: int in [16, 23]:
		var image := Image.create(48, 36, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.11, 0.14 + float(frame_id) * 0.002, 0.2, 1.0))
		support.expect_equal(
			image.save_png(sequence.path_join("%06d.png" % frame_id)), OK,
			"configured Source workspace frame should save")
	return root


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)


func _project_counts(rows: Array[Dictionary]) -> Dictionary:
	var result := {}
	for row: Dictionary in rows:
		result[String(row.get("class", ""))] = int(row.get("current_count", -1))
	return result


func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}


func _status(main: Node) -> String:
	return str(main.get_node("MainVBox/StatusBar").text)


func _viewport_snapshot(viewport: Node) -> Dictionary:
	var transform = viewport.get_image_transform()
	return {
		"texture": viewport.get("_texture"),
		"record": (viewport.get("_record") as Dictionary).duplicate(true),
		"selected": str(viewport.get("_selected_id")),
		"overlay": viewport.get_edit_overlay_state(),
		"image_size": transform.image_size,
		"viewport_rect": transform.viewport_rect,
		"fit_scale": transform.fit_scale,
		"user_zoom": transform.user_zoom,
		"pan": transform.pan,
		"letterbox_offset": transform.letterbox_offset,
		"forward": transform.get_image_to_viewport_transform(),
		"inverse": transform.get_viewport_to_image_transform(),
	}


func _dialog_snapshot(main: Node) -> Dictionary:
	var dialog = main.get_node("ClassAssignmentDialog")
	return {
		"mode": StringName(main.get("_class_dialog_mode")),
		"region_id": str(main.get("_class_dialog_region_id")),
		"token": int(main.get("_class_dialog_token")),
		"open": bool(dialog.call("is_assignment_open")),
		"visible": bool(dialog.visible),
		"class": (dialog.get_node("Margin/Content/ClassLabel") as LineEdit).text,
		"kind": (dialog.get_node("Margin/Content/Kind") as LineEdit).text,
		"status": (dialog.get_node("Margin/Content/Status") as Label).text,
	}


func _install_boundary_working_mask(edit_plugin: Variant, store: Variant, frame: int, message: String) -> void:
	var session: Variant = edit_plugin.get("_session")
	session.begin(&"paint", frame, "", store.get_corrected_record(frame))
	session.set_working_mask({
		"roi": Rect2i(0, 0, 3, 3),
		"mask": PackedByteArray([1, 1, 1, 1, 0, 1, 1, 1, 1]),
	}, message)
	edit_plugin.call("_push_session_overlay")


func _cleanup(support) -> void:
	for path: String in _temp_paths:
		if not path.begins_with(TEMP_PREFIX) or path == TEMP_PREFIX:
			support.expect(false, "refusing to remove unowned boundary fixture: %s" % path)
			continue
		_remove_tree(path)
		support.expect(not DirAccess.dir_exists_absolute(path), "boundary fixture should be removed: %s" % path)
	_temp_paths.clear()


func _remove_tree(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for child_name: String in directory.get_directories():
		_remove_tree(path.path_join(child_name))
	DirAccess.remove_absolute(path)
