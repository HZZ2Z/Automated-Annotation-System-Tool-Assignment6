extends RefCounted

const TOOL_PANEL_SCENE := "res://client/ui/tool_panel.tscn"


func run(support, tree: SceneTree) -> void:
	var packed := ResourceLoader.load(TOOL_PANEL_SCENE, "PackedScene") as PackedScene
	support.expect(packed != null, "ToolPanel scene should load")
	if packed == null:
		return
	var panel := packed.instantiate()
	tree.root.add_child(panel)
	await tree.process_frame

	var expected := [
		["Box", &"box", "Add Box", true],
		["Subtract", &"subtract", "Subtract", false],
		["Lasso", &"lasso", "Lasso", false],
		["Fill", &"fill", "Fill", true],
		["Delete", &"delete", "Erase", true],
		["Close", &"close", "Close", false],
		["Paint", &"paint", "Paint", false],
		["Wipe", &"wipe", "Wipe", false],
		["RegionGrowing", &"region_growing", "Region Growing", false],
		["LiveWire", &"live_wire", "Live Wire", false],
		["Select", &"select", "Selection", true],
		["Move", &"move", "Move / Resize", true],
	]
	var grid := panel.get_node("ToolGrid") as GridContainer
	support.expect_equal(grid.columns, 4, "ToolPanel should use one flat four-column grid")
	support.expect_equal(grid.get_child_count(), 12, "ToolPanel should expose twelve stable slots")
	for position in range(expected.size()):
		var row: Array = expected[position]
		var button := grid.get_node_or_null(row[0]) as Button
		support.expect(button != null, "ToolPanel should expose %s" % row[0])
		if button != null:
			support.expect_equal(button.get_index(), position,
				"%s should retain its approved position" % row[0])
			support.expect_equal(button.text, row[2], "%s should show its approved label" % row[0])
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
