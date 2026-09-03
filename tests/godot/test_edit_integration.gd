extends RefCounted


const VIEWPORT_SCENE := preload("res://client/ui/annotation_viewport.tscn")
const PLUGIN_SCRIPT := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")


func run(support: TestSupport, tree: SceneTree) -> void:
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
	support.expect(plugin.set_active_tool(&"move").is_empty(), "real viewport integration should select Move explicitly")
	viewport.region_selected.connect(func(region_id: String): selected[0] = region_id)
	viewport.image_pointer_event.connect(func(event: InputEvent, image_position: Vector2): plugin.handle_pointer(event, image_position))
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

	var history_before_navigation: int = history.get_undo_count()
	_start_drag(viewport, Vector2(15, 16), Vector2(17, 16))
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = transform.image_to_viewport(Vector2(17, 16))
	viewport.call("_gui_input", wheel)
	_mouse_button(viewport, false, Vector2(17, 16))

	_start_drag(viewport, Vector2(15, 16), Vector2(17, 16))
	var middle := InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	middle.position = transform.image_to_viewport(Vector2(17, 16))
	viewport.call("_gui_input", middle)
	middle.pressed = false
	viewport.call("_gui_input", middle)
	_mouse_button(viewport, false, Vector2(17, 16))

	plugin.begin_add_box()
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	viewport.call("_gui_input", space)
	_mouse_button(viewport, true, Vector2(50, 50))
	_mouse_button(viewport, false, Vector2(50, 50))
	space.pressed = false
	viewport.call("_gui_input", space)

	_start_drag(viewport, Vector2(15, 16), Vector2(17, 16))
	viewport.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_mouse_button(viewport, false, Vector2(17, 16))
	support.expect_equal(history.get_undo_count(), history_before_navigation, "real wheel, middle, Space navigation, and focus loss should not create edit history")
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
	var cancel_callback := Callable(plugin, "cancel")
	support.expect(replacement.is_connected("edit_cancel_requested", cancel_callback), "reactivation should connect cancellation only to the replacement viewport")
	replacement.region_selected.connect(func(region_id: String): selected[0] = region_id)
	replacement.image_pointer_event.connect(func(event: InputEvent, image_position: Vector2): plugin.handle_pointer(event, image_position))
	replacement.call("set_record", store.get_corrected_record(0))
	selected[0] = "box-1"
	plugin.begin_add_box()
	replacement.edit_cancel_requested.emit()
	plugin.set_active_tool(&"move")
	_mouse_button(replacement, true, Vector2(15, 15))
	_mouse_motion(replacement, Vector2(16, 15), MOUSE_BUTTON_MASK_LEFT)
	_mouse_button(replacement, false, Vector2(16, 15))
	support.expect_equal(history.get_undo_count(), history_before_navigation + 1, "replacement viewport should remain the sole live edit surface")
	replacement.queue_free()
	await tree.process_frame


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
		"dataset_id": "real-edit-integration",
		"source": "model_output_v1",
		"frame": 0,
		"image_size": [100, 80],
		"regions": [
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15], "filled": false},
			{"id": "poly-1", "class": "gallbladder", "kind": "anatomy", "polygon": [[40, 40], [55, 40], [45, 55]], "filled": true},
		],
	}
