extends SceneTree

const FRONTEND_STRUCTURE_TEST = preload("res://tests/godot/test_frontend_structure.gd")
const ANNOTATION_VALIDATOR_TEST = preload("res://tests/godot/test_annotation_validator.gd")
const ANNOTATION_STORE_TEST = preload("res://tests/godot/test_annotation_store.gd")
const PLUGIN_REGISTRY_TEST = preload("res://tests/godot/test_plugin_registry.gd")
const SOURCE_PLUGIN_TEST = preload("res://tests/godot/test_source_plugin.gd")
const VIEWPORT_TRANSFORM_TEST = preload("res://tests/godot/test_viewport_transform.gd")
const RENDERER_TEST = preload("res://tests/godot/test_renderer.gd")
const ANNOTATION_VIEWPORT_TEST = preload("res://tests/godot/test_annotation_viewport.gd")
const EDIT_COMMANDS_TEST = preload("res://tests/godot/test_edit_commands.gd")
const KEYBOARD_EDITING_TEST = preload("res://tests/godot/test_keyboard_editing.gd")
const INSPECTOR_PANEL_TEST = preload("res://tests/godot/test_inspector_panel.gd")
const EDIT_INTEGRATION_TEST = preload("res://tests/godot/test_edit_integration.gd")
const TEST_SUPPORT = preload("res://tests/godot/test_support.gd")


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var support = TEST_SUPPORT.new()
	await FRONTEND_STRUCTURE_TEST.new().run(support, self)
	ANNOTATION_VALIDATOR_TEST.run(support)
	ANNOTATION_STORE_TEST.run(support)
	PLUGIN_REGISTRY_TEST.run(support)
	SOURCE_PLUGIN_TEST.run(support)
	VIEWPORT_TRANSFORM_TEST.run(support)
	RENDERER_TEST.run(support)
	await ANNOTATION_VIEWPORT_TEST.new().run(support, self)
	EDIT_COMMANDS_TEST.run(support)
	KEYBOARD_EDITING_TEST.run(support)
	await INSPECTOR_PANEL_TEST.new().run(support, self)
	await EDIT_INTEGRATION_TEST.new().run(support, self)
	if support.failures.is_empty():
		print("PASS: complete Godot test suite")
		quit(0)
		return
	push_error("FAIL: Godot test suite\n%s" % support.failure_report())
	quit(1)
