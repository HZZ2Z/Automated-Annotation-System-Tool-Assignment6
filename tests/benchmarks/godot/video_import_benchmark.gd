extends SceneTree

const MAIN_SCENE := preload("res://client/app/main.tscn")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	var main := MAIN_SCENE.instantiate() as Control
	root.add_child(main)
	await process_frame
	var setup_errors: PackedStringArray = main.open_source("res://sample/assignment_v1")
	if not setup_errors.is_empty():
		_write_json(options["result"], {"pass": false, "errors": setup_errors})
		quit(2)
		return
	main.seek(5)
	var old_dataset_id: String = str(main.get("_manifest").get("dataset_id", ""))
	var controller = main.get_node("VideoImportController")
	controller.job_root = "/tmp/annotool-part3-import-jobs-%d" % OS.get_process_id()
	var progress_events: Array[Dictionary] = []
	var completed_paths: Array[String] = []
	var failures: Array[String] = []
	var cancelled := [false]
	controller.progress.connect(func(payload: Dictionary) -> void: progress_events.append(payload))
	controller.completed.connect(func(path: String) -> void: completed_paths.append(path))
	controller.failed.connect(func(message: String) -> void: failures.append(message))
	controller.cancelled.connect(func() -> void: cancelled[0] = true)
	main.call("_begin_video_import", options["input"])
	main.call("_on_video_output_parent_selected", str(options["output"]).get_base_dir())
	var name_field := main.get_node("VideoImportDialog/Margin/Content/DirectoryName") as LineEdit
	name_field.text = str(options["output"]).get_file()
	var started := Time.get_ticks_usec()
	main.call("_on_video_import_start_pressed")
	var old_dataset_preserved: bool = main.get_current_frame() == 5 \
		and str(main.get("_manifest").get("dataset_id", "")) == old_dataset_id
	var heartbeat := 0
	while controller.is_running() and heartbeat < 12000:
		heartbeat += 1
		old_dataset_preserved = old_dataset_preserved and main.get_current_frame() == 5 \
			and str(main.get("_manifest").get("dataset_id", "")) == old_dataset_id
		await process_frame
	var elapsed_s := float(Time.get_ticks_usec() - started) / 1_000_000.0
	await process_frame
	var fractions: Array[float] = []
	var stages: Array[String] = []
	for payload: Dictionary in progress_events:
		fractions.append(float(payload.get("fraction", 0.0)))
		var stage := str(payload.get("stage", ""))
		if not stages.has(stage):
			stages.append(stage)
	var output_path: String = options["output"]
	var manifest: Dictionary = main.get("_manifest")
	var result := {
		"benchmark": "Part 3.1 real background video import",
		"timestamp_utc": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"processor": OS.get_processor_name(),
		"input_path": options["input"],
		"input_bytes": FileAccess.get_file_as_bytes(options["input"]).size(),
		"output_path": output_path,
		"output_bytes": _directory_size(output_path),
		"import_and_open_seconds": snappedf(elapsed_s, 0.001),
		"ui_process_heartbeats": heartbeat,
		"progress_event_count": progress_events.size(),
		"observed_progress_stages": stages,
		"progress_monotonic": fractions == _sorted_copy(fractions),
		"completed_paths": completed_paths,
		"failures": failures,
		"cancelled": cancelled[0],
		"old_dataset_preserved_during_import": old_dataset_preserved,
		"loaded_frame": main.get_current_frame(),
		"loaded_frame_count": int(manifest.get("frame_count", 0)),
		"loaded_source_name": str(manifest.get("source_name", "")),
	}
	result["pass"] = not controller.is_running() and failures.is_empty() \
		and not cancelled[0] and completed_paths == [output_path] \
		and old_dataset_preserved and heartbeat > 1 \
		and DirAccess.dir_exists_absolute(output_path) \
		and result["loaded_frame"] == 0 and int(result["loaded_frame_count"]) > 0 \
		and result["loaded_source_name"] == str(options["input"]).get_file() \
		and result["progress_monotonic"]
	_write_json(options["result"], result)
	print(JSON.stringify(result))
	main.queue_free()
	await process_frame
	quit(0 if result["pass"] else 1)


func _sorted_copy(values: Array[float]) -> Array[float]:
	var result := values.duplicate()
	result.sort()
	return result


func _directory_size(path: String) -> int:
	var directory := DirAccess.open(path)
	if directory == null:
		return 0
	var total := 0
	for file_name: String in directory.get_files():
		total += FileAccess.get_file_as_bytes(path.path_join(file_name)).size()
	for child_name: String in directory.get_directories():
		total += _directory_size(path.path_join(child_name))
	return total


func _parse_options(arguments: PackedStringArray) -> Dictionary:
	var result := {"input": "", "output": "", "result": "/tmp/part3_1_import.json"}
	var index := 0
	while index < arguments.size():
		if arguments[index] == "--input" and index + 1 < arguments.size():
			result["input"] = arguments[index + 1]
			index += 1
		elif arguments[index] == "--output" and index + 1 < arguments.size():
			result["output"] = arguments[index + 1]
			index += 1
		elif arguments[index] == "--result" and index + 1 < arguments.size():
			result["result"] = arguments[index + 1]
			index += 1
		index += 1
	return result


func _write_json(path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  ") + "\n")
