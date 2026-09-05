extends RefCounted

const TOOL_PANEL_SCENE := "res://client/ui/tool_panel.tscn"
const EDIT_PLUGIN := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")


func run(support, tree: SceneTree) -> void:
	var packed := ResourceLoader.load(TOOL_PANEL_SCENE, "PackedScene") as PackedScene
	support.expect(packed != null, "ToolPanel scene should load")
	if packed == null:
		return
	var panel := packed.instantiate()
	tree.root.add_child(panel)
	await tree.process_frame
	panel.size = Vector2(320, 226)
	await tree.process_frame
	var grid := panel.get_node("ToolGrid") as GridContainer
	support.expect(panel.has_method("configure_tools"), "ToolPanel should accept descriptors supplied by an Edit plugin")
	if not panel.has_method("configure_tools"):
		panel.queue_free()
		await tree.process_frame
		return
	support.expect_equal(grid.get_child_count(), 0, "ToolPanel core should not construct hard-coded tools")
	var plugin = EDIT_PLUGIN.new()
	var definitions: Array[Dictionary] = plugin.get_tool_descriptors()
	support.expect_equal(panel.configure_tools(definitions), PackedStringArray(), "the working Edit plugin should configure its tool UI")
	await tree.process_frame

	var expected := [
		["Box", &"box", "Add Box", true, "Add\nBox"],
		["Subtract", &"subtract", "Subtract", true, "Subtract"],
		["Lasso", &"lasso", "Lasso", true, "Lasso"],
		["Fill", &"fill", "Fill", true, "Fill"],
		["Paint", &"paint", "Paint", true, "Paint"],
		["Eraser", &"eraser", "Eraser", true, "Eraser"],
		["Select", &"select", "Selection", true, "Selection"],
	]
	var expected_ids := [
		&"box", &"subtract", &"lasso", &"fill",
		&"paint", &"eraser", &"select",
	]
	support.expect_equal(definitions.map(func(definition): return definition.id), expected_ids,
		"the toolbar must expose the approved seven distinct tools in order")
	support.expect(not definitions.any(func(definition): return definition.id in [&"delete", &"wipe"]),
		"whole-region Erase and Wipe descriptors must not exist")
	support.expect(not definitions.any(func(definition): return definition.id == &"close_gaps"),
		"Close Gaps must not remain in the toolbar contract")
	var brush_option := {
		"id": &"brush_radius", "label": "Brush radius", "kind": &"float_range",
		"min": 1.0, "max": 40.0, "step": 1.0, "default": 8.0,
		"shared_key": &"brush_radius",
	}
	support.expect_equal(definitions[4].get("options"), [brush_option],
		"Paint must declare the shared image-space radius")
	support.expect_equal(definitions[5].get("options"), [brush_option],
		"Eraser must declare the same shared image-space radius")
	support.expect_equal(panel.custom_minimum_size.x, 320.0,
		"ToolPanel should retain the approved 320px minimum width")
	support.expect(panel.get_combined_minimum_size().x <= 320.0,
		"ToolPanel content should fit its real 320px width")
	support.expect_equal(grid.columns, 4, "ToolPanel should use one flat four-column grid")
	support.expect_equal(grid.get_child_count(), 7, "ToolPanel should expose seven stable slots")
	support.expect_equal(definitions.size(), expected.size(),
		"ToolPanel should retain seven approved registry entries")
	var button_height := -1.0
	for position in range(expected.size()):
		var row: Array = expected[position]
		var definition: Dictionary = definitions[position]
		support.expect_equal(definition.get("node_name"), row[0],
			"registry position %d should retain its approved node" % position)
		support.expect_equal(definition.get("id"), row[1],
			"%s should retain its approved registry ID" % row[0])
		support.expect_equal(definition.get("label"), row[2],
			"%s should retain its approved registry label" % row[0])
		support.expect_equal(definition.get("implemented"), row[3],
			"%s should retain its implemented/reserved behavior" % row[0])
		var button := grid.get_node_or_null(row[0]) as Button
		support.expect(button != null, "ToolPanel should expose %s" % row[0])
		if button != null:
			support.expect_equal(button.get_index(), position,
				"%s should retain its approved position" % row[0])
			support.expect_equal(button.text, row[4],
				"%s should use the approved compact presentation" % row[0])
			support.expect(button.text.split("\n").size() <= 2,
				"%s should use at most two explicit text lines" % row[0])
			support.expect_equal(button.autowrap_mode, TextServer.AUTOWRAP_OFF,
				"%s should not add automatic lines at 320px" % row[0])
			var icon_max_width := button.get_theme_constant("icon_max_width")
			support.expect(icon_max_width >= 16 and icon_max_width <= 18,
				"%s should keep a clear icon within the narrow cell" % row[0])
			var font_size := button.get_theme_font_size("font_size")
			support.expect(font_size >= 11 and font_size <= 12,
				"%s should use a readable compact font" % row[0])
			var minimum_width := button.get_combined_minimum_size().x
			support.expect(minimum_width <= 77.0,
				"%s should fit one quarter of the real 320px grid (got %.1fpx)" % [row[0], minimum_width])
			if button_height < 0.0:
				button_height = button.size.y
			else:
				support.expect(is_equal_approx(button.size.y, button_height),
					"%s should match every tool button height" % row[0])
			support.expect(button.icon != null, "%s should use an original local icon" % row[0])
			support.expect(not button.tooltip_text.is_empty(), "%s should explain its intent" % row[0])

	support.expect_equal(panel.get_active_tool(), &"select", "Select should be active by default")
	_assert_one_pressed(support, panel, "Select")
	var option_row := panel.get_node_or_null("OptionRow") as Control
	var option_value := panel.get_node_or_null("OptionRow/Value") as SpinBox
	support.expect(option_row != null and option_value != null,
		"ToolPanel should provide a descriptor-driven numeric option row")
	if option_row != null:
		support.expect(not option_row.visible, "tools without options should hide the option row")

	var requested: Array[StringName] = []
	var unavailable: Array[StringName] = []
	panel.tool_requested.connect(func(tool_id: StringName) -> void: requested.append(tool_id))
	panel.unavailable_tool_requested.connect(
		func(tool_id: StringName) -> void: unavailable.append(tool_id)
	)
	var option_changes: Array = []
	panel.tool_option_changed.connect(
		func(tool_id: StringName, option_id: StringName, value: Variant) -> void:
			option_changes.append([tool_id, option_id, value])
	)
	(grid.get_node("Paint") as Button).pressed.emit()
	if option_row != null and option_value != null:
		support.expect(option_row.visible, "Paint should reveal its descriptor option")
		support.expect_equal(option_value.value, 8.0, "Paint should start with the approved default radius")
		option_value.value = 13.0
	support.expect_equal(option_changes, [[&"paint", &"brush_radius", 13.0]],
		"numeric option changes should identify the active tool and option")
	if option_value != null:
		support.expect_equal(option_value.value, 8.0,
			"an option request must remain provisional until its owner explicitly accepts it")
	var has_accept_api := panel.has_method("accept_tool_option")
	support.expect(has_accept_api,
		"ToolPanel should expose an explicit acceptance boundary for transactional options")
	if has_accept_api:
		support.expect(panel.call("accept_tool_option", &"paint", &"brush_radius", 13.0),
			"the owner should be able to accept a valid requested radius")
	if option_value != null:
		support.expect_equal(option_value.value, 13.0,
			"explicit acceptance should update the visible option value")
	if option_value != null:
		option_value.value = 0.0
		support.expect_equal(option_value.value, 13.0,
			"a below-range radius must restore the prior displayed Paint value")
		option_value.value = 41.0
		support.expect_equal(option_value.value, 13.0,
			"an above-range radius must restore the prior displayed Paint value")
		option_value.value = NAN
		support.expect_equal(option_value.value, 13.0,
			"a non-finite radius must restore the prior displayed Paint value")
	support.expect_equal(option_changes, [[&"paint", &"brush_radius", 13.0]],
		"rejected radius inputs must not update the shared ToolPanel value")
	(grid.get_node("Eraser") as Button).pressed.emit()
	if option_row != null and option_value != null:
		support.expect(option_row.visible, "Eraser should reveal its shared descriptor option")
		support.expect_equal(option_value.value, 13.0,
			"Paint and Eraser should retain one shared brush-radius value")
	for route: Array in expected:
		(grid.get_node(route[0]) as Button).pressed.emit()
	support.expect_equal(requested,
		[&"paint", &"eraser", &"box", &"subtract", &"lasso", &"fill",
			&"paint", &"eraser", &"select"],
		"all seven functional tools should use tool_requested with stable IDs")
	support.expect_equal(panel.get_active_tool(), &"select", "Selection should remain active")
	support.expect_equal(unavailable, [], "implemented tools should never use the pending-development route")
	_assert_one_pressed(support, panel, "Select")
	support.expect(not panel.set_active_tool(&"polygon"), "unknown tools should be rejected")
	support.expect_equal(panel.get_active_tool(), &"select",
		"a rejected tool should preserve the active state")

	var pending_definition: Array[Dictionary] = [{
		"id": &"future_tool",
		"node_name": "FutureTool",
		"label": "Future Tool",
		"implemented": false,
		"tooltip": "Reserved without removing its UI slot",
		"icon_path": "res://client/ui/icons/tools/selection.svg",
	}]
	support.expect_equal(
		panel.configure_tools(pending_definition),
		PackedStringArray(),
		"an unimplemented descriptor should remain a valid visible tool contract",
	)
	await tree.process_frame
	var future_button := grid.get_node_or_null("FutureTool") as Button
	support.expect(future_button != null and not future_button.disabled,
		"an unimplemented tool must stay visible and clickable instead of being removed")
	if future_button != null:
		future_button.pressed.emit()
	support.expect_equal(unavailable, [&"future_tool"],
		"clicking an unimplemented tool should route to Main's exact pending-development message")
	support.expect_equal(requested.size(), 9,
		"an unimplemented tool click must not enter the functional edit route")

	panel.queue_free()
	await tree.process_frame


func _assert_one_pressed(support, panel: Node, active_name: String) -> void:
	var pressed_count := 0
	var grid := panel.get_node("ToolGrid") as GridContainer
	for child: Node in grid.get_children():
		var button := child as Button
		if button.toggle_mode and button.button_pressed:
			pressed_count += 1
		support.expect_equal(
			button.button_pressed,
			button.name == active_name,
			"%s pressed state should match active tool" % button.name,
		)
	support.expect_equal(pressed_count, 1,
			"ToolPanel should keep exactly one functional tool pressed")
