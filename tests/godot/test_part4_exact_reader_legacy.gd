extends SceneTree
func _init() -> void:
	var support = preload("res://tests/godot/test_support.gd").new()
	preload("res://tests/godot/test_source_plugin.gd").run(support)
	preload("res://tests/godot/test_cholect50_label_adapter.gd").new().run(support)
	preload("res://tests/godot/test_feedback_plugin.gd").new().run(support)
	if support.failures.is_empty(): print("PASS exact JSON legacy Source/Cholect50/Feedback regression")
	else: print(support.failure_report())
	quit(0 if support.failures.is_empty() else 1)
