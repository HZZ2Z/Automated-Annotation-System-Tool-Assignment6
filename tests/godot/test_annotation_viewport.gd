extends RefCounted

const VIEWPORT_SCENE = preload("res://client/ui/annotation_viewport.tscn")


func run(support, tree: SceneTree) -> void:
	await _test_scene_and_dirty_redraws(support, tree)
	await _test_clearing_image_state_invalidates_transform(support, tree)
	await _test_transformed_selection_and_pointer_signal(support, tree)
	await _test_wheel_and_pan_controls(support, tree)


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
