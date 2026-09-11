extends SceneTree

const TEST := preload("res://tests/godot/test_endoscapes_source.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")


func _init() -> void:
	var support = SUPPORT.new()
	TEST.new().run(support)
	if support.failures.is_empty():
		print("PASS: Endoscapes video source")
		quit(0)
		return
	push_error("FAIL: Endoscapes video source\n%s" % support.failure_report())
	quit(1)
