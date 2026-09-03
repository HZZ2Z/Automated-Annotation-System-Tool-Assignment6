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
		["Subtract", &"subtract", "Subtract", false, "Subtract"],
		["Lasso", &"lasso", "Lasso", false, "Lasso"],
		["Fill", &"fill", "Fill", true, "Fill"],
		["Delete", &"delete", "Erase", true, "Erase"],
		["Close", &"close", "Close", false, "Close"],
		["Paint", &"paint", "Paint", false, "Paint"],
		["Wipe", &"wipe", "Wipe", false, "Wipe"],
		["RegionGrowing", &"region_growing", "Region Growing", false, "Region\nGrowing"],
		["LiveWire", &"live_wire", "Live Wire", false, "Live\nWire"],
		["Select", &"select", "Selection", true, "Selection"],
		["Move", &"move", "Move / Resize", true, "Move /\nResize"],
	]
	support.expect_equal(panel.custom_minimum_size.x, 320.0,
		"ToolPanel should retain the approved 320px minimum width")
	support.expect(panel.get_combined_minimum_size().x <= 320.0,
		"ToolPanel content should fit its real 320px width")
	support.expect_equal(grid.columns, 4, "ToolPanel should use one flat four-column grid")
	support.expect_equal(grid.get_child_count(), 12, "ToolPanel should expose twelve stable slots")
	support.expect_equal(definitions.size(), expected.size(),
		"ToolPanel should retain twelve approved registry entries")
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

	var requested: Array[StringName] = []
	var unavailable: Array[StringName] = []
	panel.tool_requested.connect(func(tool_id: StringName) -> void: requested.append(tool_id))
	panel.unavailable_tool_requested.connect(
		func(tool_id: StringName) -> void: unavailable.append(tool_id)
	)
	for route: Array in [
		["Box", &"box"],
		["Fill", &"fill"],
		["Delete", &"delete"],
		["Select", &"select"],
		["Move", &"move"],
	]:
		(grid.get_node(route[0]) as Button).pressed.emit()
	support.expect_equal(requested, [&"box", &"fill", &"delete", &"select", &"move"],
		"all five functional tools should use tool_requested with stable IDs")
	support.expect_equal(panel.get_active_tool(), &"move", "Move should become active")

	for row: Array in expected:
		if not row[3]:
			(grid.get_node(row[0]) as Button).pressed.emit()
	support.expect_equal(unavailable,
		[&"subtract", &"lasso", &"close", &"paint", &"wipe",
			&"region_growing", &"live_wire"],
		"reserved tools should use only the unavailable route")
	support.expect_equal(requested, [&"box", &"fill", &"delete", &"select", &"move"],
		"reserved tools must not reach the functional edit route")
	support.expect_equal(panel.get_active_tool(), &"move",
		"reserved tools must preserve the active tool")
	_assert_one_pressed(support, panel, "Move")
	support.expect(not panel.set_active_tool(&"polygon"), "unknown tools should be rejected")
	support.expect_equal(panel.get_active_tool(), &"move",
		"a rejected tool should preserve the active state")

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
