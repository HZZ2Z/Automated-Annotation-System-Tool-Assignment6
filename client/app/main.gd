class_name AnnotationMain
extends Control

const PLUGIN_REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const SOURCE_FACTORY_SCRIPT := preload("res://client/pipeline/source_factory.gd")
const SOURCE_SESSION_BUILDER_SCRIPT := preload(
	"res://client/pipeline/source_session_builder.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const PLAYBACK_CONTROLLER_SCRIPT := preload("res://client/services/playback_controller.gd")
const PLAYBACK_FPS_METER_SCRIPT := preload("res://client/services/playback_fps_meter.gd")
const VIEWPORT_TRANSFORM_SCRIPT := preload("res://client/services/viewport_transform.gd")
const PROJECT_CLASS_CATALOG_SCRIPT := preload("res://client/domain/project_class_catalog.gd")
const CLASS_COLOR_RESOLVER_SCRIPT := preload("res://client/domain/class_color_resolver.gd")
const WORKSPACE_CATALOG_SCRIPT := preload("res://client/workspace/workspace_catalog.gd")
const WORKSPACE_MEDIA_CONTROLLER_SCRIPT := preload("res://client/workspace/workspace_media_controller.gd")
const MEDIA_LABEL_STORE_SCRIPT := preload("res://client/workspace/media_label_store.gd")
const WORKSPACE_SESSION_SCRIPT := preload("res://client/workspace/workspace_session.gd")
const WORKSPACE_PATHS_SCRIPT := preload("res://client/workspace/workspace_paths.gd")
const CHOLECT50_LABEL_ADAPTER_SCRIPT := preload("res://client/workspace/cholect50_label_adapter.gd")
const TAXONOMY_PATH := "res://core/taxonomy/classes.json"
const MAX_STATUS_LENGTH := 180
const ZOOM_FACTOR := 1.2
const PLAYBACK_CLOCK_REVIEW := &"review"
const PLAYBACK_CLOCK_MAX := &"max"
const PLAYBACK_SPEED_CUSTOM := &"custom"
const PLAYBACK_SPEED_THREE_SECONDS := &"three_seconds"
const PLAYBACK_SPEED_ONE_SECOND := &"one_second"
const PLAYBACK_SPEED_MAX := &"max"
const DEFAULT_SECONDS_PER_FRAME := 1.0
const VIDEO_EXTENSIONS := {
	"avi": true, "m4v": true, "mkv": true, "mov": true, "mp4": true,
	"mpeg": true, "mpg": true, "webm": true,
}
const IMAGE_EXTENSIONS := {"jpeg": true, "jpg": true, "png": true}


class StagedEditContextBridge:
	extends RefCounted
	signal edit_cancel_requested

	var _main_ref: WeakRef
	var _viewport_ref: WeakRef
	var _live := false
	var _staged_selection := ""
	var _staged_record: Dictionary = {}
	var _staged_viewport_selection := ""
	var _staged_overlay: Dictionary = {}
	var _staged_class_requests: Array[Dictionary] = []
	var _staged_transform: Variant
	var _staged_image: Image
	var _staged_edit_state := {
		"phase": &"idle",
		"navigation_blocked": false,
		"message": "",
	}

	func _init(main: AnnotationMain, viewport: Variant, staged_texture: Texture2D) -> void:
		_main_ref = weakref(main)
		_viewport_ref = weakref(viewport)
		var source_transform: Variant = viewport.get_image_transform() if viewport != null else null
		var image: Variant = staged_texture.get_image() if staged_texture != null else null
		if not image is Image and viewport != null:
			image = viewport.get_current_image()
		_staged_image = image.duplicate() if image is Image else null
		_staged_transform = _candidate_transform(source_transform, _staged_image)

	func get_current_frame() -> int:
		var main := _main_ref.get_ref() as AnnotationMain
		return main._current_record_frame() if _live and main != null else 0

	func get_selected_region() -> String:
		var main := _main_ref.get_ref() as AnnotationMain
		return main._get_selected_region_id() if _live and main != null else _staged_selection

	func set_selected_region(region_id: String) -> void:
		var main := _main_ref.get_ref() as AnnotationMain
		if _live and main != null:
			main._set_selected_region(region_id)
		else:
			_staged_selection = region_id

	func edit_state_changed(state: Dictionary) -> void:
		var snapshot := state.duplicate(true)
		var main := _main_ref.get_ref() as AnnotationMain
		if _live and main != null:
			main._on_edit_state_changed(snapshot)
		else:
			_staged_edit_state = snapshot

	func set_record(record: Dictionary) -> void:
		var viewport = _live_viewport()
		if viewport != null:
			viewport.set_record(record.duplicate(true))
		else:
			_staged_record = record.duplicate(true)

	func set_selected_region_id(region_id: String) -> void:
		var viewport = _live_viewport()
		if viewport != null:
			viewport.set_selected_region_id(region_id)
		else:
			_staged_viewport_selection = region_id

	func get_image_transform():
		var viewport = _live_viewport()
		return viewport.get_image_transform() if viewport != null else _staged_transform

	func get_current_image():
		var viewport = _live_viewport()
		if viewport != null:
			return viewport.get_current_image()
		return _staged_image.duplicate() if _staged_image != null else null

	func set_edit_overlay(state: Dictionary) -> void:
		var viewport = _live_viewport()
		if viewport != null:
			viewport.set_edit_overlay(state.duplicate(true))
		else:
			_staged_overlay = state.duplicate(true)

	func clear_edit_overlay() -> void:
		var viewport = _live_viewport()
		if viewport != null:
			viewport.clear_edit_overlay()
		else:
			_staged_overlay.clear()

	func request_class_assignment(request: Dictionary) -> void:
		var snapshot := request.duplicate(true)
		var main := _main_ref.get_ref() as AnnotationMain
		if _live and main != null:
			main._on_new_region_class_requested(snapshot)
		else:
			_staged_class_requests.append(snapshot)

	func switch_to_live() -> void:
		var class_requests := _staged_class_requests.duplicate(true)
		_staged_class_requests.clear()
		_staged_selection = ""
		_staged_record.clear()
		_staged_viewport_selection = ""
		_staged_overlay.clear()
		_live = true
		var viewport = _live_viewport()
		if viewport != null:
			var callback := Callable(self, "_forward_edit_cancel_requested")
			if not viewport.is_connected("edit_cancel_requested", callback):
				viewport.connect("edit_cancel_requested", callback)
		var main := _main_ref.get_ref() as AnnotationMain
		if main != null:
			main._on_edit_state_changed(_staged_edit_state.duplicate(true))
			for request: Dictionary in class_requests:
				main._on_new_region_class_requested(request)

	func detach() -> void:
		var viewport = _viewport_ref.get_ref()
		if viewport != null:
			var callback := Callable(self, "_forward_edit_cancel_requested")
			if viewport.is_connected("edit_cancel_requested", callback):
				viewport.disconnect("edit_cancel_requested", callback)
		_staged_class_requests.clear()
		_live = false

	func _live_viewport():
		if not _live:
			return null
		return _viewport_ref.get_ref()

	func _forward_edit_cancel_requested() -> void:
		edit_cancel_requested.emit()

	func _candidate_transform(source: Variant, image: Image):
		var result = VIEWPORT_TRANSFORM_SCRIPT.new()
		if image == null:
			return result
		var viewport_rect := Rect2()
		if source != null and source.has_method("is_configured") and source.is_configured():
			viewport_rect = source.viewport_rect
		var viewport = _viewport_ref.get_ref()
		if viewport_rect.size.x <= 0.0 and viewport != null:
			viewport_rect = Rect2(Vector2.ZERO, viewport.size)
		result.configure(Vector2(image.get_width(), image.get_height()), viewport_rect)
		return result


@export var plugin_roots := PackedStringArray(["res://client/plugins"])
@export var source_plugin_id := ""
@export var render_plugin_id := "canvas_region_renderer"
@export var edit_plugin_id := "basic_edit_tools"
@export var feedback_plugin_id := "file_training_handoff"

@onready var _open_button: Button = $MainVBox/TopToolbar/Open
@onready var _export_button: Button = $MainVBox/TopToolbar/Export
@onready var _redo_button: Button = $MainVBox/TopToolbar/Redo
@onready var _dataset_explorer = $MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer
@onready var _viewport = $MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport
@onready var _annotation_sidebar = $MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/AnnotationSidebar
@onready var _tool_panel = $MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel
@onready var _previous_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/Previous
@onready var _play_pause_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause
@onready var _next_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/Next
@onready var _frame_label: Label = $MainVBox/TimelinePanel/TimelineColumn/Transport/FrameLabel
@onready var _fps_label: Label = $MainVBox/TimelinePanel/TimelineColumn/Transport/FpsLabel
@onready var _playback_speed = $MainVBox/TopToolbar/PlaybackSpeed
@onready var _zoom_out_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/ZoomOut
@onready var _zoom_in_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/ZoomIn
@onready var _fit_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/Fit
@onready var _opacity_slider: HSlider = $MainVBox/TimelinePanel/TimelineColumn/Transport/Opacity
@onready var _timeline = $MainVBox/TimelinePanel/TimelineColumn/Timeline
@onready var _status_bar: Label = $MainVBox/StatusBar
@onready var _class_dialog = $ClassAssignmentDialog
@onready var _source_dialog: FileDialog = $SourceDialog
@onready var _export_dialog: FileDialog = $ExportDialog
@onready var _video_import_controller = $VideoImportController
@onready var _video_import_dialog: Window = $VideoImportDialog
@onready var _video_output_parent_dialog: FileDialog = $VideoOutputParentDialog
@onready var _video_import_source: Label = $VideoImportDialog/Margin/Content/SourceValue
@onready var _video_import_parent: LineEdit = $VideoImportDialog/Margin/Content/OutputRow/OutputParent
@onready var _video_import_browse: Button = $VideoImportDialog/Margin/Content/OutputRow/Browse
@onready var _video_import_name: LineEdit = $VideoImportDialog/Margin/Content/DirectoryName
@onready var _video_import_progress: ProgressBar = $VideoImportDialog/Margin/Content/Progress
@onready var _video_import_status: Label = $VideoImportDialog/Margin/Content/Status
@onready var _video_import_start: Button = $VideoImportDialog/Margin/Content/Actions/Start
@onready var _video_import_cancel: Button = $VideoImportDialog/Margin/Content/Actions/Cancel

var _plugin_registry = PLUGIN_REGISTRY_SCRIPT.new()
var _source_factory = SOURCE_FACTORY_SCRIPT.new(_plugin_registry)
var _source_session_builder = SOURCE_SESSION_BUILDER_SCRIPT.new()
var _source: Variant
var _store = STORE_SCRIPT.new()
var _history = HISTORY_SCRIPT.new(200)
var _playback_controller = PLAYBACK_CONTROLLER_SCRIPT.new()
var _playback_fps_meter = PLAYBACK_FPS_METER_SCRIPT.new()
var _edit_plugin: Variant
var _edit_context_bridge: Variant
var _render_plugin: Variant
var _feedback_plugin: Variant
var _manifest: Dictionary = {}
var _taxonomy: Dictionary = {}
var _class_catalog = PROJECT_CLASS_CATALOG_SCRIPT.new()
var _color_resolver = CLASS_COLOR_RESOLVER_SCRIPT.new()
var _current_frame := -1
var _selected_region_id := ""
var _class_dialog_mode: StringName = &""
var _class_dialog_region_id := ""
var _class_dialog_token := -1
var _class_dialog_action_in_progress := false
var _syncing_sidebar_selection := false
var _pending_video_path := ""
var _selected_video_output_parent := ""
var _workspace_catalog = WORKSPACE_CATALOG_SCRIPT.new()
var _workspace_root := ""
var _workspace_media_id := ""
var _workspace_label_store: Variant
var _workspace_media_controller: Variant
var _workspace_session: Variant
var _workspace_import_active := false
var _edit_state := {
	"phase": &"idle",
	"navigation_blocked": false,
	"message": "",
}


func _ready() -> void:
	_connect_ui()
	_setup_workspace_services()
	_taxonomy = _read_taxonomy()
	_color_resolver = CLASS_COLOR_RESOLVER_SCRIPT.new(_taxonomy)
	var plugin_errors: PackedStringArray = _plugin_registry.discover_roots(plugin_roots)
	if not plugin_errors.is_empty():
		_set_status("Plugin discovery: %s" % plugin_errors[0])
	var edit_catalog = _plugin_registry.create_plugin("edit", edit_plugin_id)
	var tool_errors := PackedStringArray()
	var tool_descriptors := _read_tool_descriptors(edit_catalog, tool_errors)
	if tool_errors.is_empty():
		tool_errors = _tool_panel.configure_tools(tool_descriptors)
	if not tool_errors.is_empty():
		_set_status("Edit tools: %s" % tool_errors[0])
	_render_plugin = _plugin_registry.create_plugin("render", render_plugin_id)
	if _render_plugin != null:
		_viewport.set_renderer(_render_plugin)
	else:
		_set_status("Configured render plugin is unavailable: %s" % render_plugin_id)
	_feedback_plugin = _plugin_registry.create_plugin("feedback", feedback_plugin_id)
	if _feedback_plugin == null:
		_set_status("Configured Feedback plugin is unavailable: %s" % feedback_plugin_id)
	_timeline.configure(0)
	_refresh_annotation_sidebar()
	_refresh_labels()
	_refresh_toolbar()


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if _is_class_dialog_active():
		# The modal dialog and its LineEdits own Enter, Escape, and text editing.
		# In particular, Ctrl+Z must never reach global Store history here.
		return
	var key: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	if event.ctrl_pressed and key == KEY_Z:
		if event.shift_pressed:
			_run_history_redo()
		else:
			_run_history_undo()
		get_viewport().set_input_as_handled()
		return
	elif event.ctrl_pressed and key == KEY_Y:
		_run_history_redo()
		get_viewport().set_input_as_handled()
		return
	# Focused canvas arrows are otherwise consumed by Control focus navigation
	# before _unhandled_key_input.  Main only forwards them; the Edit plugin
	# remains the sole owner of tool, modal, and spatial-key semantics.
	if is_instance_valid(_viewport) and get_viewport().gui_get_focus_owner() == _viewport:
		if _route_edit_key(event):
			get_viewport().set_input_as_handled()


func get_discovered_plugin(stage: String, plugin_id: String) -> RefCounted:
	return _plugin_registry.create_plugin(stage, plugin_id)


func open_workspace(path: String) -> PackedStringArray:
	if _is_class_dialog_active():
		return _modal_refusal("Workspace replacement")
	if _workspace_media_controller != null and _workspace_media_controller.is_busy():
		var busy_errors := PackedStringArray([
			"Wait for the selected video to finish preparing or cancel it first"])
		_show_errors("Cannot open workspace", busy_errors)
		return busy_errors
	var candidate = WORKSPACE_CATALOG_SCRIPT.new()
	var errors: PackedStringArray = candidate.scan(path)
	if not errors.is_empty():
		_show_errors("Cannot open workspace", errors)
		return errors
	errors = _flush_workspace_changes()
	if not errors.is_empty():
		_show_errors("Cannot replace workspace", errors)
		return errors
	_clear_active_source()
	_workspace_catalog = candidate
	_workspace_root = candidate.get_root()
	_workspace_media_controller.configure(
		_workspace_root, _video_import_controller, _source_factory)
	_dataset_explorer.populate_workspace(candidate.get_view_model())
	_set_status("Workspace opened: %s" % _workspace_root)
	_refresh_toolbar()
	return PackedStringArray()


func _setup_workspace_services() -> void:
	_workspace_media_controller = WORKSPACE_MEDIA_CONTROLLER_SCRIPT.new()
	add_child(_workspace_media_controller)
	_workspace_media_controller.media_ready.connect(_on_workspace_media_ready)
	_workspace_media_controller.media_failed.connect(_on_workspace_media_failed)
	_workspace_media_controller.import_started.connect(_on_workspace_import_started)
	_workspace_media_controller.import_progress.connect(_on_workspace_import_progress)
	_workspace_media_controller.import_cancelled.connect(_on_workspace_import_cancelled)
	_workspace_session = WORKSPACE_SESSION_SCRIPT.new()
	add_child(_workspace_session)


func _on_workspace_media_requested(media_id_value: String) -> void:
	if _is_class_dialog_active():
		_modal_refusal("Media selection")
		return
	if _workspace_root.is_empty():
		_set_status("Open a workspace folder before selecting media")
		return
	if media_id_value == _workspace_media_id and _source != null:
		_dataset_explorer.select_media(media_id_value)
		return
	var entry: Dictionary = _workspace_catalog.get_entry(media_id_value)
	if entry.is_empty():
		_set_status("Workspace media is no longer available: %s" % media_id_value)
		return
	var persistence_errors := _flush_workspace_changes()
	if not persistence_errors.is_empty():
		_show_errors("Cannot change media", persistence_errors)
		return
	pause()
	var errors: PackedStringArray = _workspace_media_controller.select_media(entry)
	if not errors.is_empty():
		_show_errors("Cannot open media", errors)


func _on_workspace_media_ready(payload: Dictionary) -> void:
	_workspace_import_active = false
	var source: Variant = payload.get("source")
	var media_value: Variant = payload.get("media_entry")
	if not source is Object or source == null or not media_value is Dictionary:
		if source is Object and source != null and source.has_method("close"):
			source.close()
		_set_status("Cannot open media: workspace controller returned invalid data")
		_refresh_toolbar()
		return
	var errors := _activate_workspace_media(source, media_value as Dictionary)
	if not errors.is_empty():
		_show_errors("Cannot open media", errors)
	_refresh_toolbar()


func _activate_workspace_media(
	candidate: Variant,
	media_entry: Dictionary
) -> PackedStringArray:
	var snapshot: Dictionary = _source_session_builder.build(candidate, false)
	var errors_value: Variant = snapshot.get("errors")
	var errors: PackedStringArray = (
		PackedStringArray(errors_value)
		if errors_value is PackedStringArray
		else PackedStringArray([
			"Source session builder errors must be PackedStringArray"]))
	if not errors.is_empty():
		candidate.close()
		return errors
	var candidate_manifest := (snapshot["manifest"] as Dictionary).duplicate(true)
	var source_records := (snapshot["records"] as Array).duplicate(true)
	var frame_entries := (snapshot["frame_entries"] as Array).duplicate(true)
	var playback_frames := (snapshot["playback_frames"] as Array).duplicate(true)
	var first_texture := snapshot["first_texture"] as Texture2D
	var frame_count := frame_entries.size()
	for playback_index in range(frame_count):
		var frame_id := int((frame_entries[playback_index] as Dictionary)["frame_id"])
		if frame_id > 999999:
			errors.append(
				"Workspace frame %d original frame ID exceeds six digits"
				% playback_index)
			break
	if not errors.is_empty():
		candidate.close()
		return errors
	var nominal_fps: Variant = candidate_manifest["nominal_fps"]
	candidate_manifest["dataset_id"] = media_entry["media_id"]
	candidate_manifest["source_name"] = media_entry["display_name"]
	candidate_manifest["source_sha256"] = media_entry.get("source_sha256")
	var seed_result := _workspace_seed_records(
		source_records,
		candidate_manifest,
		media_entry,
		frame_entries,
		first_texture,
	)
	var seed_errors: PackedStringArray = seed_result.get("errors", PackedStringArray())
	if not seed_errors.is_empty():
		candidate.close()
		return seed_errors

	var candidate_label_store = MEDIA_LABEL_STORE_SCRIPT.new()
	errors = candidate_label_store.prepare(
		_workspace_root,
		media_entry,
		frame_entries,
		seed_result.get("records", []),
	)
	if not errors.is_empty():
		candidate.close()
		return errors
	if candidate_label_store.has_pending_changes():
		errors = candidate_label_store.flush()
		if not errors.is_empty():
			candidate.close()
			return errors

	var candidate_store = STORE_SCRIPT.new()
	errors = candidate_store.load_model_records(
		candidate_label_store.all_display_records())
	if not errors.is_empty() or candidate_store.get_frame_count() != frame_count:
		candidate.close()
		return errors if not errors.is_empty() else PackedStringArray([
			"Workspace label frame count does not match selected media"])
	var first_frame_id: int = frame_entries[0]["frame_id"]
	var first_record: Dictionary = candidate_store.get_corrected_record(first_frame_id)
	if first_record.is_empty():
		candidate.close()
		return PackedStringArray(["Workspace first annotation record is invalid"])

	var candidate_catalog = PROJECT_CLASS_CATALOG_SCRIPT.new()
	errors = candidate_catalog.rebuild(candidate_store.snapshot_corrected())
	var candidate_playback = PLAYBACK_CONTROLLER_SCRIPT.new()
	if errors.is_empty():
		errors = candidate_playback.configure(playback_frames, float(nominal_fps))
	if errors.is_empty():
		errors = candidate_playback.set_clock(
			PLAYBACK_CLOCK_REVIEW, 1.0 / DEFAULT_SECONDS_PER_FRAME)
	var render_candidate = _plugin_registry.create_plugin("render", render_plugin_id)
	var edit_candidate = _plugin_registry.create_plugin("edit", edit_plugin_id)
	if render_candidate == null:
		errors.append("Configured render plugin is unavailable: %s" % render_plugin_id)
	if edit_candidate == null:
		errors.append("Configured edit plugin is unavailable: %s" % edit_plugin_id)
	var tool_descriptors: Array[Dictionary] = []
	if errors.is_empty():
		tool_descriptors = _read_tool_descriptors(edit_candidate, errors)
	if errors.is_empty():
		errors = _tool_panel.validate_tools(tool_descriptors)
	if not errors.is_empty():
		candidate.close()
		return errors

	var candidate_history = HISTORY_SCRIPT.new(200)
	var context_bridge := StagedEditContextBridge.new(self, _viewport, first_texture)
	var edit_result: Variant = edit_candidate.activate(
		_edit_context(candidate_store, candidate_history, context_bridge))
	var edit_errors: PackedStringArray = (
		edit_result if edit_result is PackedStringArray else PackedStringArray([
			"Edit plugin activate must return PackedStringArray"]))
	if not edit_errors.is_empty():
		_deactivate_edit(edit_candidate)
		context_bridge.detach()
		candidate.close()
		return edit_errors
	if not _prepare_edit_navigation():
		_deactivate_edit(edit_candidate)
		context_bridge.detach()
		candidate.close()
		return PackedStringArray([_edit_navigation_message()])
	errors = _flush_workspace_changes()
	if not errors.is_empty():
		_deactivate_edit(edit_candidate)
		context_bridge.detach()
		candidate.close()
		return errors

	pause()
	_unbind_workspace_session()
	_deactivate_edit(_edit_plugin)
	_detach_edit_context_bridge(_edit_context_bridge)
	if _source != null:
		_source.close()
	_source = candidate
	_store = candidate_store
	_history = candidate_history
	_playback_controller = candidate_playback
	_playback_fps_meter.stop()
	_playback_speed.select_mode(
		PLAYBACK_SPEED_ONE_SECOND, DEFAULT_SECONDS_PER_FRAME, false)
	_edit_plugin = edit_candidate
	_edit_context_bridge = context_bridge
	_render_plugin = render_candidate
	_class_catalog = candidate_catalog
	_color_resolver = CLASS_COLOR_RESOLVER_SCRIPT.new(_taxonomy)
	_manifest = candidate_manifest.duplicate(true)
	_workspace_media_id = media_entry["media_id"]
	_workspace_label_store = candidate_label_store
	_current_frame = 0
	_selected_region_id = ""
	_viewport.set_renderer(_render_plugin)
	_viewport.set_edit_selection_authoritative(true)
	_tool_panel.configure_tools(tool_descriptors)
	context_bridge.switch_to_live()
	_timeline.configure(frame_count)
	_viewport.set_state(first_texture, first_record, "", _opacity_slider.value)
	_clear_annotation_hover()
	_refresh_annotation_sidebar()
	_refresh_labels(frame_entries[0])
	_workspace_session.bind(
		_store,
		_workspace_label_store,
		Callable(self, "pause"),
		Callable(self, "_set_status"),
	)
	_dataset_explorer.select_media(_workspace_media_id)
	_set_status("Loaded %s (%d frames)" % [_workspace_media_id, frame_count])
	return PackedStringArray()


func _workspace_seed_records(
	source_records: Array,
	source_manifest: Dictionary,
	media_entry: Dictionary,
	frame_entries: Array,
	first_texture: Texture2D
) -> Dictionary:
	var label_root := String(media_entry.get("label_root", _workspace_root))
	var native_path := WORKSPACE_PATHS_SCRIPT.label_path(
		label_root, media_entry["media_id"])
	if FileAccess.file_exists(native_path):
		return {"records": [], "errors": PackedStringArray()}
	var source_label_path := label_root.path_join(
		"labels/%s.json" % media_entry["media_id"])
	if FileAccess.file_exists(source_label_path):
		var frame_ids := PackedInt64Array()
		for entry_value: Variant in frame_entries:
			frame_ids.append(int((entry_value as Dictionary)["frame_id"]))
		var adapter = CHOLECT50_LABEL_ADAPTER_SCRIPT.new()
		return adapter.read(
			source_label_path,
			media_entry["media_id"],
			frame_ids,
			Vector2(first_texture.get_width(), first_texture.get_height()),
		)
	if source_manifest.get("model_version", "none") == "none":
		return {"records": [], "errors": PackedStringArray()}
	if source_records.size() != frame_entries.size():
		return {
			"records": [],
			"errors": PackedStringArray([
				"Workspace model output does not match selected media frames"]),
		}
	var records: Array[Dictionary] = []
	for index in range(source_records.size()):
		if not source_records[index] is Dictionary:
			return {
				"records": [],
				"errors": PackedStringArray([
					"Workspace model output record %d is invalid" % index]),
			}
		var record := (source_records[index] as Dictionary).duplicate(true)
		var frame_entry := frame_entries[index] as Dictionary
		record["source"] = media_entry["media_id"]
		record["frame"] = frame_entry["frame_id"]
		record["time_s"] = frame_entry["time_s"]
		records.append(record)
	return {"records": records, "errors": PackedStringArray()}


func _on_workspace_media_failed(message: String) -> void:
	_workspace_import_active = false
	_set_status("Cannot open media: %s" % message)
	_refresh_toolbar()


func _on_workspace_import_started(_input_path: String, _output_path: String) -> void:
	_workspace_import_active = true
	_set_status("Preparing selected video…")
	_refresh_toolbar()


func _on_workspace_import_progress(payload: Dictionary) -> void:
	var completed := int(payload.get("completed", 0))
	var total := int(payload.get("total", 1))
	_set_status("Preparing video: %s — %d/%d" % [
		str(payload.get("message", "Working")), completed, total])


func _on_workspace_import_cancelled() -> void:
	_workspace_import_active = false
	_set_status("Video preparation cancelled; current media unchanged")
	_refresh_toolbar()


func open_source(path: String) -> PackedStringArray:
	if _is_class_dialog_active():
		return _modal_refusal("Source replacement")
	var candidate_errors := PackedStringArray()
	if not source_plugin_id.is_empty() and _plugin_registry.get_descriptor("source", source_plugin_id) == null:
		candidate_errors.append("Configured source plugin is unavailable: %s" % source_plugin_id)
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var source_result: Dictionary = _source_factory.open(path, source_plugin_id)
	var routed_source_plugin_id := String(source_result.get("plugin_id", ""))
	var result_errors: Variant = source_result.get("errors")
	if result_errors is PackedStringArray:
		candidate_errors = PackedStringArray(result_errors)
	else:
		candidate_errors.append("Source factory errors must be PackedStringArray")
	if not candidate_errors.is_empty():
		if routed_source_plugin_id.is_empty() and "No source plugin accepts" in candidate_errors[0]:
			candidate_errors[0] += "; normalize video with python/frame_source.py"
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var candidate: Variant = source_result.get("source")
	var render_candidate = _plugin_registry.create_plugin("render", render_plugin_id)
	var candidate_edit = _plugin_registry.create_plugin("edit", edit_plugin_id)
	if candidate == null:
		candidate_errors.append(
			"Source factory returned no opened Source: %s" % routed_source_plugin_id)
	if render_candidate == null:
		candidate_errors.append("Configured render plugin is unavailable: %s" % render_plugin_id)
	if candidate_edit == null:
		candidate_errors.append("Configured edit plugin is unavailable: %s" % edit_plugin_id)
	if not candidate_errors.is_empty():
		if candidate != null:
			candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var candidate_tool_descriptors := _read_tool_descriptors(candidate_edit, candidate_errors)
	if candidate_errors.is_empty():
		candidate_errors = _tool_panel.validate_tools(candidate_tool_descriptors)
	if not candidate_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors

	var snapshot: Dictionary = _source_session_builder.build(candidate, true)
	var snapshot_errors: Variant = snapshot.get("errors")
	if snapshot_errors is PackedStringArray:
		candidate_errors = PackedStringArray(snapshot_errors)
	else:
		candidate_errors.append(
			"Source session builder errors must be PackedStringArray")
	if not candidate_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var candidate_manifest := (snapshot["manifest"] as Dictionary).duplicate(true)
	var records_value := (snapshot["records"] as Array).duplicate(true)
	var frame_entries := (snapshot["frame_entries"] as Array).duplicate(true)
	var candidate_playback_frames := (
		(snapshot["playback_frames"] as Array).duplicate(true))
	var first_texture := snapshot["first_texture"] as Texture2D
	var candidate_explorer_view_model := (
		(snapshot["presentation"] as Dictionary).duplicate(true))
	var candidate_frame_count := frame_entries.size()

	var candidate_store = STORE_SCRIPT.new()
	var store_errors: PackedStringArray = candidate_store.load_model_records(records_value)
	if not store_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", store_errors)
		return store_errors
	if candidate_store.get_frame_count() != candidate_frame_count:
		candidate_errors.append("Source model record count must match the manifest frame count")
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var first_entry := (frame_entries[0] as Dictionary).duplicate(true)
	var first_frame_id := int(first_entry["frame_id"])
	var first_record: Dictionary = candidate_store.get_corrected_record(first_frame_id)
	if first_record.is_empty():
		candidate_errors.append("Source plugin first annotation record is invalid")
	var candidate_catalog = PROJECT_CLASS_CATALOG_SCRIPT.new()
	if candidate_errors.is_empty():
		candidate_errors.append_array(candidate_catalog.rebuild(candidate_store.snapshot_corrected()))
	if candidate_errors.is_empty():
		candidate_errors.append_array(
			_dataset_explorer.validate_view_model(candidate_explorer_view_model))
	if not candidate_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var candidate_color_resolver = CLASS_COLOR_RESOLVER_SCRIPT.new(_taxonomy)
	var candidate_playback_controller = PLAYBACK_CONTROLLER_SCRIPT.new()
	if candidate_errors.is_empty():
		candidate_errors.append_array(candidate_playback_controller.configure(
			candidate_playback_frames, float(candidate_manifest.get("nominal_fps", 0.0))))
	if candidate_errors.is_empty():
		candidate_errors.append_array(candidate_playback_controller.set_clock(
			PLAYBACK_CLOCK_REVIEW, 1.0 / DEFAULT_SECONDS_PER_FRAME))
	if not candidate_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors

	var candidate_history = HISTORY_SCRIPT.new(200)
	var candidate_context_bridge := StagedEditContextBridge.new(self, _viewport, first_texture)
	var edit_result: Variant = candidate_edit.activate(_edit_context(candidate_store, candidate_history, candidate_context_bridge))
	var edit_errors := PackedStringArray()
	if edit_result is PackedStringArray:
		edit_errors = edit_result
	else:
		edit_errors.append("Edit plugin activate must return PackedStringArray")
	if not edit_errors.is_empty():
		_deactivate_edit(candidate_edit)
		candidate_context_bridge.detach()
		candidate.close()
		_show_errors("Cannot open source", edit_errors)
		return edit_errors
	if not _prepare_edit_navigation():
		_deactivate_edit(candidate_edit)
		candidate_context_bridge.detach()
		candidate.close()
		candidate_errors.append(_edit_navigation_message())
		return candidate_errors
	var persistence_errors := _flush_workspace_changes()
	if not persistence_errors.is_empty():
		_deactivate_edit(candidate_edit)
		candidate_context_bridge.detach()
		candidate.close()
		_show_errors("Cannot replace source", persistence_errors)
		return persistence_errors

	pause()
	_unbind_workspace_session()
	_deactivate_edit(_edit_plugin)
	_detach_edit_context_bridge(_edit_context_bridge)
	if _source != null:
		_source.close()
	_source = candidate
	_store = candidate_store
	_history = candidate_history
	_playback_controller = candidate_playback_controller
	_playback_fps_meter.stop()
	_playback_speed.select_mode(
		PLAYBACK_SPEED_ONE_SECOND, DEFAULT_SECONDS_PER_FRAME, false)
	_edit_plugin = candidate_edit
	_edit_context_bridge = candidate_context_bridge
	_render_plugin = render_candidate
	_class_catalog = candidate_catalog
	_color_resolver = candidate_color_resolver
	_viewport.set_renderer(_render_plugin)
	_viewport.set_edit_selection_authoritative(true)
	_tool_panel.configure_tools(candidate_tool_descriptors)
	_manifest = candidate_manifest.duplicate(true)
	_workspace_root = ""
	_workspace_media_id = ""
	_workspace_label_store = null
	_current_frame = 0
	_selected_region_id = ""
	candidate_context_bridge.switch_to_live()
	_timeline.configure(candidate_frame_count)
	_viewport.set_state(first_texture, first_record, "", _opacity_slider.value)
	_clear_annotation_hover()
	_refresh_annotation_sidebar()
	_refresh_labels(first_entry)
	_refresh_toolbar()
	_set_status("Loaded %s (%d frames)" % [str(_manifest.get("dataset_id", "dataset")), candidate_frame_count])
	_dataset_explorer.populate(candidate_explorer_view_model)
	_dataset_explorer.select_frame(0)
	return PackedStringArray()


func set_frame(index: int) -> bool:
	if _is_class_dialog_active():
		_modal_refusal("Frame change")
		return false
	var frame_count := _active_frame_count()
	if _source == null or index < 0 or index >= frame_count:
		return false
	var texture_value: Variant = _source.load_texture(index)
	var texture: Texture2D = texture_value if texture_value is Texture2D else null
	var entry_value: Variant = _source.get_frame_entry(index)
	var entry: Dictionary = entry_value.duplicate(true) if entry_value is Dictionary else {}
	var record_frame := _record_frame_for_playback(index, entry)
	var record: Dictionary = _store.get_corrected_record(record_frame)
	if texture == null or record.is_empty() or entry.is_empty() or record_frame < 0:
		_set_status("Frame %d could not be loaded" % index)
		return false
	var entry_frame: Variant = entry.get("frame")
	var entry_time: Variant = entry.get("time_s")
	if (
		not _logical_integer(entry_frame)
		or int(entry_frame) != index
		or not _finite_non_negative(entry_time)
		or record.get("frame") != record_frame
	):
		_set_status("Frame %d metadata is invalid" % index)
		return false
	if not _prepare_edit_navigation():
		return false
	_current_frame = index
	_selected_region_id = ""
	_viewport.set_state(texture, record, "", _opacity_slider.value)
	_clear_annotation_hover()
	_refresh_annotation_sidebar()
	_timeline.set_current_frame(index)
	_refresh_labels(entry)
	_refresh_toolbar()
	if _workspace_media_id.is_empty():
		_dataset_explorer.select_frame(index)
	return true


func play() -> void:
	if _is_class_dialog_active():
		_modal_refusal("Playback")
		return
	var frame_count := _active_frame_count()
	if _source == null or _current_frame < 0 or _current_frame >= frame_count - 1:
		pause()
		return
	if not _prepare_edit_navigation():
		return
	if not _playback_controller.play(_current_frame):
		_playback_fps_meter.stop()
		_set_status("Playback could not start")
	else:
		_playback_fps_meter.start(Time.get_ticks_usec())
	_refresh_labels()
	_refresh_toolbar()


func pause() -> void:
	_playback_controller.pause()
	_playback_fps_meter.stop()
	_refresh_labels()
	_refresh_toolbar()


func _on_playback_speed_requested(mode: StringName, seconds_per_frame: float) -> void:
	if _source == null:
		return
	var interval := 0.0
	match mode:
		PLAYBACK_SPEED_CUSTOM:
			interval = seconds_per_frame
		PLAYBACK_SPEED_THREE_SECONDS:
			interval = 3.0
		PLAYBACK_SPEED_ONE_SECOND:
			interval = 1.0
		PLAYBACK_SPEED_MAX:
			pass
		_:
			_show_errors("Playback speed", PackedStringArray(["Unknown speed mode"]))
			return
	var errors := PackedStringArray()
	if mode == PLAYBACK_SPEED_MAX:
		errors = _playback_controller.set_clock(PLAYBACK_CLOCK_MAX)
	elif not is_finite(interval) or interval < 0.01 or interval > 60.0:
		errors.append("Seconds per frame must be between 0.01 and 60")
	else:
		errors = _playback_controller.set_clock(PLAYBACK_CLOCK_REVIEW, 1.0 / interval)
	if not errors.is_empty():
		_show_errors("Playback speed", errors)
		return
	_playback_fps_meter.stop()
	_refresh_labels()
	_refresh_toolbar()
	_set_status("Playback: Max" if mode == PLAYBACK_SPEED_MAX
		else "Playback: %s s/frame" % _format_seconds_per_frame(interval))


func step(delta: int) -> bool:
	if _is_class_dialog_active():
		_modal_refusal("Frame step")
		return false
	pause()
	var frame_count := _active_frame_count()
	if _source == null or _current_frame < 0 or frame_count <= 0:
		return false
	var target := clampi(_current_frame + delta, 0, frame_count - 1)
	if target == _current_frame:
		return false
	return set_frame(target)


func seek(index: int) -> bool:
	if _is_class_dialog_active():
		_modal_refusal("Frame seek")
		return false
	pause()
	if _source == null or index < 0 or index >= _active_frame_count():
		return false
	if index == _current_frame:
		return true
	return set_frame(index)


func _prepare_edit_navigation() -> bool:
	if bool(_edit_state.get("navigation_blocked", false)):
		pause()
		_set_status(_edit_navigation_message())
		return false
	if _edit_plugin != null:
		_edit_plugin.cancel()
	return true


func _edit_navigation_message() -> String:
	var message := str(_edit_state.get("message", "")).strip_edges()
	return message if not message.is_empty() else "Finish the active contour or press Escape before changing frames"


func get_current_frame() -> int:
	return _current_frame


func _current_record_frame() -> int:
	return _record_frame_for_playback(_current_frame)


func _record_frame_for_playback(index: int, entry: Dictionary = {}) -> int:
	if _source == null or index < 0:
		return -1
	var value: Variant = entry if not entry.is_empty() else _source.get_frame_entry(index)
	if not value is Dictionary:
		return -1
	var frame_value: Variant = value.get("frame_id", value.get("frame"))
	return int(frame_value) if _logical_integer(frame_value) and int(frame_value) >= 0 else -1


func export_handoff(output_path: String) -> PackedStringArray:
	if _is_class_dialog_active():
		return _modal_refusal("Export")
	if _source == null or _current_frame < 0:
		var no_source := PackedStringArray(["Open a source before exporting"])
		_show_errors("Export failed", no_source)
		return no_source
	if _feedback_plugin == null:
		var no_plugin := PackedStringArray(["Configured Feedback plugin is unavailable: %s" % feedback_plugin_id])
		_show_errors("Export failed", no_plugin)
		return no_plugin
	var dirty_frames: Array = []
	for frame: int in _store.get_dirty_frames():
		dirty_frames.append(frame)
	var context := {
		"records": _store.snapshot_corrected(),
		"output_path": output_path,
		"source_manifest": _manifest.duplicate(true),
		"model_digest": _store.model_digest(),
		"dirty_frames": dirty_frames,
		"batch_operations": _store.snapshot_batch_operations(),
	}
	var result: Variant = _feedback_plugin.export(context)
	var errors: PackedStringArray = result if result is PackedStringArray else PackedStringArray(["Feedback plugin export must return PackedStringArray"])
	if errors.is_empty():
		_set_status("Exported training handoff: %s" % output_path)
	else:
		_show_errors("Export failed", errors)
	return errors


func is_playing() -> bool:
	return _playback_controller.is_playing()


func _process(delta: float) -> void:
	if not _playback_controller.is_playing() or _source == null:
		return
	var target: int = _playback_controller.tick(delta, _current_frame)
	if target < 0:
		if not _playback_controller.is_playing():
			_refresh_toolbar()
		return
	if not set_frame(target):
		pause()
		return
	_playback_fps_meter.record_delivery(Time.get_ticks_usec())
	_refresh_fps_label()
	if _current_frame >= _active_frame_count() - 1:
		pause()


func _on_file_selected(path: String) -> void:
	if _is_class_dialog_active():
		_modal_refusal("Source selection")
		return
	var extension := path.get_extension().to_lower()
	if VIDEO_EXTENSIONS.has(extension) or not IMAGE_EXTENSIONS.has(extension):
		_begin_video_import(path)
	else:
		open_source(path)


func _on_directory_selected(path: String) -> void:
	if _is_class_dialog_active():
		_modal_refusal("Source selection")
		return
	open_workspace(path)


func _on_export_parent_selected(path: String) -> void:
	if _is_class_dialog_active():
		_modal_refusal("Export")
		return
	export_handoff(ProjectSettings.globalize_path(path).simplify_path().path_join("training_update_v1"))


func _begin_video_import(path: String) -> void:
	if _is_class_dialog_active():
		_modal_refusal("Video import")
		return
	pause()
	_pending_video_path = ProjectSettings.globalize_path(path).simplify_path()
	_selected_video_output_parent = ""
	_video_import_source.text = _pending_video_path
	_video_import_parent.text = ""
	_video_import_name.text = "%s_frames" % _pending_video_path.get_file().get_basename()
	_video_import_progress.value = 0.0
	_video_import_status.text = "Choose an output parent and a new directory name."
	_set_video_import_running_ui(false)
	_update_video_import_start_button()
	_video_import_dialog.popup_centered(Vector2i(640, 340))


func _on_video_import_browse_pressed() -> void:
	if not _video_import_controller.is_running():
		_video_output_parent_dialog.popup_centered_ratio(0.7)


func _on_video_output_parent_selected(path: String) -> void:
	_selected_video_output_parent = ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	_video_import_parent.text = _selected_video_output_parent
	_update_video_import_start_button()


func _on_video_import_start_pressed() -> void:
	if _video_import_controller.is_running():
		return
	var directory_name := _video_import_name.text.strip_edges()
	if not _valid_output_directory_name(directory_name):
		_video_import_status.text = "Enter one new directory name without /, \\, . or .."
		return
	if not DirAccess.dir_exists_absolute(_selected_video_output_parent):
		_video_import_status.text = "Choose an existing output parent directory."
		return
	var output_path := _selected_video_output_parent.path_join(directory_name).simplify_path()
	if output_path.get_base_dir() != _selected_video_output_parent:
		_video_import_status.text = "The output directory must be directly inside the chosen parent."
		return
	var errors: PackedStringArray = _video_import_controller.start(_pending_video_path, output_path)
	if not errors.is_empty():
		_video_import_status.text = _bounded(errors[0])
		_set_status("Video import: %s" % errors[0])
		return
	_video_import_progress.value = 0.0
	_video_import_status.text = "Starting background import…"
	_set_video_import_running_ui(true)
	_refresh_toolbar()


func _on_video_import_cancel_pressed() -> void:
	if _video_import_controller.is_running():
		_video_import_controller.cancel()
		_video_import_cancel.disabled = true
		_video_import_cancel.text = "Cancelling…"
		_video_import_status.text = "Cancelling safely; the current dataset is unchanged…"
		return
	_video_import_dialog.hide()


func _on_video_import_progress(payload: Dictionary) -> void:
	if _workspace_import_active:
		return
	_video_import_progress.value = float(payload.get("fraction", 0.0))
	var completed := int(payload.get("completed", 0))
	var total := int(payload.get("total", 1))
	_video_import_status.text = "%s — %d/%d" % [str(payload.get("message", "Importing")), completed, total]


func _on_video_import_completed(output_path: String) -> void:
	if _workspace_import_active:
		return
	_set_video_import_running_ui(false)
	_video_import_progress.value = 1.0
	var errors := open_source(output_path)
	if errors.is_empty():
		_video_import_dialog.hide()
		_set_status("Imported and loaded video source: %s" % output_path)
	else:
		_video_import_status.text = "Import completed, but the new source could not be opened. Output kept at: %s" % output_path
		_video_import_start.disabled = true
	_refresh_toolbar()


func _on_video_import_failed(message: String) -> void:
	if _workspace_import_active:
		return
	_set_video_import_running_ui(false)
	_video_import_status.text = _bounded(message)
	_set_status("Video import failed: %s" % message)
	_update_video_import_start_button()
	_refresh_toolbar()


func _on_video_import_cancelled() -> void:
	if _workspace_import_active:
		return
	_set_video_import_running_ui(false)
	_video_import_dialog.hide()
	_set_status("Video import cancelled; current dataset unchanged")
	_refresh_toolbar()


func _set_video_import_running_ui(running: bool) -> void:
	_video_import_browse.disabled = running
	_video_import_name.editable = not running
	_video_import_start.disabled = running
	_video_import_cancel.disabled = false
	_video_import_cancel.text = "Cancel" if running else "Close"


func _update_video_import_start_button() -> void:
	if not is_node_ready() or _video_import_controller.is_running():
		return
	_video_import_start.disabled = _selected_video_output_parent.is_empty() \
		or not _valid_output_directory_name(_video_import_name.text.strip_edges())


func _valid_output_directory_name(value: String) -> bool:
	return not value.is_empty() and value != "." and value != ".." \
		and not value.contains("/") and not value.contains("\\")


func _on_previous_pressed() -> void:
	step(-1)


func _on_next_pressed() -> void:
	step(1)


func _on_play_pause_pressed() -> void:
	if is_playing():
		pause()
	else:
		play()


func _on_timeline_frame_requested(index: int) -> void:
	if not seek(index):
		_timeline.set_current_frame(_current_frame)


func _on_explorer_frame_requested(index: int) -> void:
	if not seek(index):
		_dataset_explorer.select_frame(_current_frame)
		return


func _on_unavailable_tool_requested(_tool_id: StringName) -> void:
	if _is_class_dialog_active():
		_modal_refusal("Tool change")
		return
	_set_status("待开发")


func _on_explorer_view_model_rejected(message: String) -> void:
	_set_status(message)


func _on_region_selected(region_id: String) -> void:
	if _is_class_dialog_active():
		return
	_set_selected_region(region_id)


func _on_selection_cancel_requested() -> void:
	if _is_class_dialog_active() or _selected_region_id.is_empty():
		return
	pause()
	if _edit_plugin != null:
		_edit_plugin.cancel()
		var errors: PackedStringArray = _edit_plugin.set_active_tool(&"select")
		if not errors.is_empty():
			_show_errors("Selection cancel refused", errors)
			return
	_set_selected_region("")
	_clear_annotation_hover()
	_sync_tool_panel()
	_set_status("Selection cleared")


func _on_image_pointer_event(event: InputEvent, image_position: Vector2) -> void:
	if _edit_plugin == null or _is_class_dialog_active():
		return
	var mouse_button := event as InputEventMouseButton
	if mouse_button != null and mouse_button.button_index == MOUSE_BUTTON_LEFT and mouse_button.pressed:
		pause()
	var compare_committed_record := _pointer_event_may_commit(event)
	var before_record := _store.get_corrected_record(_current_record_frame()) if compare_committed_record and _current_frame >= 0 else {}
	_edit_plugin.handle_pointer(event, image_position)
	var after_record := _store.get_corrected_record(_current_record_frame()) if compare_committed_record and _current_frame >= 0 else {}
	if compare_committed_record and before_record != after_record:
		_refresh_after_edit(true)


func _pointer_event_may_commit(event: InputEvent) -> bool:
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return false
	# Anchored Lasso closes on the double-click press; its release is inert.
	if event.double_click:
		return event.pressed
	if _edit_plugin == null:
		return false
	var active_tool: Variant = _edit_plugin.get_active_tool()
	if typeof(active_tool) not in [TYPE_STRING, TYPE_STRING_NAME]:
		return not event.pressed
	var tool := StringName(active_tool)
	if tool == &"fill":
		return event.pressed
	return not event.pressed


func _on_tool_requested(tool_id: StringName) -> void:
	if _is_class_dialog_active():
		_modal_refusal("Tool change")
		_sync_tool_panel()
		return
	pause()
	if _edit_plugin == null:
		_tool_panel.set_active_tool(&"select")
		_set_status("Open a source before choosing an edit tool")
		return
	var result: Variant = _edit_plugin.set_active_tool(tool_id)
	var errors: PackedStringArray = result if result is PackedStringArray else PackedStringArray(["Edit plugin set_active_tool must return PackedStringArray"])
	_sync_tool_panel()
	if not errors.is_empty():
		_show_errors("Tool change refused", errors)
		return
	_set_status("Tool: %s" % _tool_display_name(tool_id))


func _on_tool_option_changed(tool_id: StringName, option_id: StringName, value: Variant) -> void:
	if _is_class_dialog_active():
		_tool_panel.restore_tool_option(tool_id, option_id)
		_modal_refusal("Tool option change")
		return
	if _edit_plugin == null:
		_tool_panel.restore_tool_option(tool_id, option_id)
		return
	var errors: PackedStringArray = _edit_plugin.invoke(&"set_tool_option", {
		"tool_id": tool_id,
		"option_id": option_id,
		"value": value,
	})
	if not errors.is_empty():
		_tool_panel.restore_tool_option(tool_id, option_id)
		_show_errors("Tool option refused", errors)
		return
	if not _tool_panel.accept_tool_option(tool_id, option_id, value):
		_tool_panel.restore_tool_option(tool_id, option_id)
		_set_status("Tool option could not be synchronized")


func _on_add_box_pressed() -> void:
	if _is_class_dialog_active():
		_modal_refusal("Tool change")
		return
	_on_tool_requested(&"box")
	if _edit_plugin != null:
		_edit_plugin.invoke(&"begin_add_box", {})
		_sync_tool_panel()


func _run_history_undo() -> void:
	if _is_class_dialog_active():
		_modal_refusal("Undo")
		return
	pause()
	if not _prepare_edit_navigation():
		_refresh_toolbar()
		return
	if _history.undo(_store):
		_refresh_after_edit()
	else:
		_refresh_toolbar()


func _on_redo_pressed() -> void:
	_run_history_redo()


func _run_history_redo() -> void:
	if _is_class_dialog_active():
		_modal_refusal("Redo")
		return
	pause()
	if not _prepare_edit_navigation():
		_refresh_toolbar()
		return
	var errors: PackedStringArray = _history.redo(_store)
	if errors.is_empty():
		_refresh_after_edit()
	elif errors == PackedStringArray(["history: nothing to redo"]):
		_refresh_toolbar()
	else:
		_show_errors("Redo failed", errors)


func _on_opacity_changed(value: float) -> void:
	_viewport.set_overlay_opacity(value)


func _on_zoom_pressed(factor: float) -> void:
	var transform = _viewport.get_image_transform()
	if transform != null and transform.is_configured():
		transform.zoom_at(_viewport.size * 0.5, factor)
		_viewport.notify_transform_changed()


func _on_fit_pressed() -> void:
	_viewport.reset_view_to_fit()


func _unhandled_key_input(event: InputEvent) -> void:
	if _route_edit_key(event):
		get_viewport().set_input_as_handled()


func _route_edit_key(event: InputEvent) -> bool:
	if _edit_plugin == null or not event is InputEventKey or _is_class_dialog_active():
		return false
	var before_record := _store.get_corrected_record(_current_record_frame()) if _current_frame >= 0 else {}
	if _edit_plugin.handle_key(event):
		# A keyboard edit owns one explicit frame just like pointer edits.
		# Stop playback in the same input turn before the next process tick can seek.
		pause()
		_sync_tool_panel()
		var after_record := _store.get_corrected_record(_current_record_frame()) if _current_frame >= 0 else {}
		if before_record != after_record:
			_refresh_after_edit(true)
		else:
			_refresh_toolbar()
		return true
	return false


func _refresh_after_edit(mark_modified: bool = true) -> void:
	_refresh_current_annotations()
	_refresh_toolbar()
	if mark_modified and not _store.get_dirty_frames().is_empty():
		_set_status("Modified")


func _refresh_current_annotations() -> void:
	if _current_frame < 0:
		_refresh_annotation_sidebar()
		return
	var record: Dictionary = _store.get_corrected_record(_current_record_frame())
	if record.is_empty():
		_refresh_annotation_sidebar()
		return
	_viewport.set_record(record)
	if not _selected_region_id.is_empty() and _find_region(record, _selected_region_id).is_empty():
		_selected_region_id = ""
		_viewport.set_selected_region_id("")
		_clear_annotation_hover()
	_refresh_annotation_sidebar()


func _set_selected_region(region_id: String) -> void:
	_selected_region_id = region_id
	_viewport.set_selected_region_id(region_id)
	if is_instance_valid(_annotation_sidebar):
		_syncing_sidebar_selection = true
		_annotation_sidebar.set_selected_region_id(region_id)
		_syncing_sidebar_selection = false


func _refresh_annotation_sidebar() -> void:
	if not is_instance_valid(_annotation_sidebar):
		return
	# Rebuilt rows invalidate transient row identity. Clear every hover owner
	# before population so the sidebar, viewport, and renderer cannot disagree.
	_clear_annotation_hover()
	if _current_frame < 0:
		_annotation_sidebar.clear()
		return
	var record: Dictionary = _store.get_corrected_record(_current_record_frame())
	if record.is_empty():
		_annotation_sidebar.clear()
		return
	var errors: PackedStringArray = _class_catalog.sync_record(record)
	if not errors.is_empty():
		_show_errors("Annotation sidebar", errors)
		return
	if not _selected_region_id.is_empty() and _find_region(record, _selected_region_id).is_empty():
		_selected_region_id = ""
		_viewport.set_selected_region_id("")
	_syncing_sidebar_selection = true
	_annotation_sidebar.populate(
		_class_catalog.project_rows(record, _color_resolver),
		_class_catalog.frame_rows(record, _color_resolver),
		_selected_region_id,
	)
	_syncing_sidebar_selection = false


func _on_sidebar_region_hovered(region_id: String) -> void:
	if is_instance_valid(_viewport) and _viewport.has_method("set_hovered_region_id"):
		_viewport.set_hovered_region_id(region_id)


func _clear_annotation_hover() -> void:
	if is_instance_valid(_annotation_sidebar):
		_annotation_sidebar.clear_hover()
	if is_instance_valid(_viewport) and _viewport.has_method("set_hovered_region_id"):
		_viewport.set_hovered_region_id("")


func _on_sidebar_region_selected(region_id: String) -> void:
	if _syncing_sidebar_selection or _is_class_dialog_active():
		return
	_set_selected_region(region_id)


func _on_sidebar_reclassify_requested(region_id: String) -> void:
	if _is_class_dialog_active():
		return
	_set_selected_region(region_id)
	_open_reclassification_dialog(region_id)


func _open_reclassification_dialog(region_id: String) -> void:
	if _is_class_dialog_active():
		_modal_refusal("Reclassification")
		return
	if _current_frame < 0 or _edit_plugin == null:
		_set_status("Open a source before reclassifying an annotation")
		return
	var region := _find_region(_store.get_corrected_record(_current_record_frame()), region_id)
	if region.is_empty():
		_set_status("Select an existing annotation before reclassifying it")
		return
	pause()
	if not _prepare_edit_navigation():
		return
	_set_selected_region(region_id)
	_class_dialog_mode = &"reclassify"
	_class_dialog_region_id = region_id
	_class_dialog_token = -1
	_class_dialog.present(
		String(region.get("class", "")),
		String(region.get("kind", "")),
		_class_catalog.suggestions(_color_resolver),
		_color_resolver,
	)
	_refresh_toolbar()


func _on_new_region_class_requested(request: Dictionary) -> void:
	if _is_class_dialog_active():
		_set_status("Finish the current class assignment before creating another annotation")
		return
	var token_value: Variant = request.get("candidate_token")
	var frame_value: Variant = request.get("frame")
	if typeof(token_value) != TYPE_INT or not _logical_integer(frame_value) or int(frame_value) != _current_record_frame():
		_set_status("Pending annotation class request is stale")
		return
	_class_dialog_mode = &"new_region"
	_class_dialog_region_id = ""
	_class_dialog_token = int(token_value)
	call_deferred("_present_new_region_dialog", _class_dialog_token)
	_refresh_toolbar()


func _present_new_region_dialog(token: int) -> void:
	if _class_dialog_mode != &"new_region" or _class_dialog_token != token:
		return
	var initial := _initial_class_pair()
	_class_dialog.present(
		String(initial.get("class", "")),
		String(initial.get("kind", "")),
		_class_catalog.suggestions(_color_resolver),
		_color_resolver,
	)
	_refresh_toolbar()


func _initial_class_pair() -> Dictionary:
	var last: Dictionary = _class_catalog.last_pair()
	if not last.is_empty():
		return last
	var suggestions: Array[Dictionary] = _class_catalog.suggestions(_color_resolver)
	return suggestions[0].duplicate(true) if not suggestions.is_empty() else {}


func _on_class_assignment_confirmed(class_label: String, kind: String) -> void:
	var mode := _class_dialog_mode
	if mode.is_empty() or _edit_plugin == null:
		return
	var errors := PackedStringArray()
	_class_dialog_action_in_progress = true
	if mode == &"reclassify":
		if _class_dialog_region_id.is_empty() or _find_region(
				_store.get_corrected_record(_current_record_frame()), _class_dialog_region_id).is_empty():
			errors.append("The selected annotation no longer exists")
		else:
			_set_selected_region(_class_dialog_region_id)
			var result: Variant = _edit_plugin.invoke(&"relabel_selected", {
				"class": class_label,
				"kind": kind,
			})
			errors = result if result is PackedStringArray else PackedStringArray(["Edit plugin invoke must return PackedStringArray"])
	elif mode == &"new_region":
		var result: Variant = _edit_plugin.invoke(&"confirm_pending_region", {
			"candidate_token": _class_dialog_token,
			"class": class_label,
			"kind": kind,
		})
		errors = result if result is PackedStringArray else PackedStringArray(["Edit plugin invoke must return PackedStringArray"])
	else:
		errors.append("Unknown class assignment mode")
	_class_dialog_action_in_progress = false
	if not errors.is_empty():
		_class_dialog.present(class_label, kind, _class_catalog.suggestions(_color_resolver), _color_resolver)
		_class_dialog.set_error(errors[0])
		_refresh_toolbar()
		return
	_class_catalog.remember(class_label, kind)
	_finish_class_dialog()
	_refresh_after_edit(true)


func _on_class_assignment_cancelled() -> void:
	if not _is_class_dialog_active():
		return
	var errors := PackedStringArray()
	var previous_class := String((_class_dialog.get_node("Margin/Content/ClassLabel") as LineEdit).text)
	var previous_kind := String((_class_dialog.get_node("Margin/Content/Kind") as LineEdit).text)
	_class_dialog_action_in_progress = true
	if _class_dialog_mode == &"new_region" and _edit_plugin != null:
		var result: Variant = _edit_plugin.invoke(&"cancel_pending_region", {
			"candidate_token": _class_dialog_token,
		})
		errors = result if result is PackedStringArray else PackedStringArray(["Edit plugin invoke must return PackedStringArray"])
	_class_dialog_action_in_progress = false
	if not errors.is_empty():
		_class_dialog.present(previous_class, previous_kind, _class_catalog.suggestions(_color_resolver), _color_resolver)
		_class_dialog.set_error(errors[0])
		_refresh_toolbar()
		return
	_finish_class_dialog()


func _finish_class_dialog() -> void:
	if is_instance_valid(_class_dialog) and _class_dialog.is_assignment_open():
		_class_dialog.dismiss_silently()
	_class_dialog_mode = &""
	_class_dialog_region_id = ""
	_class_dialog_token = -1
	if is_instance_valid(_viewport):
		_viewport.grab_focus()
	_refresh_toolbar()


func _is_class_dialog_active() -> bool:
	return not _class_dialog_mode.is_empty()


func _modal_refusal(action: String) -> PackedStringArray:
	var errors := PackedStringArray(["Finish or cancel the class assignment before %s" % action.to_lower()])
	_show_errors("Class assignment active", errors)
	_refresh_toolbar()
	return errors


func _get_selected_region_id() -> String:
	return _selected_region_id


func _on_edit_state_changed(state: Dictionary) -> void:
	var phase_value: Variant = state.get("phase", &"idle")
	var phase := StringName(phase_value) if typeof(phase_value) in [TYPE_STRING, TYPE_STRING_NAME] else &"idle"
	_edit_state = {
		"phase": phase,
		"navigation_blocked": bool(state.get("navigation_blocked", false)),
		"message": str(state.get("message", "")),
	}.duplicate(true)
	if (_class_dialog_mode == &"new_region" and phase != &"awaiting_class"
			and not _class_dialog_action_in_progress):
		_finish_class_dialog()
	else:
		_refresh_toolbar()


func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	var regions: Variant = record.get("regions", [])
	if regions is Array:
		for value: Variant in regions:
			if value is Dictionary and value.get("id") == region_id:
				return value.duplicate(true)
	return {}


func _edit_context(store: Variant, history: Variant, bridge: StagedEditContextBridge) -> Dictionary:
	return {
		"store": store,
		"history": history,
		"viewport": bridge,
		"get_current_frame": Callable(bridge, "get_current_frame"),
		"get_selected_region": Callable(bridge, "get_selected_region"),
		"set_selected_region": Callable(bridge, "set_selected_region"),
		"get_current_image": Callable(bridge, "get_current_image"),
		"status": Callable(self, "_set_status"),
		"edit_state_changed": Callable(bridge, "edit_state_changed"),
		"request_class_assignment": Callable(bridge, "request_class_assignment"),
		"taxonomy": _taxonomy,
	}


func _read_tool_descriptors(plugin: Variant, errors: PackedStringArray) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not plugin is Object or plugin == null or not plugin.has_method("get_tool_descriptors"):
		errors.append("configured Edit plugin does not provide tool descriptors")
		return result
	var value: Variant = plugin.get_tool_descriptors()
	if not value is Array:
		errors.append("Edit plugin get_tool_descriptors must return an Array")
		return result
	for index in range(value.size()):
		if not value[index] is Dictionary:
			errors.append("Edit tool descriptor %d must be a Dictionary" % index)
			continue
		result.append((value[index] as Dictionary).duplicate(true))
	return result


func _deactivate_edit(edit: Variant) -> void:
	if not edit is Object or edit == null:
		return
	if edit.has_method("deactivate"):
		edit.deactivate()


func _detach_edit_context_bridge(bridge: Variant) -> void:
	if bridge is Object and bridge != null and bridge.has_method("detach"):
		bridge.detach()


func _flush_workspace_changes() -> PackedStringArray:
	if _workspace_session == null:
		return PackedStringArray()
	return _workspace_session.flush_before_context_change()


func _unbind_workspace_session() -> void:
	if _workspace_session != null:
		_workspace_session.unbind()


func _clear_active_source() -> void:
	pause()
	_unbind_workspace_session()
	_deactivate_edit(_edit_plugin)
	_detach_edit_context_bridge(_edit_context_bridge)
	_edit_plugin = null
	_edit_context_bridge = null
	if _source != null:
		_source.close()
	_source = null
	_store = STORE_SCRIPT.new()
	_history = HISTORY_SCRIPT.new(200)
	_playback_controller = PLAYBACK_CONTROLLER_SCRIPT.new()
	_playback_fps_meter.stop()
	_playback_speed.select_mode(
		PLAYBACK_SPEED_ONE_SECOND, DEFAULT_SECONDS_PER_FRAME, false)
	_manifest.clear()
	_workspace_media_id = ""
	_workspace_label_store = null
	_current_frame = -1
	_selected_region_id = ""
	_class_catalog = PROJECT_CLASS_CATALOG_SCRIPT.new()
	_edit_state = {
		"phase": &"idle",
		"navigation_blocked": false,
		"message": "",
	}
	if is_instance_valid(_viewport):
		_viewport.set_edit_selection_authoritative(false)
		_viewport.set_state(null, {}, "", _opacity_slider.value)
	_clear_annotation_hover()
	_timeline.configure(0)
	_refresh_annotation_sidebar()
	_refresh_labels()
	_refresh_toolbar()


func _active_frame_count() -> int:
	if _source == null:
		return 0
	var value: Variant = _manifest.get("frame_count")
	return int(value) if _logical_positive_integer(value) else 0


func _connect_ui() -> void:
	_open_button.pressed.connect(_on_open_pressed)
	_export_button.pressed.connect(_on_export_pressed)
	_previous_button.pressed.connect(_on_previous_pressed)
	_play_pause_button.pressed.connect(_on_play_pause_pressed)
	_next_button.pressed.connect(_on_next_pressed)
	_playback_speed.speed_requested.connect(_on_playback_speed_requested)
	_zoom_out_button.pressed.connect(_on_zoom_pressed.bind(1.0 / ZOOM_FACTOR))
	_zoom_in_button.pressed.connect(_on_zoom_pressed.bind(ZOOM_FACTOR))
	_fit_button.pressed.connect(_on_fit_pressed)
	_opacity_slider.value_changed.connect(_on_opacity_changed)
	_redo_button.pressed.connect(_on_redo_pressed)
	_dataset_explorer.frame_requested.connect(_on_explorer_frame_requested)
	_dataset_explorer.media_requested.connect(_on_workspace_media_requested)
	_dataset_explorer.view_model_rejected.connect(_on_explorer_view_model_rejected)
	_tool_panel.tool_requested.connect(_on_tool_requested)
	_tool_panel.unavailable_tool_requested.connect(_on_unavailable_tool_requested)
	_tool_panel.tool_option_changed.connect(_on_tool_option_changed)
	_source_dialog.file_selected.connect(_on_file_selected)
	_source_dialog.dir_selected.connect(_on_directory_selected)
	_export_dialog.dir_selected.connect(_on_export_parent_selected)
	_video_import_browse.pressed.connect(_on_video_import_browse_pressed)
	_video_import_name.text_changed.connect(func(_value: String) -> void: _update_video_import_start_button())
	_video_import_start.pressed.connect(_on_video_import_start_pressed)
	_video_import_cancel.pressed.connect(_on_video_import_cancel_pressed)
	_video_import_dialog.close_requested.connect(_on_video_import_cancel_pressed)
	_video_output_parent_dialog.dir_selected.connect(_on_video_output_parent_selected)
	_video_import_controller.progress.connect(_on_video_import_progress)
	_video_import_controller.completed.connect(_on_video_import_completed)
	_video_import_controller.failed.connect(_on_video_import_failed)
	_video_import_controller.cancelled.connect(_on_video_import_cancelled)
	_timeline.frame_requested.connect(_on_timeline_frame_requested)
	_viewport.region_selected.connect(_on_region_selected)
	_viewport.image_pointer_event.connect(_on_image_pointer_event)
	_viewport.selection_cancel_requested.connect(_on_selection_cancel_requested)
	_annotation_sidebar.region_hovered.connect(_on_sidebar_region_hovered)
	_annotation_sidebar.region_selected.connect(_on_sidebar_region_selected)
	_annotation_sidebar.region_reclassify_requested.connect(_on_sidebar_reclassify_requested)
	_class_dialog.assignment_confirmed.connect(_on_class_assignment_confirmed)
	_class_dialog.assignment_cancelled.connect(_on_class_assignment_cancelled)


func _on_open_pressed() -> void:
	if _is_class_dialog_active():
		_modal_refusal("opening a source")
		return
	_source_dialog.popup_centered_ratio(0.8)


func _on_export_pressed() -> void:
	if _is_class_dialog_active():
		_modal_refusal("export")
		return
	_export_dialog.popup_centered_ratio(0.7)


func _refresh_labels(entry: Dictionary = {}) -> void:
	if _source == null or _current_frame < 0:
		_frame_label.text = "Frame - / -  ·  Time --:--:--.---"
		_refresh_fps_label()
		return
	var entry_value: Variant = entry if not entry.is_empty() else _source.get_frame_entry(_current_frame)
	var frame_entry: Dictionary = entry_value if entry_value is Dictionary else {}
	var record_frame := _record_frame_for_playback(_current_frame, frame_entry)
	var frame_text := (
		"Frame %d (%d / %d)" % [record_frame, _current_frame + 1, _active_frame_count()]
		if record_frame != _current_frame
		else "Frame %d (%d total)" % [_current_frame, _active_frame_count()]
	)
	_frame_label.text = "%s  ·  Time %s" % [
		frame_text,
		_format_source_time(float(frame_entry.get("time_s", 0.0))),
	]
	_refresh_fps_label()


func _refresh_fps_label() -> void:
	if _source == null or _current_frame < 0:
		_fps_label.text = "FPS --"
		return
	_fps_label.text = _format_fps(_playback_fps_meter.get_actual_fps())


func _refresh_toolbar() -> void:
	if not is_node_ready():
		return
	var has_source := _source != null and _current_frame >= 0
	var frame_count := _active_frame_count()
	var import_running: bool = is_instance_valid(_video_import_controller) \
		and _video_import_controller.is_running()
	var class_modal := _is_class_dialog_active()
	_open_button.disabled = import_running or class_modal
	_previous_button.disabled = import_running or class_modal or not has_source or _current_frame <= 0
	_next_button.disabled = import_running or class_modal or not has_source or _current_frame >= frame_count - 1
	_play_pause_button.disabled = import_running or class_modal or not has_source or _current_frame >= frame_count - 1
	_play_pause_button.text = "Pause" if is_playing() else "Play"
	_playback_speed.set_enabled(
		not import_running and not class_modal and has_source and frame_count >= 2)
	_redo_button.disabled = import_running or class_modal or not _history.can_redo()
	_export_button.disabled = import_running or class_modal or not has_source or _feedback_plugin == null
	_zoom_out_button.disabled = import_running
	_zoom_in_button.disabled = import_running
	_fit_button.disabled = import_running
	_opacity_slider.editable = not import_running
	_sync_tool_panel()


func _sync_tool_panel() -> void:
	if not is_node_ready():
		return
	var active_tool: StringName = &"select"
	if _edit_plugin != null:
		var value: Variant = _edit_plugin.get_active_tool()
		if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
			active_tool = StringName(value)
	_tool_panel.set_active_tool(active_tool)


func _tool_display_name(tool_id: StringName) -> String:
	return _tool_panel.get_tool_label(tool_id)


func _format_fps(fps: float) -> String:
	if not is_finite(fps) or fps < 0.0:
		return "FPS --"
	return "FPS %s" % _format_fps_value(fps)


func _format_fps_value(fps: float) -> String:
	if is_equal_approx(fps, roundf(fps)):
		return "%d" % roundi(fps)
	return "%.2f" % fps


func _format_source_time(seconds: float) -> String:
	if not is_finite(seconds) or seconds < 0.0:
		return "--:--:--.---"
	var total_ms := roundi(seconds * 1000.0)
	var hours := int(total_ms / 3_600_000)
	var minutes := int(total_ms / 60_000) % 60
	var whole_seconds := int(total_ms / 1000) % 60
	var milliseconds := total_ms % 1000
	return "%02d:%02d:%02d.%03d" % [hours, minutes, whole_seconds, milliseconds]


func _format_seconds_per_frame(seconds: float) -> String:
	if is_equal_approx(seconds, roundf(seconds)):
		return "%d" % roundi(seconds)
	return "%.2f" % seconds


func _read_taxonomy() -> Dictionary:
	var file := FileAccess.open(TAXONOMY_PATH, FileAccess.READ)
	if file == null:
		return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	return value.duplicate(true) if value is Dictionary else {}


func _show_errors(prefix: String, errors: PackedStringArray) -> void:
	var detail := errors[0] if not errors.is_empty() else "Unknown error"
	_set_status("%s: %s" % [prefix, detail])


func _set_status(message: String) -> void:
	_status_bar.text = _bounded(message)


func _bounded(message: String) -> String:
	var clean := message.replace("\n", " ").replace("\r", " ").strip_edges()
	return clean if clean.length() <= MAX_STATUS_LENGTH else clean.left(MAX_STATUS_LENGTH - 3) + "..."


func _finite_positive(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) > 0.0


func _finite_non_negative(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) >= 0.0


func _logical_integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) == floorf(float(value))


func _logical_positive_integer(value: Variant) -> bool:
	return _logical_integer(value) and int(value) > 0


func _exit_tree() -> void:
	_flush_workspace_changes()
	_unbind_workspace_session()
	_playback_controller.pause()
	if is_instance_valid(_viewport):
		_viewport.set_edit_selection_authoritative(false)
	_deactivate_edit(_edit_plugin)
	_detach_edit_context_bridge(_edit_context_bridge)
	_edit_context_bridge = null
	if _source != null:
		_source.close()
