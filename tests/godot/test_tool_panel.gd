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

	var expected := {
		"Select": &"select",
		"Move": &"move",
		"Box": &"box",
		"Fill": &"fill",
		"Delete": &"delete",
	}
	for node_name: String in expected:
		var button := panel.get_node_or_null(node_name) as Button
		support.expect(button != null, "ToolPanel should expose %s" % node_name)

	support.expect_equal(panel.call("get_active_tool"), &"select", "Select should be active by default")
	_assert_one_pressed(support, panel, "Select")

	var requested: Array[StringName] = []
	panel.tool_requested.connect(func(tool_id: StringName) -> void: requested.append(tool_id))
	(panel.get_node("Move") as Button).pressed.emit()
	support.expect_equal(requested, [&"move"], "Move should emit its stable tool ID")
	support.expect_equal(panel.call("get_active_tool"), &"move", "Move should become active")
	_assert_one_pressed(support, panel, "Move")

	(panel.get_node("Move") as Button).pressed.emit()
	support.expect_equal(panel.call("get_active_tool"), &"move", "clicking the active tool should keep it active")
	_assert_one_pressed(support, panel, "Move")

	support.expect(not panel.call("set_active_tool", &"polygon"), "unknown tools should be rejected")
	support.expect_equal(panel.call("get_active_tool"), &"move", "a rejected tool should preserve active state")
	_assert_one_pressed(support, panel, "Move")

	panel.queue_free()
	await tree.process_frame


func _assert_one_pressed(support, panel: Node, active_name: String) -> void:
	var pressed_count := 0
	for node_name in ["Select", "Move", "Box", "Fill", "Delete"]:
		var button := panel.get_node(node_name) as Button
		if button.button_pressed:
			pressed_count += 1
		support.expect_equal(
			button.button_pressed,
			node_name == active_name,
			"%s pressed state should match active tool" % node_name,
		)
	support.expect_equal(pressed_count, 1, "ToolPanel should keep exactly one pressed tool")
