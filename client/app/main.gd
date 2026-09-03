class_name AnnotationMain
extends Control

const PLUGIN_REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const TAXONOMY_PATH := "res://core/taxonomy/classes.json"
const MAX_STATUS_LENGTH := 180
const ZOOM_FACTOR := 1.2


class StagedEditContextBridge:
	extends RefCounted

	var _main_ref: WeakRef
	var _live := false
	var _staged_selection := ""

	func _init(main: AnnotationMain) -> void:
		_main_ref = weakref(main)

	func get_current_frame() -> int:
		var main := _main_ref.get_ref() as AnnotationMain
		return main.get_current_frame() if _live and main != null else 0

	func get_selected_region() -> String:
		var main := _main_ref.get_ref() as AnnotationMain
		return main._get_selected_region_id() if _live and main != null else _staged_selection

	func set_selected_region(region_id: String) -> void:
		var main := _main_ref.get_ref() as AnnotationMain
		if _live and main != null:
			main._set_selected_region(region_id)
		else:
			_staged_selection = region_id

	func switch_to_live() -> void:
		_staged_selection = ""
		_live = true


@export var source_plugin_id := "image_sequence_source"
@export var single_image_source_plugin_id := "single_image_source"
@export var render_plugin_id := "canvas_region_renderer"
@export var edit_plugin_id := "basic_edit_tools"

@onready var _open_button: Button = $MainVBox/TopToolbar/Open
@onready var _undo_button: Button = $MainVBox/TopToolbar/Undo
@onready var _redo_button: Button = $MainVBox/TopToolbar/Redo
@onready var _dataset_explorer = $MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer
@onready var _viewport = $MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport
@onready var _inspector = $MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/InspectorScroll/InspectorPanel
@onready var _tool_panel = $MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel
@onready var _previous_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/Previous
@onready var _play_pause_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/PlayPause
@onready var _next_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/Next
@onready var _frame_label: Label = $MainVBox/TimelinePanel/TimelineColumn/Transport/FrameLabel
@onready var _time_label: Label = $MainVBox/TimelinePanel/TimelineColumn/Transport/TimeLabel
@onready var _zoom_out_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/ZoomOut
@onready var _zoom_in_button: Button = $MainVBox/TimelinePanel/TimelineColumn/Transport/ZoomIn
@onready var _opacity_slider: HSlider = $MainVBox/TimelinePanel/TimelineColumn/Transport/Opacity
@onready var _timeline = $MainVBox/TimelinePanel/TimelineColumn/Timeline
@onready var _status_bar: Label = $MainVBox/StatusBar
@onready var _source_dialog: FileDialog = $SourceDialog
@onready var _playback_timer: Timer = $PlaybackTimer

var _plugin_registry = PLUGIN_REGISTRY_SCRIPT.new()
var _source: Variant
var _store = STORE_SCRIPT.new()
var _history = HISTORY_SCRIPT.new(200)
var _edit_plugin: Variant
var _edit_context_bridge: Variant
var _render_plugin: Variant
var _manifest: Dictionary = {}
var _taxonomy: Dictionary = {}
var _current_frame := -1
var _selected_region_id := ""
var _playing := false


func _ready() -> void:
	_connect_ui()
	_taxonomy = _read_taxonomy()
	_inspector.set_taxonomy(_taxonomy)
	var plugin_errors: PackedStringArray = _plugin_registry.discover("res://client/plugins")
	if not plugin_errors.is_empty():
		_set_status("Plugin discovery: %s" % plugin_errors[0])
	_render_plugin = _plugin_registry.get_plugin("render", render_plugin_id)
	if _render_plugin != null:
		_viewport.set_renderer(_render_plugin)
	else:
		_set_status("Configured render plugin is unavailable: %s" % render_plugin_id)
	_timeline.configure(0)
	_refresh_labels()
	_refresh_toolbar()


func get_discovered_plugin(stage: String, plugin_id: String) -> RefCounted:
	return _plugin_registry.get_plugin(stage, plugin_id)


func open_source(path: String) -> PackedStringArray:
	var candidate_errors := PackedStringArray()
	var routed_source_plugin_id := _source_plugin_id_for_path(path)
	if routed_source_plugin_id.is_empty():
		candidate_errors.append("Unsupported source. Select PNG/JPG/JPEG or a normalized directory; convert video with python/frame_source.py")
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var source_prototype = _plugin_registry.get_plugin("source", routed_source_plugin_id)
	var render_candidate = _plugin_registry.get_plugin("render", render_plugin_id)
	var edit_prototype = _plugin_registry.get_plugin("edit", edit_plugin_id)
	if source_prototype == null:
		candidate_errors.append("Configured source plugin is unavailable: %s" % routed_source_plugin_id)
	if render_candidate == null:
		candidate_errors.append("Configured render plugin is unavailable: %s" % render_plugin_id)
	if edit_prototype == null:
		candidate_errors.append("Configured edit plugin is unavailable: %s" % edit_plugin_id)
	if not candidate_errors.is_empty():
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var candidate = _new_plugin_instance(source_prototype)
	if candidate == null:
		candidate_errors.append("Configured source plugin cannot be instantiated: %s" % routed_source_plugin_id)
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var open_result: Variant = candidate.open(path)
	if not open_result is PackedStringArray:
		candidate_errors.append("Source plugin open must return PackedStringArray")
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	candidate_errors = open_result
	if not candidate_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors

	var frame_count_value: Variant = candidate.get_frame_count()
	if not _logical_positive_integer(frame_count_value):
		candidate_errors.append("Source plugin frame count must be a positive integer")
	var candidate_frame_count := int(frame_count_value) if _logical_positive_integer(frame_count_value) else 0
	var manifest_value: Variant = candidate.get_manifest()
	if not manifest_value is Dictionary or manifest_value.is_empty():
		candidate_errors.append("Source plugin manifest must be a non-empty Dictionary")
	var candidate_manifest: Dictionary = manifest_value.duplicate(true) if manifest_value is Dictionary else {}
	var manifest_fps: Variant = candidate_manifest.get("nominal_fps")
	if not _finite_positive(manifest_fps):
		candidate_errors.append("Source manifest nominal_fps must be finite and positive")
	var manifest_count: Variant = candidate_manifest.get("frame_count")
	if not _logical_positive_integer(manifest_count):
		candidate_errors.append("Source manifest frame_count must be a positive integer")
	elif candidate_frame_count > 0 and int(manifest_count) != candidate_frame_count:
		candidate_errors.append("Source manifest frame_count must match the source frame count")
	var records_value: Variant = candidate.get_model_records()
	if not records_value is Array:
		candidate_errors.append("Source plugin model records must be an Array")
	if not candidate_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors

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
	for index in range(candidate_frame_count):
		var indexed_record: Dictionary = candidate_store.get_corrected_record(index)
		var record_frame: Variant = indexed_record.get("frame")
		if indexed_record.is_empty() or not _logical_integer(record_frame) or int(record_frame) != index:
			candidate_errors.append("Source model records must contain contiguous frame %d" % index)
			break
	if not candidate_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var texture_value: Variant = candidate.load_texture(0)
	var first_texture: Texture2D = texture_value if texture_value is Texture2D else null
	var first_record: Dictionary = candidate_store.get_corrected_record(0)
	var entry_value: Variant = candidate.get_frame_entry(0)
	var first_entry: Dictionary = entry_value.duplicate(true) if entry_value is Dictionary else {}
	if first_texture == null:
		candidate_errors.append("Source plugin first frame texture is invalid")
	if first_record.is_empty():
		candidate_errors.append("Source plugin first annotation record is invalid")
	if first_entry.is_empty():
		candidate_errors.append("Source plugin frame zero entry must be a non-empty Dictionary")
	else:
		var entry_frame: Variant = first_entry.get("frame")
		var entry_time: Variant = first_entry.get("time_s")
		if not _logical_integer(entry_frame) or int(entry_frame) != 0:
			candidate_errors.append("Source plugin frame zero entry must identify frame 0")
		if not _finite_non_negative(entry_time):
			candidate_errors.append("Source plugin frame zero time_s must be finite and non-negative")
	if not candidate_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors

	var candidate_history = HISTORY_SCRIPT.new(200)
	var candidate_edit = _new_plugin_instance(edit_prototype)
	if candidate_edit == null:
		candidate_errors.append("Configured edit plugin cannot be instantiated: %s" % edit_plugin_id)
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var candidate_context_bridge := StagedEditContextBridge.new(self)
	var edit_result: Variant = candidate_edit.activate(_edit_context(candidate_store, candidate_history, candidate_context_bridge))
	var edit_errors := PackedStringArray()
	if edit_result is PackedStringArray:
		edit_errors = edit_result
	else:
		edit_errors.append("Edit plugin activate must return PackedStringArray")
	if not edit_errors.is_empty():
		_deactivate_edit(candidate_edit)
		candidate.close()
		_show_errors("Cannot open source", edit_errors)
		return edit_errors

	var candidate_explorer_view_model := _build_dataset_explorer_view_model(path, candidate_manifest)
	pause()
	_deactivate_edit(_edit_plugin)
	if _source != null:
		_source.close()
	_source = candidate
	_store = candidate_store
	_history = candidate_history
	_edit_plugin = candidate_edit
	_edit_context_bridge = candidate_context_bridge
	_render_plugin = render_candidate
	_viewport.set_renderer(_render_plugin)
	_manifest = candidate_manifest.duplicate(true)
	_current_frame = 0
	_selected_region_id = ""
	candidate_context_bridge.switch_to_live()
	_timeline.configure(candidate_frame_count)
	_viewport.set_state(first_texture, first_record, "", _opacity_slider.value)
	_inspector.populate({}, _taxonomy)
	_refresh_labels(first_entry)
	_refresh_toolbar()
	_set_status("Loaded %s (%d frames)" % [str(_manifest.get("dataset_id", "dataset")), candidate_frame_count])
	_dataset_explorer.populate(candidate_explorer_view_model)
	_dataset_explorer.select_frame(0)
	return PackedStringArray()


func set_frame(index: int) -> bool:
	var frame_count := _active_frame_count()
	if _source == null or index < 0 or index >= frame_count:
		return false
	var texture_value: Variant = _source.load_texture(index)
	var texture: Texture2D = texture_value if texture_value is Texture2D else null
	var record: Dictionary = _store.get_corrected_record(index)
	var entry_value: Variant = _source.get_frame_entry(index)
	var entry: Dictionary = entry_value.duplicate(true) if entry_value is Dictionary else {}
	if texture == null or record.is_empty() or entry.is_empty():
		_set_status("Frame %d could not be loaded" % index)
		return false
	var entry_frame: Variant = entry.get("frame")
	var entry_time: Variant = entry.get("time_s")
	if not _logical_integer(entry_frame) or int(entry_frame) != index or not _finite_non_negative(entry_time):
		_set_status("Frame %d metadata is invalid" % index)
		return false
	_edit_plugin.cancel()
	_current_frame = index
	_selected_region_id = ""
	_viewport.set_state(texture, record, "", _opacity_slider.value)
	_inspector.populate({}, _taxonomy)
	_timeline.set_current_frame(index)
	_refresh_labels(entry)
	_refresh_toolbar()
	_dataset_explorer.select_frame(index)
	return true


func play() -> void:
	var frame_count := _active_frame_count()
	if _source == null or _current_frame < 0 or _current_frame >= frame_count - 1:
		pause()
		return
	_edit_plugin.cancel()
	var fps_value: Variant = _manifest.get("nominal_fps")
	if not _finite_positive(fps_value):
		_set_status("Playback rate is invalid")
		pause()
		return
	_playback_timer.wait_time = 1.0 / float(fps_value)
	_playing = true
	if is_inside_tree():
		_playback_timer.start()
	_refresh_toolbar()


func pause() -> void:
	_playing = false
	if is_instance_valid(_playback_timer):
		_playback_timer.stop()
	_refresh_toolbar()


func step(delta: int) -> bool:
	var frame_count := _active_frame_count()
	if _source == null or _current_frame < 0 or frame_count <= 0:
		return false
	var target := clampi(_current_frame + delta, 0, frame_count - 1)
	if target == _current_frame:
		return false
	return set_frame(target)


func seek(index: int) -> bool:
	if _source == null or index < 0 or index >= _active_frame_count():
		return false
	if index == _current_frame:
		return true
	return set_frame(index)


func get_current_frame() -> int:
	return _current_frame


func is_playing() -> bool:
	return _playing


func _on_playback_timeout() -> void:
	if not _playing or _source == null:
		return
	var frame_count := _active_frame_count()
	if frame_count <= 0 or _current_frame >= frame_count - 1:
		pause()
		return
	if not set_frame(_current_frame + 1) or _current_frame >= frame_count - 1:
		pause()


func _on_file_selected(path: String) -> void:
	open_source(path)


func _on_directory_selected(path: String) -> void:
	open_source(path)


func _on_previous_pressed() -> void:
	pause()
	if _edit_plugin != null:
		_edit_plugin.cancel()
	step(-1)


func _on_next_pressed() -> void:
	pause()
	if _edit_plugin != null:
		_edit_plugin.cancel()
	step(1)


func _on_play_pause_pressed() -> void:
	if _playing:
		pause()
	else:
		play()


func _on_timeline_frame_requested(index: int) -> void:
	pause()
	if _edit_plugin != null:
		_edit_plugin.cancel()
	seek(index)


func _on_explorer_frame_requested(index: int) -> void:
	if not seek(index):
		_dataset_explorer.select_frame(_current_frame)
		return
	pause()
	if _edit_plugin != null:
		_edit_plugin.cancel()


func _on_unavailable_tool_requested(_tool_id: StringName) -> void:
	_set_status("待开发")


func _on_explorer_view_model_rejected(message: String) -> void:
	_set_status(message)


func _on_region_selected(region_id: String) -> void:
	_set_selected_region(region_id)


func _on_image_pointer_event(event: InputEvent, image_position: Vector2) -> void:
	if _edit_plugin == null:
		return
	pause()
	var before_record := _store.get_corrected_record(_current_frame) if _current_frame >= 0 else {}
	_edit_plugin.handle_pointer(event, image_position)
	var after_record := _store.get_corrected_record(_current_frame) if _current_frame >= 0 else {}
	if before_record != after_record:
		_refresh_after_edit(true)
	elif event is InputEventMouseButton and not event.pressed:
		_refresh_after_edit(false)


func _on_tool_requested(tool_id: StringName) -> void:
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


func _on_add_box_pressed() -> void:
	_on_tool_requested(&"box")
	if _edit_plugin != null:
		_edit_plugin.begin_add_box()
		_sync_tool_panel()


func _on_relabel_requested(region_id: String, class_label: String) -> void:
	_run_selected_edit(region_id, "relabel_selected", class_label)


func _on_track_id_requested(region_id: String, track_id: Variant) -> void:
	_run_selected_edit(region_id, "set_selected_track_id", track_id)


func _on_fill_requested(region_id: String, filled: bool) -> void:
	_run_selected_edit(region_id, "set_selected_fill", filled)


func _on_geometry_requested(region_id: String, box: Array) -> void:
	_run_selected_edit(region_id, "set_selected_geometry", box)


func _on_delete_requested(region_id: String) -> void:
	_set_selected_region(region_id)
	pause()
	if _edit_plugin != null:
		var errors: PackedStringArray = _edit_plugin.delete_selected()
		if errors.is_empty():
			_set_selected_region("")
		_refresh_after_edit(errors.is_empty())


func _on_undo_pressed() -> void:
	pause()
	if _edit_plugin != null:
		_edit_plugin.cancel()
	if _history.undo(_store):
		_refresh_after_edit()


func _on_redo_pressed() -> void:
	pause()
	if _edit_plugin != null:
		_edit_plugin.cancel()
	var errors: PackedStringArray = _history.redo(_store)
	if errors.is_empty():
		_refresh_after_edit()
	else:
		_show_errors("Redo failed", errors)


func _on_opacity_changed(value: float) -> void:
	_viewport.set_overlay_opacity(value)


func _on_zoom_pressed(factor: float) -> void:
	if _edit_plugin != null:
		_edit_plugin.cancel()
	var transform = _viewport.get_image_transform()
	if transform != null and transform.is_configured():
		transform.zoom_at(_viewport.size * 0.5, factor)
		_viewport.notify_transform_changed()


func _unhandled_key_input(event: InputEvent) -> void:
	if _edit_plugin == null or not event is InputEventKey:
		return
	var before_record := _store.get_corrected_record(_current_frame) if _current_frame >= 0 else {}
	if _edit_plugin.handle_key(event):
		get_viewport().set_input_as_handled()
		_sync_tool_panel()
		var after_record := _store.get_corrected_record(_current_frame) if _current_frame >= 0 else {}
		if before_record != after_record:
			_refresh_after_edit(true)
		else:
			_refresh_toolbar()


func _run_selected_edit(region_id: String, method: String, value: Variant) -> void:
	_set_selected_region(region_id)
	pause()
	if _edit_plugin != null:
		var errors: PackedStringArray = _edit_plugin.call(method, value)
		if not errors.is_empty():
			_show_errors("Edit refused", errors)
		_refresh_after_edit(errors.is_empty())


func _refresh_after_edit(mark_modified: bool = true) -> void:
	_refresh_current_annotations()
	_refresh_toolbar()
	if mark_modified and not _store.get_dirty_frames().is_empty():
		_set_status("Modified")


func _refresh_current_annotations() -> void:
	if _current_frame < 0:
		return
	var record: Dictionary = _store.get_corrected_record(_current_frame)
	if record.is_empty():
		return
	_viewport.set_record(record)
	if _selected_region_id.is_empty():
		_inspector.populate({}, _taxonomy)
		return
	var region := _find_region(record, _selected_region_id)
	if region.is_empty():
		_selected_region_id = ""
		_viewport.set_selected_region_id("")
		_inspector.populate({}, _taxonomy)
	else:
		_inspector.populate(region, _taxonomy)


func _set_selected_region(region_id: String) -> void:
	_selected_region_id = region_id
	_viewport.set_selected_region_id(region_id)
	if _current_frame < 0 or region_id.is_empty():
		_inspector.populate({}, _taxonomy)
		return
	_inspector.populate(_find_region(_store.get_corrected_record(_current_frame), region_id), _taxonomy)


func _get_selected_region_id() -> String:
	return _selected_region_id


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
		"viewport": _viewport,
		"get_current_frame": Callable(bridge, "get_current_frame"),
		"get_selected_region": Callable(bridge, "get_selected_region"),
		"set_selected_region": Callable(bridge, "set_selected_region"),
		"status": Callable(self, "_set_status"),
		"taxonomy": _taxonomy,
	}


func _new_plugin_instance(prototype: Variant) -> Variant:
	if not prototype is Object or prototype == null:
		return null
	var script_value: Variant = prototype.get_script()
	if not script_value is Script:
		return null
	var script := script_value as Script
	if not script.can_instantiate():
		return null
	var instance: Variant = script.new()
	return instance if instance is RefCounted else null


func _deactivate_edit(edit: Variant) -> void:
	if not edit is Object or edit == null:
		return
	if edit.has_method("deactivate"):
		edit.deactivate()


func _active_frame_count() -> int:
	if _source == null:
		return 0
	var value: Variant = _manifest.get("frame_count")
	return int(value) if _logical_positive_integer(value) else 0


func _source_plugin_id_for_path(path: String) -> String:
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute):
		return source_plugin_id
	if absolute.get_extension().to_lower() in ["png", "jpg", "jpeg"]:
		return single_image_source_plugin_id
	return ""


func _build_dataset_explorer_view_model(path: String, manifest: Dictionary) -> Dictionary:
	var absolute := ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	var is_directory := DirAccess.dir_exists_absolute(absolute)
	var frames: Array[Dictionary] = []
	var frame_values: Variant = manifest.get("frames", [])
	if frame_values is Array:
		for position in range(frame_values.size()):
			var entry_value: Variant = frame_values[position]
			if not entry_value is Dictionary:
				continue
			var relative := str(entry_value.get("image_path", ""))
			frames.append({
				"index": position,
				"label": relative,
				"path": absolute.path_join(relative) if is_directory else absolute,
			})
	var artifacts: Array[Dictionary] = []
	if is_directory:
		for label: String in ["manifest.json", "model_output.jsonl"]:
			var artifact_path := absolute.path_join(label)
			if FileAccess.file_exists(artifact_path):
				artifacts.append({"label": label, "path": artifact_path})
	var display_name := str(manifest.get("dataset_id", absolute.get_file()))
	if not is_directory:
		display_name = absolute.get_file()
	return {
		"display_name": display_name,
		"source_path": absolute,
		"frames": frames,
		"artifacts": artifacts,
	}


func _connect_ui() -> void:
	_open_button.pressed.connect(func(): _source_dialog.popup_centered_ratio(0.8))
	_previous_button.pressed.connect(_on_previous_pressed)
	_play_pause_button.pressed.connect(_on_play_pause_pressed)
	_next_button.pressed.connect(_on_next_pressed)
	_zoom_out_button.pressed.connect(_on_zoom_pressed.bind(1.0 / ZOOM_FACTOR))
	_zoom_in_button.pressed.connect(_on_zoom_pressed.bind(ZOOM_FACTOR))
	_opacity_slider.value_changed.connect(_on_opacity_changed)
	_undo_button.pressed.connect(_on_undo_pressed)
	_redo_button.pressed.connect(_on_redo_pressed)
	_dataset_explorer.frame_requested.connect(_on_explorer_frame_requested)
	_dataset_explorer.view_model_rejected.connect(_on_explorer_view_model_rejected)
	_tool_panel.tool_requested.connect(_on_tool_requested)
	_tool_panel.unavailable_tool_requested.connect(_on_unavailable_tool_requested)
	_source_dialog.file_selected.connect(_on_file_selected)
	_source_dialog.dir_selected.connect(_on_directory_selected)
	_playback_timer.timeout.connect(_on_playback_timeout)
	_timeline.frame_requested.connect(_on_timeline_frame_requested)
	_viewport.region_selected.connect(_on_region_selected)
	_viewport.image_pointer_event.connect(_on_image_pointer_event)
	_inspector.relabel_requested.connect(_on_relabel_requested)
	_inspector.track_id_requested.connect(_on_track_id_requested)
	_inspector.fill_requested.connect(_on_fill_requested)
	_inspector.geometry_requested.connect(_on_geometry_requested)
	_inspector.delete_requested.connect(_on_delete_requested)


func _refresh_labels(entry: Dictionary = {}) -> void:
	if _source == null or _current_frame < 0:
		_frame_label.text = "Frame - / -"
		_time_label.text = "--:--.---"
		return
	_frame_label.text = "Frame %d (%d total)" % [_current_frame, _active_frame_count()]
	var entry_value: Variant = entry if not entry.is_empty() else _source.get_frame_entry(_current_frame)
	var frame_entry: Dictionary = entry_value if entry_value is Dictionary else {}
	_time_label.text = _format_timestamp(float(frame_entry.get("time_s", 0.0)))


func _refresh_toolbar() -> void:
	if not is_node_ready():
		return
	var has_source := _source != null and _current_frame >= 0
	var frame_count := _active_frame_count()
	_previous_button.disabled = not has_source or _current_frame <= 0
	_next_button.disabled = not has_source or _current_frame >= frame_count - 1
	_play_pause_button.disabled = not has_source or _current_frame >= frame_count - 1
	_play_pause_button.text = "Pause" if _playing else "Play"
	_undo_button.disabled = not _history.can_undo()
	_redo_button.disabled = not _history.can_redo()
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
	match tool_id:
		&"select":
			return "Selection"
		&"move":
			return "Move / Resize"
		&"box":
			return "Add Box"
		&"fill":
			return "Fill"
		&"delete":
			return "Erase"
	return str(tool_id)


func _format_timestamp(time_s: float) -> String:
	var milliseconds := maxi(0, roundi(time_s * 1000.0))
	var minutes := milliseconds / 60000
	var seconds := (milliseconds / 1000) % 60
	return "%02d:%02d.%03d" % [minutes, seconds, milliseconds % 1000]


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
	_playing = false
	if is_instance_valid(_playback_timer):
		_playback_timer.stop()
	_deactivate_edit(_edit_plugin)
	_edit_context_bridge = null
	if _source != null:
		_source.close()
