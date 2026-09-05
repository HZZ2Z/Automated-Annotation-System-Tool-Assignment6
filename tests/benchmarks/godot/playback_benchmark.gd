extends SceneTree

const MAIN_SCENE := preload("res://client/app/main.tscn")
const WINDOW_SIZE := Vector2i(1280, 800)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	DisplayServer.window_set_size(WINDOW_SIZE)
	var main := MAIN_SCENE.instantiate() as Control
	root.add_child(main)
	await process_frame
	main.set_process(false)
	var opened_at := Time.get_ticks_usec()
	var errors: PackedStringArray = main.open_source(options["source"])
	var open_ms := float(Time.get_ticks_usec() - opened_at) / 1000.0
	if not errors.is_empty():
		_write_json(options["output"], {"pass": false, "errors": errors, "client_open_ms": open_ms})
		quit(2)
		return
	for index in range(1, 12):
		main.seek(index)
	main.seek(0)
	var source = main.get("_source")
	var cache = source.get("_cache")
	var delivered_indices: Array[int] = []
	var delivery_intervals_ms: Array[float] = []
	var load_times_ms: Array[float] = []
	var cache_hits := 0
	var cache_misses := 0
	var process_heartbeats := 0
	var measure_seconds: float = options["duration"]
	var started := Time.get_ticks_usec()
	var previous_process_tick := started
	var previous_delivery_tick := started
	main.play()
	while float(Time.get_ticks_usec() - started) / 1_000_000.0 < measure_seconds:
		await process_frame
		process_heartbeats += 1
		var now := Time.get_ticks_usec()
		var delta := float(now - previous_process_tick) / 1_000_000.0
		previous_process_tick = now
		var before: int = main.get_current_frame()
		var expected_target := before + 1
		var was_cached: bool = cache.has(expected_target)
		var load_started := Time.get_ticks_usec()
		main.call("_process", delta)
		var call_ms := float(Time.get_ticks_usec() - load_started) / 1000.0
		var after: int = main.get_current_frame()
		if after == before:
			continue
		delivered_indices.append(after)
		load_times_ms.append(call_ms)
		var delivered_at := Time.get_ticks_usec()
		delivery_intervals_ms.append(float(delivered_at - previous_delivery_tick) / 1000.0)
		previous_delivery_tick = delivered_at
		if was_cached:
			cache_hits += 1
		else:
			cache_misses += 1
	main.pause()
	var elapsed_s := float(Time.get_ticks_usec() - started) / 1_000_000.0
	var record: Dictionary = main.get("_store").get_corrected_record(main.get_current_frame())
	var continuous := _is_continuous(delivered_indices)
	var result := {
		"benchmark": "Part 3.1 frame-accurate playback",
		"timestamp_utc": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"display_server": DisplayServer.get_name(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"source_resolution": [int(main.get("_manifest").get("width", 0)), int(main.get("_manifest").get("height", 0))],
		"region_count": record.get("regions", []).size(),
		"requested_seconds": measure_seconds,
		"measured_seconds": snappedf(elapsed_s, 0.001),
		"process_heartbeats": process_heartbeats,
		"delivered_count": delivered_indices.size(),
		"first_delivered_index": delivered_indices[0] if not delivered_indices.is_empty() else -1,
		"last_delivered_index": delivered_indices[-1] if not delivered_indices.is_empty() else -1,
		"indices_continuous": continuous,
		"skipped_frame_count": 0 if continuous else _skip_count(delivered_indices),
		"actual_playback_fps": snappedf(float(delivered_indices.size()) / elapsed_s, 0.01),
		"mean_delivery_interval_ms": snappedf(_mean(delivery_intervals_ms), 0.001),
		"p95_delivery_interval_ms": snappedf(_percentile(delivery_intervals_ms, 0.95), 0.001),
		"mean_frame_load_ms": snappedf(_mean(load_times_ms), 0.001),
		"p95_frame_load_ms": snappedf(_percentile(load_times_ms, 0.95), 0.001),
		"cache_hits": cache_hits,
		"cache_misses": cache_misses,
		"cache_size": cache.size(),
		"cache_limit": cache.get("max_size"),
		"client_open_ms": snappedf(open_ms, 0.001),
		"delivered_indices": delivered_indices,
		"delivery_intervals_ms": delivery_intervals_ms,
		"frame_load_ms": load_times_ms,
	}
	result["pass"] = elapsed_s >= measure_seconds and continuous \
		and delivered_indices.size() > 0 and delivered_indices[0] == 1 \
		and result["skipped_frame_count"] == 0 \
		and result["source_resolution"] == [640, 360] and result["region_count"] == 20 \
		and int(result["cache_size"]) <= 12 and int(result["cache_limit"]) == 12
	_write_json(options["output"], result)
	print(JSON.stringify(result))
	main.queue_free()
	await process_frame
	quit(0 if result["pass"] else 1)


func _is_continuous(values: Array[int]) -> bool:
	for index in range(1, values.size()):
		if values[index] != values[index - 1] + 1:
			return false
	return true


func _skip_count(values: Array[int]) -> int:
	var skipped := 0
	for index in range(1, values.size()):
		skipped += maxi(0, values[index] - values[index - 1] - 1)
	return skipped


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
	return ordered[clampi(int(ceil(fraction * ordered.size())) - 1, 0, ordered.size() - 1)]


func _parse_options(arguments: PackedStringArray) -> Dictionary:
	var result := {"source": "/tmp/annotool-part3-playback", "output": "/tmp/part3_1_playback.json", "duration": 10.0}
	var index := 0
	while index < arguments.size():
		match arguments[index]:
			"--source":
				if index + 1 < arguments.size():
					result["source"] = arguments[index + 1]
					index += 1
			"--output":
				if index + 1 < arguments.size():
					result["output"] = arguments[index + 1]
					index += 1
			"--duration":
				if index + 1 < arguments.size():
					result["duration"] = maxf(0.1, float(arguments[index + 1]))
					index += 1
		index += 1
	return result


func _write_json(path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  ") + "\n")
