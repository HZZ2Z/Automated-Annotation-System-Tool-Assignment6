extends "res://tests/benchmarks/godot/display_benchmark.gd"

var _case := ""
var _case_start := Vector2.ZERO
var _case_position := Vector2.ZERO
var _statuses: Array[String] = []


func _run() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	if "--output" not in OS.get_cmdline_user_args():
		options.output = "/tmp/annotool-part2-2-editing.json"
	DisplayServer.window_set_size(WINDOW_SIZE)
	var errors := _setup_scene()
	if not errors.is_empty():
		push_error("Editing benchmark setup: %s" % errors)
		quit(2)
		return
	# 保留标准样本的 20 个对象，扩大编辑目标以覆盖较大区域预览。
	_region_by_id(_record, TARGET_REGION_ID).box = [80, 80, 320, 150]
	_store.load_model_records([_record])
	_viewport.set_record(_record)
	_edit.set("_status_callback", func(message: String): _statuses.append(message))
	await process_frame
	var cases: Array[Dictionary] = []
	for name: String in ["select", "paint", "eraser", "zoom_pan"]:
		_case = name
		_start_case()
		await _sample(float(options.warmup))
		_start_case()
		var intervals: Array[float] = await _sample(float(options.duration))
		var commit_started := Time.get_ticks_usec()
		if name != "zoom_pan":
			_send_left_button(false, _case_position)
		var commit_ms := (Time.get_ticks_usec() - commit_started) / 1000.0
		var mean_ms := _mean(intervals)
		var p95 := _percentile(intervals, 0.95)
		var committed: bool = name == "zoom_pan" or _history.get_undo_count() == 1
		var output := {
			"scenario": name, "warmup_seconds": options.warmup, "measure_seconds": options.duration,
			"frames": intervals.size(), "mean_fps": snappedf(1000.0 / mean_ms, 0.01),
			"p95_frame_ms": snappedf(p95, 0.001), "commit_ms": snappedf(commit_ms, 0.001),
			"command_committed": committed, "undo_count": _history.get_undo_count(),
			"frame_intervals_ms": intervals, "status": _statuses.back() if not _statuses.is_empty() else "",
			"pass": committed and 1000.0 / mean_ms >= 30.0 and p95 <= 40.0,
		}
		cases.append(output)
		var summary := output.duplicate()
		summary.erase("frame_intervals_ms")
		print(JSON.stringify(summary))
		if not str(options.screenshot).is_empty():
			await process_frame
			var path := str(options.screenshot).get_basename() + "-" + name + ".png"
			output["screenshot"] = path
			output["screenshot_saved"] = root.get_texture().get_image().save_png(path) == OK
	var passed := DisplayServer.get_name() != "headless"
	for entry: Dictionary in cases:
		passed = passed and entry.pass
	var result := {
		"benchmark": "Assignment 2.2 Editing", "timestamp_utc": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info().string,
		"display_server": DisplayServer.get_name(), "rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"video_adapter": RenderingServer.get_video_adapter_name(), "processor": OS.get_processor_name(),
		"window": [1280, 800], "image": [640, 360], "region_count": 20,
		"fixture": "canonical frame 0 with sample-r01 enlarged to [80,80,320,150]",
		"brush_radius_image_px": 8, "eraser_path": "top edge, x=85..220, y=82+6*sin(8*pi*progress); all touched regions", "thresholds": {"mean_fps_min": 30.0, "p95_frame_ms_max": 40.0},
		"commit_timing": "release and validated command are measured separately from live-preview frame intervals",
		"cases": cases, "pass": passed,
	}
	_write_result(str(options.output), result)
	quit(0 if passed else 1)


func _start_case() -> void:
	_edit.cancel()
	_store.load_model_records([_record])
	_history = HISTORY_SCRIPT.new()
	_edit.set("_history", _history)
	_viewport.set_record(_record)
	_viewport.reset_view_to_fit()
	_selected[0] = TARGET_REGION_ID
	_viewport.set_selected_region_id(TARGET_REGION_ID)
	_statuses.clear()
	_edit.set_active_tool(StringName(_case) if _case != "zoom_pan" else &"select")
	match _case:
		"select": _case_start = Vector2(240, 155)
		"paint": _case_start = Vector2(399, 85)
		"eraser": _case_start = Vector2(85, 82)
	_case_position = _case_start
	if _case != "zoom_pan":
		_send_left_button(true, _case_start)


func _sample(seconds: float) -> Array[float]:
	var intervals: Array[float] = []
	var started := Time.get_ticks_usec()
	var previous := started
	while (Time.get_ticks_usec() - started) / 1000000.0 < seconds:
		var elapsed := (Time.get_ticks_usec() - started) / 1000000.0
		var progress := minf(elapsed / seconds, 1.0)
		if _case == "zoom_pan":
			var transform = _viewport.get_image_transform()
			var target_zoom := 1.0 + (sin(elapsed * 2) + 1.0) * 0.75
			transform.zoom_at(_viewport.size * 0.5, target_zoom / transform.user_zoom)
			var pan := Vector2(sin(elapsed) * 60, cos(elapsed * 1.3) * 35)
			transform.pan_by(pan - transform.pan)
			_viewport.notify_transform_changed()
		else:
			if _case == "select":
				_case_position = _case_start + Vector2(20 * progress, 8 * progress)
			elif _case == "eraser":
				_case_position = _case_start + Vector2(135 * progress, sin(progress * TAU * 4) * 6)
			else:
				_case_position = _case_start + Vector2(sin(progress * TAU * 4) * 6, 135 * progress)
			_send_drag_motion(_case_position)
		await process_frame
		var tick := Time.get_ticks_usec()
		intervals.append((tick - previous) / 1000.0)
		previous = tick
	return intervals
