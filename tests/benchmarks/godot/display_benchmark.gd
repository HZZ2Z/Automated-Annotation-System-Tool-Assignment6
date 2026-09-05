extends SceneTree

const VIEWPORT_SCENE := preload("res://client/ui/annotation_viewport.tscn")
const RENDERER_SCRIPT := preload("res://client/plugins/render/canvas_region_renderer/plugin.gd")
const EDIT_SCRIPT := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")

const WINDOW_SIZE := Vector2i(1280, 800)
const DEFAULT_WARMUP_SECONDS := 2.0
const DEFAULT_MEASURE_SECONDS := 10.0
const TARGET_REGION_ID := "sample-r01"

var _viewport: Control
var _renderer
var _edit
var _store
var _history
var _selected := [""]
var _record: Dictionary = {}
var _initial_box: Array = []
var _drag_start := Vector2.ZERO
var _last_drag_viewport_position := Vector2.ZERO
var _drag_started := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	var output_path: String = options["output"]
	var warmup_seconds: float = options["warmup"]
	var measure_seconds: float = options["duration"]
	DisplayServer.window_set_size(WINDOW_SIZE)
	var setup_errors := _setup_scene()
	if not setup_errors.is_empty():
		_write_result(output_path, {"pass": false, "setup_errors": setup_errors})
		push_error("Display benchmark setup failed: %s" % "; ".join(setup_errors))
		quit(2)
		return
	await process_frame
	await _warm_up(warmup_seconds)
	var result: Dictionary = await _measure(measure_seconds, warmup_seconds)
	var screenshot_path: String = options["screenshot"]
	if not screenshot_path.is_empty():
		await process_frame
		var screenshot_error := root.get_texture().get_image().save_png(screenshot_path)
		result["screenshot_saved"] = screenshot_error == OK
	_write_result(output_path, result)
	print(JSON.stringify(result))
	quit(0 if result.get("pass", false) else 1)


func _setup_scene() -> PackedStringArray:
	var errors := PackedStringArray()
	_record = _read_first_record("res://sample/assignment_v1/model_output_v1.jsonl")
	if _record.is_empty():
		errors.append("could not read the first canonical sample record")
		return errors
	var image := Image.load_from_file("res://sample/assignment_v1/frames/frame_000000.png")
	if image == null or image.is_empty():
		errors.append("could not load the first canonical sample frame")
		return errors
	_renderer = RENDERER_SCRIPT.new()
	_viewport = VIEWPORT_SCENE.instantiate() as Control
	_viewport.set_renderer(_renderer)
	_viewport.set_edit_selection_authoritative(true)
	_viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_viewport.position = Vector2.ZERO
	_viewport.size = Vector2(WINDOW_SIZE)
	root.add_child(_viewport)
	_store = STORE_SCRIPT.new()
	errors.append_array(_store.load_model_records([_record]))
	_history = HISTORY_SCRIPT.new()
	_edit = EDIT_SCRIPT.new()
	var context := {
		"store": _store,
		"history": _history,
		"viewport": _viewport,
		"current_frame": func(): return 0,
		"selected_region": func(): return _selected[0],
		"set_selected_region": func(value: String): _selected[0] = value,
		"status": func(_message: String): pass,
		"taxonomy": _read_json("res://core/taxonomy/classes.json"),
	}
	errors.append_array(_edit.activate(context))
	errors.append_array(_edit.set_active_tool(&"select"))
	_viewport.region_selected.connect(func(region_id: String): _selected[0] = region_id)
	_viewport.image_pointer_event.connect(func(event: InputEvent, image_position: Vector2): _edit.handle_pointer(event, image_position))
	_viewport.set_texture(ImageTexture.create_from_image(image))
	_viewport.set_record(_record)
	var target := _region_by_id(_record, TARGET_REGION_ID)
	if target.is_empty() or not target.get("box") is Array:
		errors.append("benchmark target region is missing its box")
	else:
		_initial_box = target["box"].duplicate(true)
		_drag_start = Rect2(float(_initial_box[0]), float(_initial_box[1]), float(_initial_box[2]), float(_initial_box[3])).get_center()
	return errors


func _warm_up(seconds: float) -> void:
	var started := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - started) / 1_000_000.0 < seconds:
		var elapsed := float(Time.get_ticks_usec() - started) / 1_000_000.0
		var transform = _viewport.get_image_transform()
		var desired_pan := Vector2(sin(elapsed * 2.0) * 24.0, cos(elapsed * 1.7) * 16.0)
		transform.pan_by(desired_pan - transform.pan)
		_viewport.notify_transform_changed()
		await process_frame
	_viewport.reset_view_to_fit()


func _measure(seconds: float, warmup_seconds: float) -> Dictionary:
	var intervals_ms: Array[float] = []
	var started := Time.get_ticks_usec()
	var previous_tick := started
	var final_drag_offset := Vector2.ZERO
	while float(Time.get_ticks_usec() - started) / 1_000_000.0 < seconds:
		var elapsed := float(Time.get_ticks_usec() - started) / 1_000_000.0
		_animate_measurement(elapsed, seconds)
		await process_frame
		var current_tick := Time.get_ticks_usec()
		intervals_ms.append(float(current_tick - previous_tick) / 1000.0)
		previous_tick = current_tick
		if _drag_started:
			final_drag_offset = _viewport.get_image_transform().viewport_to_image(_last_drag_viewport_position) - _drag_start
	if _drag_started:
		final_drag_offset = Vector2(20.0, 8.0)
		_send_drag_motion(_drag_start + final_drag_offset)
		_send_left_button(false, _drag_start + final_drag_offset)
		_drag_started = false
		await process_frame
	var committed := _region_by_id(_store.get_corrected_record(0), TARGET_REGION_ID)
	var expected_box := _initial_box.duplicate(true)
	expected_box[0] = float(expected_box[0]) + final_drag_offset.x
	expected_box[1] = float(expected_box[1]) + final_drag_offset.y
	var coordinate_error := _box_error(committed.get("box", []), expected_box)
	var mean_frame_ms := _mean(intervals_ms)
	var p95_frame_ms := _percentile(intervals_ms, 0.95)
	var mean_fps := 1000.0 / mean_frame_ms if mean_frame_ms > 0.0 else 0.0
	var selection_ok: bool = _selected[0] == TARGET_REGION_ID
	var drag_commit_ok: bool = _history.get_undo_count() == 1
	var passed: bool = mean_fps >= 30.0 and p95_frame_ms <= 40.0 and coordinate_error <= 0.00001 and selection_ok and drag_commit_ok
	return {
		"benchmark": "Part 2.1 Display",
		"timestamp_utc": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"rendering_method": ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"display_server": DisplayServer.get_name(),
		"processor": OS.get_processor_name(),
		"viewport": [WINDOW_SIZE.x, WINDOW_SIZE.y],
		"region_count": _record.get("regions", []).size(),
		"warmup_seconds": warmup_seconds,
		"measured_seconds": seconds,
		"measured_frames": intervals_ms.size(),
		"mean_frame_ms": snappedf(mean_frame_ms, 0.001),
		"mean_fps": snappedf(mean_fps, 0.01),
		"p95_frame_ms": snappedf(p95_frame_ms, 0.001),
		"coordinate_error_image_px": coordinate_error,
		"selected_region": _selected[0],
		"drag_undo_count": _history.get_undo_count(),
		"renderer_cache": _renderer.get_cache_stats(),
		"thresholds": {"mean_fps_min": 30.0, "p95_frame_ms_max": 40.0, "coordinate_error_image_px_max": 0.00001},
		"frame_intervals_ms": intervals_ms,
		"pass": passed,
	}


func _animate_measurement(elapsed: float, duration: float) -> void:
	var transform = _viewport.get_image_transform()
	var progress := elapsed / duration
	if progress < 0.3:
		var phase := progress / 0.3
		var desired_pan := Vector2(sin(phase * TAU * 2.0) * 80.0, cos(phase * TAU * 1.5) * 45.0)
		transform.pan_by(desired_pan - transform.pan)
		_viewport.notify_transform_changed()
		return
	if progress < 0.6:
		var phase := (progress - 0.3) / 0.3
		var target_zoom := 1.0 + (sin(phase * TAU * 2.0 - PI * 0.5) + 1.0) * 1.5
		transform.zoom_at(_viewport.size * 0.5, target_zoom / transform.user_zoom)
		_viewport.notify_transform_changed()
		return
	if not _drag_started:
		_viewport.reset_view_to_fit()
		_send_left_button(true, _drag_start)
		_drag_started = true
	var drag_phase := clampf((progress - 0.6) / 0.4, 0.0, 1.0)
	_send_drag_motion(_drag_start + Vector2(20.0 * drag_phase, 8.0 * drag_phase))


func _send_left_button(pressed: bool, image_position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = _viewport.get_image_transform().image_to_viewport(image_position)
	_last_drag_viewport_position = event.position
	_viewport.call("_gui_input", event)


func _send_drag_motion(image_position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = _viewport.get_image_transform().image_to_viewport(image_position)
	event.relative = event.position - _last_drag_viewport_position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	_last_drag_viewport_position = event.position
	_viewport.call("_gui_input", event)


func _read_first_record(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_line())
	return parsed if parsed is Dictionary else {}


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _region_by_id(record: Dictionary, region_id: String) -> Dictionary:
	var regions: Variant = record.get("regions", [])
	if regions is Array:
		for value: Variant in regions:
			if value is Dictionary and value.get("id") == region_id:
				return value
	return {}


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value: float in values:
		total += value
	return total / values.size()


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var ordered := values.duplicate()
	ordered.sort()
	var index := clampi(int(ceil(fraction * ordered.size())) - 1, 0, ordered.size() - 1)
	return ordered[index]


func _box_error(actual: Variant, expected: Array) -> float:
	if not actual is Array or actual.size() != expected.size():
		return INF
	var error := 0.0
	for index in range(expected.size()):
		error = maxf(error, absf(float(actual[index]) - float(expected[index])))
	return error


func _parse_options(arguments: PackedStringArray) -> Dictionary:
	var result := {"output": "/tmp/annotool-part2-1-display.json", "screenshot": "", "warmup": DEFAULT_WARMUP_SECONDS, "duration": DEFAULT_MEASURE_SECONDS}
	var index := 0
	while index < arguments.size():
		match arguments[index]:
			"--output":
				if index + 1 < arguments.size():
					result["output"] = arguments[index + 1]
					index += 1
			"--warmup":
				if index + 1 < arguments.size():
					result["warmup"] = maxf(0.0, float(arguments[index + 1]))
					index += 1
			"--duration":
				if index + 1 < arguments.size():
					result["duration"] = maxf(0.1, float(arguments[index + 1]))
					index += 1
			"--screenshot":
				if index + 1 < arguments.size():
					result["screenshot"] = arguments[index + 1]
					index += 1
		index += 1
	return result


func _write_result(path: String, result: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write benchmark result: %s" % path)
		return
	file.store_string(JSON.stringify(result, "  ") + "\n")
