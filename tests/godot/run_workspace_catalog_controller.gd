extends SceneTree

const TEST := preload("res://tests/godot/test_workspace_catalog_controller.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var support = SUPPORT.new()
	await TEST.new().run(support, self)
	if support.failures.is_empty():
		print("PASS: workspace catalog background controller")
		quit(0)
		return
	push_error("FAIL: workspace catalog background controller\n%s" % support.failure_report())
	quit(1)
