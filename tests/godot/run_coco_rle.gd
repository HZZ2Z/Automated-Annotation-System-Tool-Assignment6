extends SceneTree

const TEST := preload("res://tests/godot/test_coco_rle.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")


func _init() -> void:
	var support = SUPPORT.new()
	TEST.new().run(support)
	if support.failures.is_empty():
		print("PASS: COCO compressed RLE")
		quit(0)
		return
	push_error("FAIL: COCO compressed RLE\n%s" % support.failure_report())
	quit(1)
