extends SceneTree
func _initialize():
	var source = load("res://client/plugins/source/image_sequence_source/plugin.gd").new()
	var arguments = OS.get_cmdline_user_args()
	var path = arguments[0] if not arguments.is_empty() else ProjectSettings.globalize_path("res://output/part4-demo-task5-20260908/workspace/demo")
	var errors = source.open(path)
	if errors.is_empty() and source.get_frame_count() != 120: errors.append("demo source frame count")
	print(JSON.stringify({"success":errors.is_empty(),"errors":errors,"frames":source.get_frame_count()}))
	source.close()
	quit(0 if errors.is_empty() else 1)
