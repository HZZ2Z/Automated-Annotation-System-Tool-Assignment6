extends SceneTree

const PLUGIN_SCRIPT := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var plugin = PLUGIN_SCRIPT.new()
	var ids: Array = plugin.get_tool_descriptors().map(
		func(definition: Dictionary): return StringName(definition.get("id", &""))
	)
	var expected := [
		&"box", &"subtract", &"lasso", &"fill",
		&"paint", &"eraser", &"select", &"match_region", &"model_assist",
	]
	var failures: Array[String] = []
	if ids != expected:
		failures.append("official tool descriptors must retain the seven assignment tools and append Match and Model Assist: %s" % [ids])
	if plugin.set_active_tool(&"nonexistent_tool").is_empty():
		failures.append("an undeclared extension must not be activatable")
	if failures.is_empty():
		print("PASS: delivery exposes seven assignment tools plus Match and Model Assist")
		quit(0)
		return
	push_error("FAIL: delivery tool surface\n%s" % "\n".join(failures))
	quit(1)
