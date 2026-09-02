extends SceneTree

const FRONTEND_STRUCTURE_TEST = preload("res://tests/godot/test_frontend_structure.gd")
const TEST_SUPPORT = preload("res://tests/godot/test_support.gd")


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var support = TEST_SUPPORT.new()
	FRONTEND_STRUCTURE_TEST.new().run(support, self)
	if support.failures.is_empty():
		print("PASS: Godot frontend structure")
		quit(0)
		return
	push_error("FAIL: Godot frontend structure\n%s" % support.failure_report())
	quit(1)
