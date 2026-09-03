extends RefCounted


func run(support, tree: SceneTree) -> void:
	support.expect_equal(ProjectSettings.get_setting("application/run/main_scene"), "res://client/app/main.tscn", "project main scene should use the normalized path")
	var packed_scene := load("res://client/app/main.tscn") as PackedScene
	support.expect(packed_scene != null, "main scene should load")
	if packed_scene == null:
		return
	var main := packed_scene.instantiate() as Control
	support.expect(main != null, "main scene should instantiate as Control")
	if main == null:
		return
	tree.root.add_child(main)
	await tree.process_frame

	support.expect_equal(main.name, "Main", "scene root should be named Main")
	support.expect_equal(main.anchors_preset, Control.PRESET_FULL_RECT, "scene root should fill its parent")
	for node_path in [
		"MainVBox/TopToolbar/Open",
		"MainVBox/TopToolbar/Previous",
		"MainVBox/TopToolbar/PlayPause",
		"MainVBox/TopToolbar/Next",
		"MainVBox/TopToolbar/FrameLabel",
		"MainVBox/TopToolbar/TimeLabel",
		"MainVBox/TopToolbar/Spacer",
		"MainVBox/TopToolbar/ZoomOut",
		"MainVBox/TopToolbar/ZoomIn",
		"MainVBox/TopToolbar/Opacity",
		"MainVBox/TopToolbar/Undo",
		"MainVBox/TopToolbar/Redo",
		"MainVBox/Workspace/ViewportPanel/AnnotationViewport",
		"MainVBox/Workspace/InspectorPanelContainer/InspectorColumn/InspectorPanel",
		"MainVBox/Workspace/InspectorPanelContainer/InspectorColumn/AddBox",
		"MainVBox/TimelinePanel/Timeline",
		"MainVBox/StatusBar",
		"SourceDialog",
		"PlaybackTimer",
	]:
		support.expect(main.get_node_or_null(node_path) != null, "required node should exist: %s" % node_path)

	for removed_path in [
		"MainVBox/TopToolbar/Save",
		"MainVBox/TopToolbar/Export",
		"MainVBox/Workspace/ToolPanel",
		"MainVBox/Workspace/MainSplit/CenterPanel/AnnotationCanvas/ImageView",
		"MainVBox/Workspace/MainSplit/RightPanel/RegionInspector",
	]:
		support.expect(main.get_node_or_null(removed_path) == null, "obsolete duplicate UI should be absent: %s" % removed_path)

	var viewport = main.get_node_or_null("MainVBox/Workspace/ViewportPanel/AnnotationViewport")
	var inspector = main.get_node_or_null("MainVBox/Workspace/InspectorPanelContainer/InspectorColumn/InspectorPanel")
	var timeline = main.get_node_or_null("MainVBox/TimelinePanel/Timeline")
	support.expect(viewport != null and viewport.has_method("set_state") and viewport.has_method("set_renderer"), "workspace should instantiate the real AnnotationViewport API")
	support.expect(inspector != null and inspector.has_method("populate"), "workspace should instantiate the real InspectorPanel API")
	support.expect(timeline != null and timeline.has_method("configure"), "timeline panel should instantiate the real Timeline API")

	var source_plugin = main.call("get_discovered_plugin", "source", "image_sequence_source")
	var render_plugin = main.call("get_discovered_plugin", "render", "canvas_region_renderer")
	var edit_plugin = main.call("get_discovered_plugin", "edit", "basic_edit_tools")
	support.expect(source_plugin != null and render_plugin != null and edit_plugin != null, "main startup should discover source, render, and edit plugins")
	if viewport != null and render_plugin != null:
		support.expect(viewport.get("_renderer") == render_plugin, "main should inject the registry-discovered renderer into AnnotationViewport")

	var dialog := main.get_node_or_null("SourceDialog") as FileDialog
	support.expect(dialog != null and dialog.file_mode == FileDialog.FILE_MODE_OPEN_ANY, "SourceDialog should accept directories while retaining a file signal")
	support.expect(dialog != null and dialog.access == FileDialog.ACCESS_FILESYSTEM, "SourceDialog should browse the filesystem")
	var playback_timer := main.get_node_or_null("PlaybackTimer") as Timer
	support.expect(playback_timer != null and playback_timer.one_shot == false and playback_timer.is_stopped(), "PlaybackTimer should start stopped and repeat")
	var inspector_container := main.get_node_or_null("MainVBox/Workspace/InspectorPanelContainer") as PanelContainer
	support.expect(inspector_container != null and inspector_container.custom_minimum_size.x >= 240.0, "inspector should retain the approved minimum width")
	var timeline_panel := main.get_node_or_null("MainVBox/TimelinePanel") as PanelContainer
	support.expect(timeline_panel != null and timeline_panel.custom_minimum_size.y > 0.0, "timeline should retain a fixed minimum height")

	main.queue_free()
	await tree.process_frame
