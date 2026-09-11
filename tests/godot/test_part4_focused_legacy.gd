extends SceneTree
func _init() -> void: call_deferred("_run")
func _run() -> void:
	var support = preload("res://tests/godot/test_support.gd").new()
	await preload("res://tests/godot/test_playback.gd").new().run(support,self)
	print("PLAYBACK DONE ",support.failure_report())
	await preload("res://tests/godot/test_workspace_integration.gd").new().run(support,self)
	if support.failures.is_empty(): print("PASS: Part4 legacy playback/workspace")
	else: print("FAIL: ",support.failure_report())
	quit(0 if support.failures.is_empty() else 1)
