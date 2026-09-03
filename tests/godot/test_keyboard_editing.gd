extends RefCounted


const PLUGIN_PATH := "res://client/plugins/edit/basic_edit_tools/plugin.gd"
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const TRANSFORM_SCRIPT := preload("res://client/services/viewport_transform.gd")


class ViewportProbe extends RefCounted:
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


static func run(support: TestSupport) -> void:
	var plugin_script: Script = ResourceLoader.load(PLUGIN_PATH)
	support.expect(plugin_script != null, "basic edit-tools plugin should load")
	if plugin_script == null:
		return
	_test_activation_contract(plugin_script, support)
	_test_pointer_selection_and_single_move(plugin_script, support)
	_test_resize_uses_viewport_pixel_handles(plugin_script, support)
	_test_add_cancel_and_invalid_pointer_restore(plugin_script, support)
	_test_keyboard_matrix(plugin_script, support)
	_test_cycle_delete_undo_redo(plugin_script, support)
	_test_keyboard_only_add(plugin_script, support)


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


static func _test_pointer_selection_and_single_move(plugin_script: Script, support: TestSupport) -> void:
	var fixture := _fixture(plugin_script)
	fixture.plugin.activate(fixture.context)
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
		"dataset_id": "edit-tests",
		"source": "model_output_v1",
		"frame": 0,
		"image_size": [100, 80],
		"regions": [
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15], "conf": 0.9, "track_id": "T01", "filled": false},
			{"id": "poly-1", "class": "gallbladder", "kind": "anatomy", "polygon": [[40, 40], [55, 40], [45, 55]], "filled": true},
		],
	}
