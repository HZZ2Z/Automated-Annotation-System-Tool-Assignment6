extends SceneTree

const PLUGIN_REGISTRY := preload("res://client/pipeline/plugin_registry.gd")
const SOURCE_FACTORY := preload("res://client/pipeline/source_factory.gd")
const CATALOG_CONTROLLER := preload(
	"res://client/workspace/workspace_catalog_controller.gd")
const MEDIA_CONTROLLER := preload(
	"res://client/workspace/workspace_media_controller.gd")
const PRIMARY_MEDIA_ID := "endoscapes_train_video_004"
const SECONDARY_MEDIA_ID := "endoscapes_train_video_001"
const TEXTURE_LOAD_COUNT := 15
const OPEN_TIMEOUT_MSEC := 120000

var _catalog_controller: Variant
var _media_controller: Variant
var _owned_sources: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	var dataset_root := String(options.get("dataset_root", ""))
	var output_path := String(options.get("output", ""))
	if dataset_root.is_empty() or output_path.is_empty():
		await _finish(output_path, {}, PackedStringArray([
			"--dataset-root and --output are required"]))
		return
	dataset_root = ProjectSettings.globalize_path(dataset_root).simplify_path()
	output_path = ProjectSettings.globalize_path(output_path).simplify_path()

	var registry = PLUGIN_REGISTRY.new()
	var errors: PackedStringArray = registry.discover("res://client/plugins")
	if not errors.is_empty():
		await _finish(output_path, {}, errors)
		return
	var factory = SOURCE_FACTORY.new(registry)
	_catalog_controller = CATALOG_CONTROLLER.new()
	root.add_child(_catalog_controller)
	var scan_started_usec := Time.get_ticks_usec()
	var started: Dictionary = _catalog_controller.start(dataset_root, factory)
	errors = PackedStringArray(started.get("errors", PackedStringArray([
		"Catalog start returned invalid errors"])))
	if not errors.is_empty():
		await _finish(output_path, {}, errors)
		return
	var heartbeats := 0
	while _catalog_controller.is_busy():
		await process_frame
		heartbeats += 1
	var terminal: Dictionary = await _catalog_controller.wait_for(
		int(started.get("generation", -1)))
	var scan_elapsed := float(Time.get_ticks_usec() - scan_started_usec) / 1000000.0
	if not bool(terminal.get("success", false)):
		errors = PackedStringArray(terminal.get("errors", [
			"Catalog scan did not succeed"]))
		await _finish(output_path, {}, errors)
		return
	var catalog: Variant = terminal.get("catalog")
	if not catalog is Object or catalog == null:
		await _finish(output_path, {}, PackedStringArray([
			"Catalog scan returned no catalog"]))
		return
	var entries: Array = catalog.get_entries()
	var ids: Array[String] = []
	var unique_ids := {}
	var retained_workspace_frame_paths := 0
	for value: Variant in entries:
		var entry := value as Dictionary
		var media_id := String(entry.get("media_id", ""))
		ids.append(media_id)
		unique_ids[media_id] = true
		var retained: Variant = entry.get("frame_paths", [])
		if retained is Array:
			retained_workspace_frame_paths += retained.size()
	ids.sort()
	var primary_entry: Dictionary = catalog.get_entry(PRIMARY_MEDIA_ID)
	var secondary_entry: Dictionary = catalog.get_entry(SECONDARY_MEDIA_ID)
	if primary_entry.is_empty() or secondary_entry.is_empty():
		await _finish(output_path, {}, PackedStringArray([
			"Real acceptance requires Endoscapes train videos 004 and 001"]))
		return

	_media_controller = MEDIA_CONTROLLER.new()
	root.add_child(_media_controller)
	_media_controller.configure(dataset_root, null, factory)
	var primary_opened := await _open_media(primary_entry)
	if not bool(primary_opened.get("success", false)):
		await _finish(output_path, {}, PackedStringArray(
			primary_opened.get("errors", ["Primary video did not open"])))
		return
	var primary_source: Variant = primary_opened.payload.get("source")
	_owned_sources.append(primary_source)
	var primary_count := int(primary_source.get_frame_count())
	if primary_count < TEXTURE_LOAD_COUNT:
		await _finish(output_path, {}, PackedStringArray([
			"Primary acceptance video has fewer than %d frames" % TEXTURE_LOAD_COUNT]))
		return
	var first_entry: Dictionary = primary_source.get_frame_entry(0)
	var last_entry: Dictionary = primary_source.get_frame_entry(primary_count - 1)
	var primary_retained := int(primary_source.get_retained_frame_path_count())
	var successful_texture_loads := 0
	var texture_cache_peak := 0
	for index in range(TEXTURE_LOAD_COUNT):
		var texture: Variant = primary_source.load_texture(index)
		if texture is Texture2D:
			successful_texture_loads += 1
		texture_cache_peak = maxi(texture_cache_peak, int(primary_source.get_cache_size()))

	var secondary_opened := await _open_media(secondary_entry)
	if not bool(secondary_opened.get("success", false)):
		await _finish(output_path, {}, PackedStringArray(
			secondary_opened.get("errors", ["Secondary video did not open"])))
		return
	var secondary_source: Variant = secondary_opened.payload.get("source")
	_owned_sources.append(secondary_source)
	primary_source.close()
	_owned_sources.erase(primary_source)
	var report := {
		"schema_version": 1,
		"evidence_type": "endoscapes-lazy-source-acceptance",
		"logical_video_count": entries.size(),
		"media_id_collisions": entries.size() - unique_ids.size(),
		"media_ids_sha256": ",".join(ids).sha256_text(),
		"workspace_retained_frame_paths": retained_workspace_frame_paths,
		"catalog_scan_elapsed_seconds": scan_elapsed,
		"catalog_scan_heartbeats": heartbeats,
		"selected_media_id": PRIMARY_MEDIA_ID,
		"selected_video_frame_count": primary_count,
		"selected_source_retained_frame_paths": primary_retained,
		"selected_first_frame_id": int(first_entry.get("frame_id", -1)),
		"selected_last_frame_id": int(last_entry.get("frame_id", -1)),
		"selected_import_statistics": (
			primary_opened.payload.get("import_statistics", {}).duplicate(true)),
		"secondary_media_id": SECONDARY_MEDIA_ID,
		"secondary_video_frame_count": int(secondary_source.get_frame_count()),
		"secondary_import_statistics": (
			secondary_opened.payload.get("import_statistics", {}).duplicate(true)),
		"texture_cache_limit": 12,
		"texture_load_attempt_count": TEXTURE_LOAD_COUNT,
		"texture_load_success_count": successful_texture_loads,
		"texture_cache_peak": texture_cache_peak,
		"old_source_retained_frame_paths_after_switch": int(
			primary_source.get_retained_frame_path_count()),
		"old_source_cache_size_after_switch": int(primary_source.get_cache_size()),
	}
	await _finish(output_path, report, PackedStringArray())


func _open_media(entry: Dictionary) -> Dictionary:
	var ready: Array[Dictionary] = []
	var failed: Array[String] = []
	var on_ready := func(payload: Dictionary) -> void:
		ready.append(payload.duplicate())
	var on_failed := func(message: String) -> void:
		failed.append(message)
	_media_controller.media_ready.connect(on_ready)
	_media_controller.media_failed.connect(on_failed)
	var errors: PackedStringArray = _media_controller.select_media(entry)
	var started := Time.get_ticks_msec()
	while (
		ready.is_empty()
		and failed.is_empty()
		and errors.is_empty()
		and Time.get_ticks_msec() - started < OPEN_TIMEOUT_MSEC
	):
		await process_frame
	_media_controller.media_ready.disconnect(on_ready)
	_media_controller.media_failed.disconnect(on_failed)
	if not errors.is_empty():
		return {"success": false, "errors": errors}
	if not failed.is_empty():
		return {"success": false, "errors": PackedStringArray(failed)}
	if ready.is_empty():
		return {"success": false, "errors": PackedStringArray([
			"Media preparation timed out"])}
	return {"success": true, "errors": PackedStringArray(), "payload": ready[0]}


func _parse_options(arguments: PackedStringArray) -> Dictionary:
	var result := {}
	var index := 0
	while index < arguments.size():
		var argument := arguments[index]
		if argument in ["--dataset-root", "--output"] and index + 1 < arguments.size():
			result[argument.trim_prefix("--").replace("-", "_")] = arguments[index + 1]
			index += 2
		else:
			index += 1
	return result


func _finish(
	output_path: String,
	report: Dictionary,
	errors: PackedStringArray,
) -> void:
	if _catalog_controller != null:
		await _catalog_controller.cancel_and_drain()
	if _media_controller != null:
		await _media_controller.cancel_and_drain()
	for source: Variant in _owned_sources:
		if source is Object and source != null and source.has_method("close"):
			source.close()
	_owned_sources.clear()
	var payload := report.duplicate(true)
	payload["success"] = errors.is_empty()
	payload["errors"] = errors
	if not output_path.is_empty():
		var stream := FileAccess.open(output_path, FileAccess.WRITE)
		if stream != null:
			stream.store_string(JSON.stringify(payload, "  ", false) + "\n")
			stream.close()
		else:
			printerr("Could not write Endoscapes acceptance result")
			quit(1)
			return
	if errors.is_empty():
		print("PASS: Endoscapes lazy Source real-data acceptance")
		quit(0)
	else:
		printerr("FAIL: %s" % "; ".join(errors))
		quit(1)
