extends SceneTree
const SUPPORT = preload("res://tests/godot/test_support.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var support = SUPPORT.new()
	preload("res://tests/godot/test_annotation_store.gd").run(support)
	preload("res://tests/godot/test_model_output_immutability.gd").run(support)
	await preload("res://tests/godot/test_batch_state.gd").new().run(support)
	preload("res://tests/godot/test_batch_marker_validation.gd").new().run(support)
	if support.failures.is_empty(): print("PASS: legacy store, immutable baseline, batch state and marker validation")
	else: printerr(support.failure_report())
	quit(0 if support.failures.is_empty() else 1)
