extends RefCounted


const VIEWPORT_SCENE := preload("res://client/ui/annotation_viewport.tscn")
const PLUGIN_SCRIPT := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const REAL_UI_HARNESS := preload("res://tests/godot/edit_test_harness.gd")
const ADD_BOX_COMMAND := preload("res://client/domain/commands/add_box_command.gd")
const ADD_POLYGON_COMMAND := preload("res://client/domain/commands/add_polygon_command.gd")
const EXPECTED_BOX_ID := "frame-0-added-11001"
const EXPECTED_POLYGON_ID := "frame-0-polygon-11001"

const EXPECTED_POINTER_POLYGONS := {
	"Subtract": [[36.0, 44.0], [20.0, 44.0], [20.0, 20.0], [36.0, 20.0]],
	"Paint selected": [
		[20.0, 20.0], [50.0, 20.0], [50.0, 24.0], [64.0, 24.0],
		[64.0, 25.0], [66.0, 25.0], [66.0, 26.0], [67.0, 26.0],
		[67.0, 27.0], [68.0, 27.0], [68.0, 29.0], [69.0, 29.0],
		[69.0, 35.0], [68.0, 35.0], [68.0, 37.0], [67.0, 37.0],
		[67.0, 38.0], [66.0, 38.0], [66.0, 39.0], [64.0, 39.0],
		[64.0, 40.0], [50.0, 40.0], [50.0, 44.0], [20.0, 44.0],
	],
	"Eraser": [
		[85.0, 20.0], [115.0, 20.0], [115.0, 25.0], [111.0, 25.0],
		[111.0, 26.0], [110.0, 26.0], [110.0, 31.0], [111.0, 31.0],
		[111.0, 35.0], [112.0, 35.0], [112.0, 40.0], [113.0, 40.0],
		[113.0, 44.0], [114.0, 44.0], [114.0, 45.0], [115.0, 45.0],
		[115.0, 50.0], [85.0, 50.0],
	],
	"Select polygon resize": [
		[20.0, 70.0], [36.5, 70.0], [36.5, 71.4000015258789],
		[37.5999984741211, 71.4000015258789], [37.5999984741211, 70.0],
		[64.0, 70.0], [64.0, 84.0], [20.0, 84.0],
	],
}

const EXPECTED_KEYBOARD_POLYGON_RESIZE := [
	[20.0, 70.0], [35.375, 70.0], [35.375, 71.0],
	[36.4000015258789, 71.0], [36.4000015258789, 70.0],
	[61.0, 70.0], [61.0, 80.0], [20.0, 80.0],
]


func run(support: TestSupport, tree: SceneTree) -> void:
	await _test_real_harness_exposes_sidebar_input_routes(support, tree)
	await _test_real_sidebar_pointer_keyboard_and_render_sync(support, tree)
	await _test_real_main_global_history_precedes_line_edit(support, tree)
	await _test_real_main_hover_does_not_pause_playback(support, tree)
	await _test_real_right_click_clears_selection_and_selects_tool(support, tree)
	await _test_real_focused_viewport_arrow_reaches_select(support, tree)
	await _test_real_pointer_command_matrix(support, tree)
	await _test_real_pending_class_cancel_and_stale_guard(support, tree)
	await _test_real_keyboard_only_creation_and_classification(support, tree)
	await _test_real_pending_dialog_guards_every_navigation_route(support, tree)
	await _test_real_sidebar_reclassification_matrix(support, tree)
	await _test_real_keyboard_shortcut_table(support, tree)
	await _test_real_keyboard_move_resize_steps(support, tree)
	await _test_real_keyboard_delete_and_modal_keys(support, tree)
	await _test_real_idle_select_enter_is_inert(support, tree)
	await _test_real_focus_traversal_and_text_ownership(support, tree)
	await _test_real_global_undo_cancels_only_nonblocking_preview(support, tree)
	await _test_real_harness_restores_command_allocators(support, tree)
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(200, 160)
	tree.root.add_child(viewport)
	await tree.process_frame
	var store = STORE_SCRIPT.new()
	store.load_model_records([_record()])
	var history = HISTORY_SCRIPT.new()
	var selected := [""]
	var statuses: Array[String] = []
	var plugin = PLUGIN_SCRIPT.new()
	var image := Image.create(100, 80, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_BLUE)
	var texture := ImageTexture.create_from_image(image)
	var context := {
		"store": store,
		"history": history,
		"viewport": viewport,
		"current_frame": func(): return 0,
		"selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"status": func(message: String): statuses.append(message),
		"taxonomy": {"classes": [{"id": "unknown", "kind": "region"}]},
	}
	support.expect(plugin.activate(context).is_empty(), "real viewport integration context should activate")
	viewport.call("set_edit_selection_authoritative", true)
	support.expect(plugin.set_active_tool(&"select").is_empty(), "real viewport integration should use Selection direct manipulation")
	viewport.region_selected.connect(func(region_id: String): selected[0] = region_id)
	viewport.image_pointer_event.connect(func(event: InputEvent, image_position: Vector2): plugin.handle_pointer(event, image_position))
	viewport.call("set_texture", texture)
	viewport.call("set_record", store.get_corrected_record(0))

	_mouse_button(viewport, true, Vector2(15, 15))
	_mouse_motion(viewport, Vector2(18, 19), MOUSE_BUTTON_MASK_LEFT)
	_mouse_button(viewport, false, Vector2(18, 19))
	support.expect_equal(history.get_undo_count(), 1, "real viewport ordinary drag should submit one move")
	support.expect_equal(store.get_corrected_record(0).regions[0].box, [13.0, 14.0, 20, 15], "real viewport pointer coordinates should drive the move")

	selected[0] = "box-1"
	viewport.call("set_selected_region_id", "box-1")
	var transform = viewport.call("get_image_transform")
	transform.zoom_at(transform.image_to_viewport(Vector2(33, 29)), 3.0)
	viewport.call("notify_transform_changed")
	_mouse_button(viewport, true, Vector2(33, 29))
	_mouse_motion(viewport, Vector2(38, 33), MOUSE_BUTTON_MASK_LEFT)
	_mouse_button(viewport, false, Vector2(38, 33))
	support.expect_equal(history.get_undo_count(), 2, "real viewport zoomed handle drag should submit one resize")
	support.expect_equal(store.get_corrected_record(0).regions[0].box, [13.0, 14.0, 25.0, 19.0], "real viewport zoomed handle should resize in image coordinates")

	var before_invalid: Dictionary = store.get_corrected_record(0)
	selected[0] = "box-1"
	viewport.call("set_selected_region_id", "box-1")
	_mouse_button(viewport, true, Vector2(20, 20))
	_mouse_motion(viewport, Vector2(95, 20), MOUSE_BUTTON_MASK_LEFT)
	var invalid_overlay: Dictionary = viewport.call("get_edit_overlay_state")
	support.expect_equal(invalid_overlay.get("phase"), &"invalid", "real viewport should render an out-of-image Select preview as Invalid")
	support.expect_equal(invalid_overlay.get("fill_color"), Color("#ef4444"), "real viewport should render an out-of-image Select preview in red")
	_mouse_button(viewport, false, Vector2(95, 20))
	support.expect_equal(store.get_corrected_record(0), before_invalid, "real viewport out-of-image release must preserve Store atomically")
	support.expect_equal(history.get_undo_count(), 2, "real viewport out-of-image release must not enter history")
	support.expect(not statuses.is_empty(), "real viewport out-of-image release should explain refusal")

	var before_brush_preview: Dictionary = store.get_corrected_record(0)
	selected[0] = "box-1"
	viewport.call("set_selected_region_id", "box-1")
	support.expect(plugin.set_active_tool(&"paint").is_empty(), "real viewport should activate Paint")
	_mouse_button(viewport, true, Vector2(37, 23))
	_mouse_motion(viewport, Vector2(45, 23), MOUSE_BUTTON_MASK_LEFT)
	var paint_overlay: Dictionary = viewport.call("get_edit_overlay_state")
	support.expect_equal(paint_overlay.get("phase"), &"drawing", "real Paint motion should publish only a drawing overlay")
	support.expect_equal(paint_overlay.get("brush_radius"), 8.0, "real Paint overlay should keep the shared radius in image pixels")
	support.expect_equal(paint_overlay.get("fill_color"), Color("#22d3ee"), "real Paint overlay should use the additive color")
	var paint_cursor: Vector2 = paint_overlay.get("cursor", Vector2.ZERO)
	var viewport_radius: float = transform.image_to_viewport(paint_cursor + Vector2(8, 0)).distance_to(transform.image_to_viewport(paint_cursor))
	support.expect(is_equal_approx(viewport_radius, 48.0), "an eight-image-pixel brush at 6x zoom should render as an exact 48-viewport-pixel circle")
	support.expect_equal(store.get_corrected_record(0), before_brush_preview, "real Paint motion must not mutate Store")
	support.expect_equal(history.get_undo_count(), 2, "real Paint motion must not create history")
	plugin.cancel()
	_mouse_button(viewport, false, Vector2(45, 23))

	support.expect(plugin.set_active_tool(&"eraser").is_empty(), "real viewport should activate Eraser")
	support.expect_equal(plugin.get_active_tool(), &"eraser", "real viewport Eraser activation should become authoritative")
	support.expect_equal(selected[0], "box-1", "cancelling a Paint preview should preserve the explicit selection")
	_mouse_button(viewport, true, Vector2(20, 20))
	support.expect_equal(selected[0], "box-1", "a real Eraser press on the selected box should preserve selection")
	var eraser_overlay: Dictionary = viewport.call("get_edit_overlay_state")
	support.expect_equal(eraser_overlay.get("phase"), &"drawing", "a real Eraser press should enter one brush drawing session")
	support.expect_equal(eraser_overlay.get("brush_radius"), 8.0, "real Eraser overlay should share Paint's image-space radius")
	support.expect_equal(eraser_overlay.get("fill_color"), Color("#a855f7"), "real Eraser overlay should use the subtractive color")
	support.expect(eraser_overlay.get("fill_color") != paint_overlay.get("fill_color"), "real Paint and Eraser overlays should be visibly distinct")
	plugin.cancel()
	_mouse_button(viewport, false, Vector2(20, 20))

	selected[0] = ""
	support.expect(plugin.set_active_tool(&"lasso").is_empty(), "real viewport should activate anchored Lasso")
	_mouse_button(viewport, true, Vector2(20, 10))
	_mouse_motion(viewport, Vector2(22, 10), MOUSE_BUTTON_MASK_LEFT)
	_mouse_button(viewport, false, Vector2(22, 10))
	var anchored_overlay: Dictionary = viewport.call("get_edit_overlay_state")
	support.expect_equal(anchored_overlay.get("phase"), &"drawing", "real zoomed viewport should classify exactly two image pixels as one click anchor")
	support.expect_equal(anchored_overlay.get("path"), PackedVector2Array([Vector2(20, 10)]), "Lasso threshold must use image coordinates under zoom/pan")
	_mouse_motion(viewport, Vector2(30, 10), 0)
	support.expect_equal(viewport.call("get_edit_overlay_state").get("path"), PackedVector2Array([
		Vector2(20, 10), Vector2(30, 10),
	]), "real no-button hover should preserve and extend the open anchored path")
	plugin.cancel()

	plugin.set_active_tool(&"select")

	var history_before_navigation: int = history.get_undo_count()
	_start_drag(viewport, Vector2(15, 16), Vector2(17, 16))
	var wheel_overlay: Dictionary = viewport.call("get_edit_overlay_state")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = transform.image_to_viewport(Vector2(17, 16))
	viewport.call("_gui_input", wheel)
	support.expect_equal(viewport.call("get_edit_overlay_state"), wheel_overlay, "wheel zoom preserves the active edit overlay snapshot")
	plugin.cancel()
	support.expect_equal(viewport.call("get_edit_overlay_state"), {}, "explicit cancel clears the wheel-preserved overlay")

	_start_drag(viewport, Vector2(15, 16), Vector2(17, 16))
	var middle_overlay: Dictionary = viewport.call("get_edit_overlay_state")
	var middle := InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	middle.position = transform.image_to_viewport(Vector2(17, 16))
	viewport.call("_gui_input", middle)
	middle.pressed = false
	viewport.call("_gui_input", middle)
	support.expect_equal(viewport.call("get_edit_overlay_state"), middle_overlay, "middle-button pan preserves the active edit overlay snapshot")
	plugin.cancel()

	_start_drag(viewport, Vector2(15, 16), Vector2(17, 16))
	var focus_overlay: Dictionary = viewport.call("get_edit_overlay_state")
	viewport.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	support.expect_equal(viewport.call("get_edit_overlay_state"), focus_overlay, "focus loss preserves the active edit overlay snapshot")
	plugin.cancel()
	support.expect_equal(history.get_undo_count(), history_before_navigation, "wheel, middle pan, focus loss, and explicit cancellation should not create edit history")
	viewport.queue_free()
	await tree.process_frame

	var replacement := VIEWPORT_SCENE.instantiate() as Control
	replacement.set_anchors_preset(Control.PRESET_TOP_LEFT)
	replacement.size = Vector2(200, 160)
	tree.root.add_child(replacement)
	await tree.process_frame
	var replacement_context: Dictionary = context.duplicate()
	replacement_context["viewport"] = replacement
	var lifecycle_marker := "reactivating after the old viewport is freed must complete without a script error"
	support.failures.append(lifecycle_marker)
	var reactivation_errors: PackedStringArray = plugin.activate(replacement_context)
	support.failures.erase(lifecycle_marker)
	support.expect(reactivation_errors.is_empty(), "a live replacement viewport should reactivate after the old viewport is freed")
	replacement.call("set_edit_selection_authoritative", true)
	var cancel_callback := Callable(plugin, "cancel")
	support.expect(replacement.is_connected("edit_cancel_requested", cancel_callback), "reactivation should connect cancellation only to the replacement viewport")
	replacement.region_selected.connect(func(region_id: String): selected[0] = region_id)
	replacement.image_pointer_event.connect(func(event: InputEvent, image_position: Vector2): plugin.handle_pointer(event, image_position))
	replacement.call("set_texture", texture)
	replacement.call("set_record", store.get_corrected_record(0))
	selected[0] = "box-1"
	plugin.begin_add_box()
	replacement.edit_cancel_requested.emit()
	plugin.set_active_tool(&"select")
	_mouse_button(replacement, true, Vector2(15, 15))
	_mouse_motion(replacement, Vector2(16, 15), MOUSE_BUTTON_MASK_LEFT)
	_mouse_button(replacement, false, Vector2(16, 15))
	support.expect_equal(history.get_undo_count(), history_before_navigation + 1, "replacement viewport should remain the sole live edit surface")
	replacement.queue_free()
	await tree.process_frame


func _test_real_harness_exposes_sidebar_input_routes(support: TestSupport, tree: SceneTree) -> void:
	# Break caught: mounted integration silently falls back to private Main/sidebar
	# callbacks instead of traversing the user's real sidebar/dialog controls.
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	for method_name: String in [
		"hover_annotation", "click_annotation", "double_click_annotation",
		"confirm_class", "cancel_class",
	]:
		support.expect(harness.has_method(method_name),
			"mounted harness must expose the real %s input route" % method_name)
	var snapshot: Dictionary = harness.sidebar_snapshot()
	support.expect_equal(snapshot.project.map(func(row: Dictionary): return [
		row.get("class"), row.get("current_count"), row.get("color"),
	]), [
		["cystic_duct", 0, Color("#22c55e")],
		["gallbladder", 1, Color("#3b82f6")],
		["grasper", 1, Color("#ef4444")],
		["scissors", 1, Color("#f59e0b")],
	], "Project Labels must show the real two-frame union, explicit colors, and frame-zero counts")
	support.expect_equal(snapshot.frame.map(func(row: Dictionary): return [
		row.get("region_id"), row.get("class"), row.get("kind"),
		row.get("geometry"), row.get("color"),
	]), [
		["box-1", "grasper", "instrument", &"box", Color("#ef4444")],
		["box-2", "scissors", "instrument", &"box", Color("#f59e0b")],
		["poly-1", "gallbladder", "anatomy", &"polygon", Color("#3b82f6")],
	], "Current Frame Annotations must expose exact identity, free-form kind, geometry, and color")
	var renderer = harness.viewport.get("_renderer")
	var render_colors: Dictionary = {}
	for command: Dictionary in renderer.get_overlay_descriptions():
		render_colors[str(command.get("id", ""))] = command.get("color")
	for row: Dictionary in snapshot.frame:
		support.expect_equal(render_colors.get(row.region_id), row.color,
			"sidebar and renderer must share the exact class color for %s" % row.region_id)
	await harness.finish()


func _test_real_sidebar_pointer_keyboard_and_render_sync(support: TestSupport, tree: SceneTree) -> void:
	# Break caught: mounted sidebar gestures diverge from Main/renderer state or
	# accidentally mutate durable annotation/session state.
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	await harness.select_region("box-1")
	var frame_tree := harness.sidebar.get_node("FrameAnnotations/Tree") as Tree
	support.expect_equal(str(frame_tree.get_selected().get_metadata(0)), "box-1",
		"a real canvas click must synchronize the matching sidebar row")

	await harness.click_annotation("box-2")
	support.expect_equal(harness.selected_region_id(), "box-2",
		"a real sidebar row click must select through Main")
	support.expect_equal(str(harness.viewport.get("_selected_id")), "box-2",
		"row selection must synchronize the renderer-facing viewport selection")

	var store_digest_before: String = harness.store.model_digest()
	var record_before: Dictionary = harness.record()
	var dirty_before: PackedInt64Array = harness.store.get_dirty_frames()
	var history_before := [harness.undo_count(), harness.redo_count()]
	var selection_before := harness.selected_region_id()
	var frame_before: int = harness.main.get_current_frame()
	var renderer = harness.viewport.get("_renderer")
	var normal_target := _command_for_region(renderer.get_overlay_descriptions(), "box-1")
	var normal_other := _command_for_region(renderer.get_overlay_descriptions(), "box-2")
	await harness.hover_annotation("box-1")
	var hovered_target := _command_for_region(renderer.get_overlay_descriptions(), "box-1")
	var hovered_other := _command_for_region(renderer.get_overlay_descriptions(), "box-2")
	support.expect(hovered_target.get("hovered", false),
		"real row motion must deepen the matching renderer command")
	support.expect_equal(hovered_target.get("color"),
		(normal_target.get("color") as Color).darkened(0.18),
		"hover must use the shared deeper version of the class color")
	support.expect_equal(hovered_other, normal_other,
		"hover must preserve every non-target renderer command")
	support.expect_equal(harness.store.model_digest(), store_digest_before,
		"hover must preserve the exact model digest")
	support.expect_equal(harness.record(), record_before, "hover must preserve Store records")
	support.expect_equal(harness.store.get_dirty_frames(), dirty_before,
		"hover must preserve dirty frames")
	support.expect_equal([harness.undo_count(), harness.redo_count()], history_before,
		"hover must preserve both History stacks")
	support.expect_equal(harness.selected_region_id(), selection_before,
		"hover must preserve authoritative selection")
	support.expect_equal(harness.main.get_current_frame(), frame_before,
		"hover must preserve the current frame")
	await harness.clear_annotation_hover()
	support.expect_equal(_command_for_region(renderer.get_overlay_descriptions(), "box-1"), normal_target,
		"real pointer exit must restore the target command immediately")

	await harness.hover_annotation("box-1")
	await harness.click_control("MainVBox/TimelinePanel/TimelineColumn/Transport/Next")
	support.expect_equal(harness.main.get_current_frame(), 1,
		"real Next must commit the second fixture frame")
	support.expect_equal(str(harness.viewport.get_hovered_region_id()), "",
		"frame seek must clear viewport hover")
	support.expect_equal(str(harness.sidebar.get("_hovered_region_id")), "",
		"frame seek must clear sidebar hover")
	var frame_one: Dictionary = harness.sidebar_snapshot()
	support.expect_equal(frame_one.frame.map(func(row: Dictionary): return row.region_id), ["duct-2"],
		"frame seek must rebuild Current Frame Annotations")
	support.expect_equal(frame_one.project.map(func(row: Dictionary): return [row["class"], row.current_count]), [
		["cystic_duct", 1], ["gallbladder", 0], ["grasper", 0], ["scissors", 0],
	], "frame seek must rebuild Project Labels current counts")
	await harness.click_control("MainVBox/TimelinePanel/TimelineColumn/Transport/Previous")

	await harness.double_click_annotation("poly-1")
	support.expect(harness.class_dialog.is_assignment_open(),
		"real row double-click must open reclassification")
	support.expect_equal((harness.class_dialog_control("Margin/Content/ClassLabel") as LineEdit).text,
		"gallbladder", "double-click dialog must be populated with the current class")
	support.expect_equal((harness.class_dialog_control("Margin/Content/Kind") as LineEdit).text,
		"anatomy", "double-click dialog must be populated with the free-form kind")
	var cancel_record: Dictionary = harness.record()
	var cancel_history := [harness.undo_count(), harness.redo_count()]
	var cancel_state := _exact_harness_state(harness)
	await harness.cancel_class()
	support.expect(not harness.class_dialog.is_assignment_open(),
		"real Escape must close existing-region reclassification")
	support.expect_equal(harness.record(), cancel_record,
		"real Escape must cancel existing-region reclassification without mutation")
	support.expect_equal([harness.undo_count(), harness.redo_count()], cancel_history,
		"cancelled reclassification must preserve both History stacks")
	support.expect_equal(_exact_harness_state(harness), cancel_state,
		"real Escape must preserve exact digest/dirty/allocator/selection/frame state")
	await harness.finish()

	# The headless root viewport does not retarget synthetic pointer events after
	# closing an embedded subwindow, so keyboard-row evidence uses a fresh real
	# mount while still traversing the production Tree input route.
	var enter_harness = REAL_UI_HARNESS.new()
	if not await enter_harness.mount(support, tree):
		await enter_harness.finish()
		return
	await enter_harness.click_annotation("box-1")
	support.expect_equal(enter_harness.selected_region_id(), "box-1",
		"real row click must select the Enter target")
	frame_tree = enter_harness.sidebar.get_node("FrameAnnotations/Tree") as Tree
	frame_tree.grab_focus()
	await tree.process_frame
	support.expect(frame_tree.has_focus(),
		"Current Frame Annotations tree must own focus before row Enter")
	await enter_harness.press_key(KEY_ENTER)
	support.expect(enter_harness.class_dialog.is_assignment_open(),
		"real Enter on the selected row must open reclassification")
	support.expect_equal((enter_harness.class_dialog_control("Margin/Content/ClassLabel") as LineEdit).text,
		"grasper", "row Enter must populate the selected region class")
	await enter_harness.cancel_class()
	support.expect(not enter_harness.class_dialog.is_assignment_open(),
		"real Escape must close selected-row Enter reclassification")
	await enter_harness.finish()


func _command_for_region(commands: Array[Dictionary], region_id: String) -> Dictionary:
	for command: Dictionary in commands:
		if str(command.get("id", "")) == region_id:
			return command
	return {}


func _test_real_main_global_history_precedes_line_edit(support: TestSupport, tree: SceneTree) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	await harness.select_region("box-1")
	support.expect_equal(harness.selected_region_id(), "box-1", "real Select click should choose box-1 before keyboard history setup")
	_expect_real_active_tool(harness, &"select", "focused LineEdit history fixture", support)
	var original: Dictionary = harness.record()
	var expected_moved := _expected_with_box(original, "box-1", [21.0, 20.0, 30.0, 24.0])
	harness.pointer_drag([Vector2(30, 30), Vector2(31, 30)])
	await tree.process_frame
	support.expect_equal(harness.record(), expected_moved, "real Select drag should establish the independently expected Store record")
	support.expect_equal(harness.undo_count(), 1, "real Select drag should enter history exactly once")

	await harness.double_click_annotation("box-1")
	support.expect(harness.class_dialog.call("is_assignment_open"),
		"reclassification should expose the real class-assignment dialog")
	var class_edit := harness.class_dialog_control("Margin/Content/ClassLabel") as LineEdit
	class_edit.caret_column = class_edit.text.length()
	class_edit.deselect()
	await harness.press_key(KEY_X, false, false, false, 120)
	support.expect_equal(class_edit.text, "grasperx",
		"the modal class field should own ordinary text input")
	await harness.press_key(KEY_Z, false, true)
	support.expect_equal(harness.record(), expected_moved,
		"Ctrl+Z inside class assignment must not reach global Store history")
	support.expect_equal([harness.undo_count(), harness.redo_count()], [1, 0],
		"class assignment should preserve both global history stacks")
	await harness.cancel_class()
	support.expect(not harness.class_dialog.call("is_assignment_open"),
		"cancelling reclassification should close the modal without a command")
	await harness.press_key(KEY_Z, false, true)
	support.expect_equal(harness.record(), original,
		"global Ctrl+Z should resume after class assignment closes")
	support.expect_equal([harness.undo_count(), harness.redo_count()], [0, 1],
		"the resumed global shortcut should move exactly one command to Redo")
	await harness.press_key(KEY_Y, false, true)
	support.expect_equal(harness.record(), expected_moved,
		"global Ctrl+Y should resume after class assignment closes")
	support.expect_equal([harness.undo_count(), harness.redo_count()], [1, 0],
		"the resumed global Redo shortcut should restore exactly one command")
	await harness.finish()


func _test_real_main_hover_does_not_pause_playback(support: TestSupport, tree: SceneTree) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	harness.main.play()
	support.expect(harness.main.is_playing(), "real two-frame source should begin continuous playback")
	var record_before: Dictionary = harness.record()
	harness.pointer_hover(Vector2(75, 55))
	await tree.process_frame
	support.expect(harness.main.is_playing(), "ordinary real viewport hover must not pause playback")
	support.expect_equal(harness.record(), record_before, "ordinary hover must not change committed annotations")
	harness.pointer_click(Vector2(75, 55))
	await tree.process_frame
	support.expect(not harness.main.is_playing(), "a real left-button gesture should pause playback at its start")
	await harness.finish()


func _test_real_right_click_clears_selection_and_selects_tool(support: TestSupport, tree: SceneTree) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	await harness.select_region("box-1")
	await harness.click_tool(&"paint")
	_expect_real_active_tool(harness, &"paint", "right-click cancellation setup", support)
	var before := harness.record()
	var history_before := [harness.undo_count(), harness.redo_count()]
	harness.pointer_right_click(Vector2(30, 30))
	await tree.process_frame
	support.expect_equal(harness.selected_region_id(), "", "right click should clear the selected region through Main")
	_expect_real_active_tool(harness, &"select", "right-click cancellation", support)
	support.expect_equal(harness.overlay(), {}, "right click should clear any transient edit overlay")
	support.expect_equal(harness.record(), before, "right click must not mutate the annotation record")
	support.expect_equal([harness.undo_count(), harness.redo_count()], history_before, "right click must not alter either history stack")
	await harness.finish()


func _test_real_focused_viewport_arrow_reaches_select(support: TestSupport, tree: SceneTree) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	await harness.select_region("box-1")
	var before: Dictionary = harness.record()
	var expected_after := _expected_with_box(before, "box-1", [21.0, 20.0, 30.0, 24.0])
	harness.viewport.grab_focus()
	support.expect(harness.viewport.has_focus(), "real AnnotationViewport should own focus before a spatial shortcut")
	await harness.press_key(KEY_RIGHT)
	_expect_real_active_tool(harness, &"select", "focused viewport Right", support)
	await _expect_real_command_round_trip(
		harness, before, expected_after, "move_region_command.gd", "focused viewport Right", support,
	)
	await harness.finish()


func _test_real_pointer_command_matrix(support: TestSupport, tree: SceneTree) -> void:
	var cases := [
		{"name": "Add Box", "tool": &"box", "command": "add_box_command.gd"},
		{"name": "Subtract", "tool": &"subtract", "command": "replace_region_geometry_command.gd"},
		{"name": "Lasso", "tool": &"lasso", "command": "add_polygon_command.gd"},
		{"name": "Lasso anchored", "tool": &"lasso", "command": "add_polygon_command.gd"},
		{"name": "Fill", "tool": &"fill", "command": "add_polygon_command.gd"},
		{"name": "Paint selected", "tool": &"paint", "command": "replace_region_geometry_command.gd"},
		{"name": "Eraser", "tool": &"eraser", "command": "replace_region_geometry_command.gd"},
		{"name": "Select move", "tool": &"select", "command": "move_region_command.gd"},
		{"name": "Select box resize", "tool": &"select", "command": "resize_box_command.gd"},
		{"name": "Select polygon resize", "tool": &"select", "command": "replace_region_geometry_command.gd"},
	]
	for case: Dictionary in cases:
		var harness = REAL_UI_HARNESS.new()
		if not await harness.mount(support, tree):
			await harness.finish()
			continue
		if case.name == "Fill":
			var bounded_record := _with_fill_boundaries(harness.record())
			support.expect_equal(harness.store.replace_corrected_record(0, bounded_record), PackedStringArray(),
				"Fill matrix setup should install four valid annotation boundaries")
		var before: Dictionary = harness.record()
		var digest_before: String = harness.store.model_digest()
		var dirty_before: PackedInt64Array = harness.store.get_dirty_frames()
		var history_before := [harness.undo_count(), harness.redo_count()]
		var selection_before := harness.selected_region_id()
		var frame_before: int = harness.main.get_current_frame()
		var allocator_before := [
			ADD_BOX_COMMAND._next_session_id, ADD_POLYGON_COMMAND._next_session_id,
		]
		match case.name:
			"Add Box":
				await harness.click_tool(case.tool)
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_drag([Vector2(122, 18), Vector2(146, 42)])
			"Subtract":
				await harness.select_region("box-1")
				await harness.click_tool(case.tool)
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_drag([
					Vector2(36, 15), Vector2(56, 15), Vector2(56, 50),
					Vector2(36, 50), Vector2(36, 15),
				])
			"Lasso":
				await harness.click_tool(case.tool)
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_drag([
					Vector2(68, 72), Vector2(96, 72), Vector2(96, 104),
					Vector2(68, 104), Vector2(68, 72),
				])
			"Lasso anchored":
				await harness.click_tool(case.tool)
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_click(Vector2(68, 72))
				harness.pointer_hover(Vector2(96, 72))
				harness.pointer_click(Vector2(96, 72))
				harness.pointer_hover(Vector2(96, 104))
				harness.pointer_click(Vector2(96, 104))
				harness.pointer_hover(Vector2(68, 104))
				harness.pointer_click(Vector2(68, 104), true)
			"Fill":
				await harness.click_tool(case.tool)
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_click(Vector2(80, 88))
			"Paint selected":
				await harness.select_region("box-1")
				await harness.click_tool(case.tool)
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_drag([Vector2(47, 32), Vector2(61, 32)])
			"Eraser":
				await harness.select_region("box-2")
				await harness.click_tool(case.tool)
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				var radius := harness.tool_panel.get_node("OptionRow/Value") as SpinBox
				radius.value = 3.0
				harness.pointer_drag([Vector2(113, 28), Vector2(116, 42)])
			"Select move":
				await harness.select_region("box-1")
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_drag([Vector2(30, 30), Vector2(33, 34)])
			"Select box resize":
				await harness.select_region("box-1")
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_drag([Vector2(50, 44), Vector2(55, 48)])
			"Select polygon resize":
				await harness.select_region("poly-1")
				_expect_real_active_tool(harness, case.tool, str(case.name), support)
				harness.pointer_drag([Vector2(60, 80), Vector2(64, 84)])
		await tree.process_frame
		if case.name in ["Add Box", "Lasso", "Lasso anchored", "Fill"]:
			support.expect_equal(harness.record(), before,
				"%s geometry completion must not write before class assignment" % case.name)
			support.expect_equal(harness.store.model_digest(), digest_before,
				"%s pending candidate must preserve the exact Store digest" % case.name)
			support.expect_equal(harness.store.get_dirty_frames(), dirty_before,
				"%s pending candidate must preserve dirty frames" % case.name)
			support.expect_equal([harness.undo_count(), harness.redo_count()], history_before,
				"%s pending candidate must preserve both History stacks" % case.name)
			support.expect_equal([
				ADD_BOX_COMMAND._next_session_id, ADD_POLYGON_COMMAND._next_session_id,
			], allocator_before, "%s pending candidate must not consume a region ID" % case.name)
			support.expect_equal(harness.selected_region_id(), selection_before,
				"%s pending candidate must preserve selection" % case.name)
			support.expect_equal(harness.main.get_current_frame(), frame_before,
				"%s pending candidate must preserve its exact frame" % case.name)
			support.expect_equal(harness.overlay().get("phase"), &"awaiting_class",
				"%s must retain its pending geometry for class assignment" % case.name)
			support.expect(harness.class_dialog.is_assignment_open(),
				"%s must show the real class dialog at geometry completion" % case.name)
			var pending_request: Dictionary = harness.edit_plugin.get("_session").pending_request()
			support.expect_equal(int(harness.main.get("_class_dialog_token")),
				int(pending_request.get("candidate_token", -2)),
				"%s dialog and retained candidate must share one opaque token" % case.name)
			await harness.confirm_class("grasper", "instrument")
			support.expect(not harness.class_dialog.is_assignment_open(),
				"%s real Enter confirmation must close the dialog" % case.name)
			support.expect_equal(harness.overlay(), {},
				"%s successful confirmation must clear the retained candidate" % case.name)
		var generated_id := ""
		if case.name in ["Add Box", "Lasso", "Lasso anchored", "Fill"]:
			generated_id = EXPECTED_BOX_ID if case.name == "Add Box" else EXPECTED_POLYGON_ID
			support.expect_equal(
				harness.selected_region_id(), generated_id,
				"%s should select the id independently predicted by the fixture allocator" % case.name,
			)
			var new_row := _sidebar_row_for_region(harness.sidebar_snapshot().frame, generated_id)
			support.expect_equal([new_row.get("class"), new_row.get("kind")],
				["grasper", "instrument"],
				"%s confirmation must publish the exact class/kind sidebar row" % case.name)
			var new_command := _command_for_region(
				harness.viewport.get("_renderer").get_overlay_descriptions(), generated_id,
			)
			support.expect_equal(new_command.get("color"), new_row.get("color"),
				"%s must use the shared color in renderer and sidebar" % case.name)
		var expected_after := _expected_pointer_record(before, str(case.name), generated_id)
		await _expect_real_command_round_trip(
			harness, before, expected_after, str(case.command), str(case.name), support,
		)
		await harness.finish()


func _expect_real_command_round_trip(
	harness: Variant,
	before: Dictionary,
	expected_after: Dictionary,
	expected_command_file: String,
	label: String,
	support: TestSupport,
) -> void:
	var committed: Dictionary = harness.record()
	_expect_record_with_geometry_tolerance(committed, expected_after, label, support)
	support.expect_equal(harness.undo_count(), 1, "%s should create exactly one command" % label)
	support.expect(harness.last_command_script().ends_with(expected_command_file), "%s should use %s" % [label, expected_command_file])
	await harness.press_key(KEY_Z, false, true)
	support.expect_equal(harness.record(), before, "%s global undo should restore the exact full record" % label)
	support.expect_equal(harness.undo_count(), 0, "%s undo stack should be empty after one global undo" % label)
	support.expect_equal(harness.redo_count(), 1, "%s should expose exactly one redo command" % label)
	await harness.press_key(KEY_Y, false, true)
	support.expect_equal(harness.record(), committed,
		"%s global redo should restore the first committed record byte-for-byte" % label)
	support.expect_equal(harness.undo_count(), 1, "%s global redo should restore one undo command" % label)
	support.expect_equal(harness.redo_count(), 0, "%s global redo should consume its redo command" % label)


func _expect_record_with_geometry_tolerance(
	actual: Dictionary,
	expected: Dictionary,
	label: String,
	support: TestSupport,
) -> void:
	const EPSILON := 1.0e-5
	var normalized := actual.duplicate(true)
	var normalized_regions: Array = normalized.get("regions", [])
	var expected_regions: Array = expected.get("regions", [])
	support.expect_equal(normalized_regions.size(), expected_regions.size(),
		"%s should preserve the exact region count" % label)
	for index in range(mini(normalized_regions.size(), expected_regions.size())):
		if not normalized_regions[index] is Dictionary or not expected_regions[index] is Dictionary:
			continue
		var actual_region := normalized_regions[index] as Dictionary
		var expected_region := expected_regions[index] as Dictionary
		for geometry_key in ["box", "polygon"]:
			if not expected_region.has(geometry_key):
				continue
			support.expect(actual_region.has(geometry_key) and _geometry_values_close(
				actual_region.get(geometry_key), expected_region.get(geometry_key), EPSILON,
			), "%s %s geometry must match the independent image-space oracle within 1e-5" % [
				label, geometry_key,
			])
			if actual_region.has(geometry_key):
				actual_region[geometry_key] = expected_region[geometry_key]
	support.expect_equal(normalized, expected,
		"%s should commit every non-geometry field exactly" % label)


func _geometry_values_close(actual: Variant, expected: Variant, epsilon: float) -> bool:
	if actual is Array and expected is Array:
		if actual.size() != expected.size():
			return false
		for index in range(actual.size()):
			if not _geometry_values_close(actual[index], expected[index], epsilon):
				return false
		return true
	if typeof(actual) not in [TYPE_INT, TYPE_FLOAT] or typeof(expected) not in [TYPE_INT, TYPE_FLOAT]:
		return false
	return is_finite(float(actual)) and is_finite(float(expected)) \
		and absf(float(actual) - float(expected)) <= epsilon


func _test_real_pending_class_cancel_and_stale_guard(support: TestSupport, tree: SceneTree) -> void:
	var cancel_cases := [
		{"name": "pointer Box", "route": &"pointer_box"},
		{"name": "keyboard Box", "route": &"keyboard_box"},
		{"name": "pointer Lasso", "route": &"pointer_lasso"},
	]
	for case: Dictionary in cancel_cases:
		# Break caught: Escape dismisses the modal but leaks candidate allocation,
		# dirty state, Store bytes, selection, or one hidden History command.
		var harness = REAL_UI_HARNESS.new()
		if not await harness.mount(support, tree):
			await harness.finish()
			continue
		var before := _exact_harness_state(harness)
		match case.route:
			&"pointer_box":
				await harness.click_tool(&"box")
				harness.pointer_drag([Vector2(122, 18), Vector2(146, 42)])
			&"keyboard_box":
				await harness.focus_viewport()
				await harness.press_key(KEY_A)
				await harness.press_key(KEY_RIGHT)
				await harness.press_key(KEY_ENTER)
			&"pointer_lasso":
				await harness.click_tool(&"lasso")
				harness.pointer_drag([
					Vector2(68, 72), Vector2(96, 72), Vector2(96, 104),
					Vector2(68, 104), Vector2(68, 72),
				])
		await tree.process_frame
		support.expect(harness.class_dialog.is_assignment_open(),
			"%s must reach the real pending class modal" % case.name)
		support.expect_equal(harness.overlay().get("phase"), &"awaiting_class",
			"%s must retain its candidate before Escape" % case.name)
		await harness.cancel_class()
		support.expect(not harness.class_dialog.is_assignment_open(),
			"%s real Escape must close the class dialog" % case.name)
		support.expect_equal(harness.overlay(), {},
			"%s real Escape must clear the candidate overlay" % case.name)
		support.expect_equal(_exact_harness_state(harness), before,
			"%s cancellation must be an exact zero-mutation transaction" % case.name)
		if case.route == &"keyboard_box":
			support.expect(harness.viewport.has_focus(),
				"keyboard dialog Escape must restore focus to AnnotationViewport")
		await harness.finish()

	# The direct Store replacement is the one explicitly permitted test-only
	# stale-state setup. Confirmation itself still uses real LineEdit/Enter input.
	var stale = REAL_UI_HARNESS.new()
	if not await stale.mount(support, tree):
		await stale.finish()
		return
	var durable_before_candidate := _exact_harness_state(stale)
	await stale.click_tool(&"box")
	stale.pointer_drag([Vector2(122, 18), Vector2(146, 42)])
	await tree.process_frame
	support.expect_equal(_exact_harness_state(stale), durable_before_candidate,
		"stale fixture candidate creation must preserve exact durable state")
	var pending_before_external := _exact_modal_state(stale)
	var changed: Dictionary = stale.record()
	_real_region(changed, "box-1")["class"] = "intervening-change"
	support.expect_equal(stale.store.replace_corrected_record(0, changed), PackedStringArray(),
		"controlled stale-state setup must be schema-valid")
	var before_confirm := _exact_modal_state(stale)
	support.expect_equal(_modal_state_without_store_payload(before_confirm),
		_modal_state_without_store_payload(pending_before_external),
		"external stale setup may change only record digest and dirty state")
	support.expect_equal(before_confirm.record, changed,
		"external stale setup must install exactly the intended record")
	support.expect_equal(before_confirm.digest, pending_before_external.digest,
		"corrected-record stale setup must preserve the model-only digest exactly")
	support.expect_equal(before_confirm.dirty, PackedInt64Array([0]),
		"external stale setup must dirty only the candidate frame")
	var focus_evidence: Dictionary = await stale.confirm_class("candidate-class", "candidate-kind")
	support.expect_equal(focus_evidence, {
		"class_focused_before_input": true,
		"kind_focused_after_tab": true,
	}, "stale confirmation must still use production auto-focus and real Tab traversal")
	var after_confirm := _exact_modal_state(stale)
	support.expect(stale.class_dialog.is_assignment_open(),
		"stale confirmation must keep the real dialog open")
	support.expect_equal(after_confirm, before_confirm,
		"stale confirmation must preserve the exact source/frame/model/candidate/dialog/token/selection/history/hover/tool snapshot")
	var stale_status := (stale.class_dialog_control("Margin/Content/Status") as Label).text.to_lower()
	support.expect("stale" in stale_status or "changed" in stale_status,
		"stale dialog must explain why confirmation was refused")
	await stale.cancel_class()
	await stale.finish()


func _test_real_keyboard_only_creation_and_classification(
	support: TestSupport,
	tree: SceneTree,
) -> void:
	var cases := [
		{"name": "keyboard-only Box", "route": &"box", "key": KEY_A,
			"command": "add_box_command.gd", "class": "keyboard box", "kind": "free box kind"},
		{"name": "keyboard-only Lasso", "route": &"lasso", "key": KEY_L,
			"command": "add_polygon_command.gd", "class": "keyboard lasso", "kind": "free lasso kind"},
		{"name": "keyboard-only Fill", "route": &"fill", "key": KEY_F,
			"command": "add_polygon_command.gd", "class": "keyboard fill", "kind": "free fill kind"},
	]
	for case: Dictionary in cases:
		# The complete route below is parsed keyboard input: no tool button,
		# pointer gesture, direct plugin call, or direct Store write is involved.
		var harness = REAL_UI_HARNESS.new()
		if not await harness.mount(support, tree):
			await harness.finish()
			continue
		if case.route == &"fill":
			var bounded_record := _with_fill_boundaries(harness.record())
			support.expect_equal(harness.store.replace_corrected_record(0, bounded_record), PackedStringArray(),
				"keyboard Fill setup should install four valid annotation boundaries")
		await harness.focus_viewport()
		var before := _exact_harness_state(harness)
		var region_count_before: int = harness.record().get("regions", []).size()
		await harness.press_key(case.key)
		match case.route:
			&"box":
				await harness.press_key(KEY_RIGHT)
				await harness.press_key(KEY_RIGHT, false, false, true)
				await harness.press_key(KEY_DOWN)
				await harness.press_key(KEY_ENTER)
			&"lasso":
				await harness.press_key(KEY_RIGHT)
				await harness.press_key(KEY_RIGHT, true)
				await harness.press_key(KEY_RIGHT, true, true)
				await harness.press_key(KEY_DOWN, true)
				await harness.press_key(KEY_LEFT, true, true)
				await harness.press_key(KEY_LEFT, true)
				await harness.press_key(KEY_LEFT)
				await harness.press_key(KEY_SPACE)
			&"fill":
				await harness.press_key(KEY_DOWN, true, true)
				await harness.press_key(KEY_DOWN, true, true)
				await harness.press_key(KEY_ENTER)
		support.expect(harness.class_dialog.is_assignment_open(),
			"%s must reach the real class dialog using parsed keys only" % case.name)
		var class_edit := harness.class_dialog_control("Margin/Content/ClassLabel") as LineEdit
		support.expect(class_edit.has_focus(),
			"%s deferred dialog presentation must automatically focus ClassLabel" % case.name)
		support.expect_equal(harness.overlay().get("phase"), &"awaiting_class",
			"%s must retain its keyboard geometry before classification" % case.name)
		support.expect_equal(_exact_harness_state(harness), before,
			"%s must preserve exact model/history/allocator state before classification" % case.name)
		var confirmations := [0]
		harness.class_dialog.assignment_confirmed.connect(
			func(_class_label: String, _kind: String): confirmations[0] += 1)
		var focus_evidence: Variant = await harness.confirm_class(case["class"], case.kind)
		support.expect_equal(focus_evidence, {
			"class_focused_before_input": true,
			"kind_focused_after_tab": true,
		}, "%s must rely on production auto-focus and real Tab traversal" % case.name)
		support.expect(not harness.class_dialog.is_assignment_open(),
			"%s real Enter must close the class dialog" % case.name)
		support.expect_equal(confirmations[0], 1,
			"%s real Enter must confirm exactly once" % case.name)
		support.expect(harness.viewport.has_focus(),
			"%s successful confirmation must return focus to AnnotationViewport" % case.name)
		var after: Dictionary = harness.record()
		support.expect_equal(after.get("regions", []).size(), region_count_before + 1,
			"%s must add exactly one region" % case.name)
		support.expect_equal([harness.undo_count(), harness.redo_count()], [1, 0],
			"%s must create exactly one History command" % case.name)
		support.expect(harness.last_command_script().ends_with(case.command),
			"%s must use the expected Add command" % case.name)
		var added := _real_region(after, harness.selected_region_id())
		support.expect_equal([added.get("class"), added.get("kind")],
			[case["class"], case.kind],
			"%s must persist actual typed Class and Kind" % case.name)
		support.expect(not added.is_empty() and (added.has("box") or added.has("polygon")),
			"%s must persist one Model Output V1 geometry" % case.name)
		await harness.finish()


func _test_real_pending_dialog_guards_every_navigation_route(
	support: TestSupport,
	tree: SceneTree,
) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return

	# Keep a real undo and redo entry alive so both global shortcuts have
	# observable state to protect while the class assignment is modal.
	await harness.select_region("box-1")
	await harness.focus_viewport()
	await harness.press_key(KEY_RIGHT)
	await harness.press_key(KEY_DOWN)
	await harness.press_key(KEY_Z, false, true)
	support.expect_equal([harness.undo_count(), harness.redo_count()], [1, 1],
		"modal guard fixture must contain one real Undo and one real Redo entry")
	var before_candidate := _exact_harness_state(harness)
	await harness.click_tool(&"box")
	harness.pointer_drag([Vector2(122, 18), Vector2(146, 42)])
	await tree.process_frame
	support.expect(harness.class_dialog.is_assignment_open(),
		"modal guard fixture must expose a real pending class dialog")
	var protected := _exact_modal_state(harness)
	var cases := [
		{
			"name": "real Play button",
			"action": func(): await harness.click_control(
				"MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause"),
		},
		{
			"name": "real Previous button",
			"action": func(): await harness.click_control(
				"MainVBox/TimelinePanel/TimelineColumn/Transport/Previous"),
		},
		{
			"name": "real Next button",
			"action": func(): await harness.click_control(
				"MainVBox/TimelinePanel/TimelineColumn/Transport/Next"),
		},
		{"name": "real timeline cell", "action": func(): await harness.click_timeline_frame(1)},
		{"name": "real Explorer row", "action": func(): await harness.click_explorer_frame(1)},
		{
			"name": "public source replacement",
			"action": func():
				var errors: PackedStringArray = harness.main.open_source(harness.source_root)
				support.expect(not errors.is_empty(),
					"open_source must explain refusal while class assignment is active"),
		},
		{"name": "parsed Ctrl+Z", "action": func(): await harness.press_key(KEY_Z, false, true)},
		{"name": "parsed Ctrl+Y", "action": func(): await harness.press_key(KEY_Y, false, true)},
		{"name": "real Lasso tool button", "action": func(): await harness.click_tool(&"lasso")},
	]
	for case: Dictionary in cases:
		await case.action.call()
		support.expect_equal(_exact_modal_state(harness), protected,
			"%s must preserve source/frame/model/candidate/dialog/token/selection/history/hover exactly" % case.name)
		support.expect(not harness.main.is_playing(),
			"%s must keep playback paused" % case.name)
	var status := str(harness.main.get_node("MainVBox/StatusBar").text).to_lower()
	support.expect("class assignment" in status and ("finish" in status or "cancel" in status),
		"modal refusal status must explain that class assignment must finish or cancel")

	var cancellations := [0]
	harness.class_dialog.assignment_cancelled.connect(func(): cancellations[0] += 1)
	await harness.cancel_class()
	support.expect_equal(cancellations[0], 1,
		"pending-dialog real Escape must emit cancellation exactly once")
	support.expect(not harness.class_dialog.is_assignment_open(),
		"real Escape must release the modal navigation guard")
	support.expect_equal(_exact_harness_state(harness), before_candidate,
		"Escape must discard only the pending candidate and preserve all model/history state")
	support.expect(harness.viewport.has_focus(),
		"pending-dialog Escape must return focus to AnnotationViewport (got %s)" %
		str(harness.viewport.get_viewport().gui_get_focus_owner()))
	await harness.click_control("MainVBox/TimelinePanel/TimelineColumn/Transport/Next")
	support.expect_equal(harness.main.get_current_frame(), 1,
		"real Next must work again after pending-dialog Escape")
	await harness.click_timeline_frame(0)
	support.expect_equal(harness.main.get_current_frame(), 0,
		"real timeline seek must work again after pending-dialog Escape")
	await harness.click_explorer_frame(1)
	support.expect_equal(harness.main.get_current_frame(), 1,
		"real Explorer seek must work again after pending-dialog Escape")
	await harness.click_control("MainVBox/TimelinePanel/TimelineColumn/Transport/Previous")
	support.expect_equal(harness.main.get_current_frame(), 0,
		"real Previous must work again after pending-dialog Escape")
	await harness.click_control("MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause")
	support.expect(harness.main.is_playing(),
		"real Play must become available after pending-dialog Escape")
	await harness.click_control("MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause")
	support.expect(not harness.main.is_playing() and harness.main.get_current_frame() == 0,
		"the same real transport control must restore Pause without changing frame")
	await harness.click_control("MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause")
	harness.main.call("_process", 10.0)
	support.expect_equal(harness.main.get_current_frame(), 1,
		"restored real Play must advance the manifest-driven frame index")
	support.expect(not harness.main.is_playing(),
		"restored playback must auto-pause after reaching the final frame")
	await harness.click_control("MainVBox/TimelinePanel/TimelineColumn/Transport/Previous")
	support.expect_equal(harness.main.get_current_frame(), 0,
		"real Previous must restore the fixture after playback advances")
	await harness.click_tool(&"lasso")
	_expect_real_active_tool(harness, &"lasso",
		"real tool route after pending-dialog Escape", support)
	await harness.focus_viewport()
	await harness.press_key(KEY_Z, false, true)
	support.expect_equal([harness.undo_count(), harness.redo_count()], [0, 2],
		"global Ctrl+Z must work again after pending-dialog Escape")
	await harness.press_key(KEY_Y, false, true)
	support.expect_equal([harness.undo_count(), harness.redo_count()], [1, 1],
		"global Ctrl+Y must work again after pending-dialog Escape")
	support.expect_equal(harness.main.open_source(harness.source_root), PackedStringArray(),
		"source replacement must work again after pending-dialog Escape")
	await harness.finish()


func _exact_modal_state(harness: Variant) -> Dictionary:
	return {
		"source": harness.main.get("_source"),
		"source_path": harness.source_root,
		"store": harness.main.get("_store"),
		"history": harness.main.get("_history"),
		"manifest": harness.main.get("_manifest").duplicate(true),
		"record": harness.record(),
		"digest": harness.store.model_digest(),
		"dirty": harness.store.get_dirty_frames(),
		"undo": harness.undo_count(),
		"redo": harness.redo_count(),
		"box_allocator": ADD_BOX_COMMAND._next_session_id,
		"polygon_allocator": ADD_POLYGON_COMMAND._next_session_id,
		"selection": harness.selected_region_id(),
		"frame": harness.main.get_current_frame(),
		"overlay": harness.overlay(),
		"dialog_open": harness.class_dialog.is_assignment_open(),
		"dialog_mode": harness.main.get("_class_dialog_mode"),
		"dialog_token": harness.main.get("_class_dialog_token"),
		"sidebar_hover": harness.sidebar.get("_hovered_region_id"),
		"viewport_hover": harness.viewport.get_hovered_region_id(),
		"tool": harness.edit_plugin.get_active_tool(),
	}


func _modal_state_without_store_payload(state: Dictionary) -> Dictionary:
	var result := state.duplicate(true)
	result.erase("record")
	result.erase("digest")
	result.erase("dirty")
	return result


func _exact_harness_state(harness: Variant) -> Dictionary:
	return {
		"record": harness.record(),
		"digest": harness.store.model_digest(),
		"dirty": harness.store.get_dirty_frames(),
		"undo": harness.undo_count(),
		"redo": harness.redo_count(),
		"box_allocator": ADD_BOX_COMMAND._next_session_id,
		"polygon_allocator": ADD_POLYGON_COMMAND._next_session_id,
		"selection": harness.selected_region_id(),
		"frame": harness.main.get_current_frame(),
	}


func _test_real_sidebar_reclassification_matrix(support: TestSupport, tree: SceneTree) -> void:
	var cases := [
		{
			"name": "row double-click reclassification", "region_id": "box-1",
			"class": "custom-tissue", "kind": "free-kind", "enter": false,
		},
		{
			"name": "selected-row Enter reclassification", "region_id": "box-2",
			"class": "rare custom class", "kind": "arbitrary free kind", "enter": true,
		},
	]
	for case: Dictionary in cases:
		# Break caught: visible sidebar intent opens a draft but bypasses the
		# single undoable class+kind command, or dialog text is not real input.
		var harness = REAL_UI_HARNESS.new()
		if not await harness.mount(support, tree):
			await harness.finish()
			continue
		var before: Dictionary = harness.record()
		var expected_after := before.duplicate(true)
		var expected_region := _real_region(expected_after, case.region_id)
		expected_region["class"] = case["class"]
		expected_region["kind"] = case.kind
		if case.enter:
			await harness.click_annotation(case.region_id)
			var frame_tree := harness.sidebar.get_node("FrameAnnotations/Tree") as Tree
			frame_tree.grab_focus()
			await tree.process_frame
			await harness.press_key(KEY_ENTER)
		else:
			await harness.double_click_annotation(case.region_id)
		support.expect(harness.class_dialog.is_assignment_open(),
			"%s must open the real populated dialog" % case.name)
		var confirmations := [0]
		harness.class_dialog.assignment_confirmed.connect(
			func(_class_label: String, _kind: String): confirmations[0] += 1)
		await harness.confirm_class(case["class"], case.kind)
		support.expect(not harness.class_dialog.is_assignment_open(),
			"%s Enter confirmation must close the dialog" % case.name)
		support.expect_equal(confirmations[0], 1,
			"%s Enter confirmation must emit exactly once" % case.name)
		support.expect(harness.viewport.has_focus(),
			"%s successful reclassification must return focus to AnnotationViewport" % case.name)
		support.expect_equal(harness.selected_region_id(), case.region_id,
			"%s must preserve the reclassified region selection" % case.name)
		var row := _sidebar_row_for_region(harness.sidebar_snapshot().frame, case.region_id)
		support.expect_equal([row.get("class"), row.get("kind")], [case["class"], case.kind],
			"%s must refresh exact class and free-form kind in the sidebar" % case.name)
		var command := _command_for_region(
			harness.viewport.get("_renderer").get_overlay_descriptions(), case.region_id,
		)
		support.expect_equal(command.get("color"), row.get("color"),
			"%s must share one deterministic sidebar/renderer color" % case.name)
		await _expect_real_command_round_trip(
			harness, before, expected_after, "relabel_region_command.gd", case.name, support,
		)
		await harness.finish()

	var cancelled = REAL_UI_HARNESS.new()
	if await cancelled.mount(support, tree):
		await cancelled.double_click_annotation("poly-1")
		support.expect(cancelled.class_dialog.is_assignment_open(),
			"cancel fixture must open through a real row double-click")
		var before_cancel := _exact_harness_state(cancelled)
		var cancellations := [0]
		cancelled.class_dialog.assignment_cancelled.connect(func(): cancellations[0] += 1)
		await cancelled.cancel_class()
		support.expect_equal(cancellations[0], 1,
			"real reclassification Escape must emit cancellation exactly once")
		support.expect(not cancelled.class_dialog.is_assignment_open(),
			"real Escape cancellation must close the reclassification dialog")
		support.expect(cancelled.viewport.has_focus(),
			"real reclassification Escape must return focus to AnnotationViewport")
		support.expect_equal(_exact_harness_state(cancelled), before_cancel,
			"real Escape cancellation must preserve exact model/history/allocator/selection/frame state")
	await cancelled.finish()


func _sidebar_row_for_region(rows: Array[Dictionary], region_id: String) -> Dictionary:
	for row: Dictionary in rows:
		if str(row.get("region_id", "")) == region_id:
			return row
	return {}


func _test_real_keyboard_shortcut_table(support: TestSupport, tree: SceneTree) -> void:
	var cases := [
		{"name": "V Selection", "key": KEY_V, "tool": &"select", "prime_tool": &"lasso"},
		{"name": "A Add Box", "key": KEY_A, "tool": &"box", "modal": true},
		{"name": "S Subtract", "key": KEY_S, "tool": &"subtract", "selected": "box-1", "modal": true},
		{"name": "L Lasso", "key": KEY_L, "tool": &"lasso", "modal": true},
		{"name": "F Fill", "key": KEY_F, "tool": &"fill", "modal": true},
		{"name": "P Paint", "key": KEY_P, "tool": &"paint", "selected": "box-1", "modal": true},
		{"name": "Shift+P Eraser", "key": KEY_P, "shift": true, "tool": &"eraser", "selected": "box-1", "modal": true},
	]
	for case: Dictionary in cases:
		var harness = REAL_UI_HARNESS.new()
		if not await harness.mount(support, tree):
			await harness.finish()
			continue
		if case.has("selected"):
			await harness.select_region(str(case.selected))
		if case.has("prime_tool"):
			await harness.click_tool(StringName(case.prime_tool))
		harness.viewport.grab_focus()
		await tree.process_frame
		var before: Dictionary = harness.record()
		await harness.press_key(case.key, bool(case.get("shift", false)))
		_expect_real_active_tool(harness, case.tool, str(case.name), support)
		if bool(case.get("modal", false)):
			support.expect(not harness.overlay().is_empty(), "%s should publish a real edit preview" % case.name)
			support.expect_equal(harness.record(), before, "%s preview should not mutate Store before confirmation" % case.name)
			await harness.press_key(KEY_ESCAPE)
			if case.tool in [&"paint", &"eraser"]:
				support.expect_equal(harness.overlay().get("phase"), &"brush_cursor",
					"%s Escape should return to the idle brush cursor" % case.name)
			else:
				support.expect_equal(harness.overlay(), {}, "%s Escape should clear the real preview" % case.name)
			support.expect_equal(harness.record(), before, "%s Escape should preserve Store" % case.name)
		await harness.finish()

	var no_op = REAL_UI_HARNESS.new()
	if await no_op.mount(support, tree):
		await no_op.click_tool(&"select")
		no_op.viewport.grab_focus()
		await tree.process_frame
		var no_op_before: Dictionary = no_op.record()
		for key: Key in [KEY_C, KEY_E, KEY_G, KEY_I, KEY_W]:
			await no_op.press_key(key)
			_expect_real_active_tool(no_op, &"select", "%s no-op" % key, support)
			support.expect_equal(no_op.record(), no_op_before, "%s should not mutate Store" % key)
			support.expect_equal(no_op.undo_count(), 0, "%s should not create history" % key)
	await no_op.finish()


func _test_real_keyboard_move_resize_steps(support: TestSupport, tree: SceneTree) -> void:
	var move_cases := [
		{"name": "plain 1 px move", "shift": false, "ctrl": false, "key": KEY_RIGHT, "box": [21.0, 20.0, 30.0, 24.0]},
		{"name": "Shift 5 px move", "shift": true, "ctrl": false, "key": KEY_DOWN, "box": [20.0, 25.0, 30.0, 24.0]},
		{"name": "Ctrl+Shift 10 px move", "shift": true, "ctrl": true, "key": KEY_RIGHT, "box": [30.0, 20.0, 30.0, 24.0]},
	]
	for case: Dictionary in move_cases:
		var harness = REAL_UI_HARNESS.new()
		if not await harness.mount(support, tree):
			await harness.finish()
			continue
		await harness.select_region("box-1")
		_expect_real_active_tool(harness, &"select", str(case.name), support)
		harness.viewport.grab_focus()
		await tree.process_frame
		var before: Dictionary = harness.record()
		var expected_after := _expected_with_box(before, "box-1", case.box)
		await harness.press_key(case.key, case.shift, case.ctrl)
		await _expect_real_command_round_trip(
			harness, before, expected_after, "move_region_command.gd", str(case.name), support,
		)
		await harness.finish()

	var resize_cases := [
		{"name": "Alt 1 px box resize", "shift": false, "ctrl": false, "key": KEY_RIGHT, "box": [20.0, 20.0, 31.0, 24.0]},
		{"name": "Alt+Shift 5 px box resize", "shift": true, "ctrl": false, "key": KEY_DOWN, "box": [20.0, 20.0, 30.0, 29.0]},
		{"name": "Alt+Ctrl+Shift 10 px box resize", "shift": true, "ctrl": true, "key": KEY_RIGHT, "box": [20.0, 20.0, 40.0, 24.0]},
	]
	for case: Dictionary in resize_cases:
		var harness = REAL_UI_HARNESS.new()
		if not await harness.mount(support, tree):
			await harness.finish()
			continue
		await harness.select_region("box-1")
		_expect_real_active_tool(harness, &"select", str(case.name), support)
		harness.viewport.grab_focus()
		await tree.process_frame
		var before: Dictionary = harness.record()
		var expected_after := _expected_with_box(before, "box-1", case.box)
		await harness.press_key(case.key, case.shift, case.ctrl, true)
		await _expect_real_command_round_trip(
			harness, before, expected_after, "resize_box_command.gd", str(case.name), support,
		)
		await harness.finish()

	var polygon = REAL_UI_HARNESS.new()
	if await polygon.mount(support, tree):
		await polygon.select_region("poly-1")
		_expect_real_active_tool(polygon, &"select", "Alt polygon resize", support)
		polygon.viewport.grab_focus()
		await tree.process_frame
		var polygon_before: Dictionary = polygon.record()
		var expected_polygon_after := _expected_with_polygon(
			polygon_before, "poly-1", EXPECTED_KEYBOARD_POLYGON_RESIZE,
		)
		await polygon.press_key(KEY_RIGHT, false, false, true)
		await _expect_real_command_round_trip(
			polygon, polygon_before, expected_polygon_after,
			"replace_region_geometry_command.gd", "Alt polygon resize", support,
		)
	await polygon.finish()


func _test_real_keyboard_delete_and_modal_keys(support: TestSupport, tree: SceneTree) -> void:
	for deletion_key: Key in [KEY_DELETE, KEY_BACKSPACE]:
		var harness = REAL_UI_HARNESS.new()
		if not await harness.mount(support, tree):
			await harness.finish()
			continue
		await harness.select_region("box-1")
		_expect_real_active_tool(harness, &"select", "idle Select %s" % deletion_key, support)
		harness.viewport.grab_focus()
		await tree.process_frame
		var before: Dictionary = harness.record()
		var expected_after := _expected_without_region(before, "box-1")
		await harness.press_key(deletion_key)
		await _expect_real_command_round_trip(
			harness, before, expected_after, "delete_region_command.gd",
			"idle Select %s" % deletion_key, support,
		)
		await harness.finish()

	var guarded = REAL_UI_HARNESS.new()
	if await guarded.mount(support, tree):
		await guarded.select_region("box-1")
		await guarded.click_tool(&"fill")
		_expect_real_active_tool(guarded, &"fill", "guarded deletion keys", support)
		guarded.viewport.grab_focus()
		await tree.process_frame
		var guarded_before: Dictionary = guarded.record()
		for key: Key in [KEY_DELETE, KEY_BACKSPACE, KEY_ENTER]:
			await guarded.press_key(key)
			support.expect_equal(guarded.record(), guarded_before, "%s outside idle Selection must never delete a region" % key)
			support.expect_equal(guarded.undo_count(), 0, "%s outside idle Selection must create no history" % key)
	await guarded.finish()

	var modal = REAL_UI_HARNESS.new()
	if await modal.mount(support, tree):
		modal.viewport.grab_focus()
		await tree.process_frame
		await modal.press_key(KEY_L)
		_expect_real_active_tool(modal, &"lasso", "modal Backspace and Escape", support)
		await modal.press_key(KEY_RIGHT, true)
		await modal.press_key(KEY_DOWN, true)
		var path_before: PackedVector2Array = modal.overlay().get("path", PackedVector2Array())
		await modal.press_key(KEY_BACKSPACE)
		var path_after: PackedVector2Array = modal.overlay().get("path", PackedVector2Array())
		support.expect(path_after.size() < path_before.size(), "modal Lasso Backspace should remove one path point without deleting a region")
		support.expect_equal(modal.undo_count(), 0, "modal Backspace should stay outside command history")
		await modal.press_key(KEY_ESCAPE)
		support.expect_equal(modal.overlay(), {}, "modal Escape should clear the corrected Lasso preview")
	await modal.finish()


func _test_real_idle_select_enter_is_inert(support: TestSupport, tree: SceneTree) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	await harness.select_region("box-1")
	_expect_real_active_tool(harness, &"select", "idle Select Enter", support)
	await harness.focus_viewport()
	var store_before: Dictionary = harness.record()
	var selection_before := harness.selected_region_id()
	var overlay_before: Dictionary = harness.overlay()
	var history_before := [harness.undo_count(), harness.redo_count()]
	await harness.press_key(KEY_ENTER)
	support.expect_equal(harness.record(), store_before,
		"idle Select Enter must preserve the exact Store record")
	support.expect_equal(harness.selected_region_id(), selection_before,
		"idle Select Enter must preserve the selected region")
	support.expect_equal([harness.undo_count(), harness.redo_count()], history_before,
		"idle Select Enter must preserve both history stacks")
	support.expect_equal(harness.overlay(), overlay_before,
		"idle Select Enter must preserve the exact empty overlay")
	_expect_real_active_tool(harness, &"select", "idle Select Enter after input", support)
	await harness.finish()


func _test_real_live_wire_modal_backspace(support: TestSupport, tree: SceneTree) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	await harness.select_region("box-1")
	await harness.click_tool(&"live_wire")
	_expect_real_active_tool(harness, &"live_wire", "modal Live Wire Backspace", support)
	var store_before: Dictionary = harness.record()
	var selection_before := harness.selected_region_id()

	harness.pointer_click(Vector2(112, 75))
	harness.pointer_click(Vector2(132, 75))
	await tree.process_frame
	var two_anchor_overlay: Dictionary = harness.overlay()
	support.expect_equal(
		harness.edit_plugin.get("_live_wire_anchors"),
		PackedVector2Array([Vector2(112, 75), Vector2(132, 75)]),
		"two real clicks should create the independently expected Live Wire anchors",
	)
	harness.pointer_click(Vector2(132, 95))
	await tree.process_frame
	var three_anchor_path: PackedVector2Array = harness.overlay().get("path", PackedVector2Array())
	support.expect_equal(
		harness.edit_plugin.get("_live_wire_anchors"),
		PackedVector2Array([Vector2(112, 75), Vector2(132, 75), Vector2(132, 95)]),
		"third real click should append exactly one Live Wire anchor",
	)

	await harness.focus_viewport()
	await harness.press_key(KEY_BACKSPACE)
	support.expect_equal(
		harness.edit_plugin.get("_live_wire_anchors"),
		PackedVector2Array([Vector2(112, 75), Vector2(132, 75)]),
		"modal Live Wire Backspace should remove only the final anchor",
	)
	var after_backspace: Dictionary = harness.overlay()
	support.expect_equal(after_backspace.get("path"), two_anchor_overlay.get("path"),
		"modal Live Wire Backspace should restore the exact prior fixed path")
	support.expect(after_backspace.get("path", PackedVector2Array()).size() < three_anchor_path.size(),
		"modal Live Wire Backspace should visibly shorten the path")
	support.expect_equal(harness.record(), store_before,
		"modal Live Wire Backspace must not delete or mutate the selected region")
	support.expect_equal(harness.selected_region_id(), selection_before,
		"modal Live Wire Backspace must preserve selection")
	support.expect_equal([harness.undo_count(), harness.redo_count()], [0, 0],
		"modal Live Wire Backspace must create no history")

	harness.pointer_click(Vector2(112, 95))
	await tree.process_frame
	support.expect_equal(
		harness.edit_plugin.get("_live_wire_anchors"),
		PackedVector2Array([Vector2(112, 75), Vector2(132, 75), Vector2(112, 95)]),
		"Live Wire should continue from the retained anchors after Backspace",
	)
	support.expect(not harness.overlay().is_empty(),
		"continued Live Wire should retain a visible modal path before cancellation")
	await harness.press_key(KEY_ESCAPE)
	support.expect_equal(harness.overlay(), {}, "Escape should cancel the continued Live Wire transaction")
	support.expect_equal(harness.edit_plugin.get("_live_wire_anchors"), PackedVector2Array(),
		"Escape should clear Live Wire anchors after a Backspace continuation")
	support.expect_equal(harness.record(), store_before,
		"continued then cancelled Live Wire must preserve the exact Store record")
	support.expect_equal(harness.selected_region_id(), selection_before,
		"continued then cancelled Live Wire must preserve selection")
	support.expect_equal([harness.undo_count(), harness.redo_count()], [0, 0],
		"continued then cancelled Live Wire must create no history")
	await harness.finish()


func _test_real_focus_traversal_and_text_ownership(support: TestSupport, tree: SceneTree) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	await harness.select_region("box-1")
	_expect_real_active_tool(harness, &"select", "focused LineEdit letters", support)
	await harness.double_click_annotation("box-1")
	var class_edit := harness.class_dialog_control("Margin/Content/ClassLabel") as LineEdit
	var kind_edit := harness.class_dialog_control("Margin/Content/Kind") as LineEdit
	class_edit.grab_focus()
	await tree.process_frame
	await harness.press_key(KEY_TAB)
	support.expect(kind_edit.has_focus(),
		"Tab from Class label should reach Kind through normal modal focus traversal")
	await harness.press_key(KEY_TAB, true)
	support.expect(class_edit.has_focus(), "Shift+Tab from Kind should return to Class label")

	class_edit.grab_focus()
	class_edit.caret_column = class_edit.text.length()
	class_edit.deselect()
	await tree.process_frame
	var before: Dictionary = harness.record()
	await harness.press_key(KEY_A, false, false, false, 97)
	support.expect_equal(class_edit.text, "graspera", "ordinary focused modal letters should edit only the local draft")
	_expect_real_active_tool(harness, &"select", "focused LineEdit A", support)
	support.expect_equal(harness.overlay(), {}, "focused LineEdit letters must not arm an edit preview")
	support.expect_equal(harness.record(), before, "focused LineEdit letters must not mutate Store until submitted")
	support.expect_equal(harness.undo_count(), 0, "focused LineEdit letters must not enter command history")
	await harness.cancel_class()
	await harness.finish()


func _real_region(record: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}


func _expect_real_active_tool(
	harness: Variant,
	expected_tool: StringName,
	label: String,
	support: TestSupport,
) -> void:
	support.expect_equal(
		harness.tool_panel.get_active_tool(), expected_tool,
		"%s should expose %s as the real ToolPanel active state" % [label, expected_tool],
	)
	support.expect_equal(
		harness.edit_plugin.get_active_tool(), expected_tool,
		"%s should keep the Edit plugin synchronized with ToolPanel" % label,
	)


func _expected_pointer_record(before: Dictionary, case_name: String, generated_id: String) -> Dictionary:
	match case_name:
		"Add Box":
			var expected := before.duplicate(true)
			expected["regions"].append({
				"id": generated_id,
				"class": "grasper",
				"kind": "instrument",
				"box": [122.0, 18.0, 24.0, 24.0],
				"track_id": null,
			})
			return expected
		"Subtract":
			return _expected_with_polygon(before, "box-1", EXPECTED_POINTER_POLYGONS[case_name])
		"Lasso", "Lasso anchored", "Fill":
			return _expected_with_added_polygon(
				before, generated_id,
				[[68.0, 72.0], [96.0, 72.0], [96.0, 104.0], [68.0, 104.0]],
			)
		"Paint selected":
			return _expected_with_polygon(before, "box-1", EXPECTED_POINTER_POLYGONS[case_name])
		"Eraser":
			return _expected_with_polygon(before, "box-2", EXPECTED_POINTER_POLYGONS[case_name])
		"Select move":
			return _expected_with_box(before, "box-1", [23.0, 24.0, 30.0, 24.0])
		"Select box resize":
			return _expected_with_box(before, "box-1", [20.0, 20.0, 35.0, 28.0])
		"Select polygon resize":
			return _expected_with_polygon(before, "poly-1", EXPECTED_POINTER_POLYGONS[case_name])
	return before.duplicate(true)


func _expected_with_box(before: Dictionary, region_id: String, box: Array) -> Dictionary:
	var expected := before.duplicate(true)
	var region := _real_region(expected, region_id)
	region.erase("polygon")
	region["box"] = box.duplicate(true)
	return expected


func _expected_with_polygon(before: Dictionary, region_id: String, polygon: Array) -> Dictionary:
	var expected := before.duplicate(true)
	var region := _real_region(expected, region_id)
	region.erase("box")
	region["polygon"] = _literal_image_polygon(polygon)
	return expected


func _expected_with_added_polygon(before: Dictionary, region_id: String, polygon: Array) -> Dictionary:
	var expected := before.duplicate(true)
	expected["regions"].append({
		"id": region_id,
		"class": "grasper",
		"kind": "instrument",
		"polygon": _literal_image_polygon(polygon),
		"track_id": null,
	})
	return expected


func _with_fill_boundaries(record: Dictionary) -> Dictionary:
	var result := record.duplicate(true)
	for region: Dictionary in [
		{"id": "fill-top", "class": "boundary", "kind": "region", "box": [64, 68, 36, 4]},
		{"id": "fill-bottom", "class": "boundary", "kind": "region", "box": [64, 104, 36, 4]},
		{"id": "fill-left", "class": "boundary", "kind": "region", "box": [64, 72, 4, 32]},
		{"id": "fill-right", "class": "boundary", "kind": "region", "box": [96, 72, 4, 32]},
	]:
		result.regions.append(region)
	return result


func _literal_image_polygon(points: Array) -> Array:
	# Production geometry crosses Godot's Vector2 boundary.  Build the oracle
	# from literal image coordinates through that same numeric representation,
	# without consulting the observed Store output.
	var result: Array = []
	for value: Variant in points:
		var point := Vector2(float(value[0]), float(value[1]))
		result.append([point.x, point.y])
	return result


func _expected_without_region(before: Dictionary, region_id: String) -> Dictionary:
	var expected := before.duplicate(true)
	var remaining: Array = []
	for value: Variant in expected.get("regions", []):
		if value is Dictionary and str(value.get("id", "")) == region_id:
			continue
		remaining.append(value)
	expected["regions"] = remaining
	return expected


func _test_real_global_undo_cancels_only_nonblocking_preview(support: TestSupport, tree: SceneTree) -> void:
	var harness = REAL_UI_HARNESS.new()
	if not await harness.mount(support, tree):
		await harness.finish()
		return
	await harness.select_region("box-1")
	_expect_real_active_tool(harness, &"select", "nonblocking preview history fixture", support)
	var original: Dictionary = harness.record()
	var expected_moved := _expected_with_box(original, "box-1", [21.0, 20.0, 30.0, 24.0])
	harness.pointer_drag([Vector2(30, 30), Vector2(31, 30)])
	await tree.process_frame
	support.expect_equal(harness.record(), expected_moved, "nonblocking preview fixture should commit its independent move record")
	support.expect_equal(harness.undo_count(), 1, "nonblocking history fixture should contain one real command")
	await harness.click_tool(&"lasso")
	_expect_real_active_tool(harness, &"lasso", "nonblocking Lasso preview", support)
	harness.pointer_click(Vector2(70, 60))
	await tree.process_frame
	support.expect(not harness.overlay().is_empty(), "nonblocking Lasso preview should be visible before global undo")
	await harness.press_key(KEY_Z, false, true)
	support.expect_equal(harness.overlay(), {}, "global undo should cancel a nonblocking transient preview")
	support.expect_equal(harness.record(), original, "global undo should then restore the exact prior Store record")
	support.expect_equal(harness.undo_count(), 0, "global undo should consume the one real command after preview cancellation")
	support.expect_equal(harness.redo_count(), 1, "global undo should preserve one redo command after preview cancellation")
	await harness.finish()


func _test_real_harness_restores_command_allocators(support: TestSupport, tree: SceneTree) -> void:
	var original_box: int = ADD_BOX_COMMAND._next_session_id
	var original_polygon: int = ADD_POLYGON_COMMAND._next_session_id
	ADD_BOX_COMMAND._next_session_id = 42001
	ADD_POLYGON_COMMAND._next_session_id = 43001
	var harness = REAL_UI_HARNESS.new()
	if await harness.mount(support, tree):
		support.expect_equal(ADD_BOX_COMMAND._next_session_id, REAL_UI_HARNESS.GENERATED_ID_SEED,
			"mounted harness should expose its deterministic AddBox allocator seed")
		support.expect_equal(ADD_POLYGON_COMMAND._next_session_id, REAL_UI_HARNESS.GENERATED_ID_SEED,
			"mounted harness should expose its deterministic AddPolygon allocator seed")
	await harness.finish()
	support.expect_equal(ADD_BOX_COMMAND._next_session_id, 42001,
		"successful harness finish should restore the exact prior AddBox allocator")
	support.expect_equal(ADD_POLYGON_COMMAND._next_session_id, 43001,
		"successful harness finish should restore the exact prior AddPolygon allocator")
	await harness.finish()
	support.expect_equal([ADD_BOX_COMMAND._next_session_id, ADD_POLYGON_COMMAND._next_session_id], [42001, 43001],
		"repeated harness finish should be allocator-idempotent")

	ADD_BOX_COMMAND._next_session_id = 52001
	ADD_POLYGON_COMMAND._next_session_id = 53001
	if await harness.mount(support, tree):
		await harness.finish()
	support.expect_equal([ADD_BOX_COMMAND._next_session_id, ADD_POLYGON_COMMAND._next_session_id], [52001, 53001],
		"the same harness should save and restore a fresh allocator pair on a later mount")

	ADD_BOX_COMMAND._next_session_id = 62001
	ADD_POLYGON_COMMAND._next_session_id = 63001
	var failed_harness = REAL_UI_HARNESS.new()
	var expected_failure_support := TestSupport.new()
	var missing_source := "/tmp/annotool-task11-intentional-missing-%d" % Time.get_ticks_usec()
	var did_mount: bool = await failed_harness.mount(expected_failure_support, tree, missing_source)
	support.expect(not did_mount, "an unavailable real source should exercise the harness mount-failure path")
	support.expect(not expected_failure_support.failures.is_empty(),
		"the intentional missing source should be rejected by real Main.open_source")
	support.expect_equal([ADD_BOX_COMMAND._next_session_id, ADD_POLYGON_COMMAND._next_session_id], [62001, 63001],
		"failed mount should restore both allocators before returning to its caller")
	await failed_harness.finish()
	support.expect_equal([ADD_BOX_COMMAND._next_session_id, ADD_POLYGON_COMMAND._next_session_id], [62001, 63001],
		"finish after a failed mount should remain allocator-idempotent")
	# Keep the surrounding runner independent even during the expected RED run.
	ADD_BOX_COMMAND._next_session_id = original_box
	ADD_POLYGON_COMMAND._next_session_id = original_polygon


func _start_drag(viewport: Control, start: Vector2, finish: Vector2) -> void:
	_mouse_button(viewport, true, start)
	_mouse_motion(viewport, finish, MOUSE_BUTTON_MASK_LEFT)


func _mouse_button(viewport: Control, pressed: bool, image_position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = viewport.call("get_image_transform").image_to_viewport(image_position)
	viewport.call("_gui_input", event)


func _mouse_motion(viewport: Control, image_position: Vector2, button_mask: int) -> void:
	var event := InputEventMouseMotion.new()
	event.position = viewport.call("get_image_transform").image_to_viewport(image_position)
	event.button_mask = button_mask
	viewport.call("_gui_input", event)


func _record() -> Dictionary:
	return {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15]},
			{"id": "poly-1", "class": "gallbladder", "kind": "anatomy", "polygon": [[40, 40], [55, 40], [45, 55]]},
		],
	}
