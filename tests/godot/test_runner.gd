extends SceneTree

const FRONTEND_STRUCTURE_TEST = preload("res://tests/godot/test_frontend_structure.gd")
const ANNOTATION_VALIDATOR_TEST = preload("res://tests/godot/test_annotation_validator.gd")
const ANNOTATION_STORE_TEST = preload("res://tests/godot/test_annotation_store.gd")
const TEST_SUPPORT = preload("res://tests/godot/test_support.gd")


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var support = TEST_SUPPORT.new()
	await FRONTEND_STRUCTURE_TEST.new().run(support, self)
	ANNOTATION_VALIDATOR_TEST.run(support)
	ANNOTATION_STORE_TEST.run(support)
	if support.failures.is_empty():
		print("PASS: complete Godot test suite")
		quit(0)
		return
	push_error("FAIL: Godot test suite\n%s" % support.failure_report())
	quit(1)
