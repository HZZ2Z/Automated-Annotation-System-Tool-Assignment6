extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const SUITE := preload("res://tests/godot/test_main_boundaries.gd")


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var support = SUPPORT.new()
	await SUITE.new().run(support, self)
	if support.failures.is_empty():
		print("PASS main boundaries")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)
