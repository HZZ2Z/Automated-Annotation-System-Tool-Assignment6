extends RefCounted


const PLUGIN_PATH := "res://client/plugins/edit/basic_edit_tools/plugin.gd"
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const TRANSFORM_SCRIPT := preload("res://client/services/viewport_transform.gd")


class ViewportProbe extends RefCounted:
	signal edit_cancel_requested

	var records: Array[Dictionary] = []
	var selected_ids: Array[String] = []
	var transform = TRANSFORM_SCRIPT.new()

	func _init() -> void:
		transform.configure(Vector2(100, 80), Rect2(0, 0, 200, 160))

	func set_record(record: Dictionary) -> void:
		records.append(record.duplicate(true))

	func set_selected_region_id(region_id: String) -> void:
		selected_ids.append(region_id)

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
	_test_add_cancel_and_invalid_pointer_restore(plugin_script, support)
	_test_keyboard_matrix(plugin_script, support)
	_test_cycle_delete_undo_redo(plugin_script, support)
	_test_keyboard_only_add(plugin_script, support)
	_test_pointer_interrupts_keyboard_add(plugin_script, support)
	_test_pointer_drag_blocks_command_keys(plugin_script, support)
	_test_pointer_motion_loss_and_repress_cancel(plugin_script, support)
	_test_cross_frame_restore_and_selection(plugin_script, support)
	_test_reactivation_cancels_and_rewires(plugin_script, support)
	_test_activation_dependency_surface_and_callable_arity(plugin_script, support)
	_test_pointer_noops_are_numeric_and_cross_frame_safe(plugin_script, support)
	_test_activation_dependency_method_arity(plugin_script, support)


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


static func _test_explicit_tool_contract_and_preview_cancel(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	support.expect_equal(fixture.plugin.get_active_tool(), &"select", "activation should start in the non-mutating Select tool")
	var errors: PackedStringArray = fixture.plugin.set_active_tool(&"polygon")
	support.expect(not errors.is_empty(), "unsupported tools should be rejected")
	support.expect_equal(fixture.plugin.get_active_tool(), &"select", "rejected tools should preserve the active tool")

	support.expect(fixture.plugin.set_active_tool(&"box").is_empty(), "Box should be a supported explicit tool")
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	_motion(fixture.plugin, Vector2(75, 65), fixture.viewport)
	var preview_region := _find_region(fixture.viewport.records.back(), "__new_box_preview")
	support.expect(not preview_region.is_empty(), "Box drag should create only a transient preview before release")
	support.expect(not preview_region.has("filled"), "new preview should not add a model-output field")
	support.expect(fixture.plugin.set_active_tool(&"move").is_empty(), "switching tools should be accepted during a preview")
	support.expect_equal(fixture.plugin.get_active_tool(), &"move", "the requested Move tool should become authoritative")
	support.expect_equal(fixture.viewport.records.back(), fixture.store.get_corrected_record(0), "tool switching should restore the committed record and cancel the preview")
	support.expect_equal(fixture.history.get_undo_count(), 0, "cancelled preview must not enter command history")


static func _test_pointer_tools_have_distinct_commands(plugin_script: Script, support: TestSupport) -> void:
	var selected := _fixture(plugin_script)
	selected.plugin.activate(selected.context)
	selected.plugin.set_active_tool(&"select")
	_pointer(selected.plugin, true, Vector2(15, 15), selected.viewport)
	_motion(selected.plugin, Vector2(18, 19), selected.viewport)
	_pointer(selected.plugin, false, Vector2(18, 19), selected.viewport)
	support.expect_equal(selected.selected[0], "box-1", "Select should select the hit region")
	support.expect_equal(selected.store.get_corrected_record(0), _record(), "Select drag should never mutate geometry")
	support.expect_equal(selected.history.get_undo_count(), 0, "Select should never create edit history")

	var moved := _fixture(plugin_script)
	moved.plugin.activate(moved.context)
	moved.plugin.set_active_tool(&"move")
	_pointer(moved.plugin, true, Vector2(15, 15), moved.viewport)
	_motion(moved.plugin, Vector2(18, 19), moved.viewport)
	_pointer(moved.plugin, false, Vector2(18, 19), moved.viewport)
	support.expect_equal(moved.store.get_corrected_record(0).regions[0].box, [13.0, 14.0, 20, 15], "Move should commit the pointer delta")
	support.expect_equal(moved.history.get_undo_count(), 1, "Move should create exactly one command")

	var added := _fixture(plugin_script)
	added.plugin.activate(added.context)
	added.plugin.set_active_tool(&"box")
	_pointer(added.plugin, true, Vector2(60, 50), added.viewport)
	_motion(added.plugin, Vector2(75, 65), added.viewport)
	_pointer(added.plugin, false, Vector2(75, 65), added.viewport)
	support.expect_equal(added.store.get_corrected_record(0).regions.size(), 3, "Box should add exactly one region")
	support.expect_equal(added.history.get_undo_count(), 1, "Box should create exactly one command")

	var filled := _fixture(plugin_script)
	filled.plugin.activate(filled.context)
	filled.plugin.set_active_tool(&"fill")
	_pointer(filled.plugin, true, Vector2(15, 15), filled.viewport)
	_pointer(filled.plugin, false, Vector2(15, 15), filled.viewport)
	support.expect_equal(filled.store.get_corrected_record(0).regions[0].filled, true, "Fill should toggle the hit region")
	support.expect_equal(filled.history.get_undo_count(), 1, "Fill should create exactly one command")

	var deleted := _fixture(plugin_script)
	deleted.plugin.activate(deleted.context)
	deleted.plugin.set_active_tool(&"delete")
	_pointer(deleted.plugin, true, Vector2(15, 15), deleted.viewport)
	_pointer(deleted.plugin, false, Vector2(15, 15), deleted.viewport)
	support.expect_equal(deleted.store.get_corrected_record(0).regions.size(), 1, "Delete should remove exactly the hit region")
	support.expect_equal(deleted.selected[0], "", "Delete should clear the removed selection")
	support.expect_equal(deleted.history.get_undo_count(), 1, "Delete should create exactly one command")


static func _test_pointer_selection_and_single_move(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"move")
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(15, 15), fixture.viewport)
	support.expect_equal(fixture.selected[0], "box-1", "click should select the hit region")
	support.expect_equal(fixture.history.get_undo_count(), 0, "click without movement should not create a command")

	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_motion(fixture.plugin, Vector2(18, 19), fixture.viewport)
	support.expect_equal(fixture.viewport.records.back().regions[0].box, [13.0, 14.0, 20, 15], "drag should update only viewport preview")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [10, 10, 20, 15], "drag preview must not mutate the store")
	fixture.frame[0] = 99
	fixture.selected[0] = "poly-1"
	_pointer(fixture.plugin, false, Vector2(18, 19), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 1, "one pointer drag should commit exactly one command on release")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [13.0, 14.0, 20, 15], "drag should commit against its frozen frame and region")


static func _test_resize_uses_viewport_pixel_handles(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"move")
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


static func _test_add_cancel_and_invalid_pointer_restore(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.begin_add_box()
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	_motion(fixture.plugin, Vector2(75, 65), fixture.viewport)
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 2, "add drag should remain a viewport-only preview")
	fixture.plugin.cancel()
	support.expect_equal(fixture.viewport.records.back(), fixture.store.get_corrected_record(0), "cancel should restore the real corrected record")
	support.expect_equal(fixture.history.get_undo_count(), 0, "cancel should not enter history")

	fixture.plugin.begin_add_box()
	_pointer(fixture.plugin, true, Vector2(60, 50), fixture.viewport)
	_motion(fixture.plugin, Vector2(75, 65), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(75, 65), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 1, "add-box drag should commit one command")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 3, "add-box drag should add one region")
	support.expect(not fixture.selected[0].is_empty(), "successful add should select its generated region")

	var invalid := _fixture(plugin_script)
	invalid.plugin.activate(invalid.context)
	invalid.plugin.set_active_tool(&"move")
	invalid.selected[0] = "box-1"
	_pointer(invalid.plugin, true, Vector2(15, 15), invalid.viewport)
	_motion(invalid.plugin, Vector2(-20, 15), invalid.viewport)
	_pointer(invalid.plugin, false, Vector2(-20, 15), invalid.viewport)
	support.expect_equal(invalid.history.get_undo_count(), 0, "invalid pointer release should not enter history")
	support.expect_equal(invalid.store.get_corrected_record(0), _record(), "invalid pointer release should preserve corrected data")
	support.expect_equal(invalid.viewport.records.back(), invalid.store.get_corrected_record(0), "invalid pointer release should restore real corrected data")
	support.expect_equal(invalid.selected[0], "box-1", "failed commit should not fake a selection change")
	support.expect(not invalid.statuses.is_empty(), "invalid pointer release should report validation errors")


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


static func _test_cycle_delete_undo_redo(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	support.expect(fixture.plugin.handle_key(_key(KEY_TAB)), "Tab should be handled")
	support.expect_equal(fixture.selected[0], "box-1", "Tab should select the first region from empty selection")
	fixture.plugin.handle_key(_key(KEY_TAB))
	support.expect_equal(fixture.selected[0], "poly-1", "Tab should cycle forward")
	fixture.plugin.handle_key(_key(KEY_TAB, true))
	support.expect_equal(fixture.selected[0], "box-1", "Shift+Tab should cycle backward")
	fixture.plugin.handle_key(_key(KEY_RIGHT))
	fixture.plugin.handle_key(_key(KEY_Z, false, true))
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [10, 10, 20, 15], "Ctrl+Z should undo the latest edit")
	fixture.plugin.handle_key(_key(KEY_Z, true, true))
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [11.0, 10.0, 20, 15], "Ctrl+Shift+Z should redo")
	fixture.plugin.handle_key(_key(KEY_DELETE))
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 1, "Delete should remove selected region")
	support.expect_equal(fixture.selected[0], "", "successful Delete should clear selection")


static func _test_keyboard_only_add(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	support.expect(fixture.plugin.handle_key(_key(KEY_A)), "A should start keyboard-only box creation")
	support.expect_equal(fixture.history.get_undo_count(), 0, "keyboard add preview should not commit immediately")
	fixture.plugin.handle_key(_key(KEY_RIGHT))
	fixture.plugin.handle_key(_key(KEY_DOWN, false, false, true))
	support.expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should confirm keyboard-only box creation")
	support.expect_equal(fixture.history.get_undo_count(), 1, "keyboard-only add should create exactly one command")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 3, "keyboard-only add should create a valid box")


static func _test_pointer_interrupts_keyboard_add(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"move")
	fixture.plugin.handle_key(_key(KEY_A))
	support.expect_equal(fixture.viewport.records.back().regions.size(), 3, "keyboard add should begin with a transient preview")
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	support.expect_equal(fixture.viewport.records.back(), fixture.store.get_corrected_record(0), "a new pointer press should cancel the keyboard-add preview before starting a fresh gesture")
	_motion(fixture.plugin, Vector2(18, 15), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(18, 15), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 1, "pointer interruption should commit only the fresh pointer gesture")
	support.expect_equal(fixture.store.get_corrected_record(0).regions.size(), 2, "interrupted keyboard add must not leak into the committed record")
	support.expect_equal(fixture.store.get_corrected_record(0).regions[0].box, [13.0, 10.0, 20, 15], "pointer interruption should apply the explicit move")


static func _test_pointer_drag_blocks_command_keys(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"move")
	fixture.selected[0] = "box-1"
	fixture.plugin.handle_key(_key(KEY_RIGHT))
	fixture.plugin.handle_key(_key(KEY_Z, false, true))
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
	support.expect_equal(armed.viewport.records.back(), armed.store.get_corrected_record(0), "Escape should cancel armed add and restore the visible record")

	var resize := _fixture(plugin_script)
	resize.plugin.activate(resize.context)
	resize.plugin.set_active_tool(&"move")
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
	support.expect_equal(add_drag.history.get_undo_count(), 1, "add release should remain one atomic command")


static func _test_pointer_motion_loss_and_repress_cancel(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
	fixture.plugin.set_active_tool(&"move")
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	var lost_motion := InputEventMouseMotion.new()
	lost_motion.position = fixture.viewport.transform.image_to_viewport(Vector2(20, 15))
	lost_motion.button_mask = 0
	fixture.plugin.handle_pointer(lost_motion, Vector2(20, 15))
	support.expect_equal(fixture.viewport.records.back(), fixture.store.get_corrected_record(0), "motion without left button should cancel and restore the real record")
	_pointer(fixture.plugin, false, Vector2(20, 15), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 0, "lost-release cancellation must not commit on a later release")

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
	support.expect_equal(fixture.viewport.records.back(), fixture.store.get_corrected_record(0), "viewport cancellation signal should restore a suspended drag")
	_pointer(fixture.plugin, false, Vector2(19, 15), fixture.viewport)
	support.expect_equal(fixture.history.get_undo_count(), 0, "navigation cancellation should prevent a later stale release commit")


static func _test_cross_frame_restore_and_selection(plugin_script: Script, support: TestSupport) -> void:
	var cancel_fixture := _two_frame_fixture(plugin_script)
	cancel_fixture.plugin.activate(cancel_fixture.context)
	cancel_fixture.plugin.set_active_tool(&"move")
	_pointer(cancel_fixture.plugin, true, Vector2(15, 15), cancel_fixture.viewport)
	_motion(cancel_fixture.plugin, Vector2(18, 15), cancel_fixture.viewport)
	cancel_fixture.frame[0] = 1
	cancel_fixture.selected[0] = "frame-1-box"
	cancel_fixture.plugin.cancel()
	support.expect_equal(cancel_fixture.viewport.records.back(), cancel_fixture.store.get_corrected_record(1), "cross-frame cancel should render the valid current frame")

	var release_fixture := _two_frame_fixture(plugin_script)
	release_fixture.plugin.activate(release_fixture.context)
	release_fixture.plugin.set_active_tool(&"move")
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
	invalid_release.plugin.set_active_tool(&"move")
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
	support.expect_equal(pointer_add.store.get_corrected_record(0).regions.size(), 3, "cross-frame pointer add should apply only to its frozen frame")
	support.expect_equal(pointer_add.viewport.records.back(), pointer_add.store.get_corrected_record(1), "cross-frame pointer add should leave the current frame visible")
	support.expect_equal(pointer_add.selected[0], "frame-1-box", "cross-frame pointer add must not select an ID from the old frame")

	var corrected_selection := _two_frame_fixture(plugin_script)
	corrected_selection.plugin.activate(corrected_selection.context)
	corrected_selection.plugin.begin_add_box()
	_pointer(corrected_selection.plugin, true, Vector2(60, 50), corrected_selection.viewport)
	_motion(corrected_selection.plugin, Vector2(70, 60), corrected_selection.viewport)
	corrected_selection.frame[0] = 1
	corrected_selection.selected[0] = "box-1"
	_pointer(corrected_selection.plugin, false, Vector2(70, 60), corrected_selection.viewport)
	support.expect_equal(corrected_selection.selected[0], "", "cross-frame add should clear a selection that is invalid on the current frame")

	var keyboard_add := _two_frame_fixture(plugin_script)
	keyboard_add.plugin.activate(keyboard_add.context)
	keyboard_add.plugin.handle_key(_key(KEY_A))
	keyboard_add.frame[0] = 1
	keyboard_add.selected[0] = "frame-1-box"
	keyboard_add.plugin.handle_key(_key(KEY_ENTER))
	support.expect_equal(keyboard_add.store.get_corrected_record(0).regions.size(), 3, "cross-frame keyboard add should apply to its frozen frame")
	support.expect_equal(keyboard_add.viewport.records.back(), keyboard_add.store.get_corrected_record(1), "keyboard add Enter should render the current frame")
	support.expect_equal(keyboard_add.selected[0], "frame-1-box", "keyboard add Enter must not select an old-frame ID")


static func _test_reactivation_cancels_and_rewires(plugin_script: Script, support: TestSupport) -> void:
	var old_fixture := _fixture(plugin_script)
	var plugin = old_fixture.plugin
	plugin.activate(old_fixture.context)
	plugin.set_active_tool(&"move")
	_pointer(plugin, true, Vector2(15, 15), old_fixture.viewport)
	_motion(plugin, Vector2(19, 15), old_fixture.viewport)
	var new_fixture := _fixture(plugin_script)
	support.expect(plugin.activate(new_fixture.context).is_empty(), "valid reactivation should succeed after cancelling old preview")
	plugin.set_active_tool(&"move")
	support.expect_equal(old_fixture.viewport.records.back(), old_fixture.store.get_corrected_record(0), "valid reactivation should restore the old viewport before replacing context")
	_pointer(plugin, true, Vector2(15, 15), new_fixture.viewport)
	_motion(plugin, Vector2(18, 15), new_fixture.viewport)
	var new_preview: Dictionary = new_fixture.viewport.records.back()
	old_fixture.viewport.edit_cancel_requested.emit()
	support.expect_equal(new_fixture.viewport.records.back(), new_preview, "old viewport cancellation signal should be disconnected after reactivation")
	new_fixture.viewport.edit_cancel_requested.emit()
	support.expect_equal(new_fixture.viewport.records.back(), new_fixture.store.get_corrected_record(0), "new viewport cancellation signal should cancel the current preview")

	plugin.activate(new_fixture.context)
	plugin.set_active_tool(&"move")
	_pointer(plugin, true, Vector2(15, 15), new_fixture.viewport)
	_motion(plugin, Vector2(19, 15), new_fixture.viewport)
	var invalid_context: Dictionary = new_fixture.context.duplicate()
	invalid_context["history"] = RefCounted.new()
	support.expect(not plugin.activate(invalid_context).is_empty(), "invalid reactivation should be rejected")
	support.expect_equal(new_fixture.viewport.records.back(), new_fixture.store.get_corrected_record(0), "invalid reactivation should still restore the prior preview immediately")
	plugin.handle_key(_key(KEY_ESCAPE))
	support.expect_equal(new_fixture.viewport.records.back(), new_fixture.store.get_corrected_record(0), "Escape after failed reactivation should not be needed to repair ghost preview")


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
		fixture.plugin.set_active_tool(&"move")
		fixture.selected[0] = "box-1"
		_pointer(fixture.plugin, true, Vector2(30, 25), fixture.viewport)
		_pointer(fixture.plugin, false, Vector2(30, 25), fixture.viewport)
		support.expect_equal(fixture.history.get_undo_count(), 0, "numeric-equivalent resize handle click should not enter history for %s" % str(box))
		support.expect(fixture.store.get_dirty_frames().is_empty(), "numeric-equivalent resize handle click should not dirty the frame for %s" % str(box))

	var zero_move := _two_frame_fixture(plugin_script)
	zero_move.plugin.activate(zero_move.context)
	zero_move.plugin.set_active_tool(&"move")
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
	zero_resize.plugin.set_active_tool(&"move")
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


static func _fixture(plugin_script: Script) -> Dictionary:
	var store = STORE_SCRIPT.new()
	store.load_model_records([_record()])
	var history = HISTORY_SCRIPT.new()
	var viewport := ViewportProbe.new()
	var frame := [0]
	var selected := [""]
	var statuses: Array[String] = []
	var context := {
		"store": store,
		"history": history,
		"viewport": viewport,
		"current_frame": func(): return frame[0],
		"selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"status": func(message: String): statuses.append(message),
		"taxonomy": {"classes": [{"id": "unknown", "kind": "region"}]},
	}
	return {"plugin": plugin_script.new(), "store": store, "history": history, "viewport": viewport, "frame": frame, "selected": selected, "statuses": statuses, "context": context}


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
	var context := {
		"store": store,
		"history": history,
		"viewport": viewport,
		"current_frame": func(): return frame[0],
		"selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"status": func(message: String): statuses.append(message),
		"taxonomy": {"classes": [{"id": "unknown", "kind": "region"}]},
	}
	return {"plugin": plugin_script.new(), "store": store, "history": history, "viewport": viewport, "frame": frame, "selected": selected, "statuses": statuses, "context": context}


static func _pointer(plugin, pressed: bool, image_position: Vector2, viewport: ViewportProbe) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = viewport.transform.image_to_viewport(image_position)
	plugin.handle_pointer(event, image_position)


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


static func _contains_error(errors: PackedStringArray, fragment: String) -> bool:
	for error: String in errors:
		if fragment in error:
			return true
	return false


static func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}
