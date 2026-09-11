extends SceneTree
func _init():
	var support = preload("res://tests/godot/test_support.gd").new()
	preload("res://tests/godot/test_feedback_plugin.gd").new().run(support)
	if support.failures.is_empty(): print("PASS: legacy Feedback API V1")
	else: printerr(support.failure_report())
	quit(0 if support.failures.is_empty() else 1)
