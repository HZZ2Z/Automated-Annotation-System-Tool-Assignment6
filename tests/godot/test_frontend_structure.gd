extends RefCounted


func run(support, tree: SceneTree) -> void:
	support.expect_equal(ProjectSettings.get_setting("application/run/main_scene"), "res://client/app/main.tscn", "project main scene should use the normalized path")
	var packed_scene := load("res://client/app/main.tscn") as PackedScene
	support.expect(packed_scene != null, "normalized main scene should load")
	if packed_scene == null:
		return
	var main := packed_scene.instantiate() as Control
	support.expect(main != null, "normalized main scene should instantiate as Control")
	if main == null:
		return
	tree.root.add_child(main)
	await tree.process_frame
	support.expect_equal(main.name, "Main", "scene root should be named Main")
	support.expect_equal(main.anchors_preset, Control.PRESET_FULL_RECT, "scene root should fill its parent")
	for node_path in [
		"MainVBox/TopToolbar/Open",
		"MainVBox/Workspace/ToolPanel",
		"MainVBox/Workspace/MainSplit/CenterPanel/AnnotationCanvas/ImageView",
		"MainVBox/Workspace/MainSplit/RightPanel/RegionInspector/ClassFreeText",
		"MainVBox/TimelinePanel/TimelineVBox/PlaybackControls",
		"MainVBox/StatusBar",
	]:
		support.expect(main.get_node_or_null(node_path) != null, "required node should exist: %s" % node_path)
	support.expect(main.get_node_or_null("MainVBox/Workspace/ToolPanel/VBoxContainer/Polygon") == null, "Polygon drawing button should be absent")
	var dialog := main.get_node_or_null("OpenFileDialog") as FileDialog
	support.expect(dialog != null, "OpenFileDialog should exist")
	if dialog != null:
		var filters := " ".join(dialog.filters).to_lower()
		for extension in ["*.png", "*.jpg", "*.jpeg"]:
			support.expect(filters.contains(extension), "file filters should include %s" % extension)
	var image_view := main.get_node_or_null("MainVBox/Workspace/MainSplit/CenterPanel/AnnotationCanvas/ImageView") as TextureRect
	var preview_path := "res://tests/godot/.task_1a_preview.png"
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	support.expect_equal(image.save_png(preview_path), OK, "test fixture PNG should be created")
	var load_result: int = main.call("load_image_preview", preview_path)
	support.expect_equal(load_result, OK, "generated 2x2 PNG should load")
	support.expect(image_view.texture != null, "successful preview load should set ImageView texture")
	var status_bar := main.get_node_or_null("MainVBox/StatusBar") as Label
	support.expect(status_bar != null and status_bar.text.contains("task_1a_preview.png") and status_bar.text.contains("2 x 2"), "success status should include filename and dimensions")
	var main_vbox := main.get_node_or_null("MainVBox") as VBoxContainer
	var timeline := main.get_node_or_null("MainVBox/TimelinePanel") as PanelContainer
	support.expect(status_bar != null and status_bar.get_parent() == main_vbox, "StatusBar should be a MainVBox child")
	support.expect(status_bar != null and timeline != null and status_bar.get_index() == timeline.get_index() + 1, "StatusBar should immediately follow TimelinePanel")
	support.expect(status_bar != null and timeline != null and status_bar.get_global_rect().position.y >= timeline.get_global_rect().end.y, "StatusBar should not overlap TimelinePanel")
	var previous_texture := image_view.texture
	var missing_path := "res://tests/godot/missing_task_1a_preview.png"
	var missing_result: int = main.call("load_image_preview", missing_path)
	support.expect(missing_result != OK, "invalid image path should return an error")
	support.expect(image_view.texture == previous_texture, "invalid image path should preserve previous texture")
	support.expect(status_bar != null and status_bar.text == "Cannot load image: missing_task_1a_preview.png", "invalid image path should report concise status")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(preview_path))
	main.queue_free()
