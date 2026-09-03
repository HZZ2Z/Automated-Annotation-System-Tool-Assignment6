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
		"MainVBox/TopToolbar/Save",
		"MainVBox/TopToolbar/Undo",
		"MainVBox/TopToolbar/Redo",
		"MainVBox/TopToolbar/Export",
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer",
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport",
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/InspectorScroll/InspectorPanel",
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/Separator",
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Previous",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Next",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/FrameLabel",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/TimeLabel",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/ZoomOut",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/ZoomIn",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Opacity",
		"MainVBox/TimelinePanel/TimelineColumn/Timeline",
		"MainVBox/StatusBar",
		"SourceDialog",
		"PlaybackTimer",
	]:
		support.expect(main.get_node_or_null(node_path) != null, "required node should exist: %s" % node_path)

	for removed_path in [
		"MainVBox/TopToolbar/Previous",
		"MainVBox/TopToolbar/PlayPause",
		"MainVBox/TopToolbar/Next",
	]:
		support.expect(main.get_node_or_null(removed_path) == null, "obsolete duplicate UI should be absent: %s" % removed_path)

	var workspace := main.get_node("MainVBox/WorkspaceSplit") as HSplitContainer
	var content := main.get_node("MainVBox/WorkspaceSplit/ContentSplit") as HSplitContainer
	var explorer_container := main.get_node(
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer"
	) as PanelContainer
	var right_container := main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer"
	) as PanelContainer
	var inspector_scroll := main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/InspectorScroll"
	) as ScrollContainer
	var tool_panel := main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel"
	)
	support.expect(workspace != null and content != null,
		"workspace should use nested resizable split containers")
	support.expect(explorer_container.custom_minimum_size.x >= 220.0,
		"dataset explorer should retain its approved minimum width")
	support.expect(right_container.custom_minimum_size.x >= 320.0,
		"right sidebar should retain its approved minimum width")
	support.expect(inspector_scroll.size_flags_vertical == Control.SIZE_EXPAND_FILL,
		"inspector should scroll and yield fixed space to the tool grid")
	support.expect(tool_panel.get_parent().name == "RightSidebar",
		"ToolPanel should sit below the right inspector")
	support.expect(main.get_node_or_null("MainVBox/" + "Workspace/ToolPanel") == null,
		"the obsolete left edit strip should be absent")

	var viewport = main.get_node_or_null("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var inspector = main.get_node_or_null("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/InspectorScroll/InspectorPanel")
	var timeline = main.get_node_or_null("MainVBox/TimelinePanel/TimelineColumn/Timeline")
	support.expect(viewport != null and viewport.has_method("set_state") and viewport.has_method("set_renderer"), "workspace should instantiate the real AnnotationViewport API")
	support.expect(inspector != null and inspector.has_method("populate"), "workspace should instantiate the real InspectorPanel API")
	support.expect(tool_panel != null and tool_panel.has_method("set_active_tool") and tool_panel.has_method("get_active_tool"), "workspace should instantiate the focused ToolPanel API")
	if tool_panel != null and tool_panel.has_method("get_active_tool"):
		support.expect_equal(tool_panel.call("get_active_tool"), &"select", "Select should be the startup tool")
	support.expect(timeline != null and timeline.has_method("configure"), "timeline panel should instantiate the real Timeline API")

	var save_button := main.get_node_or_null("MainVBox/TopToolbar/Save") as Button
	var export_button := main.get_node_or_null("MainVBox/TopToolbar/Export") as Button
	support.expect(save_button != null and save_button.visible and save_button.disabled, "Save should remain visible and disabled until persistence is implemented")
	support.expect(export_button != null and export_button.visible and export_button.disabled, "Export should remain visible and disabled until feedback wiring is implemented")

	var source_plugin = main.call("get_discovered_plugin", "source", "image_sequence_source")
	var single_image_plugin = main.call("get_discovered_plugin", "source", "single_image_source")
	var render_plugin = main.call("get_discovered_plugin", "render", "canvas_region_renderer")
	var edit_plugin = main.call("get_discovered_plugin", "edit", "basic_edit_tools")
	var feedback_plugin = main.call("get_discovered_plugin", "feedback", "file_training_handoff")
	support.expect(source_plugin != null and single_image_plugin != null and render_plugin != null and edit_plugin != null and feedback_plugin != null, "main startup should discover every required plugin stage")
	if viewport != null and render_plugin != null:
		support.expect(viewport.get("_renderer") == render_plugin, "main should inject the registry-discovered renderer into AnnotationViewport")

	var dialog := main.get_node_or_null("SourceDialog") as FileDialog
	support.expect(dialog != null and dialog.file_mode == FileDialog.FILE_MODE_OPEN_ANY, "SourceDialog should accept directories while retaining a file signal")
	support.expect(dialog != null and dialog.access == FileDialog.ACCESS_FILESYSTEM, "SourceDialog should browse the filesystem")
	if dialog != null:
		var filters := " ".join(dialog.filters).to_lower()
		for extension in ["*.png", "*.jpg", "*.jpeg"]:
			support.expect(extension in filters, "SourceDialog should expose %s files" % extension)
		support.expect("*.mp4" in filters, "SourceDialog should expose common video selection for the documented conversion path")
	var playback_timer := main.get_node_or_null("PlaybackTimer") as Timer
	support.expect(playback_timer != null and playback_timer.one_shot == false and playback_timer.is_stopped(), "PlaybackTimer should start stopped and repeat")
	var timeline_panel := main.get_node_or_null("MainVBox/TimelinePanel") as PanelContainer
	support.expect(timeline_panel != null and timeline_panel.custom_minimum_size.y > 0.0, "timeline should retain a fixed minimum height")

	main.queue_free()
	await tree.process_frame
