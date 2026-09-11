extends SceneTree
const SUPPORT = preload("res://tests/godot/test_support.gd")
func _init() -> void:
	var support = SUPPORT.new()
	preload("res://tests/godot/test_annotation_store.gd").run(support)
	preload("res://tests/godot/test_model_output_immutability.gd").run(support)
	preload("res://tests/godot/test_batch_marker_validation.gd").new().run(support)
	if support.failures.is_empty(): print("PASS: core store, immutable baseline and marker validation")
	else: printerr(support.failure_report())
	quit(0 if support.failures.is_empty() else 1)
