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
		"MainVBox/TopToolbar/Redo",
		"MainVBox/TopToolbar/Export",
		"MainVBox/TopToolbar/PlaybackSpeed",
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer",
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport",
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar",
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/Separator",
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Previous",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Next",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/FrameLabel",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/FpsLabel",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/ZoomOut",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/ZoomIn",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Fit",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/OpacityLabel",
		"MainVBox/TimelinePanel/TimelineColumn/Transport/Opacity",
		"MainVBox/TimelinePanel/TimelineColumn/Timeline",
		"MainVBox/StatusBar",
		"ClassAssignmentDialog",
		"SourceDialog",
		"ExportDialog",
		"VideoImportController",
		"VideoImportDialog",
		"VideoImportDialog/Margin/Content/SourceValue",
		"VideoImportDialog/Margin/Content/OutputRow/OutputParent",
		"VideoImportDialog/Margin/Content/OutputRow/Browse",
		"VideoImportDialog/Margin/Content/DirectoryName",
		"VideoImportDialog/Margin/Content/Progress",
		"VideoImportDialog/Margin/Content/Actions/Start",
		"VideoImportDialog/Margin/Content/Actions/Cancel",
		"VideoOutputParentDialog",
	]:
		support.expect(main.get_node_or_null(node_path) != null, "required node should exist: %s" % node_path)

	for removed_path in [
		"MainVBox/TopToolbar/Undo",
		"MainVBox/TopToolbar/Previous",
		"MainVBox/TopToolbar/PlayPause",
		"MainVBox/TopToolbar/Next",
		"MainVBox/TopToolbar/PlaybackClockLabel",
		"MainVBox/TopToolbar/PlaybackClock",
	]:
		support.expect(main.get_node_or_null(removed_path) == null, "obsolete duplicate UI should be absent: %s" % removed_path)
	support.expect(main.find_child("Undo", true, false) == null,
		"no Undo node should exist anywhere in the main scene")
	for removed_name in [
		"InspectorScroll", "InspectorPanel", "RegionId", "Confidence", "TrackId",
		"BoxX", "BoxY", "BoxWidth", "BoxHeight",
	]:
		support.expect(main.find_child(removed_name, true, false) == null,
			"the mounted Main scene must not retain old Inspector node %s" % removed_name)

	var workspace := main.get_node("MainVBox/WorkspaceSplit") as HSplitContainer
	var content := main.get_node("MainVBox/WorkspaceSplit/ContentSplit") as HSplitContainer
	var explorer_container := main.get_node(
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer"
	) as PanelContainer
	var right_container := main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer"
	) as PanelContainer
	var annotation_sidebar := main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar"
	) as Control
	var tool_panel := main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel"
	)
	support.expect(workspace != null and content != null,
		"workspace should use nested resizable split containers")
	support.expect(explorer_container.custom_minimum_size.x >= 150.0,
		"dataset explorer should retain the current compact-layout minimum width")
	support.expect(right_container.custom_minimum_size.x >= 200.0,
		"right sidebar should retain the current compact-layout minimum width")
	support.expect(annotation_sidebar != null and annotation_sidebar.size_flags_vertical == Control.SIZE_EXPAND_FILL,
		"annotation sidebar should expand vertically and yield fixed space to the tool grid")
	support.expect(tool_panel.get_parent().name == "RightSidebar",
		"ToolPanel should remain below the annotation sidebar separator")
	support.expect(annotation_sidebar != null and tool_panel != null and annotation_sidebar.get_index() < tool_panel.get_index(),
		"annotation sidebar must remain above ToolPanel")
	support.expect(main.get_node_or_null("MainVBox/" + "Workspace/ToolPanel") == null,
		"the obsolete left edit strip should be absent")

	var viewport = main.get_node_or_null("MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	var sidebar = main.get_node_or_null("MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar")
	var class_dialog = main.get_node_or_null("ClassAssignmentDialog")
	var timeline = main.get_node_or_null("MainVBox/TimelinePanel/TimelineColumn/Timeline")
	support.expect(viewport != null and viewport.has_method("set_state") and viewport.has_method("set_renderer"), "workspace should instantiate the real AnnotationViewport API")
	support.expect(sidebar != null and sidebar.has_method("populate") and sidebar.has_method("get_project_rows_snapshot"),
		"workspace should instantiate the real AnnotationSidebar API")
	support.expect(class_dialog != null and class_dialog.has_method("present") and class_dialog.has_method("is_assignment_open"),
		"main root should instantiate the real ClassAssignmentDialog API")
	support.expect(tool_panel != null and tool_panel.has_method("set_active_tool") and tool_panel.has_method("get_active_tool"), "workspace should instantiate the focused ToolPanel API")
	if tool_panel != null and tool_panel.has_method("get_active_tool"):
		support.expect_equal(tool_panel.call("get_active_tool"), &"select", "Select should be the startup tool")
	support.expect(timeline != null and timeline.has_method("configure"), "timeline panel should instantiate the real Timeline API")

	var save_button := main.get_node_or_null("MainVBox/TopToolbar/Save") as Button
	var redo_button := main.get_node_or_null("MainVBox/TopToolbar/Redo") as Button
	var export_button := main.get_node_or_null("MainVBox/TopToolbar/Export") as Button
	support.expect(save_button != null and save_button.visible and save_button.disabled, "Save should remain visible and disabled until persistence is implemented")
	support.expect(redo_button != null and redo_button.visible,
		"Redo should remain visible after the redundant Undo button is removed")
	support.expect(export_button != null and export_button.visible and export_button.disabled, "Export should remain visible and disabled until feedback wiring is implemented")

	var source_plugin = main.call("get_discovered_plugin", "source", "image_sequence_source")
	var single_image_plugin = main.call("get_discovered_plugin", "source", "single_image_source")
	var render_plugin = main.call("get_discovered_plugin", "render", "canvas_region_renderer")
	var edit_plugin = main.call("get_discovered_plugin", "edit", "basic_edit_tools")
	var feedback_plugin = main.call("get_discovered_plugin", "feedback", "file_training_handoff")
	support.expect(source_plugin != null and single_image_plugin != null and render_plugin != null and edit_plugin != null and feedback_plugin != null, "main startup should discover every required plugin stage")
	if viewport != null and render_plugin != null:
		support.expect(viewport.get("_renderer").get_script() == render_plugin.get_script(), "main should inject an instance created from the registry-discovered renderer")
	support.expect(main.get("_feedback_plugin") != null, "main startup should instantiate the configured Feedback plugin")

	var dialog := main.get_node_or_null("SourceDialog") as FileDialog
	support.expect(dialog != null and dialog.file_mode == FileDialog.FILE_MODE_OPEN_ANY, "SourceDialog should accept directories while retaining a file signal")
	support.expect(dialog != null and dialog.access == FileDialog.ACCESS_FILESYSTEM, "SourceDialog should browse the filesystem")
	if dialog != null:
		var filters := " ".join(dialog.filters).to_lower()
		for extension in ["*.png", "*.jpg", "*.jpeg"]:
			support.expect(extension in filters, "SourceDialog should expose %s files" % extension)
		support.expect("*.mp4" in filters, "SourceDialog should expose common video selection for the documented conversion path")
	var export_dialog := main.get_node_or_null("ExportDialog") as FileDialog
	support.expect(export_dialog != null and export_dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR, "ExportDialog should choose a parent for the training handoff package")
	var import_dialog := main.get_node_or_null("VideoImportDialog") as Window
	support.expect(import_dialog != null and import_dialog.exclusive,
		"video import should use a modal window that blocks the underlying editor")
	main.call("_on_file_selected", "/tmp/reviewer-video.mp4")
	support.expect(import_dialog != null and import_dialog.visible,
		"selecting a video should open normalization setup instead of a Source plugin")
	if import_dialog != null:
		var source_value := import_dialog.get_node("Margin/Content/SourceValue") as Label
		support.expect_equal(source_value.text, "/tmp/reviewer-video.mp4",
			"video setup should identify the selected input")
		var parent_value := import_dialog.get_node("Margin/Content/OutputRow/OutputParent") as LineEdit
		support.expect(parent_value.text.is_empty(),
			"the output parent should require an explicit user choice")
		import_dialog.hide()
	support.expect(main.get_node_or_null("PlaybackTimer") == null,
		"frame-accurate playback should not retain the fixed repeating Timer")
	support.expect(main.get("_playback_controller") != null,
		"Main should own the frame-accurate playback controller")
	var playback_speed = main.get_node_or_null("MainVBox/TopToolbar/PlaybackSpeed")
	support.expect(playback_speed != null,
		"the compact playback speed bar should live in the top toolbar")
	if playback_speed != null:
		support.expect_equal(playback_speed.call("get_selected_mode"), &"one_second",
			"the top speed bar should default to one second per frame")
		var speed_summary := playback_speed.get_node("SummaryButton") as Button
		var speed_popup := playback_speed.get_node("AdjustmentPopup") as PopupPanel
		var speed_slider := playback_speed.get_node(
			"AdjustmentPopup/Margin/Content/SpeedSlider") as HSlider
		support.expect(speed_summary.text == "1 s/frame  ▾" and not speed_popup.visible,
			"the toolbar should normally show only its current playback status")
		support.expect(not speed_slider.editable,
			"playback speed should remain disabled until a multi-frame source is open")
	var fps_label := main.get_node_or_null(
		"MainVBox/TimelinePanel/TimelineColumn/Transport/FpsLabel") as Label
	support.expect(fps_label != null and fps_label.text == "FPS --",
		"transport should show a read-only FPS placeholder before a source opens")
	var opacity_label := main.get_node_or_null("MainVBox/TimelinePanel/TimelineColumn/Transport/OpacityLabel") as Label
	support.expect(opacity_label != null and opacity_label.text == "Overlay opacity", "opacity slider should have a persistent visible label")
	var timeline_panel := main.get_node_or_null("MainVBox/TimelinePanel") as PanelContainer
	support.expect(timeline_panel != null and timeline_panel.custom_minimum_size.y > 0.0, "timeline should retain a fixed minimum height")

	main.queue_free()
	await tree.process_frame
