extends RefCounted

const VIEWPORT_SCENE = preload("res://client/ui/annotation_viewport.tscn")


func run(support, tree: SceneTree) -> void:
	await _test_scene_and_dirty_redraws(support, tree)
	await _test_set_record_uses_snapshots(support, tree)
	await _test_set_state_uses_snapshots(support, tree)
	await _test_clearing_image_state_invalidates_transform(support, tree)
	await _test_resize_preserves_user_view(support, tree)
	await _test_transformed_selection_and_pointer_signal(support, tree)
	await _test_edit_pointer_boundary_and_order(support, tree)
	await _test_wheel_and_pan_controls(support, tree)
	await _test_focus_out_clears_space_pan_state(support, tree)
	await _test_space_pan_survives_focused_text_input(support, tree)


func _test_scene_and_dirty_redraws(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	support.expect(viewport != null, "annotation viewport scene should instantiate as a Control")
	if viewport == null:
		return
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	var draws := [0]
	viewport.draw.connect(func(): draws[0] += 1)
	tree.root.add_child(viewport)
	await tree.process_frame
	draws[0] = 0

	var record := _record()
	viewport.call("set_record", record)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "record change should queue one redraw")
	viewport.call("set_record", record)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "setting the same record should not queue another redraw")

	viewport.call("set_selected_region_id", "box")
	await tree.process_frame
	support.expect_equal(draws[0], 2, "selection change should queue a redraw")
	viewport.call("set_selected_region_id", "box")
	await tree.process_frame
	support.expect_equal(draws[0], 2, "setting the same selection should not queue another redraw")

	viewport.call("set_overlay_opacity", 0.7)
	await tree.process_frame
	support.expect_equal(draws[0], 3, "opacity change should queue a redraw")
	viewport.call("set_overlay_opacity", 0.7)
	await tree.process_frame
	support.expect_equal(draws[0], 3, "setting the same opacity should not queue another redraw")

	var image := Image.create(200, 120, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_SLATE_GRAY)
	var texture := ImageTexture.create_from_image(image)
	viewport.call("set_texture", texture)
	await tree.process_frame
	support.expect_equal(draws[0], 4, "texture change should queue a redraw")
	viewport.call("set_texture", texture)
	await tree.process_frame
	support.expect_equal(draws[0], 4, "setting the same texture should not queue another redraw")
	viewport.call("notify_transform_changed")
	await tree.process_frame
	support.expect_equal(draws[0], 4, "an unchanged transform notification should not queue another redraw")
	var transform = viewport.call("get_image_transform")
	transform.pan_by(Vector2(1, 0))
	viewport.call("notify_transform_changed")
	await tree.process_frame
	support.expect_equal(draws[0], 5, "an actual transform change should queue a redraw")
	viewport.queue_free()
	await tree.process_frame


func _test_set_record_uses_snapshots(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	var caller_record := _record()
	viewport.call("set_record", caller_record)
	await tree.process_frame
	var draws := [0]
	viewport.draw.connect(func(): draws[0] += 1)
	var selected_ids: Array[String] = []
	viewport.connect("region_selected", func(region_id: String): selected_ids.append(region_id))

	caller_record["regions"][0]["id"] = "moved"
	caller_record["regions"][0]["box"] = [100, 10, 40, 40]
	_click(viewport, Vector2(25, 25))
	_click(viewport, Vector2(115, 25))
	support.expect_equal(selected_ids, ["box"], "set_record should isolate viewport picking from later caller mutation")
	support.expect_equal(draws[0], 0, "caller mutation alone should not queue viewport redraw")

	selected_ids.clear()
	viewport.call("set_record", caller_record)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "explicitly setting a modified caller snapshot should queue exactly one redraw")
	_click(viewport, Vector2(25, 25))
	_click(viewport, Vector2(115, 25))
	support.expect_equal(selected_ids, ["moved"], "explicitly setting a modified caller snapshot should update viewport picking")
	viewport.call("set_record", caller_record)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "reapplying an equal record snapshot should not redraw")
	viewport.queue_free()
	await tree.process_frame


func _test_set_state_uses_snapshots(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	var caller_record := _record()
	viewport.call("set_state", null, caller_record, "", 0.35)
	await tree.process_frame
	var draws := [0]
	viewport.draw.connect(func(): draws[0] += 1)
	var selected_ids: Array[String] = []
	viewport.connect("region_selected", func(region_id: String): selected_ids.append(region_id))

	caller_record["regions"][0]["id"] = "state-moved"
	caller_record["regions"][0]["box"] = [100, 10, 40, 40]
	_click(viewport, Vector2(25, 25))
	_click(viewport, Vector2(115, 25))
	support.expect_equal(selected_ids, ["box"], "set_state should isolate viewport picking from later caller mutation")
	viewport.call("set_state", null, caller_record, "", 0.35)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "explicitly setting modified combined state should queue exactly one redraw")
	selected_ids.clear()
	_click(viewport, Vector2(25, 25))
	_click(viewport, Vector2(115, 25))
	support.expect_equal(selected_ids, ["state-moved"], "explicitly setting modified combined state should update viewport picking")
	viewport.call("set_state", null, caller_record, "", 0.35)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "reapplying equal combined state should not redraw")
	viewport.queue_free()
	await tree.process_frame


func _test_clearing_image_state_invalidates_transform(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	support.expect(transform.is_configured(), "record image dimensions should configure the viewport transform")
	viewport.call("set_record", {})
	support.expect(not transform.is_configured(), "clearing the only image dimensions should invalidate stale coordinate mapping")
	support.expect_equal(transform.viewport_to_image(Vector2(50, 50)), Vector2.ZERO, "cleared viewport should use the transform safe sentinel")
	viewport.queue_free()
	await tree.process_frame


func _test_resize_preserves_user_view(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	transform.zoom_at(transform.image_to_viewport(Vector2.ZERO), 1.8)
	transform.pan_by(Vector2(23, -11))
	viewport.call("notify_transform_changed")
	viewport.size = Vector2(900, 650)
	await tree.process_frame
	support.expect(absf(transform.user_zoom - 1.8) < 0.000001, "valid viewport resize should preserve user zoom")
	support.expect_equal(transform.pan, Vector2(23, -11), "valid viewport resize should preserve pan")
	support.expect_equal(transform.viewport_rect, Rect2(Vector2.ZERO, Vector2(900, 650)), "valid viewport resize should configure the new local rect")
	viewport.queue_free()
	await tree.process_frame


func _test_transformed_selection_and_pointer_signal(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	transform.zoom_at(Vector2(300, 240), 1.8)
	transform.pan_by(Vector2(37, -19))
	viewport.call("notify_transform_changed")
	var selected_ids: Array[String] = []
	var pointer_positions: Array[Vector2] = []
	viewport.connect("region_selected", func(region_id: String): selected_ids.append(region_id))
	viewport.connect("image_pointer_event", func(_event: InputEvent, image_position: Vector2): pointer_positions.append(image_position))
	var image_point := Vector2(25, 25)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = transform.image_to_viewport(image_point)
	viewport.call("_gui_input", click)
	support.expect_equal(selected_ids, ["box"], "selection should use the same transformed coordinates as drawing")
	support.expect(pointer_positions.size() == 1 and pointer_positions[0].distance_to(image_point) < 0.00001, "pointer signal should expose image coordinates")
	viewport.queue_free()
	await tree.process_frame


func _test_edit_pointer_boundary_and_order(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var events: Array[String] = []
	var cancellation_count := [0]
	viewport.region_selected.connect(func(_id: String): events.append("selection"))
	viewport.image_pointer_event.connect(func(_event: InputEvent, _point: Vector2): events.append("pointer"))
	viewport.connect("edit_cancel_requested", func(): cancellation_count[0] += 1)
	_click(viewport, Vector2(25, 25))
	support.expect_equal(events, ["selection", "pointer"], "ordinary left press should publish selection before the edit pointer event")

	events.clear()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = Vector2(25, 25)
	viewport.call("_gui_input", wheel)
	var middle := InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	middle.position = Vector2(25, 25)
	viewport.call("_gui_input", middle)
	var pan_motion := InputEventMouseMotion.new()
	pan_motion.position = Vector2(30, 30)
	pan_motion.relative = Vector2(5, 5)
	pan_motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	viewport.call("_gui_input", pan_motion)
	middle.pressed = false
	viewport.call("_gui_input", middle)
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	viewport.call("_gui_input", space)
	var left := InputEventMouseButton.new()
	left.button_index = MOUSE_BUTTON_LEFT
	left.pressed = true
	left.position = Vector2(25, 25)
	viewport.call("_gui_input", left)
	var space_pan := InputEventMouseMotion.new()
	space_pan.position = Vector2(33, 28)
	space_pan.relative = Vector2(8, 3)
	space_pan.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.call("_gui_input", space_pan)
	left.pressed = false
	viewport.call("_gui_input", left)
	support.expect(events.is_empty(), "wheel, middle pan, and Space-left pan events must not reach edit tools")
	space.pressed = false
	viewport.call("_gui_input", space)
	viewport.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	support.expect_equal(cancellation_count[0], 4, "wheel, middle pan, Space-left pan, and focus loss should request transient edit cancellation")
	viewport.queue_free()
	await tree.process_frame


func _test_wheel_and_pan_controls(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	var transform_signal_count := [0]
	viewport.connect("transform_changed", func(): transform_signal_count[0] += 1)

	var cursor := Vector2(211, 177)
	var anchored_image_point: Vector2 = transform.viewport_to_image(cursor)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = cursor
	viewport.call("_gui_input", wheel)
	support.expect(transform.user_zoom > 1.0, "mouse wheel should zoom")
	support.expect(transform.image_to_viewport(anchored_image_point).distance_to(cursor) < 0.00001, "wheel zoom should stay anchored beneath the cursor")

	var middle_down := InputEventMouseButton.new()
	middle_down.button_index = MOUSE_BUTTON_MIDDLE
	middle_down.pressed = true
	middle_down.position = Vector2(100, 100)
	viewport.call("_gui_input", middle_down)
	var pan_before: Vector2 = transform.pan
	var middle_drag := InputEventMouseMotion.new()
	middle_drag.position = Vector2(112, 93)
	middle_drag.relative = Vector2(12, -7)
	viewport.call("_gui_input", middle_drag)
	support.expect_equal(transform.pan, pan_before + Vector2(12, -7), "middle-button drag should pan by local mouse delta")
	var middle_up := InputEventMouseButton.new()
	middle_up.button_index = MOUSE_BUTTON_MIDDLE
	middle_up.pressed = false
	viewport.call("_gui_input", middle_up)

	var space_down := InputEventKey.new()
	space_down.keycode = KEY_SPACE
	space_down.pressed = true
	viewport.call("_gui_input", space_down)
	var left_down := InputEventMouseButton.new()
	left_down.button_index = MOUSE_BUTTON_LEFT
	left_down.pressed = true
	viewport.call("_gui_input", left_down)
	pan_before = transform.pan
	var space_drag := InputEventMouseMotion.new()
	space_drag.position = Vector2(120, 105)
	space_drag.relative = Vector2(8, 5)
	viewport.call("_gui_input", space_drag)
	support.expect_equal(transform.pan, pan_before + Vector2(8, 5), "Space plus left drag should pan")
	support.expect(transform_signal_count[0] >= 3, "zoom and both pan gestures should emit transform changes")
	viewport.queue_free()
	await tree.process_frame


func _test_focus_out_clears_space_pan_state(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	await tree.process_frame
	var transform = viewport.call("get_image_transform")
	var transform_signal_count := [0]
	var redraw_count := [0]
	viewport.connect("transform_changed", func(): transform_signal_count[0] += 1)
	viewport.draw.connect(func(): redraw_count[0] += 1)

	var space_down := InputEventKey.new()
	space_down.keycode = KEY_SPACE
	space_down.pressed = true
	Input.parse_input_event(space_down)
	await tree.process_frame
	var left_down := InputEventMouseButton.new()
	left_down.button_index = MOUSE_BUTTON_LEFT
	left_down.pressed = true
	left_down.position = Vector2(100, 100)
	viewport.call("_gui_input", left_down)

	viewport.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	var pan_before: Vector2 = transform.pan
	viewport.call("_gui_input", left_down)
	var ordinary_drag := InputEventMouseMotion.new()
	ordinary_drag.position = Vector2(109, 104)
	ordinary_drag.relative = Vector2(9, 4)
	ordinary_drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.call("_gui_input", ordinary_drag)
	support.expect_equal(transform.pan, pan_before, "window focus loss should clear Space and active pan before an ordinary left drag")
	support.expect_equal(transform_signal_count[0], 0, "focus loss without a transform change should not emit transform_changed")
	await tree.process_frame
	support.expect_equal(redraw_count[0], 0, "focus loss without a transform change should not queue redraw")

	var left_up := InputEventMouseButton.new()
	left_up.button_index = MOUSE_BUTTON_LEFT
	left_up.pressed = false
	viewport.call("_gui_input", left_up)
	var space_up := InputEventKey.new()
	space_up.keycode = KEY_SPACE
	space_up.pressed = false
	Input.parse_input_event(space_up)
	await tree.process_frame
	viewport.queue_free()
	await tree.process_frame


func _test_space_pan_survives_focused_text_input(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var line_edit := LineEdit.new()
	line_edit.position = Vector2(900, 20)
	line_edit.size = Vector2(200, 40)
	tree.root.add_child(line_edit)
	line_edit.grab_focus()
	await tree.process_frame
	support.expect(line_edit.has_focus(), "text input should own keyboard focus before the Space event")

	var space_down := InputEventKey.new()
	space_down.keycode = KEY_SPACE
	space_down.unicode = 32
	space_down.pressed = true
	Input.parse_input_event(space_down)
	await tree.process_frame
	support.expect_equal(line_edit.text, " ", "pre-GUI Space tracking must not prevent the focused LineEdit from consuming the event")
	support.expect(line_edit.has_focus(), "focused LineEdit should retain focus after consuming Space")

	var transform = viewport.call("get_image_transform")
	var pan_before: Vector2 = transform.pan
	var left_down := InputEventMouseButton.new()
	left_down.button_index = MOUSE_BUTTON_LEFT
	left_down.pressed = true
	left_down.position = Vector2(100, 100)
	left_down.global_position = left_down.position
	viewport.call("_gui_input", left_down)
	var drag := InputEventMouseMotion.new()
	drag.position = Vector2(114, 91)
	drag.global_position = drag.position
	drag.relative = Vector2(14, -9)
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.call("_gui_input", drag)
	support.expect_equal(transform.pan, pan_before + Vector2(14, -9), "Space consumed by a focused LineEdit should still enable subsequent left-button pan")

	var left_up := InputEventMouseButton.new()
	left_up.button_index = MOUSE_BUTTON_LEFT
	left_up.pressed = false
	left_up.position = drag.position
	left_up.global_position = drag.position
	viewport.call("_gui_input", left_up)
	var space_up := InputEventKey.new()
	space_up.keycode = KEY_SPACE
	space_up.unicode = 32
	space_up.pressed = false
	Input.parse_input_event(space_up)
	await tree.process_frame
	pan_before = transform.pan
	viewport.call("_gui_input", left_down)
	viewport.call("_gui_input", drag)
	support.expect_equal(transform.pan, pan_before, "normal Space release should clear the modifier before an ordinary left drag")
	viewport.call("_gui_input", left_up)
	line_edit.release_focus()
	line_edit.queue_free()
	viewport.queue_free()
	await tree.process_frame


func _record() -> Dictionary:
	return {
		"schema_version": 1,
		"dataset_id": "viewport-test",
		"source": "model_output_v1",
		"frame": 0,
		"image_size": [200, 120],
		"regions": [{
			"id": "box",
			"class": "grasper",
			"kind": "instrument",
			"box": [10, 10, 40, 40],
		}],
	}


func _mounted_viewport(tree: SceneTree) -> Control:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	await tree.process_frame
	return viewport


func _click(viewport: Control, image_position: Vector2) -> void:
	var transform = viewport.call("get_image_transform")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = transform.image_to_viewport(image_position)
	viewport.call("_gui_input", click)
