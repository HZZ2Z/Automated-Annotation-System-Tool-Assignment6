extends RefCounted


const PLUGIN_PATH := "res://client/plugins/edit/basic_edit_tools/plugin.gd"
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const ADD_BOX_COMMAND := preload("res://client/domain/commands/add_box_command.gd")
const TRANSFORM_SCRIPT := preload("res://client/services/viewport_transform.gd")
const POLYGON_OPS := preload("res://client/domain/polygon_ops.gd")


class ViewportProbe extends RefCounted:
	signal edit_cancel_requested

	var records: Array[Dictionary] = []
	var selected_ids: Array[String] = []
	var transform = TRANSFORM_SCRIPT.new()
	var overlay_state: Dictionary = {}

	func _init() -> void:
		transform.configure(Vector2(100, 80), Rect2(0, 0, 200, 160))

	func set_record(record: Dictionary) -> void:
		records.append(record.duplicate(true))

	func set_selected_region_id(region_id: String) -> void:
		selected_ids.append(region_id)

	func set_edit_overlay(state: Dictionary) -> void:
		overlay_state = state.duplicate(true)

	func clear_edit_overlay() -> void:
		overlay_state = {}

	func get_edit_overlay_state() -> Dictionary:
		return overlay_state.duplicate(true)

	func get_image_transform():
		return transform


class ExecuteOnlyHistory extends RefCounted:
	func execute(_command, _store) -> PackedStringArray:
		return PackedStringArray()


class ReadOnlyStore extends RefCounted:
	func get_corrected_record(_frame: int) -> Dictionary:
		return {}


class WrongArityHistory extends RefCounted:
	func execute(_command) -> PackedStringArray:
		return PackedStringArray()

	func undo() -> bool:
		return false

	func redo(_store, _extra) -> PackedStringArray:
		return PackedStringArray()


class WrongArityStore extends RefCounted:
	func get_corrected_record() -> Dictionary:
		return {}

	func replace_corrected_record(_frame) -> PackedStringArray:
		return PackedStringArray()


class WrongArityViewport extends RefCounted:
	func set_record() -> void:
		pass

	func set_selected_region_id(_region_id, _extra) -> void:
		pass

	func get_image_transform(_extra):
		return null


class DefaultArgumentSurface extends RefCounted:
	func get_corrected_record(_frame = 0) -> Dictionary:
		return {}

	func replace_corrected_record(_frame = 0, _record = {}) -> PackedStringArray:
		return PackedStringArray()

	func execute(_command = null, _store = null) -> PackedStringArray:
		return PackedStringArray()

	func undo(_store = null) -> bool:
		return false

	func redo(_store = null) -> PackedStringArray:
		return PackedStringArray()

	func set_record(_record = {}) -> void:
		pass

	func set_selected_region_id(_region_id = "") -> void:
		pass

	func get_image_transform():
		return null


static func run(support: TestSupport) -> void:
	var plugin_script: Script = ResourceLoader.load(PLUGIN_PATH)
	support.expect(plugin_script != null, "basic edit-tools plugin should load")
	if plugin_script == null:
		return
	_test_activation_contract(plugin_script, support)
	_test_explicit_tool_contract_and_preview_cancel(plugin_script, support)
	_test_pointer_tools_have_distinct_commands(plugin_script, support)
	_test_pointer_selection_and_single_move(plugin_script, support)
	_test_resize_uses_viewport_pixel_handles(plugin_script, support)
	_test_all_selection_resize_handles(plugin_script, support)
	_test_add_cancel_and_invalid_pointer_restore(plugin_script, support)
	_test_out_of_bounds_selection_preview_and_release(plugin_script, support)
	_test_keyboard_matrix(plugin_script, support)
	_test_bounded_keyboard_nudge_and_resize(plugin_script, support)
	_test_cycle_delete_undo_redo(plugin_script, support)
	_test_whole_region_delete_is_idle_select_only(plugin_script, support)
	_test_keyboard_only_add(plugin_script, support)
	_test_pointer_interrupts_keyboard_add(plugin_script, support)
	_test_pointer_drag_blocks_command_keys(plugin_script, support)
	_test_pointer_motion_loss_and_repress_cancel(plugin_script, support)
	_test_cross_frame_restore_and_selection(plugin_script, support)
	_test_reactivation_cancels_and_rewires(plugin_script, support)
	_test_activation_dependency_surface_and_callable_arity(plugin_script, support)
	_test_pointer_noops_are_numeric_and_cross_frame_safe(plugin_script, support)
	_test_activation_dependency_method_arity(plugin_script, support)
	_test_relabel_selected_pair_action(plugin_script, support)
	_test_relabel_invalid_action_preserves_redo(plugin_script, support)
	_test_box_awaits_class_before_one_atomic_add(plugin_script, support)
	_test_pending_box_guards_and_zero_mutation_cancel(plugin_script, support)


static func _test_activation_contract(plugin_script: Script, support: TestSupport) -> void:
	var plugin = plugin_script.new()
	var errors: PackedStringArray = plugin.activate({})
	support.expect(not errors.is_empty(), "activation should reject missing context without crashing")
	var fixture := _fixture(plugin_script)
	support.expect(fixture.plugin.activate(fixture.context).is_empty(), "valid callable context should activate")
	var bad_context: Dictionary = fixture.context.duplicate()
	bad_context["current_frame"] = "zero"
	errors = fixture.plugin.activate(bad_context)
	support.expect(not errors.is_empty(), "activation should reject a non-callable current-frame getter")
	support.expect(not fixture.statuses.is_empty(), "activation errors should reach the status callback when available")
	var wrong_request_context: Dictionary = fixture.context.duplicate()
	wrong_request_context["request_class_assignment"] = func(): pass
	errors = plugin_script.new().activate(wrong_request_context)
	support.expect(_contains_error(errors, "request_class_assignment") and _contains_error(errors, "argument"),
		"an optional class-assignment callback with the wrong arity must be rejected")


static func _test_explicit_tool_contract_and_preview_cancel(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	support.expect_equal(fixture.plugin.get_active_tool(), &"select", "activation should start in Selection")
	var errors: PackedStringArray = fixture.plugin.set_active_tool(&"polygon")
	support.expect(not errors.is_empty(), "unsupported tools should be rejected")
	support.expect_equal(fixture.plugin.get_active_tool(), &"select", "rejected tools should preserve the active tool")

	support.expect(fixture.plugin.set_active_tool(&"box").is_empty(), "Box should be a supported explicit tool")
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	_motion(fixture.plugin, Vector2(75, 65), fixture.viewport)
	var preview_state: Dictionary = fixture.viewport.get_edit_overlay_state()
	support.expect_equal(preview_state.get("phase"), &"drawing", "Box drag should create a Drawing overlay before release")
	support.expect_equal(preview_state.get("path", PackedVector2Array()).size(), 5, "Box Drawing overlay should contain a closed image-space path")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "Box overlay must not add a fake Model Output region")
	support.expect(fixture.plugin.set_active_tool(&"select").is_empty(), "switching to Selection should be accepted during a preview")
	support.expect_equal(fixture.plugin.get_active_tool(), &"select", "Selection should become authoritative")
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), {}, "tool switching should clear the transient overlay")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "tool switching should leave the committed record unchanged")
	support.expect_equal(fixture.history.get_undo_count(), 0, "cancelled preview must not enter command history")
	var move_errors: PackedStringArray = fixture.plugin.set_active_tool(&"move")
	support.expect(not move_errors.is_empty(), "the removed Move / Resize tool ID should be rejected")
	support.expect_equal(fixture.plugin.get_active_tool(), &"select",
		"a removed Move / Resize request should preserve Selection")


static func _test_pointer_tools_have_distinct_commands(plugin_script: Script, support: TestSupport) -> void:
	var selected := _fixture(plugin_script)
	selected.plugin.activate(selected.context)
	selected.plugin.set_active_tool(&"select")
	_pointer(selected.plugin, true, Vector2(15, 15), selected.viewport)
	_pointer(selected.plugin, false, Vector2(15, 15), selected.viewport)
	support.expect_equal(selected.selected[0], "box-1", "Selection click should select the hit region")
	support.expect_equal(selected.store.get_corrected_record(0), _record(), "Selection click should not mutate geometry")
	support.expect_equal(selected.history.get_undo_count(), 0, "Selection click should not create edit history")

	var moved := _fixture(plugin_script)
	moved.plugin.activate(moved.context)
	moved.plugin.set_active_tool(&"select")
	_pointer(moved.plugin, true, Vector2(15, 15), moved.viewport)
	_motion(moved.plugin, Vector2(18, 19), moved.viewport)
	_pointer(moved.plugin, false, Vector2(18, 19), moved.viewport)
	support.expect_equal(moved.store.get_corrected_record(0).regions[0].box, [13.0, 14.0, 20, 15], "Selection drag should commit the pointer delta")
	support.expect_equal(moved.history.get_undo_count(), 1, "Selection drag should create exactly one command")

	var added := _fixture(plugin_script)
	added.plugin.activate(added.context)
	added.plugin.set_active_tool(&"box")
	_pointer(added.plugin, true, Vector2(60, 50), added.viewport)
	_motion(added.plugin, Vector2(75, 65), added.viewport)
	_pointer(added.plugin, false, Vector2(75, 65), added.viewport)
	support.expect(_confirm_latest_request(added).is_empty(), "Box class confirmation should succeed")
	support.expect_equal(added.store.get_corrected_record(0).regions.size(), 3, "Box should add exactly one region")
	support.expect_equal(added.history.get_undo_count(), 1, "Box should create exactly one command")

	var filled := _fixture(plugin_script)
	filled.plugin.activate(filled.context)
	var hidden_record: Dictionary = filled.store.get_corrected_record(0)
	hidden_record.regions[0]["filled"] = false
	hidden_record = _with_fill_boundaries(hidden_record)
	filled.store.replace_corrected_record(0, hidden_record)
	var hidden_before: Dictionary = filled.store.get_corrected_record(0)
	filled.plugin.set_active_tool(&"fill")
	_pointer(filled.plugin, true, Vector2(75, 60), filled.viewport)
	support.expect_equal(filled.store.get_corrected_record(0), hidden_before,
		"standalone Fill should preserve Store until class assignment")
	support.expect_equal(filled.store.get_corrected_record(0).regions[0].filled, false,
		"toolbar Fill must not take over the Inspector overlay-visibility contract")
	support.expect_equal(filled.viewport.get_edit_overlay_state().get("phase"), &"awaiting_class",
		"clicking a blank area enclosed by annotations should request classification")
	support.expect(_confirm_latest_request(filled).is_empty(),
		"standalone Fill class confirmation should succeed")
	support.expect_equal(filled.store.get_corrected_record(0).regions.size(), hidden_before.regions.size() + 1,
		"standalone Fill should add exactly one region")
	support.expect_equal(filled.store.get_corrected_record(0).regions[0].filled, false,
		"standalone Fill must preserve an existing region's display metadata")
	support.expect_equal(filled.history.get_undo_count(), 1,
		"standalone Fill should create exactly one command after classification")

static func _test_pointer_selection_and_single_move(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"select")
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(15, 15), fixture.viewport)
	support.expect_equal(fixture.selected[0], "box-1", "click should select the hit region")
	support.expect_equal(fixture.history.get_undo_count(), 0, "click without movement should not create a command")

	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_motion(fixture.plugin, Vector2(18, 19), fixture.viewport)
	var move_path: PackedVector2Array = fixture.viewport.get_edit_overlay_state().get("path", PackedVector2Array())
	support.expect(move_path.size() == 5 and move_path[0].is_equal_approx(Vector2(13, 14)) and move_path[2].is_equal_approx(Vector2(33, 29)), "drag should update only the image-space overlay path")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [10, 10, 20, 15], "drag preview must not mutate the store")
	fixture.frame[0] = 99
	fixture.selected[0] = "poly-1"
	_pointer(fixture.plugin, false, Vector2(18, 19), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 1, "one pointer drag should commit exactly one command on release")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [13.0, 14.0, 20, 15], "drag should commit against its frozen frame and region")


static func _test_resize_uses_viewport_pixel_handles(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"select")
	fixture.selected[0] = "box-1"
	fixture.viewport.transform.zoom_at(Vector2(100, 80), 3.0)
	var handle := Vector2(30, 25)
	var scale: float = fixture.viewport.transform.fit_scale * fixture.viewport.transform.user_zoom
	var near_handle := handle + Vector2(5.0 / scale, 0)
	_pointer(fixture.plugin, true, near_handle, fixture.viewport)
	_motion(fixture.plugin, Vector2(35, 29), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(35, 29), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 1, "resize-handle drag should submit one command")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [10.0, 10.0, 25.0, 19.0], "handle hit tolerance should stay in viewport pixels under zoom")


static func _test_all_selection_resize_handles(plugin_script: Script, support: TestSupport) -> void:
	var cases := [
		{"handle": 0, "press": Vector2(10, 10), "target": Vector2(8, 7), "bounds": Rect2(8, 7, 22, 18)},
		{"handle": 1, "press": Vector2(20, 10), "target": Vector2(20, 7), "bounds": Rect2(10, 7, 20, 18)},
		{"handle": 2, "press": Vector2(30, 10), "target": Vector2(32, 7), "bounds": Rect2(10, 7, 22, 18)},
		{"handle": 3, "press": Vector2(30, 17.5), "target": Vector2(32, 17.5), "bounds": Rect2(10, 10, 22, 15)},
		{"handle": 4, "press": Vector2(30, 25), "target": Vector2(32, 28), "bounds": Rect2(10, 10, 22, 18)},
		{"handle": 5, "press": Vector2(20, 25), "target": Vector2(20, 28), "bounds": Rect2(10, 10, 20, 18)},
		{"handle": 6, "press": Vector2(10, 25), "target": Vector2(8, 28), "bounds": Rect2(8, 10, 22, 18)},
		{"handle": 7, "press": Vector2(10, 17.5), "target": Vector2(8, 17.5), "bounds": Rect2(8, 10, 22, 15)},
	]
	for case: Dictionary in cases:
		var box_fixture := _fixture(plugin_script)
		box_fixture.plugin.activate(box_fixture.context)
		box_fixture.selected[0] = "box-1"
		_pointer(box_fixture.plugin, true, case.press, box_fixture.viewport)
		_motion(box_fixture.plugin, case.target, box_fixture.viewport)
		_pointer(box_fixture.plugin, false, case.target, box_fixture.viewport)
		var box: Array = box_fixture.store.get_corrected_record(0).regions[0].box
		support.expect_equal(Rect2(float(box[0]), float(box[1]), float(box[2]), float(box[3])), case.bounds, "box handle %d should own its documented axes" % case.handle)
		support.expect_equal(box_fixture.history.get_undo_count(), 1, "box handle %d should commit once" % case.handle)

		var polygon_fixture := _fixture(plugin_script)
		polygon_fixture.plugin.activate(polygon_fixture.context)
		polygon_fixture.selected[0] = "poly-1"
		var polygon_bounds := Rect2(40, 40, 15, 15)
		var polygon_press := _handle_point(polygon_bounds, case.handle)
		var delta: Vector2 = case.target - case.press
		_pointer(polygon_fixture.plugin, true, polygon_press, polygon_fixture.viewport)
		_motion(polygon_fixture.plugin, polygon_press + delta, polygon_fixture.viewport)
		_pointer(polygon_fixture.plugin, false, polygon_press + delta, polygon_fixture.viewport)
		var polygon: Variant = polygon_fixture.store.get_corrected_record(0).regions[1].polygon
		var expected_polygon_bounds := _resize_bounds(polygon_bounds, case.handle, polygon_press + delta)
		support.expect_equal(POLYGON_OPS.polygon_bounds(polygon), expected_polygon_bounds, "polygon handle %d should affine-resize the same axes" % case.handle)
		support.expect_equal(polygon_fixture.history.get_undo_count(), 1, "polygon handle %d should commit once" % case.handle)


static func _test_add_cancel_and_invalid_pointer_restore(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.begin_add_box()
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	_motion(fixture.plugin, Vector2(75, 65), fixture.viewport)
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 2, "add drag should remain a viewport-only preview")
	fixture.plugin.cancel()
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), {}, "cancel should clear the viewport overlay")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "cancel should leave the real corrected record unchanged")
	support.expect_equal(fixture.history.get_undo_count(), 0, "cancel should not enter history")

	fixture.plugin.begin_add_box()
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	_motion(fixture.plugin, Vector2(75, 65), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(75, 65), fixture.viewport)
	support.expect(_confirm_latest_request(fixture).is_empty(), "add-box drag should confirm its pending class")
	support.expect_equal(fixture.history.get_undo_count(), 1, "add-box drag should commit one command")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 3, "add-box drag should add one region")
	support.expect(not fixture.selected[0].is_empty(), "successful add should select its generated region")

	var invalid := _fixture(plugin_script)
	invalid.plugin.activate(invalid.context)
	invalid.plugin.set_active_tool(&"select")
	invalid.selected[0] = "box-1"
	_pointer(invalid.plugin, true, Vector2(15, 15), invalid.viewport)
	_motion(invalid.plugin, Vector2(-20, 15), invalid.viewport)
	_pointer(invalid.plugin, false, Vector2(-20, 15), invalid.viewport)
	support.expect_equal(invalid.history.get_undo_count(), 0, "invalid pointer release should not enter history")
	support.expect_equal(invalid.store.get_corrected_record(0), _record(), "invalid pointer release should preserve corrected data")
	support.expect_equal(invalid.viewport.get_edit_overlay_state(), {}, "invalid pointer release should clear transient drawing")
	support.expect_equal(invalid.selected[0], "box-1", "failed commit should not fake a selection change")
	support.expect(not invalid.statuses.is_empty(), "invalid pointer release should report validation errors")


static func _test_out_of_bounds_selection_preview_and_release(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.selected[0] = "box-1"
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_motion(fixture.plugin, Vector2(95, 15), fixture.viewport)
	var preview: Dictionary = fixture.viewport.get_edit_overlay_state()
	support.expect_equal(preview.get("phase"), &"invalid", "out-of-image Select preview should enter the Invalid overlay phase")
	support.expect_equal(preview.get("fill_color"), Color("#ef4444"), "out-of-image Select preview should use the red refusal color")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "an invalid Select preview must remain detached from Store")
	_pointer(fixture.plugin, false, Vector2(95, 15), fixture.viewport)
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "out-of-image release must preserve the exact record")
	support.expect_equal(fixture.history.get_undo_count(), 0, "out-of-image release must not enter history")
	support.expect(not fixture.statuses.is_empty(), "out-of-image release should explain its refusal")

	var resize := _fixture(plugin_script)
	resize.plugin.activate(resize.context)
	resize.selected[0] = "poly-1"
	_pointer(resize.plugin, true, Vector2(55, 55), resize.viewport)
	_motion(resize.plugin, Vector2(105, 81), resize.viewport)
	support.expect_equal(resize.viewport.get_edit_overlay_state().get("phase"), &"invalid", "out-of-image polygon resize preview should be red")
	_pointer(resize.plugin, false, Vector2(105, 81), resize.viewport)
	support.expect_equal(resize.store.get_corrected_record(0), _record(), "out-of-image polygon resize release must be atomic")
	support.expect_equal(resize.history.get_undo_count(), 0, "refused polygon resize must not enter history")


static func _test_keyboard_matrix(plugin_script: Script, support: TestSupport) -> void:
	var cases := [
		{"name": "right 1", "key": KEY_RIGHT, "shift": false, "ctrl": false, "alt": false, "want": [11.0, 10.0, 20, 15]},
		{"name": "down 5", "key": KEY_DOWN, "shift": true, "ctrl": false, "alt": false, "want": [10.0, 15.0, 20, 15]},
		{"name": "left 10", "key": KEY_LEFT, "shift": true, "ctrl": true, "alt": false, "want": [0.0, 10.0, 20, 15]},
		{"name": "grow width 1", "key": KEY_RIGHT, "shift": false, "ctrl": false, "alt": true, "want": [10, 10, 21.0, 15.0]},
		{"name": "grow height 5", "key": KEY_DOWN, "shift": true, "ctrl": false, "alt": true, "want": [10, 10, 20.0, 20.0]},
		{"name": "shrink width 10", "key": KEY_LEFT, "shift": true, "ctrl": true, "alt": true, "want": [10, 10, 10.0, 15.0]},
	]
	for case: Dictionary in cases:
		var fixture := _fixture(plugin_script)
		fixture.plugin.activate(fixture.context)
		fixture.selected[0] = "box-1"
		var handled: bool = fixture.plugin.handle_key(_key(case.key, case.shift, case.ctrl, case.alt))
		support.expect(handled, "%s should be handled" % case.name)
		support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, case.want, "%s should use the documented image-pixel step" % case.name)
		support.expect_equal(fixture.history.get_undo_count(), 1, "%s should execute once" % case.name)

	var repeats := _fixture(plugin_script)
	repeats.plugin.activate(repeats.context)
	repeats.selected[0] = "box-1"
	var released := _key(KEY_RIGHT)
	released.pressed = false
	var echo := _key(KEY_RIGHT)
	echo.echo = true
	support.expect(not repeats.plugin.handle_key(released), "key release should not execute an edit")
	support.expect(not repeats.plugin.handle_key(echo), "echo key event should not execute an edit")
	support.expect_equal(repeats.history.get_undo_count(), 0, "release and echo must not enter history")


static func _test_bounded_keyboard_nudge_and_resize(plugin_script: Script, support: TestSupport) -> void:
	var nudge := _fixture(plugin_script)
	nudge.plugin.activate(nudge.context)
	nudge.selected[0] = "box-1"
	var nudge_before: Dictionary = nudge.store.get_corrected_record(0)
	var nudge_expected: Dictionary = nudge_before.duplicate(true)
	nudge_expected.regions[0].box = [15.0, 10.0, 20, 15]
	support.expect(nudge.plugin.handle_key(_key(KEY_RIGHT, true)), "bounded Shift-arrow nudge should be owned by Select")
	support.expect_equal(nudge.store.get_corrected_record(0), nudge_expected, "bounded keyboard nudge should produce the exact requested record")
	support.expect_equal(nudge.history.get_undo_count(), 1, "bounded keyboard nudge should create one undo entry")
	support.expect_equal(nudge.history.get_redo_count(), 0, "bounded keyboard nudge apply should have no redo entry")
	support.expect(nudge.history.undo(nudge.store), "bounded keyboard nudge should undo")
	support.expect_equal(nudge.store.get_corrected_record(0), nudge_before, "bounded keyboard nudge undo should restore the exact before record")
	support.expect_equal(nudge.history.get_undo_count(), 0, "bounded keyboard nudge undo should consume its undo entry")
	support.expect_equal(nudge.history.get_redo_count(), 1, "bounded keyboard nudge undo should create one redo entry")
	support.expect(nudge.history.redo(nudge.store).is_empty(), "bounded keyboard nudge should redo")
	support.expect_equal(nudge.store.get_corrected_record(0), nudge_expected, "bounded keyboard nudge redo should restore the exact after record")
	support.expect_equal(nudge.history.get_undo_count(), 1, "bounded keyboard nudge redo should restore one undo entry")
	support.expect_equal(nudge.history.get_redo_count(), 0, "bounded keyboard nudge redo should consume its redo entry")

	var resize := _fixture(plugin_script)
	resize.plugin.activate(resize.context)
	resize.selected[0] = "box-1"
	var resize_before: Dictionary = resize.store.get_corrected_record(0)
	var resize_expected: Dictionary = resize_before.duplicate(true)
	resize_expected.regions[0].box = [10, 10, 20.0, 20.0]
	support.expect(resize.plugin.handle_key(_key(KEY_DOWN, true, false, true)), "bounded Alt+Shift-arrow resize should be owned by Select")
	support.expect_equal(resize.store.get_corrected_record(0), resize_expected, "bounded keyboard resize should produce the exact requested record")
	support.expect_equal(resize.history.get_undo_count(), 1, "bounded keyboard resize should create one undo entry")
	support.expect_equal(resize.history.get_redo_count(), 0, "bounded keyboard resize apply should have no redo entry")
	support.expect(resize.history.undo(resize.store), "bounded keyboard resize should undo")
	support.expect_equal(resize.store.get_corrected_record(0), resize_before, "bounded keyboard resize undo should restore the exact before record")
	support.expect_equal(resize.history.get_undo_count(), 0, "bounded keyboard resize undo should consume its undo entry")
	support.expect_equal(resize.history.get_redo_count(), 1, "bounded keyboard resize undo should create one redo entry")
	support.expect(resize.history.redo(resize.store).is_empty(), "bounded keyboard resize should redo")
	support.expect_equal(resize.store.get_corrected_record(0), resize_expected, "bounded keyboard resize redo should restore the exact after record")
	support.expect_equal(resize.history.get_undo_count(), 1, "bounded keyboard resize redo should restore one undo entry")
	support.expect_equal(resize.history.get_redo_count(), 0, "bounded keyboard resize redo should consume its redo entry")

	var edge_record := _record()
	edge_record.regions[0].box = [0, 10, 20, 15]
	var move := _fixture_with_records(plugin_script, [edge_record])
	move.plugin.activate(move.context)
	move.selected[0] = "box-1"
	support.expect(move.plugin.handle_key(_key(KEY_LEFT)), "an out-of-image nudge should still be owned by Select")
	support.expect_equal(move.store.get_corrected_record(0), edge_record, "out-of-image nudge must preserve Store exactly")
	support.expect_equal(move.history.get_undo_count(), 0, "out-of-image nudge must not enter history")
	support.expect(not move.statuses.is_empty(), "out-of-image nudge should explain refusal")

	edge_record = _record()
	edge_record.regions[0].box = [80, 10, 20, 15]
	var box_resize := _fixture_with_records(plugin_script, [edge_record])
	box_resize.plugin.activate(box_resize.context)
	box_resize.selected[0] = "box-1"
	box_resize.plugin.handle_key(_key(KEY_RIGHT, false, false, true))
	support.expect_equal(box_resize.store.get_corrected_record(0), edge_record, "Alt-arrow box resize beyond the image must be atomic")
	support.expect_equal(box_resize.history.get_undo_count(), 0, "refused keyboard box resize must not enter history")

	edge_record = _record()
	edge_record.regions[1].polygon = [[85, 40], [100, 40], [90, 55]]
	var polygon_resize := _fixture_with_records(plugin_script, [edge_record])
	polygon_resize.plugin.activate(polygon_resize.context)
	polygon_resize.selected[0] = "poly-1"
	polygon_resize.plugin.handle_key(_key(KEY_RIGHT, false, false, true))
	support.expect_equal(polygon_resize.store.get_corrected_record(0), edge_record, "Alt-arrow polygon resize beyond the image must be atomic")
	support.expect_equal(polygon_resize.history.get_undo_count(), 0, "refused keyboard polygon resize must not enter history")


static func _test_cycle_delete_undo_redo(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	support.expect(not fixture.plugin.handle_key(_key(KEY_TAB)), "Tab should remain available for standard focus traversal")
	support.expect(fixture.plugin.handle_key(_key(KEY_BRACKETRIGHT)), "] should be handled")
	support.expect_equal(fixture.selected[0], "box-1", "] should select the first region from empty selection")
	fixture.plugin.handle_key(_key(KEY_BRACKETRIGHT))
	support.expect_equal(fixture.selected[0], "poly-1", "] should cycle forward")
	fixture.plugin.handle_key(_key(KEY_BRACKETLEFT))
	support.expect_equal(fixture.selected[0], "box-1", "[ should cycle backward")
	fixture.plugin.handle_key(_key(KEY_RIGHT))
	var moved_record: Dictionary = fixture.store.get_corrected_record(0)
	for history_event: InputEventKey in [
		_key(KEY_Z, false, true),
		_key(KEY_Z, true, true),
		_key(KEY_Y, false, true),
	]:
		support.expect(not fixture.plugin.handle_key(history_event),
			"Edit plugin must leave normal Ctrl+Z/Ctrl+Shift+Z/Ctrl+Y ownership to Main")
		support.expect_equal(fixture.store.get_corrected_record(0), moved_record,
			"plugin-level history shortcuts must not mutate Store")
		support.expect_equal(fixture.history.get_undo_count(), 1,
			"plugin-level history shortcuts must not mutate undo history")
		support.expect_equal(fixture.history.get_redo_count(), 0,
			"plugin-level history shortcuts must not mutate redo history")
	support.expect(fixture.history.undo(fixture.store), "command-history fixture should undo the latest plugin edit")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [10, 10, 20, 15], "command undo should restore the latest edit")
	support.expect(fixture.history.redo(fixture.store).is_empty(), "command-history fixture should redo the plugin edit")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [11.0, 10.0, 20, 15], "command redo should restore the edit")
	fixture.plugin.handle_key(_key(KEY_DELETE))
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 1,
		"idle Select Delete should remove selected region")
	support.expect_equal(fixture.selected[0], "", "idle Select Delete should clear selection")
	var backspace := _fixture(plugin_script)
	backspace.plugin.activate(backspace.context)
	backspace.selected[0] = "box-1"
	support.expect_equal(backspace.plugin.get_active_tool(), &"select",
		"whole-region keyboard deletion must begin in idle Select")
	backspace.plugin.handle_key(_key(KEY_BACKSPACE))
	support.expect_equal(backspace.store.get_corrected_record(0).regions.size(), 1,
		"idle Select Backspace should remove selected region")
	support.expect_equal(backspace.selected[0], "", "idle Select Backspace should clear selection")


static func _test_whole_region_delete_is_idle_select_only(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.selected[0] = "box-1"
	support.expect(not fixture.plugin.handle_key(_key(KEY_E)), "E should remain unbound")
	support.expect(not fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should remain unbound in idle Select")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "E and Enter must never delete a selected region")
	support.expect_equal(fixture.history.get_undo_count(), 0, "E and Enter must not enter edit history")

	fixture.plugin.set_active_tool(&"fill")
	support.expect(not fixture.plugin.handle_key(_key(KEY_DELETE)), "Delete should remain unbound outside idle Select")
	support.expect(not fixture.plugin.handle_key(_key(KEY_BACKSPACE)), "Backspace should remain unbound outside idle Select")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "whole-region deletion must not escape Select")
	support.expect_equal(fixture.history.get_undo_count(), 0, "non-Select delete keys must not enter history")


static func _test_keyboard_only_add(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	support.expect(fixture.plugin.handle_key(_key(KEY_A)), "A should start keyboard-only box creation")
	support.expect_equal(fixture.history.get_undo_count(), 0, "keyboard add preview should not commit immediately")
	fixture.plugin.handle_key(_key(KEY_RIGHT))
	fixture.plugin.handle_key(_key(KEY_DOWN, false, false, true))
	support.expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should confirm keyboard-only box creation")
	support.expect(_confirm_latest_request(fixture).is_empty(), "keyboard-only box should accept explicit class confirmation")
	support.expect_equal(fixture.history.get_undo_count(), 1, "keyboard-only add should create exactly one command")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 3, "keyboard-only add should create a valid box")


static func _test_pointer_interrupts_keyboard_add(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"select")
	fixture.plugin.handle_key(_key(KEY_A))
	var keyboard_overlay: Dictionary = fixture.viewport.get_edit_overlay_state()
	support.expect_equal(keyboard_overlay.get("phase"), &"drawing", "keyboard add should begin with a Drawing overlay")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 2, "keyboard add overlay should not enter the committed record")
	support.expect_equal(fixture.plugin.get_active_tool(), &"box", "A should make Box authoritative before a pointer interruption")
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	support.expect_equal(fixture.viewport.get_edit_overlay_state().get("path"), PackedVector2Array([Vector2(60, 50)]), "a new pointer press should replace the keyboard overlay with a fresh gesture")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "pointer interruption should leave the committed record unchanged before release")
	_motion(fixture.plugin, Vector2(75, 65), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(75, 65), fixture.viewport)
	support.expect(_confirm_latest_request(fixture).is_empty(), "fresh pointer gesture should accept explicit class confirmation")
	support.expect_equal(fixture.history.get_undo_count(), 1, "pointer interruption should commit only the fresh pointer gesture")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 3, "interrupted keyboard preview must be replaced by exactly one pointer-added region")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.back().box, [60.0, 50.0, 15.0, 15.0], "pointer interruption should continue with the visible active Box tool")


static func _test_pointer_drag_blocks_command_keys(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"select")
	fixture.selected[0] = "box-1"
	fixture.plugin.handle_key(_key(KEY_RIGHT))
	support.expect(fixture.history.undo(fixture.store), "pointer-drag guard fixture should create one redo entry")
	support.expect_equal(fixture.history.get_undo_count(), 0, "setup undo should leave no undo entry")
	support.expect_equal(fixture.history.get_redo_count(), 1, "setup undo should leave one redo entry")
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_motion(fixture.plugin, Vector2(18, 15), fixture.viewport)
	for blocked_event in [_key(KEY_Z, true, true), _key(KEY_RIGHT), _key(KEY_DELETE), _key(KEY_TAB), _key(KEY_A)]:
		support.expect(fixture.plugin.handle_key(blocked_event), "command and selection keys should be consumed during pointer drag")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "keys during pointer drag must not mutate the store")
	support.expect_equal(fixture.history.get_undo_count(), 0, "keys during pointer drag must not mutate undo history")
	support.expect_equal(fixture.history.get_redo_count(), 1, "keys during pointer drag must not mutate redo history")
	support.expect_equal(fixture.selected[0], "box-1", "keys during pointer drag must not change selection")
	_pointer(fixture.plugin, false, Vector2(18, 15), fixture.viewport)
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [13.0, 10.0, 20, 15], "release should commit only the explicit pointer edit")
	support.expect_equal(fixture.history.get_undo_count(), 1, "pointer edit should be the sole undo entry")
	support.expect_equal(fixture.history.get_redo_count(), 0, "successful pointer edit should clear the prior redo branch")

	var armed := _fixture(plugin_script)
	armed.plugin.activate(armed.context)
	armed.selected[0] = "box-1"
	armed.plugin.begin_add_box()
	for blocked_event in [_key(KEY_RIGHT), _key(KEY_DELETE), _key(KEY_TAB), _key(KEY_A)]:
		support.expect(armed.plugin.handle_key(blocked_event), "armed pointer add should consume command and selection keys")
	support.expect_equal(armed.store.get_corrected_record(0), _record(), "armed add keys must not mutate the store")
	support.expect_equal(armed.selected[0], "box-1", "armed add keys must not change selection")
	armed.plugin.handle_key(_key(KEY_ESCAPE))
	support.expect_equal(armed.viewport.get_edit_overlay_state(), {}, "Escape should cancel armed add and clear transient drawing")
	support.expect_equal(armed.store.get_corrected_record(0), _record(), "Escape should preserve the committed record")

	var resize := _fixture(plugin_script)
	resize.plugin.activate(resize.context)
	resize.plugin.set_active_tool(&"select")
	resize.selected[0] = "box-1"
	_pointer(resize.plugin, true, Vector2(30, 25), resize.viewport)
	_motion(resize.plugin, Vector2(35, 29), resize.viewport)
	for blocked_event in [_key(KEY_RIGHT), _key(KEY_DELETE), _key(KEY_TAB)]:
		resize.plugin.handle_key(blocked_event)
	support.expect_equal(resize.store.get_corrected_record(0), _record(), "keys during resize drag must not mutate the store")
	support.expect_equal(resize.history.get_undo_count(), 0, "keys during resize drag must not enter history")
	_pointer(resize.plugin, false, Vector2(35, 29), resize.viewport)
	support.expect_equal(resize.history.get_undo_count(), 1, "resize release should remain one atomic command")

	var add_drag := _fixture(plugin_script)
	add_drag.plugin.activate(add_drag.context)
	add_drag.plugin.begin_add_box()
	_pointer(add_drag.plugin, true, Vector2(60, 50), add_drag.viewport)
	_motion(add_drag.plugin, Vector2(70, 60), add_drag.viewport)
	for blocked_event in [_key(KEY_RIGHT), _key(KEY_DELETE), _key(KEY_TAB), _key(KEY_A)]:
		add_drag.plugin.handle_key(blocked_event)
	support.expect_equal(add_drag.store.get_corrected_record(0), _record(), "keys during add drag must not mutate the store")
	support.expect_equal(add_drag.history.get_undo_count(), 0, "keys during add drag must not enter history")
	_pointer(add_drag.plugin, false, Vector2(70, 60), add_drag.viewport)
	support.expect(_confirm_latest_request(add_drag).is_empty(), "add release should wait for and accept class confirmation")
	support.expect_equal(add_drag.history.get_undo_count(), 1, "add release should remain one atomic command")


static func _test_pointer_motion_loss_and_repress_cancel(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"select")
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_motion(fixture.plugin, Vector2(18, 15), fixture.viewport)
	var preserved_overlay: Dictionary = fixture.viewport.get_edit_overlay_state()
	var lost_motion := InputEventMouseMotion.new()
	lost_motion.position = fixture.viewport.transform.image_to_viewport(Vector2(20, 15))
	lost_motion.button_mask = 0
	fixture.plugin.handle_pointer(lost_motion, Vector2(20, 15))
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), preserved_overlay, "motion without left-button bits should preserve the active overlay")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "missing-button motion should not mutate committed data")
	fixture.plugin.handle_key(_key(KEY_ESCAPE))
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), {}, "Escape explicitly cancels a gesture preserved across missing-button motion")
	_pointer(fixture.plugin, false, Vector2(20, 15), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 0, "release after explicit Escape must not commit")

	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_motion(fixture.plugin, Vector2(18, 15), fixture.viewport)
	_pointer(fixture.plugin, true, Vector2(45, 45), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 0, "new left press should cancel rather than submit the abandoned drag")
	support.expect_equal(fixture.selected[0], "poly-1", "new left press should be evaluated as a fresh selection")
	_pointer(fixture.plugin, false, Vector2(45, 45), fixture.viewport)
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "fresh click after abandoned drag should not apply stale preview")

	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_motion(fixture.plugin, Vector2(19, 15), fixture.viewport)
	fixture.viewport.edit_cancel_requested.emit()
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), {}, "explicit viewport cancellation signal should clear a suspended overlay")
	support.expect_equal(fixture.store.get_corrected_record(0), _record(), "explicit viewport cancellation should preserve committed data")
	_pointer(fixture.plugin, false, Vector2(19, 15), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 0, "navigation cancellation should prevent a later stale release commit")


static func _test_cross_frame_restore_and_selection(plugin_script: Script, support: TestSupport) -> void:
	var cancel_fixture := _two_frame_fixture(plugin_script)
	cancel_fixture.plugin.activate(cancel_fixture.context)
	cancel_fixture.plugin.set_active_tool(&"select")
	_pointer(cancel_fixture.plugin, true, Vector2(15, 15), cancel_fixture.viewport)
	_motion(cancel_fixture.plugin, Vector2(18, 15), cancel_fixture.viewport)
	cancel_fixture.frame[0] = 1
	cancel_fixture.selected[0] = "frame-1-box"
	cancel_fixture.plugin.cancel()
	support.expect_equal(cancel_fixture.viewport.get_edit_overlay_state(), {}, "cross-frame cancel should clear the transient overlay")
	support.expect_equal(cancel_fixture.store.get_corrected_record(1).regions[0].id, "frame-1-box", "cross-frame cancel should preserve the valid current-frame record")

	var release_fixture := _two_frame_fixture(plugin_script)
	release_fixture.plugin.activate(release_fixture.context)
	release_fixture.plugin.set_active_tool(&"select")
	_pointer(release_fixture.plugin, true, Vector2(15, 15), release_fixture.viewport)
	_motion(release_fixture.plugin, Vector2(18, 15), release_fixture.viewport)
	release_fixture.frame[0] = 1
	release_fixture.selected[0] = "frame-1-box"
	_pointer(release_fixture.plugin, false, Vector2(18, 15), release_fixture.viewport)
	support.expect_equal(release_fixture.store.get_corrected_record(0).regions[0].box, [13.0, 10.0, 20, 15], "cross-frame release may commit to its frozen press frame")
	support.expect_equal(release_fixture.viewport.records.back(), release_fixture.store.get_corrected_record(1), "cross-frame release should render the current frame")
	support.expect_equal(release_fixture.selected[0], "frame-1-box", "cross-frame move release should preserve current-frame selection")

	var invalid_release := _two_frame_fixture(plugin_script)
	invalid_release.plugin.activate(invalid_release.context)
	invalid_release.plugin.set_active_tool(&"select")
	_pointer(invalid_release.plugin, true, Vector2(15, 15), invalid_release.viewport)
	_motion(invalid_release.plugin, Vector2(-20, 15), invalid_release.viewport)
	invalid_release.frame[0] = 1
	invalid_release.selected[0] = "frame-1-box"
	_pointer(invalid_release.plugin, false, Vector2(-20, 15), invalid_release.viewport)
	support.expect_equal(invalid_release.history.get_undo_count(), 0, "invalid cross-frame release should not enter history")
	support.expect_equal(invalid_release.store.get_corrected_record(0), _record(), "invalid cross-frame release should preserve its frozen frame")
	support.expect_equal(invalid_release.viewport.records.back(), invalid_release.store.get_corrected_record(1), "invalid cross-frame release should restore the current visible frame")

	var pointer_add := _two_frame_fixture(plugin_script)
	pointer_add.plugin.activate(pointer_add.context)
	pointer_add.plugin.begin_add_box()
	_pointer(pointer_add.plugin, true, Vector2(60, 50), pointer_add.viewport)
	_motion(pointer_add.plugin, Vector2(70, 60), pointer_add.viewport)
	pointer_add.frame[0] = 1
	pointer_add.selected[0] = "frame-1-box"
	_pointer(pointer_add.plugin, false, Vector2(70, 60), pointer_add.viewport)
	var pointer_stale_errors: PackedStringArray = _confirm_latest_request(pointer_add)
	support.expect(not pointer_stale_errors.is_empty(), "cross-frame pointer confirmation must be refused as stale")
	support.expect_equal(pointer_add.store.get_corrected_record(0).regions.size(), 2, "stale pointer Box must not write its frozen frame")
	support.expect_equal(pointer_add.selected[0], "frame-1-box", "stale pointer Box must preserve current-frame selection")
	pointer_add.plugin.handle_key(_key(KEY_ESCAPE))

	var corrected_selection := _two_frame_fixture(plugin_script)
	corrected_selection.plugin.activate(corrected_selection.context)
	corrected_selection.plugin.begin_add_box()
	_pointer(corrected_selection.plugin, true, Vector2(60, 50), corrected_selection.viewport)
	_motion(corrected_selection.plugin, Vector2(70, 60), corrected_selection.viewport)
	corrected_selection.frame[0] = 1
	corrected_selection.selected[0] = "box-1"
	_pointer(corrected_selection.plugin, false, Vector2(70, 60), corrected_selection.viewport)
	var corrected_stale_errors: PackedStringArray = _confirm_latest_request(corrected_selection)
	support.expect(not corrected_stale_errors.is_empty(), "cross-frame confirmation must not repair selection by mutating data")
	support.expect_equal(corrected_selection.selected[0], "box-1", "stale confirmation must preserve selection exactly")
	corrected_selection.plugin.handle_key(_key(KEY_ESCAPE))

	var keyboard_add := _two_frame_fixture(plugin_script)
	keyboard_add.plugin.activate(keyboard_add.context)
	keyboard_add.plugin.handle_key(_key(KEY_A))
	keyboard_add.frame[0] = 1
	keyboard_add.selected[0] = "frame-1-box"
	keyboard_add.plugin.handle_key(_key(KEY_ENTER))
	var keyboard_stale_errors: PackedStringArray = _confirm_latest_request(keyboard_add)
	support.expect(not keyboard_stale_errors.is_empty(), "cross-frame keyboard confirmation must be refused as stale")
	support.expect_equal(keyboard_add.store.get_corrected_record(0).regions.size(), 2, "stale keyboard Box must not write its frozen frame")
	support.expect_equal(keyboard_add.selected[0], "frame-1-box", "stale keyboard Box must preserve current-frame selection")
	keyboard_add.plugin.handle_key(_key(KEY_ESCAPE))


static func _test_reactivation_cancels_and_rewires(plugin_script: Script, support: TestSupport) -> void:
	var old_fixture := _fixture(plugin_script)
	var plugin = old_fixture.plugin
	plugin.activate(old_fixture.context)
	plugin.set_active_tool(&"select")
	_pointer(plugin, true, Vector2(15, 15), old_fixture.viewport)
	_motion(plugin, Vector2(19, 15), old_fixture.viewport)
	var new_fixture := _fixture(plugin_script)
	support.expect(plugin.activate(new_fixture.context).is_empty(), "valid reactivation should succeed after cancelling old preview")
	plugin.set_active_tool(&"select")
	support.expect_equal(old_fixture.viewport.get_edit_overlay_state(), {}, "valid reactivation should clear the old viewport overlay before replacing context")
	support.expect_equal(old_fixture.store.get_corrected_record(0), _record(), "valid reactivation should preserve the old committed record")
	_pointer(plugin, true, Vector2(15, 15), new_fixture.viewport)
	_motion(plugin, Vector2(18, 15), new_fixture.viewport)
	var new_preview: Dictionary = new_fixture.viewport.get_edit_overlay_state()
	old_fixture.viewport.edit_cancel_requested.emit()
	support.expect_equal(new_fixture.viewport.get_edit_overlay_state(), new_preview, "old viewport cancellation signal should be disconnected after reactivation")
	new_fixture.viewport.edit_cancel_requested.emit()
	support.expect_equal(new_fixture.viewport.get_edit_overlay_state(), {}, "new viewport cancellation signal should cancel the current overlay")
	support.expect_equal(new_fixture.store.get_corrected_record(0), _record(), "new viewport cancellation should preserve committed data")

	plugin.activate(new_fixture.context)
	plugin.set_active_tool(&"select")
	_pointer(plugin, true, Vector2(15, 15), new_fixture.viewport)
	_motion(plugin, Vector2(19, 15), new_fixture.viewport)
	var invalid_context: Dictionary = new_fixture.context.duplicate()
	invalid_context["history"] = RefCounted.new()
	support.expect(not plugin.activate(invalid_context).is_empty(), "invalid reactivation should be rejected")
	support.expect_equal(new_fixture.viewport.get_edit_overlay_state(), {}, "invalid reactivation should still clear the prior overlay immediately")
	support.expect_equal(new_fixture.store.get_corrected_record(0), _record(), "invalid reactivation should preserve the committed record")
	plugin.handle_key(_key(KEY_ESCAPE))
	support.expect_equal(new_fixture.viewport.get_edit_overlay_state(), {}, "Escape after failed reactivation should not be needed to repair ghost overlay")


static func _test_activation_dependency_surface_and_callable_arity(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	var execute_only: Dictionary = fixture.context.duplicate()
	execute_only["history"] = ExecuteOnlyHistory.new()
	var errors: PackedStringArray = plugin_script.new().activate(execute_only)
	support.expect(_contains_error(errors, "undo") and _contains_error(errors, "redo"), "activation should require the full history method surface")
	var read_only: Dictionary = fixture.context.duplicate()
	read_only["store"] = ReadOnlyStore.new()
	errors = plugin_script.new().activate(read_only)
	support.expect(_contains_error(errors, "replace_corrected_record"), "activation should require the store replacement boundary")

	var wrong_callbacks := [
		{"field": "current_frame", "value": func(_unused): return 0, "fragment": "current_frame"},
		{"field": "selected_region", "value": func(_unused): return "", "fragment": "selected_region"},
		{"field": "set_selected_region", "value": func(): pass, "fragment": "set_selected_region"},
		{"field": "status", "value": func(): pass, "fragment": "status"},
	]
	for case: Dictionary in wrong_callbacks:
		var context: Dictionary = fixture.context.duplicate()
		context[case.field] = case.value
		errors = plugin_script.new().activate(context)
		support.expect(_contains_error(errors, case.fragment) and _contains_error(errors, "argument"), "%s callback with wrong arity should be rejected clearly" % case.field)


static func _test_pointer_noops_are_numeric_and_cross_frame_safe(plugin_script: Script, support: TestSupport) -> void:
	for box in [[10, 10, 20, 15], [10.0, 10.0, 20.0, 15.0]]:
		var record := _record()
		record.regions[0].box = box.duplicate()
		var fixture := _fixture_with_records(plugin_script, [record])
		fixture.plugin.activate(fixture.context)
		fixture.plugin.set_active_tool(&"select")
		fixture.selected[0] = "box-1"
		_pointer(fixture.plugin, true, Vector2(30, 25), fixture.viewport)
		_pointer(fixture.plugin, false, Vector2(30, 25), fixture.viewport)
		support.expect_equal(fixture.history.get_undo_count(), 0, "numeric-equivalent resize handle click should not enter history for %s" % str(box))
		support.expect(fixture.store.get_dirty_frames().is_empty(), "numeric-equivalent resize handle click should not dirty the frame for %s" % str(box))

	var zero_move := _two_frame_fixture(plugin_script)
	zero_move.plugin.activate(zero_move.context)
	zero_move.plugin.set_active_tool(&"select")
	_pointer(zero_move.plugin, true, Vector2(15, 15), zero_move.viewport)
	zero_move.frame[0] = 1
	zero_move.selected[0] = "frame-1-box"
	_pointer(zero_move.plugin, false, Vector2(15, 15), zero_move.viewport)
	support.expect_equal(zero_move.history.get_undo_count(), 0, "cross-frame zero move should not enter history")
	support.expect_equal(zero_move.viewport.records.back(), zero_move.store.get_corrected_record(1), "cross-frame zero move should render the current frame")

	var float_zero_resize := _record()
	float_zero_resize.regions[0].box = [10.0, 10.0, 20.0, 15.0]
	var second := _record()
	second.frame = 1
	second.regions[0].id = "frame-1-box"
	second.regions[1].id = "frame-1-poly"
	var zero_resize := _fixture_with_records(plugin_script, [float_zero_resize, second])
	zero_resize.plugin.activate(zero_resize.context)
	zero_resize.plugin.set_active_tool(&"select")
	zero_resize.selected[0] = "box-1"
	_pointer(zero_resize.plugin, true, Vector2(30, 25), zero_resize.viewport)
	zero_resize.frame[0] = 1
	zero_resize.selected[0] = "frame-1-box"
	_pointer(zero_resize.plugin, false, Vector2(30, 25), zero_resize.viewport)
	support.expect_equal(zero_resize.history.get_undo_count(), 0, "cross-frame zero resize should not enter history")
	support.expect_equal(zero_resize.viewport.records.back(), zero_resize.store.get_corrected_record(1), "cross-frame zero resize should render the current frame")


static func _test_activation_dependency_method_arity(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	var cases := [
		{"field": "history", "value": WrongArityHistory.new(), "methods": ["execute", "undo", "redo"]},
		{"field": "store", "value": WrongArityStore.new(), "methods": ["get_corrected_record", "replace_corrected_record"]},
		{"field": "viewport", "value": WrongArityViewport.new(), "methods": ["set_record", "set_selected_region_id", "get_image_transform"]},
	]
	for case: Dictionary in cases:
		var context: Dictionary = fixture.context.duplicate()
		context[case.field] = case.value
		var plugin = plugin_script.new()
		var errors: PackedStringArray = plugin.activate(context)
		for method: String in case.methods:
			support.expect(_contains_error(errors, method) and _contains_error(errors, "argument"), "%s.%s wrong arity should be rejected clearly" % [case.field, method])
		support.expect(not plugin.handle_key(_key(KEY_RIGHT)), "plugin must remain inactive after %s method-signature rejection" % case.field)

	var defaults := DefaultArgumentSurface.new()
	var default_context: Dictionary = fixture.context.duplicate()
	default_context["store"] = defaults
	default_context["history"] = defaults
	default_context["viewport"] = defaults
	support.expect(plugin_script.new().activate(default_context).is_empty(), "dependency methods with defaults should activate when they accept the actual call counts")


static func _test_relabel_selected_pair_action(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	support.expect(fixture.plugin.activate(fixture.context).is_empty(), "relabel fixture should activate")
	fixture.selected[0] = "box-1"
	var before: Dictionary = fixture.store.get_corrected_record(0)
	var errors: PackedStringArray = fixture.plugin.invoke(&"relabel_selected", {"class": "  lesion  ", "kind": "  pathology custom  "})
	support.expect(errors.is_empty(), "relabel action should accept a class and kind pair")
	var changed: Dictionary = fixture.store.get_corrected_record(0).regions[0]
	support.expect_equal([changed["class"], changed["kind"]], ["lesion", "pathology custom"], "relabel action should trim and update both fields")
	support.expect_equal(fixture.history.get_undo_count(), 1, "relabel action should create exactly one command")
	support.expect(fixture.history.undo(fixture.store), "relabel action should undo")
	support.expect_equal(fixture.store.get_corrected_record(0), before, "relabel action undo should restore the exact record")
	support.expect(fixture.history.redo(fixture.store).is_empty(), "relabel action should redo")

	var blank_before: Dictionary = fixture.store.get_corrected_record(0)
	var blank_history_count: int = fixture.history.get_undo_count()
	errors = fixture.plugin.invoke(&"relabel_selected", {"class": "lesion", "kind": "   "})
	support.expect(not errors.is_empty(), "relabel action should reject a blank kind")
	support.expect_equal(fixture.store.get_corrected_record(0), blank_before, "blank kind action should preserve the Store")
	support.expect_equal(fixture.history.get_undo_count(), blank_history_count, "blank kind action should not create History")

	errors = fixture.plugin.invoke(&"relabel_selected", {"class": "  scissors  "})
	support.expect(errors.is_empty(), "class-only relabel action should remain compatible")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0]["kind"], "instrument", "class-only action should derive taxonomy kind")

	for invalid_payload: Dictionary in [
		{"class": 123, "kind": "custom"},
		{"class": "lesion", "kind": null},
		{"class": "lesion", "kind": 123},
	]:
		var invalid_fixture := _fixture(plugin_script)
		support.expect(invalid_fixture.plugin.activate(invalid_fixture.context).is_empty(), "invalid relabel fixture should activate")
		invalid_fixture.selected[0] = "box-1"
		var invalid_before: Dictionary = invalid_fixture.store.get_corrected_record(0)
		var invalid_undo_count: int = invalid_fixture.history.get_undo_count()
		var invalid_redo_count: int = invalid_fixture.history.get_redo_count()
		errors = invalid_fixture.plugin.invoke(&"relabel_selected", invalid_payload)
		support.expect(not errors.is_empty(), "non-string class or explicit null kind should be rejected at the action boundary")
		support.expect_equal(invalid_fixture.store.get_corrected_record(0), invalid_before, "invalid action payload should preserve Store exactly")
		support.expect_equal(invalid_fixture.history.get_undo_count(), invalid_undo_count, "invalid action payload should preserve undo depth")
		support.expect_equal(invalid_fixture.history.get_redo_count(), invalid_redo_count, "invalid action payload should preserve redo depth")


static func _test_relabel_invalid_action_preserves_redo(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	support.expect(fixture.plugin.activate(fixture.context).is_empty(), "redo-preservation fixture should activate")
	fixture.selected[0] = "box-1"
	var before: Dictionary = fixture.store.get_corrected_record(0)
	var apply_errors: PackedStringArray = fixture.plugin.invoke(&"relabel_selected", {"class": "lesion", "kind": "custom"})
	support.expect(apply_errors.is_empty(), "valid relabel should create the redo setup command")
	support.expect(fixture.history.undo(fixture.store), "valid relabel should be undoable for redo setup")
	support.expect_equal(fixture.store.get_corrected_record(0), before, "redo setup undo should restore the original record")
	support.expect_equal(fixture.history.get_undo_count(), 0, "redo setup undo should leave no undo entry")
	support.expect_equal(fixture.history.get_redo_count(), 1, "redo setup undo should leave one redo entry")

	var invalid_before: Dictionary = fixture.store.get_corrected_record(0)
	var invalid_undo_count: int = fixture.history.get_undo_count()
	var invalid_redo_count: int = fixture.history.get_redo_count()
	var errors: PackedStringArray = fixture.plugin.invoke(&"relabel_selected", {"class": "lesion", "kind": 123})
	support.expect(not errors.is_empty(), "numeric kind should be rejected with an existing redo stack")
	support.expect_equal(fixture.store.get_corrected_record(0), invalid_before, "invalid relabel should preserve the full record with an existing redo stack")
	support.expect_equal(fixture.history.get_undo_count(), invalid_undo_count, "invalid relabel should preserve undo depth with an existing redo stack")
	support.expect_equal(fixture.history.get_redo_count(), invalid_redo_count, "invalid relabel should preserve redo depth")


static func _test_box_awaits_class_before_one_atomic_add(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	support.expect(fixture.plugin.activate(fixture.context).is_empty(), "pending Box fixture should activate")
	fixture.selected[0] = "box-1"
	var before: Dictionary = fixture.store.get_corrected_record(0)
	var dirty_before: PackedInt64Array = fixture.store.get_dirty_frames()
	var undo_before: int = fixture.history.get_undo_count()
	var redo_before: int = fixture.history.get_redo_count()
	fixture.plugin.set_active_tool(&"box")
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	_motion(fixture.plugin, Vector2(75, 65), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(75, 65), fixture.viewport)

	support.expect_equal(fixture.store.get_corrected_record(0), before, "pointer Box completion must not write a placeholder region")
	support.expect_equal(fixture.store.get_dirty_frames(), dirty_before, "pending pointer Box must not dirty the frame")
	support.expect_equal(fixture.history.get_undo_count(), undo_before, "pending pointer Box must not enter undo history")
	support.expect_equal(fixture.history.get_redo_count(), redo_before, "pending pointer Box must preserve redo history")
	support.expect_equal(fixture.selected[0], "box-1", "pending pointer Box must preserve selection")
	support.expect_equal(fixture.requests.size(), 1, "pointer Box completion must request class assignment exactly once")
	support.expect_equal(_sorted_keys(fixture.requests[0]), ["candidate_token", "frame", "tool_id"],
		"class-assignment callback must receive identifiers only")
	support.expect_equal(fixture.requests[0]["frame"], 0, "pending request must bind to its frozen frame")
	support.expect_equal(fixture.requests[0]["tool_id"], &"box", "pending request must identify Add Box")
	support.expect(fixture.plugin.get_edit_state().get("navigation_blocked", false), "AwaitingClass must block navigation")
	support.expect_equal(fixture.viewport.get_edit_overlay_state().get("phase"), &"awaiting_class", "pending Box must remain visible")
	support.expect_equal(fixture.viewport.get_edit_overlay_state().get("candidate_polygon", PackedVector2Array()).size(), 4,
		"pending pointer Box must render four candidate corners")

	var token: int = fixture.requests[0]["candidate_token"]
	var errors: PackedStringArray = fixture.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": token,
		"class": "  lesion  ",
		"kind": "  free kind  ",
	})
	support.expect_equal(errors, PackedStringArray(), "valid class and kind should confirm the pending Box")
	support.expect_equal(fixture.history.get_undo_count(), undo_before + 1, "confirmation must execute exactly one Add command")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), before.regions.size() + 1,
		"confirmation must add exactly one region")
	var added: Dictionary = fixture.store.get_corrected_record(0).regions.back()
	support.expect_equal([added.get("class"), added.get("kind"), added.get("box")],
		["lesion", "free kind", [60.0, 50.0, 15.0, 15.0]],
		"confirmation must trim labels and retain the private Box geometry")
	support.expect_equal(fixture.selected[0], added.get("id"), "successful confirmation must select the new region")
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), {}, "successful confirmation must clear pending geometry")
	support.expect(not fixture.plugin.get_edit_state().get("navigation_blocked", true), "successful confirmation must release navigation")
	support.expect(fixture.history.undo(fixture.store), "confirmed Add Box must undo")
	support.expect_equal(fixture.store.get_corrected_record(0), before, "confirmed Add Box undo must restore the exact record")
	support.expect(fixture.history.redo(fixture.store).is_empty(), "confirmed Add Box must redo")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.back(), added, "confirmed Add Box redo must restore the exact region")

	var keyboard := _fixture(plugin_script)
	support.expect(keyboard.plugin.activate(keyboard.context).is_empty(), "keyboard pending Box fixture should activate")
	var keyboard_before: Dictionary = keyboard.store.get_corrected_record(0)
	support.expect(keyboard.plugin.handle_key(_key(KEY_A)), "A should begin keyboard Add Box")
	keyboard.plugin.handle_key(_key(KEY_RIGHT))
	keyboard.plugin.handle_key(_key(KEY_DOWN, false, false, true))
	support.expect(keyboard.plugin.handle_key(_key(KEY_ENTER)), "Enter should finish keyboard geometry")
	support.expect_equal(keyboard.store.get_corrected_record(0), keyboard_before, "keyboard geometry completion must stay pending")
	support.expect_equal(keyboard.history.get_undo_count(), 0, "pending keyboard Box must not enter History")
	support.expect_equal(keyboard.requests.size(), 1, "keyboard Box completion must request class assignment once")
	var keyboard_errors: PackedStringArray = keyboard.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": keyboard.requests[0]["candidate_token"],
		"class": "keyboard lesion",
		"kind": "custom",
	})
	support.expect(keyboard_errors.is_empty(), "keyboard pending Box should confirm")
	support.expect_equal(keyboard.store.get_corrected_record(0).regions.size(), keyboard_before.regions.size() + 1,
		"keyboard confirmation must add exactly one region")
	support.expect_equal(keyboard.history.get_undo_count(), 1, "keyboard confirmation must create one History entry")


static func _test_pending_box_guards_and_zero_mutation_cancel(plugin_script: Script, support: TestSupport) -> void:
	var allocator_before = ADD_BOX_COMMAND.new(0, _record(), [70, 60, 5, 5], "probe", "probe")
	var allocator_before_number := _id_suffix(allocator_before.get_region_id())
	var fixture := _fixture(plugin_script)
	support.expect(fixture.plugin.activate(fixture.context).is_empty(), "pending guard fixture should activate")
	fixture.selected[0] = "poly-1"
	var before: Dictionary = fixture.store.get_corrected_record(0)
	var dirty_before: PackedInt64Array = fixture.store.get_dirty_frames()
	fixture.plugin.set_active_tool(&"box")
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(70, 60), fixture.viewport)
	var token: int = fixture.requests[0]["candidate_token"]
	var pending_overlay: Dictionary = fixture.viewport.get_edit_overlay_state()
	var allocator_after = ADD_BOX_COMMAND.new(0, _record(), [75, 60, 5, 5], "probe", "probe")
	support.expect_equal(_id_suffix(allocator_after.get_region_id()), allocator_before_number + 1,
		"pending geometry must not allocate a region ID before confirmation")

	for invalid_payload: Dictionary in [
		{"candidate_token": token + 1, "class": "lesion", "kind": "custom"},
		{"candidate_token": token, "class": "   ", "kind": "custom"},
		{"candidate_token": token, "class": 12, "kind": "custom"},
		{"candidate_token": token, "class": "lesion", "kind": "   "},
		{"candidate_token": token, "class": "lesion", "kind": null},
	]:
		var errors: PackedStringArray = fixture.plugin.invoke(&"confirm_pending_region", invalid_payload)
		support.expect(not errors.is_empty(), "invalid pending confirmation must return a clear error")
		support.expect_equal(fixture.store.get_corrected_record(0), before, "invalid pending confirmation must preserve Store")
		support.expect_equal(fixture.store.get_dirty_frames(), dirty_before, "invalid pending confirmation must preserve dirty frames")
		support.expect_equal(fixture.history.get_undo_count(), 0, "invalid pending confirmation must preserve History")
		support.expect_equal(fixture.selected[0], "poly-1", "invalid pending confirmation must preserve selection")
		support.expect_equal(fixture.viewport.get_edit_overlay_state(), pending_overlay, "invalid pending confirmation must retain geometry")
	var wrong_cancel_errors: PackedStringArray = fixture.plugin.invoke(&"cancel_pending_region", {"candidate_token": token + 1})
	support.expect(not wrong_cancel_errors.is_empty(), "a stale token must not cancel the pending Box")
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), pending_overlay, "stale cancellation must retain pending geometry")

	var tool_errors: PackedStringArray = fixture.plugin.set_active_tool(&"select")
	support.expect(not tool_errors.is_empty(), "tool switching must be refused while class assignment is pending")
	var unrelated_errors: PackedStringArray = fixture.plugin.invoke(&"delete_selected")
	support.expect(not unrelated_errors.is_empty(), "unrelated edit actions must be refused while class assignment is pending")
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(20, 20), fixture.viewport)
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), pending_overlay, "pointer input must be ignored while class assignment is pending")
	for guarded_key: InputEventKey in [_key(KEY_DELETE), _key(KEY_ENTER), _key(KEY_TAB), _key(KEY_Z, false, true)]:
		support.expect(fixture.plugin.handle_key(guarded_key), "editing keys must be consumed while class assignment is pending")
	support.expect_equal(fixture.store.get_corrected_record(0), before, "pending guards must preserve Store")
	support.expect_equal(fixture.history.get_undo_count(), 0, "pending guards must preserve History")
	support.expect_equal(fixture.selected[0], "poly-1", "pending guards must preserve selection")

	var cancel_errors: PackedStringArray = fixture.plugin.invoke(&"cancel_pending_region", {"candidate_token": token})
	support.expect(cancel_errors.is_empty(), "matching token should cancel a pending Box")
	support.expect_equal(fixture.viewport.get_edit_overlay_state(), {}, "cancel action must clear the pending overlay")
	support.expect_equal(fixture.store.get_corrected_record(0), before, "cancel action must preserve Store")
	support.expect_equal(fixture.store.get_dirty_frames(), dirty_before, "cancel action must preserve dirty frames")
	support.expect_equal(fixture.history.get_undo_count(), 0, "cancel action must preserve History")
	support.expect_equal(fixture.selected[0], "poly-1", "cancel action must preserve selection")
	var allocator_after_cancel = ADD_BOX_COMMAND.new(0, _record(), [80, 60, 5, 5], "probe", "probe")
	support.expect_equal(_id_suffix(allocator_after_cancel.get_region_id()), _id_suffix(allocator_after.get_region_id()) + 1,
		"pending cancellation must not allocate a region ID")

	var out_of_bounds := _fixture(plugin_script)
	support.expect(out_of_bounds.plugin.activate(out_of_bounds.context).is_empty(), "out-of-bounds fixture should activate")
	var out_of_bounds_before: Dictionary = out_of_bounds.store.get_corrected_record(0)
	var allocator_before_invalid = ADD_BOX_COMMAND.new(0, _record(), [70, 60, 5, 5], "probe", "probe")
	var allocator_before_invalid_number := _id_suffix(allocator_before_invalid.get_region_id())
	out_of_bounds.plugin.call("_await_class_for_box", 0, out_of_bounds_before, [95.0, 75.0, 10.0, 10.0], Vector2(100, 80))
	var out_of_bounds_request: Dictionary = out_of_bounds.requests[0]
	var out_of_bounds_errors: PackedStringArray = out_of_bounds.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": out_of_bounds_request["candidate_token"], "class": "lesion", "kind": "custom",
	})
	var allocator_after_invalid = ADD_BOX_COMMAND.new(0, _record(), [75, 60, 5, 5], "probe", "probe")
	support.expect(not out_of_bounds_errors.is_empty() and _contains_error(out_of_bounds_errors, "inside"),
		"out-of-bounds confirmation must return a clear geometry error")
	support.expect(out_of_bounds.plugin.get_edit_state().get("navigation_blocked", false),
		"out-of-bounds confirmation must retain AwaitingClass")
	support.expect_equal(out_of_bounds.store.get_corrected_record(0), out_of_bounds_before,
		"out-of-bounds confirmation must preserve Store")
	support.expect_equal(out_of_bounds.history.get_undo_count(), 0,
		"out-of-bounds confirmation must preserve History")
	support.expect_equal(_id_suffix(allocator_after_invalid.get_region_id()), allocator_before_invalid_number + 1,
		"out-of-bounds confirmation must fail before allocating a region ID")

	var no_callback := _fixture(plugin_script)
	no_callback.context.erase("request_class_assignment")
	support.expect(no_callback.plugin.activate(no_callback.context).is_empty(), "class callback must remain optional")
	no_callback.plugin.set_active_tool(&"box")
	_pointer(no_callback.plugin, true, Vector2(60, 50), no_callback.viewport)
	_pointer(no_callback.plugin, false, Vector2(70, 60), no_callback.viewport)
	support.expect(no_callback.plugin.get_edit_state().get("navigation_blocked", false),
		"missing optional callback must retain a safe pending candidate")
	support.expect(not no_callback.statuses.is_empty() and "Class assignment is unavailable" in no_callback.statuses.back(),
		"missing optional callback must explain Escape recovery")
	no_callback.plugin.handle_key(_key(KEY_ESCAPE))

	var stale := _two_frame_fixture(plugin_script)
	support.expect(stale.plugin.activate(stale.context).is_empty(), "stale-frame fixture should activate")
	stale.plugin.set_active_tool(&"box")
	_pointer(stale.plugin, true, Vector2(60, 50), stale.viewport)
	_pointer(stale.plugin, false, Vector2(70, 60), stale.viewport)
	var stale_token: int = stale.requests[0]["candidate_token"]
	stale.frame[0] = 1
	var stale_errors: PackedStringArray = stale.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": stale_token, "class": "lesion", "kind": "custom",
	})
	support.expect(not stale_errors.is_empty() and _contains_error(stale_errors, "frame"), "stale frame must be explained")
	support.expect(stale.plugin.get_edit_state().get("navigation_blocked", false), "stale frame must retain AwaitingClass")
	support.expect_equal(stale.store.get_corrected_record(0), _record(), "stale frame must preserve its frozen record")

	var changed := _fixture(plugin_script)
	support.expect(changed.plugin.activate(changed.context).is_empty(), "changed-record fixture should activate")
	changed.plugin.set_active_tool(&"box")
	_pointer(changed.plugin, true, Vector2(60, 50), changed.viewport)
	_pointer(changed.plugin, false, Vector2(70, 60), changed.viewport)
	var changed_token: int = changed.requests[0]["candidate_token"]
	var externally_changed: Dictionary = changed.store.get_corrected_record(0)
	externally_changed.regions[0]["class"] = "external"
	changed.store.replace_corrected_record(0, externally_changed)
	var changed_errors: PackedStringArray = changed.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": changed_token, "class": "lesion", "kind": "custom",
	})
	support.expect(not changed_errors.is_empty() and _contains_error(changed_errors, "record"), "changed record must be explained")
	support.expect(changed.plugin.get_edit_state().get("navigation_blocked", false), "changed record must retain AwaitingClass")
	support.expect_equal(changed.history.get_undo_count(), 0, "changed-record refusal must not enter History")

	var escape := _fixture(plugin_script)
	support.expect(escape.plugin.activate(escape.context).is_empty(), "Escape cancellation fixture should activate")
	escape.selected[0] = "box-1"
	var escape_before: Dictionary = escape.store.get_corrected_record(0)
	escape.plugin.handle_key(_key(KEY_A))
	escape.plugin.handle_key(_key(KEY_ENTER))
	support.expect_equal(escape.requests.size(), 1, "Escape fixture must reach AwaitingClass")
	support.expect(escape.plugin.handle_key(_key(KEY_ESCAPE)), "Escape must cancel AwaitingClass")
	support.expect_equal(escape.store.get_corrected_record(0), escape_before, "Escape cancellation must preserve Store")
	support.expect_equal(escape.store.get_dirty_frames(), PackedInt64Array(), "Escape cancellation must preserve dirty frames")
	support.expect_equal(escape.history.get_undo_count(), 0, "Escape cancellation must preserve History")
	support.expect_equal(escape.selected[0], "box-1", "Escape cancellation must preserve selection")
	support.expect_equal(escape.viewport.get_edit_overlay_state(), {}, "Escape cancellation must clear pending geometry")


static func _fixture(plugin_script: Script) -> Dictionary:
	var store = STORE_SCRIPT.new()
	store.load_model_records([_record()])
	var history = HISTORY_SCRIPT.new()
	var viewport := ViewportProbe.new()
	var frame := [0]
	var selected := [""]
	var statuses: Array[String] = []
	var requests: Array[Dictionary] = []
	var context := {
		"store": store,
		"history": history,
		"viewport": viewport,
		"current_frame": func(): return frame[0],
		"selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"status": func(message: String): statuses.append(message),
		"request_class_assignment": func(payload: Dictionary): requests.append(payload.duplicate(true)),
		"taxonomy": {"classes": [{"id": "unknown", "kind": "region"}]},
	}
	return {"plugin": plugin_script.new(), "store": store, "history": history, "viewport": viewport, "frame": frame, "selected": selected, "statuses": statuses, "requests": requests, "context": context}


static func _two_frame_fixture(plugin_script: Script) -> Dictionary:
	var second := _record()
	second["frame"] = 1
	second["regions"][0]["id"] = "frame-1-box"
	second["regions"][1]["id"] = "frame-1-poly"
	return _fixture_with_records(plugin_script, [_record(), second])


static func _fixture_with_records(plugin_script: Script, records: Array) -> Dictionary:
	var store = STORE_SCRIPT.new()
	store.load_model_records(records)
	var history = HISTORY_SCRIPT.new()
	var viewport := ViewportProbe.new()
	var frame := [0]
	var selected := [""]
	var statuses: Array[String] = []
	var requests: Array[Dictionary] = []
	var context := {
		"store": store,
		"history": history,
		"viewport": viewport,
		"current_frame": func(): return frame[0],
		"selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"status": func(message: String): statuses.append(message),
		"request_class_assignment": func(payload: Dictionary): requests.append(payload.duplicate(true)),
		"taxonomy": {"classes": [{"id": "unknown", "kind": "region"}]},
	}
	return {"plugin": plugin_script.new(), "store": store, "history": history, "viewport": viewport, "frame": frame, "selected": selected, "statuses": statuses, "requests": requests, "context": context}


static func _pointer(plugin, pressed: bool, image_position: Vector2, viewport: ViewportProbe) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = viewport.transform.image_to_viewport(image_position)
	plugin.handle_pointer(event, image_position)


static func _confirm_latest_request(fixture: Dictionary, class_label := "unknown", kind := "region") -> PackedStringArray:
	if fixture.requests.is_empty():
		return PackedStringArray(["test fixture captured no pending class request"])
	return fixture.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": fixture.requests.back()["candidate_token"],
		"class": class_label,
		"kind": kind,
	})


static func _motion(plugin, image_position: Vector2, viewport: ViewportProbe) -> void:
	var event := InputEventMouseMotion.new()
	event.position = viewport.transform.image_to_viewport(image_position)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	plugin.handle_pointer(event, image_position)


static func _key(code: Key, shift := false, ctrl := false, alt := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	event.alt_pressed = alt
	return event


static func _handle_point(bounds: Rect2, handle: int) -> Vector2:
	var center := bounds.get_center()
	return [
		bounds.position,
		Vector2(center.x, bounds.position.y),
		Vector2(bounds.end.x, bounds.position.y),
		Vector2(bounds.end.x, center.y),
		bounds.end,
		Vector2(center.x, bounds.end.y),
		Vector2(bounds.position.x, bounds.end.y),
		Vector2(bounds.position.x, center.y),
	][handle]


static func _resize_bounds(bounds: Rect2, handle: int, target: Vector2) -> Rect2:
	var minimum := bounds.position
	var maximum := bounds.end
	if handle in [0, 6, 7]:
		minimum.x = target.x
	elif handle in [2, 3, 4]:
		maximum.x = target.x
	if handle in [0, 1, 2]:
		minimum.y = target.y
	elif handle in [4, 5, 6]:
		maximum.y = target.y
	return Rect2(minimum, maximum - minimum)


static func _record() -> Dictionary:
	return {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15], "conf": 0.9, "track_id": "T01"},
			{"id": "poly-1", "class": "gallbladder", "kind": "anatomy", "polygon": [[40, 40], [55, 40], [45, 55]]},
		],
	}


static func _with_fill_boundaries(record: Dictionary) -> Dictionary:
	var result := record.duplicate(true)
	for region: Dictionary in [
		{"id": "fill-top", "class": "boundary", "kind": "region", "box": [65, 50, 25, 3]},
		{"id": "fill-bottom", "class": "boundary", "kind": "region", "box": [65, 70, 25, 3]},
		{"id": "fill-left", "class": "boundary", "kind": "region", "box": [65, 53, 3, 17]},
		{"id": "fill-right", "class": "boundary", "kind": "region", "box": [87, 53, 3, 17]},
	]:
		result.regions.append(region)
	return result


static func _contains_error(errors: PackedStringArray, fragment: String) -> bool:
	for error: String in errors:
		if fragment in error:
			return true
	return false


static func _sorted_keys(value: Dictionary) -> Array:
	var keys: Array = value.keys()
	keys.sort()
	return keys


static func _id_suffix(region_id: String) -> int:
	return int(region_id.get_slice("-", region_id.get_slice_count("-") - 1))


static func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}
