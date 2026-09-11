extends SceneTree

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1440,900)
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/part4-ui-capture-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var errors: PackedStringArray = await main.open_source("res://sample/assignment_v1")
	if not errors.is_empty():
		print("FAIL: " + str(errors))
		quit(1)
		return
	main._history.execute(load("res://client/domain/commands/review_frames_command.gd").new([12,13,24,36,72,90],true),main._store)
	await main._flush_workspace_changes()
	main.seek(12)
	await process_frame
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://output/part4-ui")
	DirAccess.make_dir_recursive_absolute(directory)
	root.get_texture().get_image().save_png(directory.path_join("main.png"))
	await main._review_workflow.exports.open()
	main._review_workflow.exports._directory.text = "/tmp/project6-delivery-output"
	await process_frame
	await RenderingServer.frame_post_draw
	var dialog: Window = main._review_workflow.exports._dialog
	dialog.get_texture().get_image().save_png(directory.path_join("export.png"))
	print("UI_CAPTURE " + directory)
	print("GEOMETRY ", main.position, main.size,main.get_combined_minimum_size(),root.content_scale_size,root.get_visible_rect())
	print("VBOX_GEOMETRY ",main.get_node("MainVBox").position,main.get_node("MainVBox").size,main.get_node("MainVBox").get_combined_minimum_size())
	print("TOOLBAR_MIN " + str(main.get_node("MainVBox/TopToolbar").get_combined_minimum_size()))
	await main._review_workflow.exports.cancel_and_drain()
	main.queue_free()
	await process_frame
	quit(0)
