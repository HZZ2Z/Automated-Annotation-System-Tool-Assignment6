extends SceneTree

const MAIN_SCENE := preload("res://client/app/main.tscn")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	var memory_before := Performance.get_monitor(Performance.MEMORY_STATIC)
	var main := MAIN_SCENE.instantiate() as Control
	root.add_child(main)
	await process_frame
	main.set_process(false)
	var started := Time.get_ticks_usec()
	var errors: PackedStringArray = main.open_source(options["source"])
	var open_ms := float(Time.get_ticks_usec() - started) / 1000.0
	if not errors.is_empty():
		_write_json(options["output"], {"pass": false, "errors": errors, "client_open_ms": open_ms})
		quit(2)
		return
	var targets := [0, 5000, 9999, 137, 8765]
	var seek_times_ms: Array[float] = []
	var accepted: Array[int] = []
	for target: int in targets:
		started = Time.get_ticks_usec()
		if main.seek(target):
			accepted.append(main.get_current_frame())
		seek_times_ms.append(float(Time.get_ticks_usec() - started) / 1000.0)
		await process_frame
	var source = main.get("_source")
	var cache = source.get("_cache")
	var explorer = main.get_node("MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer")
	var timeline = main.get_node("MainVBox/TimelinePanel/TimelineColumn/Timeline")
	var item_count := _tree_item_count(explorer.get_node("Tree") as Tree)
	var memory_after := Performance.get_monitor(Performance.MEMORY_STATIC)
	var result := {
		"benchmark": "Part 3.1 10000-frame bounded-source stress",
		"timestamp_utc": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"processor": OS.get_processor_name(),
		"frame_count": int(main.get("_manifest").get("frame_count", 0)),
		"client_open_ms": snappedf(open_ms, 0.001),
		"seek_targets": targets,
		"accepted_indices": accepted,
		"seek_times_ms": seek_times_ms,
		"mean_seek_ms": snappedf(_mean(seek_times_ms), 0.001),
		"p95_seek_ms": snappedf(_percentile(seek_times_ms, 0.95), 0.001),
		"texture_cache_size": cache.size(),
		"texture_cache_limit": cache.get("max_size"),
		"explorer_tree_items": item_count,
		"explorer_materialized_frame_items": explorer.get("_frame_items").size(),
		"timeline_child_nodes": timeline.get_child_count(),
		"timeline_frame_buttons": timeline.find_children("*", "Button", true, false).size(),
		"static_memory_before_bytes": memory_before,
		"static_memory_after_bytes": memory_after,
	}
	result["pass"] = result["frame_count"] == 10000 and accepted == targets \
		and int(result["texture_cache_size"]) <= 12 \
		and int(result["texture_cache_limit"]) == 12 \
		and int(result["explorer_tree_items"]) <= 8 \
		and int(result["explorer_materialized_frame_items"]) == 1 \
		and int(result["timeline_child_nodes"]) <= 1 \
		and int(result["timeline_frame_buttons"]) == 0
	_write_json(options["output"], result)
	print(JSON.stringify(result))
	main.queue_free()
	await process_frame
	quit(0 if result["pass"] else 1)


func _tree_item_count(tree: Tree) -> int:
	var root_item := tree.get_root()
	return _branch_count(root_item) if root_item != null else 0


func _branch_count(item: TreeItem) -> int:
	var count := 1
	var child := item.get_first_child()
	while child != null:
		count += _branch_count(child)
		child = child.get_next()
	return count


func _mean(values: Array[float]) -> float:
	var total := 0.0
	for value: float in values:
		total += value
	return total / values.size() if not values.is_empty() else 0.0


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var ordered := values.duplicate()
	ordered.sort()
	return ordered[clampi(int(ceil(fraction * ordered.size())) - 1, 0, ordered.size() - 1)]


func _parse_options(arguments: PackedStringArray) -> Dictionary:
	var result := {"source": "/tmp/annotool-part3-stress", "output": "/tmp/part3_1_long_source.json"}
	var index := 0
	while index < arguments.size():
		if arguments[index] == "--source" and index + 1 < arguments.size():
			result["source"] = arguments[index + 1]
			index += 1
		elif arguments[index] == "--output" and index + 1 < arguments.size():
			result["output"] = arguments[index + 1]
			index += 1
		index += 1
	return result


func _write_json(path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  ") + "\n")
