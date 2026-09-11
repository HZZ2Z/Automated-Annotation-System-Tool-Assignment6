extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const HARNESS := preload("res://tests/godot/edit_test_harness.gd")

var support = SUPPORT.new()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var h = await _mount()
	if h != null:
		var button := h.tool_panel.get_node_or_null("ToolGrid/Match") as Button
		support.expect(button != null, "the real toolbar must expose the Match tool")
		if button != null:
			support.expect_equal(button.get_index(), 7, "Match occupies the eighth existing grid slot")
			await _test_cycle(h)
		await h.finish()
	if support.failures.is_empty():
		await _test_smallest_hit()
		await _test_gap_under_transforms()
		await _test_cancellation_and_staleness()
		await _test_persistence()
	if support.failures.is_empty():
		print("PASS: Match real toolbar, pointer lifecycle and persistence")
		quit(0)
	else:
		push_error(support.failure_report())
		quit(1)


func _mount():
	var h = HARNESS.new()
	if not await h.mount(support, self):
		await h.finish()
		return null
	return h


func _test_cycle(h) -> void:
	var before: Dictionary = h.record()
	var other: Dictionary = h.record(1)
	await h.click_tool(&"match_region")
	support.expect_equal(h.edit_plugin.get_active_tool(), &"match_region", "toolbar click activates Match")
	support.expect(_status(h).contains("待修正"), "activation shows the first-click instruction")
	h.pointer_click(Vector2(30, 30))
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"awaiting_reference", "first click waits for B")
	support.expect_equal(h.record(), before, "first click is entirely transient")
	support.expect_equal(h.undo_count(), 0, "first click consumes no history")
	var layers: Array = h.overlay().get("region_highlights", [])
	support.expect_equal(layers.size(), 1, "A has a visible contour highlight")
	if not layers.is_empty():
		support.expect_equal(layers[0].region_id, "box-1", "the source highlight identifies the clicked region")
		support.expect_equal(layers[0].color, Color("#f59e0b"), "the pending source uses orange")
	h.pointer_hover(Vector2(30, 75))
	var transform = h.viewport.get_image_transform()
	transform.pan_by(Vector2(30, 20))
	h.viewport.notify_transform_changed()
	support.expect_equal(h.overlay().get("region_highlights", []).size(), 1, "pan invalidates the old B hover without cancelling A")
	transform.pan_by(Vector2(-30, -20))
	h.viewport.notify_transform_changed()
	h.pointer_hover(Vector2(30, 75))
	layers = h.overlay().get("region_highlights", [])
	support.expect_equal(layers.size(), 2, "hovering B keeps A and adds the reference highlight")
	if layers.size() == 2:
		support.expect_equal(layers[1].region_id, "poly-1", "the hovered reference is the actual hit")
		support.expect_equal(layers[1].color, Color("#22d3ee"), "the reference uses cyan")
		support.expect(String(layers[1].label).contains("gallbladder") and String(layers[1].label).contains("anatomy"),
			"hover shows both reference labels")
	support.expect_equal(h.record(), before, "hover cannot relabel or merge")
	h.viewport.mouse_exited.emit()
	support.expect_equal(h.overlay().get("region_highlights", []).size(), 1, "leaving the viewport clears B but retains A")
	h.pointer_hover(Vector2(-5, -5))
	support.expect_equal(h.overlay().get("region_highlights", []).size(), 1, "image margins cannot retain B")
	h.pointer_hover(Vector2(30, 75))
	h.pointer_click(Vector2(30, 30))
	h.pointer_click(Vector2(145, 110))
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"awaiting_reference", "A again and blank clicks retain the pending source")
	support.expect_equal(h.undo_count(), 0, "invalid reference clicks do not create history")
	# 双击标记会改变旧 Main 的提交事件判断；这个释放仍必须刷新和保存。
	h.pointer_click(Vector2(30, 75), true)
	var expected := before.duplicate(true)
	expected.regions[0]["class"] = "gallbladder"
	expected.regions[0].kind = "anatomy"
	support.expect_equal(h.record(), expected, "second click copies both labels and preserves all other fields")
	support.expect_equal(h.record(1), other, "pointer editing is scoped to the current original frame")
	support.expect_equal(h.undo_count(), 1, "one correction creates one history entry")
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"idle", "completion returns to the first-click phase")
	support.expect_equal(h.edit_plugin.get_active_tool(), &"match_region", "completion keeps Match active")
	support.expect(_status(h).contains("未合并"), "the specific fallback message survives Main's Modified refresh")
	var row := h._sidebar_item("box-1") as TreeItem
	support.expect(row != null and (row.get_text(0).contains("gallbladder") or row.get_text(1).contains("gallbladder")),
		"the mounted annotation list refreshes after the reference release")
	await h.press_key(KEY_Z, false, true)
	support.expect_equal(h.record(), before, "real undo shortcut restores both labels in one step")
	await h.press_key(KEY_Y, false, true)
	support.expect_equal(h.record(), expected, "real redo restores the correction")
	h.pointer_click(Vector2(100, 35))
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"awaiting_reference", "a new two-click round can start immediately")
	await h.press_key(KEY_ESCAPE)
	support.expect_equal(h.edit_plugin.get_active_tool(), &"match_region", "Escape keeps Match active")
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"idle", "Escape drops A")
	support.expect(h.overlay().get("region_highlights", []).is_empty(), "Escape removes transient highlights")


func _test_smallest_hit() -> void:
	var h = await _mount()
	if h == null:
		return
	await h.click_tool(&"match_region")
	_install(h, [
		{"id": "tiny", "class": "grasper", "kind": "instrument", "box": [25, 25, 4, 4]},
		{"id": "large", "class": "gallbladder", "kind": "anatomy", "box": [10, 10, 60, 50]},
	])
	h.pointer_click(Vector2(27, 27))
	support.expect_equal(h.selected_region_id(), "tiny", "a small defect beats a larger region drawn on top")
	h.pointer_click(Vector2(50, 40))
	support.expect_equal(h.record().regions.size(), 1, "a contained defect is absorbed by its reference")
	support.expect_equal(h.record().regions[0].id, "large", "the containing reference identity remains")
	await h.press_key(KEY_Z, false, true)
	_install(h, [
		{"id": "thin-l", "class": "grasper", "kind": "instrument", "box": [0, 0, 120, 120],
			"polygon": [[20, 20], [60, 20], [60, 22], [22, 22], [22, 60], [20, 60]]},
		{"id": "square", "class": "gallbladder", "kind": "anatomy", "box": [19, 19, 15, 15]},
	])
	h.pointer_click(Vector2(21, 21))
	support.expect_equal(h.selected_region_id(), "thin-l", "hit ranking uses actual concave area, not bounding-box area")
	h.edit_plugin.cancel()
	_install(h, [
		{"id": "under", "class": "one", "kind": "test", "box": [20, 20, 10, 10]},
		{"id": "top", "class": "two", "kind": "test", "box": [20, 20, 10, 10]},
	])
	h.pointer_click(Vector2(25, 25))
	support.expect_equal(h.selected_region_id(), "top", "equal-area ties follow the existing topmost order")
	await h.finish()


func _test_gap_under_transforms() -> void:
	var h = await _mount()
	if h == null:
		return
	await h.click_tool(&"match_region")
	for gap: float in [0.5, 1.0, 1.01]:
		var first_result: Dictionary = {}
		for zoom: float in [0.5, 2.0]:
			_install(h, _gap_regions(gap))
			var transform = h.viewport.get_image_transform()
			transform.reset_to_fit()
			transform.zoom_at(transform.image_to_viewport(Vector2(40, 44)), zoom)
			transform.pan_by(Vector2(17, -9))
			h.viewport.notify_transform_changed()
			h.pointer_click(Vector2(34, 44))
			h.pointer_click(Vector2(45, 45))
			var after: Dictionary = h.record()
			support.expect_equal(after.regions.size(), 1 if gap <= 1.0 else 2,
				"%.2f image-pixel gap at zoom %.1f has the agreed merge result" % [gap, zoom])
			if first_result.is_empty():
				first_result = after
			else:
				support.expect_equal(after, first_result, "pan and zoom do not change the saved geometry")
			support.expect_equal(h.undo_count(), 1, "merged and relabeled UI corrections each use one command")
			await h.press_key(KEY_Z, false, true)
	await h.finish()


func _test_cancellation_and_staleness() -> void:
	var h = await _mount()
	if h == null:
		return
	var before: Dictionary = h.record()
	await h.click_tool(&"match_region")
	h.pointer_drag([Vector2(30, 30), Vector2(45, 40)])
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"idle", "dragging does not become a region-selection click")
	h.pointer_click(Vector2(30, 30))
	h.pointer_right_click(Vector2(30, 30))
	support.expect_equal(h.edit_plugin.get_active_tool(), &"select", "right click retains the existing Selection cancel behavior")
	await h.click_tool(&"match_region")
	h.pointer_click(Vector2(30, 30))
	await h.click_tool(&"paint")
	await h.click_tool(&"match_region")
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"idle", "switching away and back never resurrects A")
	h.pointer_click(Vector2(30, 30))
	support.expect(h.main.set_frame(1), "navigation can cancel the pending pair without blocking")
	h.pointer_click(Vector2(20, 20))
	support.expect_equal(h.record(), before, "a reference click on another frame cannot change the frozen frame")
	support.expect_equal(h.undo_count(), 0, "cross-frame input does not make a correction")
	h.main.set_frame(0)
	h.pointer_click(Vector2(30, 30))
	await h.press_key(KEY_Z, false, true)
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"idle", "even empty undo clears the pending pair")
	h.pointer_click(Vector2(30, 30))
	var newer := before.duplicate(true)
	newer.regions[1]["class"] = "newer-class"
	h.store.replace_corrected_record(0, newer)
	h.pointer_click(Vector2(100, 35))
	support.expect_equal(h.record(), newer, "a stale first click cannot overwrite intervening edits")
	support.expect_equal(h.undo_count(), 0, "stale input creates no history")
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"idle", "stale input resets the two-click phase")
	support.expect(_status(h).contains("变化"), "stale cancellation tells the user to pick again")
	h.pointer_click(Vector2(30, 30))
	var old_matcher = h.edit_plugin.get("_matcher")
	var next_source: String = h._write_source(support)
	support.expect_equal(await h.main.open_source(next_source), PackedStringArray(), "switching sources safely settles the pending pair")
	support.expect_equal(old_matcher.source_id, "", "source replacement clears the old controller")
	h.edit_plugin = h.main.get("_edit_plugin")
	h.store = h.main.get("_store")
	h.history = h.main.get("_history")
	# 换源会重建工具按钮，等待容器布局后再注入真实坐标点击。
	await process_frame
	await process_frame
	await h.click_tool(&"match_region")
	support.expect_equal(h.edit_plugin.get_active_tool(), &"match_region", "Match can be selected on the new source")
	h.pointer_click(Vector2(100, 35))
	support.expect_equal(h.edit_plugin.get_edit_state().phase, &"awaiting_reference", "the new source starts a fresh A click")
	support.expect_equal(h.undo_count(), 0, "source replacement cannot commit an old pending pair")
	await h.finish()


func _test_persistence() -> void:
	var h = await _mount()
	if h == null:
		return
	var source_text := FileAccess.get_file_as_string(h.source_root.path_join("model_output_v1.jsonl"))
	_install(h, _gap_regions(0.0))
	await h.click_tool(&"match_region")
	h.pointer_click(Vector2(34, 44))
	h.pointer_click(Vector2(45, 45))
	var after: Dictionary = h.record()
	support.expect_equal(after.regions.size(), 1, "the persisted fixture really performs a merge")
	var session = h.main.get("_workspace_session")
	support.expect_equal(await session.flush_before_context_change(), PackedStringArray(), "real session save accepts Match output")
	support.expect(not session.has_unsaved_changes(), "the Match revision reaches disk")
	support.expect_equal(await h.main.open_source(h.source_root), PackedStringArray(), "the saved source can reopen")
	h.store = h.main.get("_store")
	support.expect_equal(h.store.get_corrected_record(0), after, "reopening restores the merged geometry, identity and labels")
	var exported: Array = h.store.snapshot_corrected()
	support.expect_equal(exported[0], after, "the export projection contains the same corrected V1 record")
	var package: Dictionary = await h.main.export_package(h.source_root.path_join("match-export"), "review_export_v1")
	support.expect(package.get("success", false), "Match can export a validated review package: " + str(package.get("errors", [])))
	if package.get("success", false):
		var line := FileAccess.get_file_as_string(String(package.output_path).path_join("data/corrected_annotations.jsonl")).split("\n")[0]
		var disk_record: Dictionary = JSON.parse_string(line)
		var expected_export: Dictionary = JSON.parse_string(JSON.stringify(after))
		expected_export.source = "human_corrected"
		support.expect_equal(disk_record, expected_export, "export preserves all edits and uses the package's corrected source marker")
	support.expect_equal(FileAccess.get_file_as_string(h.source_root.path_join("model_output_v1.jsonl")), source_text,
		"saving the correction preserves the original model output file")
	await h.finish()


func _install(h, regions: Array) -> void:
	h.edit_plugin.cancel()
	var record: Dictionary = h.store.get_model_record(0)
	record.regions = regions.duplicate(true)
	support.expect_equal(h.store.replace_corrected_record(0, record), PackedStringArray(), "test model geometry is a valid V1 input")
	h.main._refresh_current_annotations()


func _gap_regions(gap: float) -> Array:
	return [
		{"id": "a", "class": "grasper", "kind": "instrument", "box": [30, 40, 8, 8], "conf": 0.2, "track_id": "A"},
		{"id": "b", "class": "gallbladder", "kind": "anatomy", "box": [38 + gap, 40, 20, 20], "conf": 0.9, "track_id": "B"},
	]


func _status(h) -> String:
	return (h.main.get_node("MainVBox/StatusBar") as Label).text
