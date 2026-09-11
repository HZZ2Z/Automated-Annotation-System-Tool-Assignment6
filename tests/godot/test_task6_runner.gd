extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const TOOL_PANEL_TEST := preload("res://tests/godot/test_tool_panel.gd")
const EDIT_OVERLAY_TEST := preload("res://tests/godot/test_edit_overlay.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var support = SUPPORT.new()
	await TOOL_PANEL_TEST.new().run(support, self)
	await EDIT_OVERLAY_TEST.new().run(support, self)
	if support.failures.is_empty():
		print("PASS task 6 UI components")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)
