extends "res://tests/godot/test_keyboard_reachability.gd"


func _run_tests() -> void:
	_test_clicked_contour_vertices()
	_test_vertex_keyboard_and_history()
	_test_vertex_pointer_and_refusal()
	_test_stale_drag_and_bounds()
	await _test_mounted_vertex_input()
	await _test_mounted_clicked_contour()
	if _failures.is_empty():
		print("PASS: Lasso polygon vertex editing")
		quit(0)
	else:
		push_error("FAIL: Lasso polygon vertex editing\n%s" % "\n".join(_failures))
		quit(1)


func _test_clicked_contour_vertices() -> void:
	var f := _fixture()
	_activate(f, "clicked contour")
	f.plugin.set_active_tool(&"lasso")
	# 非矩形、含凹点的轮廓；P2 共线但仍是用户指定的控制点。
	var clicked := PackedVector2Array([Vector2(10, 10), Vector2(25, 15), Vector2(40, 20), Vector2(60, 10), Vector2(55, 60), Vector2(15, 55)])
	for point in clicked:
		_button(f, point, true)
		_button(f, point, false)
	_expect_equal(_overlay(f).get("vertex_points"), clicked, "drawing exposes exactly the clicked contour points")
	var before: Dictionary = f.store.get_corrected_record(0)
	_button(f, clicked[2], true)
	_motion(f, Vector2(40, 30))
	_button(f, Vector2(40, 30), false)
	clicked[2] = Vector2(40, 30)
	_expect_equal(_overlay(f).get("vertex_points"), clicked, "dragging draft P3 changes only P3, not a bounding corner")
	_expect_equal(f.store.get_corrected_record(0), before, "draft vertex move does not change saved annotations")
	f.plugin.handle_key(_key(KEY_SPACE))
	_expect_equal(f.class_requests.size(), 1, "explicit click contour closes into class dialog")
	if f.class_requests.size() != 1:
		return
	_expect(_confirm_pending_polygon(f, "clicked contour", "region").is_empty(), "clicked contour saves")
	var saved: Dictionary = f.store.get_corrected_record(0).regions[-1]
	_expect_equal(saved.polygon, [[10.0,10.0],[25.0,15.0],[40.0,30.0],[60.0,10.0],[55.0,60.0],[15.0,55.0]], "saved polygon preserves clicked point order and positions")
	_expect_equal(_overlay(f).get("vertex_points"), clicked, "after confirmation the same contour points remain draggable")
	_button(f, Vector2(40, 30), true)
	_motion(f, Vector2(40, 35))
	_button(f, Vector2(40, 35), false)
	_expect_equal(f.store.get_corrected_record(0).regions[-1].polygon[2], [40.0,35.0], "saved P3 drags immediately without reselecting Lasso")
	_expect_equal(f.history.get_undo_count(), 2, "creation and later vertex drag are separate commands")
	var collinear := _fixture()
	_activate(collinear, "explicit collinear anchor")
	collinear.plugin.set_active_tool(&"lasso")
	for point in [Vector2(10,10), Vector2(25,15), Vector2(40,20), Vector2(60,10), Vector2(55,60), Vector2(15,55)]:
		_button(collinear, point, true)
		_button(collinear, point, false)
	collinear.plugin.handle_key(_key(KEY_SPACE))
	_expect(_confirm_pending_polygon(collinear, "collinear control point", "region").is_empty(), "collinear point contour saves")
	_expect_equal(collinear.store.get_corrected_record(0).regions[-1].polygon.size(), 6, "simplification cannot discard a user's collinear control point")


func _vertex_fixture() -> Dictionary:
	var f := _fixture()
	var record: Dictionary = f.store.get_corrected_record(0)
	record.regions[1].polygon = [[40, 20], [80, 20], [80, 60], [40, 60]]
	_expect(f.store.replace_corrected_record(0, record).is_empty(), "vertex fixture validates")
	_activate(f, "vertex editing")
	f.selected[0] = "notch-1"
	f.plugin.handle_key(_key(KEY_L))
	return f


func _points(f: Dictionary) -> Array:
	return f.store.get_corrected_record(0).regions[1].polygon


func _test_vertex_keyboard_and_history() -> void:
	var f := _vertex_fixture()
	var before: Dictionary = f.store.get_corrected_record(0)
	_expect_equal(_overlay(f).get("vertex_points", PackedVector2Array()).size(), 4, "L displays saved polygon vertices")
	_expect(not f.plugin.get_edit_state().gesture_active, "idle handles must not block relabel or history")
	f.plugin.handle_key(_key(KEY_RIGHT))
	f.plugin.handle_key(_key(KEY_DOWN, true))
	f.plugin.handle_key(_key(KEY_RIGHT, true, true))
	_expect_equal(_points(f)[0], [51.0, 25.0], "arrows nudge only active vertex by 1/5/10 image px")
	_expect_equal(_points(f)[1], [80.0, 20.0], "other vertices unchanged")
	_expect_equal(f.history.get_undo_count(), 3, "each keyboard edit is undoable")
	f.plugin.handle_key(_key(KEY_BRACKETRIGHT))
	f.plugin.handle_key(_key(KEY_INSERT))
	_expect_equal(_points(f).size(), 5, "Insert adds a vertex after the active vertex")
	if _points(f).size() == 5:
		_expect_equal(_points(f)[2], [80.0, 40.0], "insert uses next-edge midpoint")
	f.plugin.handle_key(_key(KEY_DELETE))
	_expect_equal(_points(f).size(), 4, "Delete removes the active vertex, not the region")
	var after: Dictionary = f.store.get_corrected_record(0)
	for _i in range(5):
		_expect(f.history.undo(f.store), "vertex undo succeeds")
	_expect_equal(f.store.get_corrected_record(0), before, "all vertex edits restore full original record")
	for _i in range(5):
		_expect(f.history.redo(f.store).is_empty(), "vertex redo succeeds")
	_expect_equal(f.store.get_corrected_record(0), after, "redo restores full record including metadata")
	_expect(not f.plugin.handle_key(_key(KEY_TAB)), "vertex mode allows standard focus traversal")
	f.plugin.handle_key(_key(KEY_ESCAPE))
	_expect_equal(f.selected[0], "", "Escape exits vertex editing and clears selection")
	f.plugin.handle_key(_key(KEY_L))
	_expect_equal(f.plugin.get("_keyboard_tool"), &"lasso", "L without selection still creates polygons")


func _button(f: Dictionary, point: Vector2, pressed: bool, double_click := false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.double_click = double_click
	f.plugin.handle_pointer(event, point)


func _motion(f: Dictionary, point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	f.plugin.handle_pointer(event, point)


func _test_vertex_pointer_and_refusal() -> void:
	var f := _vertex_fixture()
	var before: Dictionary = f.store.get_corrected_record(0)
	f.viewport.transform.zoom_at(Vector2(100, 80), 2.0)
	_button(f, Vector2(41.5, 20), true)
	_button(f, Vector2(41.5, 20), false)
	_expect_equal(f.store.get_corrected_record(0), before, "clicking within handle tolerance must not move vertex")
	_expect_equal(f.history.get_undo_count(), 0, "handle selection alone has no history")
	# Six viewport pixels from vertex zero must still hit after zoom.
	_button(f, Vector2(41.5, 20), true)
	_expect(f.plugin.get_edit_state().gesture_active, "pressed vertex owns gesture before motion")
	_motion(f, Vector2(45, 25))
	_expect_equal(f.store.get_corrected_record(0), before, "vertex drag previews without writing Store")
	_button(f, Vector2(45, 25), false)
	_expect_equal(_points(f)[0], [45.0, 25.0], "zoomed vertex drag commits image coordinates")
	_expect_equal(f.history.get_undo_count(), 1, "one drag is one command")
	_button(f, Vector2(80, 40), true, true)
	_button(f, Vector2(80, 40), false)
	_expect_equal(_points(f).size(), 5, "double-click edge inserts vertex")
	_expect_equal(f.history.get_undo_count(), 2, "double-click release does not duplicate insertion")
	var valid: Dictionary = f.store.get_corrected_record(0)
	_button(f, Vector2(45, 25), true)
	_motion(f, Vector2(90, 40))
	_button(f, Vector2(90, 40), false)
	_expect_equal(f.store.get_corrected_record(0), valid, "self-intersection refuses entire edit")
	_expect_equal(f.history.get_undo_count(), 2, "invalid drag adds no history")
	_expect(not f.statuses.is_empty() and "vertex" in f.statuses[-1].to_lower(), "invalid vertex edit explains refusal")
	_button(f, Vector2(45, 25), true)
	_motion(f, Vector2(46, 26))
	f.plugin.handle_key(_key(KEY_ESCAPE))
	_button(f, Vector2(46, 26), false)
	_expect_equal(f.store.get_corrected_record(0), valid, "Escape discards drag")
	var triangle := _vertex_fixture()
	triangle.plugin.handle_key(_key(KEY_DELETE))
	_expect_equal(_points(triangle).size(), 3, "quadrilateral can become triangle")
	var three: Dictionary = triangle.store.get_corrected_record(0)
	triangle.plugin.handle_key(_key(KEY_DELETE))
	_expect_equal(triangle.store.get_corrected_record(0), three, "triangle cannot lose another vertex")
	_expect_equal(triangle.history.get_undo_count(), 1, "minimum-vertex refusal preserves history")


func _test_stale_drag_and_bounds() -> void:
	var f := _vertex_fixture()
	_button(f, Vector2(40, 20), true)
	var updated: Dictionary = f.store.get_corrected_record(0)
	updated.regions[0]["class"] = "external update"
	_expect(f.store.replace_corrected_record(0, updated).is_empty(), "concurrent update is valid")
	_button(f, Vector2(42, 22), false)
	_expect_equal(f.store.get_corrected_record(0), updated, "stale drag cannot overwrite another edit")
	_expect_equal(f.history.get_undo_count(), 0, "stale drag has no command")
	f.plugin.handle_key(_key(KEY_L))
	_button(f, Vector2(40, 20), true)
	_button(f, Vector2(-1, 20), false)
	_expect_equal(f.store.get_corrected_record(0), updated, "out-of-bounds vertex refuses mutation")
	_button(f, Vector2(40, 20), true)
	f.frame[0] = 1
	_button(f, Vector2(42, 22), false)
	_expect_equal(f.store.get_corrected_record(0), updated, "drag cannot write after frame changes")


func _test_mounted_vertex_input() -> void:
	var support := TestSupport.new()
	var harness = load("res://tests/godot/edit_test_harness.gd").new()
	if not await harness.mount(support, self):
		_failures.append_array(support.failures)
		return
	var record: Dictionary = harness.store.get_corrected_record(0)
	record.regions[2].polygon = [[20, 70], [60, 70], [60, 100], [20, 100]]
	_expect(harness.store.replace_corrected_record(0, record).is_empty(), "mounted vertex fixture validates")
	harness.main.call("_refresh_current_annotations")
	await harness.pointer_click(Vector2(30, 85))
	await harness.press_key(KEY_L)
	_expect_equal(harness.viewport.get_edit_overlay_state().get("vertex_points", []).size(), 4, "real click and L show vertex handles")
	await harness.press_key(KEY_Z, false, true)
	_expect_equal(harness.viewport.get_edit_overlay_state().get("vertex_points", []).size(), 4, "empty undo keeps vertex editing reachable")
	await harness.press_key(KEY_Y, false, true)
	_expect_equal(harness.viewport.get_edit_overlay_state().get("vertex_points", []).size(), 4, "empty redo keeps vertex editing reachable")
	await harness.press_key(KEY_RIGHT, true, true)
	_expect_equal(harness.store.get_corrected_record(0).regions[2].polygon[0], [30.0, 70.0], "real Ctrl+Shift+Arrow moves active vertex by ten")
	await harness.press_key(KEY_Z, false, true)
	_expect_equal(harness.store.get_corrected_record(0), record, "real global undo restores polygon")
	_expect_equal(harness.viewport.get_edit_overlay_state().get("vertex_points", [])[0], Vector2(20, 70), "undo refreshes vertex overlay")
	await harness.press_key(KEY_Y, false, true)
	await harness.press_key(KEY_BRACKETRIGHT)
	await harness.press_key(KEY_INSERT)
	_expect_equal(harness.store.get_corrected_record(0).regions[2].polygon.size(), 5, "real Insert adds saved polygon vertex")
	await harness.press_key(KEY_DELETE)
	_expect_equal(harness.store.get_corrected_record(0).regions.size(), 3, "real Delete in Lasso never deletes entire region")
	var transform = harness.viewport.get_image_transform()
	transform.zoom_at(transform.image_to_viewport(Vector2(40, 85)), 1.5)
	harness.viewport.notify_transform_changed()
	var drag_points: Array[Vector2] = [Vector2(30, 70), Vector2(32, 72)]
	await harness.pointer_drag(drag_points)
	_expect_equal(harness.store.get_corrected_record(0).regions[2].polygon[0], [32.0, 72.0], "real zoomed pointer moves vertex")
	await harness.pointer_click(Vector2(60, 85), true)
	_expect_equal(harness.store.get_corrected_record(0).regions[2].polygon.size(), 5, "real double-click inserts on edge")
	await harness.press_key(KEY_R)
	_expect(harness.class_dialog.visible, "idle vertex handles permit R relabel")
	await harness.press_key(KEY_ESCAPE)
	await harness.focus_viewport()
	await harness.press_key(KEY_ESCAPE)
	_expect_equal(harness.main.get("_selected_region_id"), "", "real Escape clears vertex selection")
	await harness.pointer_click(Vector2(40, 85))
	# A toolbar switch must enter the same vertex mode as the keyboard.
	harness.main.call("_set_selected_region", "poly-1")
	await harness.click_tool(&"select")
	await harness.click_tool(&"lasso")
	_expect_equal(harness.viewport.get_edit_overlay_state().get("vertex_points", []).size(), 5, "toolbar Lasso shows selected polygon vertices")
	if "--screenshot" in OS.get_cmdline_user_args():
		await process_frame
		await RenderingServer.frame_post_draw
		_expect_equal(root.get_texture().get_image().save_png("/tmp/project6-lasso-vertices.png"), OK, "vertex screenshot saves")
	await harness.finish()
	_failures.append_array(support.failures)


func _test_mounted_clicked_contour() -> void:
	var support := TestSupport.new()
	var h = load("res://tests/godot/edit_test_harness.gd").new()
	if not await h.mount(support, self):
		_failures.append_array(support.failures)
		return
	var record: Dictionary = h.store.get_corrected_record(0)
	record.regions = []
	_expect(h.store.replace_corrected_record(0, record).is_empty(), "blank mounted source validates")
	h.main.call("_refresh_current_annotations")
	await h.click_tool(&"lasso")
	var points := PackedVector2Array([Vector2(20,25), Vector2(70,30), Vector2(60,65), Vector2(100,40), Vector2(130,95), Vector2(30,105)])
	for point in points:
		await h.pointer_click(point)
	_expect_equal(h.overlay().get("vertex_points"), points, "real individual clicks expose the six original contour vertices")
	var drag: Array[Vector2] = [Vector2(60,65), Vector2(55,70)]
	await h.pointer_drag(drag)
	points[2] = Vector2(55,70)
	_expect_equal(h.overlay().get("vertex_points"), points, "real draft drag moves inward P3 only")
	await h.press_key(KEY_SPACE)
	_expect(h.class_dialog.visible, "Space closes clicked polygon for classification")
	await h.confirm_class("contour", "region")
	_expect_equal(h.overlay().get("vertex_points"), points, "confirmed contour immediately keeps P1 to P6 handles")
	var descriptions: Array = h.viewport.get("_renderer").get_overlay_descriptions()
	_expect_equal(descriptions.size(), 1, "actual filled polygon and label remain visible in Lasso")
	if descriptions.size() == 1:
		_expect_equal(descriptions[0].handles.size(), 0, "Lasso never shows external bounding-box handles")
		_expect(descriptions[0].fill, "class fill remains visible beneath contour points")
	drag = [Vector2(55,70), Vector2(60,72)]
	await h.pointer_drag(drag)
	points[2] = Vector2(60,72)
	_expect_equal(h.overlay().get("vertex_points"), points, "same P3 remains draggable immediately after class confirmation")
	_expect_equal(h.store.get_corrected_record(0).regions[0].polygon, [[20.0,25.0],[70.0,30.0],[60.0,72.0],[100.0,40.0],[130.0,95.0],[30.0,105.0]], "saved concave geometry follows only the clicked points")
	_expect_equal(h.history.get_undo_count(), 2, "one create and one saved-vertex drag")
	if "--screenshot" in OS.get_cmdline_user_args():
		await process_frame
		await RenderingServer.frame_post_draw
		_expect_equal(root.get_texture().get_image().save_png("/tmp/project6-lasso-contour-points.png"), OK, "clicked concave contour screenshot saves")
	await h.click_tool(&"select")
	descriptions = h.viewport.get("_renderer").get_overlay_descriptions()
	if descriptions.size() == 1:
		_expect_equal(descriptions[0].handles.size(), 8, "Selection still supports whole-polygon bounding resize")
	await h.finish()
	_failures.append_array(support.failures)
