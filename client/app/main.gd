class_name AnnotationMain
extends Control

const PLUGIN_REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const TAXONOMY_PATH := "res://core/taxonomy/classes.json"
const MAX_STATUS_LENGTH := 180
const ZOOM_FACTOR := 1.2

@onready var _open_button: Button = $MainVBox/TopToolbar/Open
@onready var _previous_button: Button = $MainVBox/TopToolbar/Previous
@onready var _play_pause_button: Button = $MainVBox/TopToolbar/PlayPause
@onready var _next_button: Button = $MainVBox/TopToolbar/Next
@onready var _frame_label: Label = $MainVBox/TopToolbar/FrameLabel
@onready var _time_label: Label = $MainVBox/TopToolbar/TimeLabel
@onready var _zoom_out_button: Button = $MainVBox/TopToolbar/ZoomOut
@onready var _zoom_in_button: Button = $MainVBox/TopToolbar/ZoomIn
@onready var _opacity_slider: HSlider = $MainVBox/TopToolbar/Opacity
@onready var _undo_button: Button = $MainVBox/TopToolbar/Undo
@onready var _redo_button: Button = $MainVBox/TopToolbar/Redo
@onready var _viewport = $MainVBox/Workspace/ViewportPanel/AnnotationViewport
@onready var _inspector = $MainVBox/Workspace/InspectorPanelContainer/InspectorColumn/InspectorPanel
@onready var _add_box_button: Button = $MainVBox/Workspace/InspectorPanelContainer/InspectorColumn/AddBox
@onready var _timeline = $MainVBox/TimelinePanel/Timeline
@onready var _status_bar: Label = $MainVBox/StatusBar
@onready var _source_dialog: FileDialog = $SourceDialog
@onready var _playback_timer: Timer = $PlaybackTimer

var _plugin_registry = PLUGIN_REGISTRY_SCRIPT.new()
var _source: Variant
var _store = STORE_SCRIPT.new()
var _history = HISTORY_SCRIPT.new(200)
var _edit_plugin: Variant
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
	var renderer = _plugin_registry.get_plugin("render", "canvas_region_renderer")
	if renderer != null:
		_viewport.set_renderer(renderer)
	_edit_plugin = _plugin_registry.get_plugin("edit", "basic_edit_tools")
	_timeline.configure(0)
	_refresh_labels()
	_refresh_toolbar()


func get_discovered_plugin(stage: String, plugin_id: String) -> RefCounted:
	return _plugin_registry.get_plugin(stage, plugin_id)


func open_source(path: String) -> PackedStringArray:
	var candidate_errors := PackedStringArray()
	var prototype = _plugin_registry.get_plugin("source", "image_sequence_source")
	if prototype == null or prototype.get_script() == null:
		candidate_errors.append("Source plugin is unavailable")
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		candidate_errors.append("Select a normalized directory containing manifest.json")
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var source_script := prototype.get_script() as Script
	var candidate = source_script.new()
	candidate_errors = candidate.open(path)
	if not candidate_errors.is_empty():
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var candidate_manifest: Dictionary = candidate.get_manifest()
	var candidate_store = STORE_SCRIPT.new()
	var store_errors: PackedStringArray = candidate_store.load_model_records(candidate.get_model_records())
	if not store_errors.is_empty():
		candidate.close()
		_show_errors("Cannot open source", store_errors)
		return store_errors
	if candidate.get_frame_count() <= 0:
		candidate_errors.append("Source contains no frames")
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var first_texture: Texture2D = candidate.load_texture(0)
	var first_record: Dictionary = candidate_store.get_corrected_record(0)
	var first_entry: Dictionary = candidate.get_frame_entry(0)
	if first_texture == null or first_record.is_empty() or first_entry.is_empty():
		var detail := str(candidate.get("last_error")) if candidate.get("last_error") != null else ""
		candidate_errors.append(detail if not detail.is_empty() else "First frame could not be loaded")
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var candidate_history = HISTORY_SCRIPT.new(200)
	if _edit_plugin == null:
		candidate_errors.append("Edit plugin is unavailable")
		candidate.close()
		_show_errors("Cannot open source", candidate_errors)
		return candidate_errors
	var edit_errors: PackedStringArray = _edit_plugin.activate(_edit_context(candidate_store, candidate_history))
	if not edit_errors.is_empty():
		candidate.close()
		if _source != null:
			_edit_plugin.activate(_edit_context(_store, _history))
		_show_errors("Cannot open source", edit_errors)
		return edit_errors

	pause()
	_edit_plugin.cancel()
	if _source != null:
		_source.close()
	_source = candidate
	_store = candidate_store
	_history = candidate_history
	_manifest = candidate_manifest.duplicate(true)
	_current_frame = 0
	_selected_region_id = ""
	_timeline.configure(candidate.get_frame_count())
	_viewport.set_state(first_texture, first_record, "", _opacity_slider.value)
	_inspector.populate({}, _taxonomy)
	_refresh_labels(first_entry)
	_refresh_toolbar()
	_set_status("Loaded %s (%d frames)" % [str(_manifest.get("dataset_id", "dataset")), candidate.get_frame_count()])
	return PackedStringArray()


func set_frame(index: int) -> bool:
	if _source == null or index < 0 or index >= _source.get_frame_count():
		return false
	var texture: Texture2D = _source.load_texture(index)
	var record: Dictionary = _store.get_corrected_record(index)
	var entry: Dictionary = _source.get_frame_entry(index)
	if texture == null or record.is_empty() or entry.is_empty():
		var detail := str(_source.get("last_error")) if _source.get("last_error") != null else ""
		_set_status(_bounded(detail if not detail.is_empty() else "Frame %d could not be loaded" % index))
		return false
	_edit_plugin.cancel()
	_current_frame = index
	_selected_region_id = ""
	_viewport.set_state(texture, record, "", _opacity_slider.value)
	_inspector.populate({}, _taxonomy)
	_timeline.set_current_frame(index)
	_refresh_labels(entry)
	_refresh_toolbar()
	return true


func play() -> void:
	if _source == null or _current_frame < 0 or _current_frame >= _source.get_frame_count() - 1:
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
	if _source == null or _current_frame < 0:
		return false
	var target := clampi(_current_frame + delta, 0, _source.get_frame_count() - 1)
	if target == _current_frame:
		return false
	return set_frame(target)


func seek(index: int) -> bool:
	if _source == null or index < 0 or index >= _source.get_frame_count():
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
	if _current_frame >= _source.get_frame_count() - 1:
		pause()
		return
	if not set_frame(_current_frame + 1) or _current_frame >= _source.get_frame_count() - 1:
		pause()


func _on_file_selected(path: String) -> void:
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		open_source(path)
		return
	_set_status("Select a normalized directory containing manifest.json")


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


func _on_region_selected(region_id: String) -> void:
	_set_selected_region(region_id)


func _on_image_pointer_event(event: InputEvent, image_position: Vector2) -> void:
	if _edit_plugin == null:
		return
	pause()
	var before_record := _store.get_corrected_record(_current_frame) if _current_frame >= 0 else {}
	_edit_plugin.handle_pointer(event, image_position)
	if event is InputEventMouseButton and not event.pressed:
		var after_record := _store.get_corrected_record(_current_frame) if _current_frame >= 0 else {}
		_refresh_after_edit(before_record != after_record)


func _on_add_box_pressed() -> void:
	pause()
	if _edit_plugin != null:
		_edit_plugin.begin_add_box()


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
		var after_record := _store.get_corrected_record(_current_frame) if _current_frame >= 0 else {}
		_refresh_after_edit(before_record != after_record)


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


func _edit_context(store: Variant, history: Variant) -> Dictionary:
	return {
		"store": store,
		"history": history,
		"viewport": _viewport,
		"get_current_frame": Callable(self, "get_current_frame"),
		"get_selected_region": Callable(self, "_get_selected_region_id"),
		"set_selected_region": Callable(self, "_set_selected_region"),
		"status": Callable(self, "_set_status"),
		"taxonomy": _taxonomy,
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
	_add_box_button.pressed.connect(_on_add_box_pressed)
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
	_frame_label.text = "Frame %d / %d" % [_current_frame, _source.get_frame_count() - 1]
	var frame_entry: Dictionary = entry if not entry.is_empty() else _source.get_frame_entry(_current_frame)
	_time_label.text = _format_timestamp(float(frame_entry.get("time_s", 0.0)))


func _refresh_toolbar() -> void:
	if not is_node_ready():
		return
	var has_source := _source != null and _current_frame >= 0
	_previous_button.disabled = not has_source or _current_frame <= 0
	_next_button.disabled = not has_source or _current_frame >= _source.get_frame_count() - 1
	_play_pause_button.disabled = not has_source or _current_frame >= _source.get_frame_count() - 1
	_play_pause_button.text = "Pause" if _playing else "Play"
	_undo_button.disabled = not _history.can_undo()
	_redo_button.disabled = not _history.can_redo()
	_add_box_button.disabled = not has_source


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


func _exit_tree() -> void:
	_playing = false
	if is_instance_valid(_playback_timer):
		_playback_timer.stop()
	if _edit_plugin != null:
		_edit_plugin.cancel()
	if _source != null:
		_source.close()
