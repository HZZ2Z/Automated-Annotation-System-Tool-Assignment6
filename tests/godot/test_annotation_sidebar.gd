extends RefCounted

const SIDEBAR_SCENE_PATH := "res://client/ui/annotation_sidebar.tscn"


func run(support, tree: SceneTree) -> void:
	var packed := load(SIDEBAR_SCENE_PATH) as PackedScene
	support.expect(packed != null, "AnnotationSidebar scene should load")
	if packed == null:
		return
	var sidebar := packed.instantiate() as Control
	sidebar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	sidebar.position = Vector2(80, 40)
	sidebar.size = Vector2(360, 600)
	var viewport := SubViewport.new()
	viewport.size = Vector2(640, 720)
	viewport.gui_disable_input = false
	viewport.handle_input_locally = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(viewport)
	viewport.add_child(sidebar)
	await tree.process_frame

	support.expect(sidebar is VBoxContainer, "sidebar root should be a VBoxContainer")
	support.expect_equal((sidebar.get_node("ProjectLabels/Title") as Label).text, "Project Labels",
		"upper panel must identify the project catalog")
	support.expect_equal((sidebar.get_node("FrameAnnotations/Title") as Label).text,
		"Current Frame Annotations", "lower panel must identify current objects")
	support.expect((sidebar.get_node("ProjectLabels/Tree") as Tree).position.y >
		(sidebar.get_node("ProjectLabels/Title") as Label).position.y,
		"project tree should be laid out below its title")
	support.expect((sidebar.get_node("FrameAnnotations/Tree") as Tree).position.y >
		(sidebar.get_node("FrameAnnotations/Title") as Label).position.y,
		"frame tree should be laid out below its title")
	for panel_path in ["ProjectLabels", "FrameAnnotations"]:
		var panel := sidebar.get_node(panel_path) as Control
		var title := sidebar.get_node(panel_path + "/Title") as Control
		var tree_control := sidebar.get_node(panel_path + "/Tree") as Control
		support.expect(panel.get_global_rect().has_point(title.get_global_rect().position + Vector2(1, 1)),
			"%s title should remain inside the panel at a non-zero parent position" % panel_path)
		support.expect(panel.get_global_rect().has_point(tree_control.get_global_rect().position + Vector2(1, 1)),
			"%s tree should remain inside the panel at a non-zero parent position" % panel_path)
	for old_name in ["RegionId", "Confidence", "TrackId", "BoxX", "BoxY", "BoxWidth", "BoxHeight", "Fill"]:
		support.expect(sidebar.find_child(old_name, true, false) == null,
			"new sidebar must not expose old Inspector field %s" % old_name)

	var project_tree := sidebar.get_node("ProjectLabels/Tree") as Tree
	var frame_tree := sidebar.get_node("FrameAnnotations/Tree") as Tree
	support.expect_equal(project_tree.mouse_filter, Control.MOUSE_FILTER_STOP,
		"project tree should stop pointer events for stable scrolling")
	support.expect_equal(frame_tree.select_mode, Tree.SELECT_ROW,
		"frame tree should select complete rows")
	support.expect_equal(project_tree.get_column_title(0), "Color", "project tree color column")
	support.expect_equal(project_tree.get_column_title(1), "Class", "project tree class column")
	support.expect_equal(project_tree.get_column_title(2), "This Frame", "project tree count column")
	support.expect_equal(frame_tree.get_column_title(0), "Color", "frame tree color column")
	support.expect_equal(frame_tree.get_column_title(1), "Class", "frame tree class column")
	support.expect_equal(frame_tree.get_column_title(2), "Kind", "frame tree kind column")
	support.expect_equal(frame_tree.get_column_title(3), "Geometry", "frame tree geometry column")

	var project_rows := [
		{"class": "grasper", "color": Color("#ef4444"), "current_count": 2},
		{"class": "custom lesion", "color": Color("#22c55e"), "current_count": 1},
	]
	var frame_rows := [
		{"region_id": "r-box", "class": "grasper", "kind": "instrument", "geometry": &"box", "color": Color("#ef4444")},
		{"region_id": "r-poly", "class": "custom lesion", "kind": "pathology_custom", "geometry": &"polygon", "color": Color("#22c55e")},
	]
	var populate_calls: Array[String] = []
	sidebar.region_hovered.connect(func(region_id: String): populate_calls.append("hover:" + region_id))
	sidebar.region_selected.connect(func(region_id: String): populate_calls.append("select:" + region_id))
	sidebar.region_reclassify_requested.connect(func(region_id: String): populate_calls.append("reclassify:" + region_id))
	sidebar.populate(project_rows, frame_rows, "r-box")
	support.expect_equal(populate_calls, [], "populate must not emit user-intent signals")
	support.expect_equal(sidebar.call("get_project_rows_snapshot"), project_rows,
		"project snapshot should reflect the supplied rows")
	support.expect_equal(sidebar.call("get_frame_rows_snapshot"), frame_rows,
		"frame snapshot should reflect the supplied rows")
	support.expect_equal((frame_tree.get_root().get_child(0) as TreeItem).get_text(3), "Box",
		"box geometry should be displayed as Box")
	support.expect_equal((frame_tree.get_root().get_child(1) as TreeItem).get_text(3), "Polygon",
		"non-box geometry should be displayed as Polygon")

	# Caller mutation must not change the rendered/read-only view models.
	project_rows[0]["class"] = "mutated caller class"
	frame_rows[0]["kind"] = "mutated caller kind"
	support.expect_equal(sidebar.call("get_project_rows_snapshot")[0]["class"], "grasper",
		"project view models must be copied on populate")
	support.expect_equal(sidebar.call("get_frame_rows_snapshot")[0]["kind"], "instrument",
		"frame view models must be copied on populate")

	# Pointer motion emits only transitions; exit clears exactly once.
	var motion := InputEventMouseMotion.new()
	var box_item := frame_tree.get_root().get_child(0) as TreeItem
	var box_global_position := frame_tree.get_global_rect().position + frame_tree.get_item_area_rect(box_item).position + Vector2(8, 2)
	motion.position = Vector2(8, 8)
	motion.global_position = motion.position
	motion.relative = Vector2(8, 8)
	viewport.push_input(motion)
	await tree.process_frame
	var motion_inside := InputEventMouseMotion.new()
	motion_inside.position = box_global_position
	motion_inside.global_position = box_global_position
	motion_inside.relative = box_global_position - motion.position
	viewport.push_input(motion_inside)
	await tree.process_frame
	if not populate_calls.has("hover:r-box"):
		# Headless Godot's SubViewport has no OS cursor to synthesize motion
		# delivery; keep the real push_input attempt above, then exercise the
		# same Tree gui_input handler with the event in Tree-local coordinates.
		var local_motion := motion_inside.duplicate() as InputEventMouseMotion
		local_motion.position = frame_tree.get_item_area_rect(box_item).position + Vector2(8, 2)
		frame_tree.gui_input.emit(local_motion)
	support.expect_equal(populate_calls, ["hover:r-box"],
		"motion over a frame row should emit its stable region ID once")
	var motion_again := InputEventMouseMotion.new()
	motion_again.position = box_global_position
	motion_again.global_position = box_global_position
	motion_again.relative = Vector2.ZERO
	viewport.push_input(motion_again)
	await tree.process_frame
	support.expect_equal(populate_calls, ["hover:r-box"],
		"repeated motion over the same row should not re-emit hover")
	var outside_motion := InputEventMouseMotion.new()
	outside_motion.position = Vector2(8, 8)
	outside_motion.global_position = outside_motion.position
	outside_motion.relative = outside_motion.position - box_global_position
	viewport.push_input(outside_motion)
	await tree.process_frame
	support.expect_equal(populate_calls, ["hover:r-box", "hover:"],
		"pointer exit should clear hover exactly once")
	var outside_again := outside_motion.duplicate() as InputEventMouseMotion
	viewport.push_input(outside_again)
	await tree.process_frame
	support.expect_equal(populate_calls, ["hover:r-box", "hover:"],
		"repeated pointer exit should not re-emit an empty hover")

	# A real left-button click selects through Tree's input path.
	frame_tree.grab_focus()
	var poly_item := frame_tree.get_root().get_child(1) as TreeItem
	var poly_global_position := frame_tree.get_global_rect().position + frame_tree.get_item_area_rect(poly_item).position + Vector2(8, 2)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.button_mask = MOUSE_BUTTON_MASK_LEFT
	click.position = poly_global_position
	viewport.push_input(click)
	await tree.process_frame
	var click_release := InputEventMouseButton.new()
	click_release.button_index = MOUSE_BUTTON_LEFT
	click_release.position = poly_global_position
	viewport.push_input(click_release)
	await tree.process_frame
	support.expect_equal(populate_calls, ["hover:r-box", "hover:", "select:r-poly"],
		"single click should emit selection for the second row exactly once")
	# A real double-click requests reclassification exactly once.
	var before_programmatic_selection := populate_calls.size()
	sidebar.call("set_selected_region_id", "r-box")
	support.expect_equal(populate_calls.size(), before_programmatic_selection,
		"programmatic selection before double-click must stay signal-silent")
	support.expect_equal(str((frame_tree.get_selected() as TreeItem).get_metadata(0)), "r-box",
		"programmatic selection should make the double-click target current")
	var double_click := InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.button_mask = MOUSE_BUTTON_MASK_LEFT
	double_click.double_click = true
	double_click.position = box_global_position
	viewport.push_input(double_click)
	await tree.process_frame
	var double_click_release := InputEventMouseButton.new()
	double_click_release.button_index = MOUSE_BUTTON_LEFT
	double_click_release.position = box_global_position
	viewport.push_input(double_click_release)
	await tree.process_frame
	support.expect_equal(populate_calls,
		["hover:r-box", "hover:", "select:r-poly", "reclassify:r-box"],
		"double-click should emit one reclassification intent")

	# Enter is a keyboard reclassification intent for the selected row.
	frame_tree.grab_focus()
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	viewport.push_input(enter)
	await tree.process_frame
	support.expect_equal(populate_calls.back(), "reclassify:r-box",
		"Enter with tree focus should request reclassification")
	var reclassify_count := populate_calls.count("reclassify:r-box")
	support.expect_equal(reclassify_count, 2,
		"double-click and Enter should each emit exactly one reclassification intent")
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	viewport.push_input(space)
	await tree.process_frame
	support.expect_equal(populate_calls.count("reclassify:r-box"), reclassify_count,
		"Space must not request reclassification")
	var second_click := InputEventMouseButton.new()
	second_click.button_index = MOUSE_BUTTON_LEFT
	second_click.pressed = true
	second_click.position = poly_global_position
	viewport.push_input(second_click)
	await tree.process_frame
	var second_click_release := InputEventMouseButton.new()
	second_click_release.button_index = MOUSE_BUTTON_LEFT
	second_click_release.position = poly_global_position
	viewport.push_input(second_click_release)
	await tree.process_frame
	support.expect_equal(populate_calls.count("select:r-poly"), 2,
		"real clicks on the second row should each select it exactly once")

	# Programmatic selection sync must not emit selection intent.
	var before_sync_count := populate_calls.size()
	sidebar.call("set_selected_region_id", "r-poly")
	support.expect_equal(populate_calls.size(), before_sync_count,
		"programmatic selection should be signal-silent")
	support.expect_equal(str((frame_tree.get_selected() as TreeItem).get_metadata(0)), "r-poly",
		"programmatic selection should locate the matching stable ID")
	sidebar.call("clear_hover")
	sidebar.call("clear")
	support.expect_equal(sidebar.call("get_project_rows_snapshot"), [], "clear should remove project rows")
	support.expect_equal(sidebar.call("get_frame_rows_snapshot"), [], "clear should remove frame rows")

	sidebar.queue_free()
	viewport.queue_free()
	await tree.process_frame
