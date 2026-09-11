class_name WorkspaceMediaController
extends Node


signal media_ready(payload: Dictionary)
signal media_failed(message: String)
signal import_started(input_path: String, output_path: String)
signal import_progress(payload: Dictionary)
signal import_cancelled
signal media_preparation_started(media_id: String)
signal media_preparation_progress(payload: Dictionary)
signal media_preparation_cancelled(media_id: String)

const PATHS_SCRIPT := preload("res://client/workspace/workspace_paths.gd")
const BACKGROUND_JOB := preload("res://client/services/background_job.gd")


class SourceWorker extends RefCounted:
	func run(
		factory: Variant,
		locator: String,
		preferred_id: String,
		token: Variant,
	) -> Dictionary:
		if token.is_cancelled():
			return {"source": null, "plugin_id": preferred_id,
				"errors": PackedStringArray(["Media preparation cancelled"]),
				"cancelled": true}
		var opened: Variant
		if _method_arity(factory, "open") >= 3:
			opened = factory.open(locator, preferred_id, token)
		else:
			opened = factory.open(locator, preferred_id)
		if not opened is Dictionary:
			return {"source": null, "plugin_id": preferred_id,
				"errors": PackedStringArray(["Source factory must return a Dictionary"]),
				"cancelled": token.is_cancelled()}
		var source: Variant = opened.get("source")
		if token.is_cancelled():
			if source is Object and source != null and source.has_method("close"):
				source.close()
			return {"source": null, "plugin_id": String(opened.get("plugin_id", "")),
				"errors": PackedStringArray(["Media preparation cancelled"]),
				"cancelled": true}
		var result := (opened as Dictionary).duplicate()
		result["cancelled"] = false
		return result

	func _method_arity(object: Variant, method_name: String) -> int:
		if not object is Object or not object.has_method(method_name):
			return -1
		for method: Dictionary in object.get_method_list():
			if method.get("name") == method_name:
				return Array(method.get("args", [])).size()
		return -1


var _workspace_root := ""
var _importer: Variant
var _source_factory: Variant
var _source_plugin_id := ""
var _pending_entry: Dictionary = {}
var _pending_cache_path := ""
var _source_job: Variant
var _source_worker := SourceWorker.new()
var _generation := 0
var _running_source_generation := -1
var _running_source_entry: Dictionary = {}
var _queued_source_request: Dictionary = {}
var _explicit_cancelled_generation := -1


func _init() -> void:
	_source_job = BACKGROUND_JOB.new()
	add_child(_source_job)
	_source_job.progress.connect(_on_source_progress)
	_source_job.finished.connect(_on_source_finished)


func configure(
	workspace_root: String,
	importer: Variant,
	source_factory: Variant,
	preferred_source_plugin_id: String = ""
) -> void:
	_disconnect_importer()
	_generation += 1
	_queued_source_request.clear()
	_explicit_cancelled_generation = _running_source_generation
	if _source_job != null:
		_source_job.cancel()
	_workspace_root = ProjectSettings.globalize_path(
		workspace_root).simplify_path().trim_suffix("/")
	_importer = importer
	_source_factory = source_factory
	_source_plugin_id = preferred_source_plugin_id
	if _importer is Object:
		_connect_importer_signal("progress", _on_import_progress)
		_connect_importer_signal("completed", _on_import_completed)
		_connect_importer_signal("failed", _on_import_failed)
		_connect_importer_signal("cancelled", _on_import_cancelled)


func select_media(media_entry: Dictionary) -> PackedStringArray:
	var plugin_owned := not String(media_entry.get("source_plugin_id", "")).is_empty()
	if is_busy() and not (plugin_owned and _source_job != null and _source_job.is_running()):
		return PackedStringArray(["A media selection is already being prepared"])
	var errors := _entry_errors(media_entry)
	if not errors.is_empty():
		return errors
	if plugin_owned:
		return _open_source_media(media_entry)
	match String(media_entry["media_type"]):
		"image":
			return _open_source_media(media_entry)
		"image_sequence":
			return _open_sequence(media_entry)
		"video":
			return _open_or_import_video(media_entry)
	return PackedStringArray(["Unsupported workspace media type"])


func is_busy() -> bool:
	return (
		not _pending_entry.is_empty()
		or (_source_job != null and _source_job.is_running())
		or not _queued_source_request.is_empty()
		or (
			_importer is Object
			and _importer.has_method("is_running")
			and bool(_importer.is_running())
		)
	)


func cancel() -> void:
	_generation += 1
	_queued_source_request.clear()
	if _source_job != null and _source_job.is_running():
		_explicit_cancelled_generation = _running_source_generation
		_source_job.cancel()
	if (
		_importer is Object
		and _importer.has_method("cancel")
		and _importer.has_method("is_running")
		and bool(_importer.is_running())
	):
		_importer.cancel()


func cancel_and_drain() -> void:
	cancel()
	while is_busy():
		await get_tree().process_frame


func _open_source_media(media_entry: Dictionary) -> PackedStringArray:
	if not String(media_entry.get("source_plugin_id", "")).is_empty():
		return _start_source_media(media_entry)
	var opened := _open_source(
		media_entry["source_path"],
		String(media_entry.get("source_plugin_id", "")),
	)
	var errors: PackedStringArray = opened["errors"]
	if not errors.is_empty():
		return _emit_failure(errors)
	var source: Variant = opened["source"]
	var entry := media_entry.duplicate(true)
	entry["source_sha256"] = source.get_manifest().get("source_sha256")
	media_ready.emit({
		"source": source,
		"media_entry": entry,
		"source_path": media_entry["source_path"],
		"import_statistics": _source_import_statistics(source),
	})
	return PackedStringArray()


func _start_source_media(media_entry: Dictionary) -> PackedStringArray:
	_generation += 1
	_explicit_cancelled_generation = -1
	var request := {
		"generation": _generation,
		"entry": media_entry.duplicate(true),
	}
	if _source_job.is_running():
		_source_job.cancel()
		_queued_source_request = request
		return PackedStringArray()
	return _launch_source_request(request)


func _launch_source_request(request: Dictionary) -> PackedStringArray:
	_running_source_generation = int(request.generation)
	_running_source_entry = (request.entry as Dictionary).duplicate(true)
	var errors: PackedStringArray = _source_job.start(Callable(_source_worker, "run"), [
		_source_factory,
		String(_running_source_entry.source_path),
		String(_running_source_entry.get("source_plugin_id", _source_plugin_id)),
	])
	if not errors.is_empty():
		_running_source_generation = -1
		_running_source_entry.clear()
		return _emit_failure(errors)
	media_preparation_started.emit(String(_running_source_entry.media_id))
	return PackedStringArray()


func _on_source_progress(payload: Dictionary) -> void:
	if _running_source_generation != _generation:
		return
	var snapshot := payload.duplicate(true)
	snapshot["generation"] = _running_source_generation
	snapshot["media_id"] = String(_running_source_entry.get("media_id", ""))
	media_preparation_progress.emit(snapshot)


func _on_source_finished(value: Dictionary) -> void:
	var finished_generation := _running_source_generation
	var finished_entry := _running_source_entry.duplicate(true)
	var next := _queued_source_request.duplicate()
	_queued_source_request.clear()
	_running_source_generation = -1
	_running_source_entry.clear()
	if not next.is_empty():
		_launch_source_request(next)

	var source: Variant = value.get("source")
	var stale := finished_generation != _generation
	var cancelled := bool(value.get("cancelled", false))
	var errors_value: Variant = value.get("errors")
	var errors := (
		PackedStringArray(errors_value)
		if errors_value is PackedStringArray
		else PackedStringArray(["Source factory errors must be PackedStringArray"])
	)
	if stale or cancelled or not errors.is_empty():
		if source is Object and source != null and source.has_method("close"):
			source.close()
		if finished_generation == _explicit_cancelled_generation and next.is_empty():
			_explicit_cancelled_generation = -1
			media_preparation_cancelled.emit(String(finished_entry.get("media_id", "")))
		elif not stale and not cancelled:
			_emit_failure(errors)
		return
	if not source is Object or source == null:
		_emit_failure(PackedStringArray(["Source factory returned no opened Source"]))
		return
	finished_entry["source_sha256"] = source.get_manifest().get("source_sha256")
	media_ready.emit({
		"source": source,
		"media_entry": finished_entry,
		"source_path": finished_entry.source_path,
		"import_statistics": _source_import_statistics(source),
	})


func _open_sequence(media_entry: Dictionary) -> PackedStringArray:
	var opened := _open_source(media_entry["source_path"])
	var errors: PackedStringArray = opened["errors"]
	if not errors.is_empty():
		return _emit_failure(errors)
	var source: Variant = opened["source"]
	var entry := media_entry.duplicate(true)
	entry["source_sha256"] = source.get_manifest().get("source_sha256")
	media_ready.emit({
		"source": source,
		"media_entry": entry,
		"source_path": media_entry["source_path"],
		"import_statistics": _source_import_statistics(source),
	})
	return PackedStringArray()


func _open_or_import_video(media_entry: Dictionary) -> PackedStringArray:
	var source_path: String = media_entry["source_path"]
	var digest := FileAccess.get_sha256(source_path)
	if digest.length() != 64:
		return _emit_failure(PackedStringArray([
			"Video SHA-256 could not be calculated: %s" % source_path]))
	var cache_path := PATHS_SCRIPT.cache_path(
		_workspace_root, media_entry["media_id"])
	if DirAccess.dir_exists_absolute(cache_path):
		return _open_cached_video(media_entry, cache_path, digest)
	if FileAccess.file_exists(cache_path):
		return _emit_failure(PackedStringArray([
			"Deterministic video cache path is occupied by a file: %s" % cache_path]))
	var cache_parent := cache_path.get_base_dir()
	var make_error := DirAccess.make_dir_recursive_absolute(cache_parent)
	if make_error != OK:
		return _emit_failure(PackedStringArray([
			"Cannot create video cache parent %s (%s)" % [
				cache_parent, error_string(make_error)]]))
	if not _importer is Object or not _importer.has_method("start"):
		return _emit_failure(PackedStringArray(["Video importer is unavailable"]))
	var start_result: Variant = _importer.start(source_path, cache_path)
	if not start_result is PackedStringArray:
		return _emit_failure(PackedStringArray([
			"Video importer start must return PackedStringArray"]))
	var errors := start_result as PackedStringArray
	if not errors.is_empty():
		return _emit_failure(errors)
	_pending_entry = media_entry.duplicate(true)
	_pending_entry["source_sha256"] = digest
	_pending_cache_path = cache_path
	import_started.emit(source_path, cache_path)
	return PackedStringArray()


func _open_cached_video(
	media_entry: Dictionary,
	cache_path: String,
	expected_digest: String
) -> PackedStringArray:
	var opened := _open_source(cache_path)
	var errors: PackedStringArray = opened["errors"]
	if not errors.is_empty():
		return _emit_failure(PackedStringArray([
			"Existing video cache is invalid and was preserved: %s" % errors[0]]))
	var source: Variant = opened["source"]
	var actual_digest: Variant = source.get_manifest().get("source_sha256")
	if actual_digest != expected_digest:
		source.close()
		return _emit_failure(PackedStringArray([
			"Existing video cache belongs to different source data: %s" % cache_path]))
	var entry := media_entry.duplicate(true)
	entry["source_sha256"] = expected_digest
	media_ready.emit({
		"source": source,
		"media_entry": entry,
		"source_path": cache_path,
		"import_statistics": _source_import_statistics(source),
	})
	return PackedStringArray()


func _open_source(locator: String, preferred_id: String = "") -> Dictionary:
	if not _source_factory is Object or not _source_factory.has_method("open"):
		return {
			"source": null,
			"plugin_id": "",
			"errors": PackedStringArray(["Source factory is unavailable"]),
		}
	var routed_preference := (
		preferred_id if not preferred_id.is_empty() else _source_plugin_id)
	var value: Variant = _source_factory.open(locator, routed_preference)
	if not value is Dictionary:
		return {
			"source": null,
			"plugin_id": "",
			"errors": PackedStringArray([
				"Source factory must return a Dictionary"]),
		}
	var errors: Variant = value.get("errors")
	var source: Variant = value.get("source")
	if not errors is PackedStringArray:
		if source is Object and source != null and source.has_method("close"):
			source.close()
		return {
			"source": null,
			"plugin_id": String(value.get("plugin_id", "")),
			"errors": PackedStringArray([
				"Source factory errors must be PackedStringArray"]),
		}
	if errors.is_empty() and (not source is Object or source == null):
		return {
			"source": null,
			"plugin_id": String(value.get("plugin_id", "")),
			"errors": PackedStringArray([
				"Source factory returned no opened Source"]),
		}
	return {
		"source": source,
		"plugin_id": String(value.get("plugin_id", "")),
		"errors": PackedStringArray(errors),
	}


func _on_import_progress(payload: Dictionary) -> void:
	import_progress.emit(payload.duplicate(true))


func _on_import_completed(output_path: String) -> void:
	if _pending_entry.is_empty():
		return
	var entry := _pending_entry.duplicate(true)
	var expected_path := _pending_cache_path
	_pending_entry.clear()
	_pending_cache_path = ""
	if output_path.simplify_path() != expected_path:
		_emit_failure(PackedStringArray([
			"Video importer published an unexpected cache path: %s" % output_path]))
		return
	_open_cached_video(entry, expected_path, entry["source_sha256"])


func _on_import_failed(message: String) -> void:
	_pending_entry.clear()
	_pending_cache_path = ""
	media_failed.emit(message)


func _on_import_cancelled() -> void:
	_pending_entry.clear()
	_pending_cache_path = ""
	import_cancelled.emit()


func _emit_failure(errors: PackedStringArray) -> PackedStringArray:
	if not errors.is_empty():
		media_failed.emit(errors[0])
	return errors


func _source_import_statistics(source: Variant) -> Dictionary:
	if not source is Object or source == null or not source.has_method(
		"get_import_statistics"):
		return {}
	var value: Variant = source.get_import_statistics()
	return value.duplicate(true) if value is Dictionary else {}


func _entry_errors(entry: Dictionary) -> PackedStringArray:
	for field: String in [
		"display_name", "media_id", "media_type", "source_path", "relative_path"
	]:
		var value: Variant = entry.get(field)
		if typeof(value) != TYPE_STRING or value.strip_edges().is_empty():
			return PackedStringArray(["Workspace media %s must be non-empty text" % field])
	if not PATHS_SCRIPT.is_portable_media_id(entry["media_id"]):
		return PackedStringArray(["Workspace media_id is not portable"])
	if entry["media_type"] not in ["image", "video", "image_sequence"]:
		return PackedStringArray(["Workspace media type is unsupported"])
	var entry_source_plugin_id: Variant = entry.get("source_plugin_id", "")
	if (
		typeof(entry_source_plugin_id) != TYPE_STRING
		or (
			not entry_source_plugin_id.is_empty()
			and not entry_source_plugin_id.is_valid_identifier()
		)
	):
		return PackedStringArray(["Workspace source_plugin_id is invalid"])
	var baseline_kind: Variant = entry.get("baseline_kind", "empty")
	if (
		typeof(baseline_kind) != TYPE_STRING
		or String(baseline_kind) not in ["empty", "model", "imported_labels"]
	):
		return PackedStringArray(["Workspace baseline_kind is invalid"])
	if (
		entry["media_type"] == "image_sequence"
		and String(entry.get("source_plugin_id", "")).is_empty()
		and not DirAccess.dir_exists_absolute(entry["source_path"])
	):
		return PackedStringArray(["Workspace image sequence does not exist"])
	if (
		entry["media_type"] != "image_sequence"
		and not FileAccess.file_exists(entry["source_path"])
	):
		return PackedStringArray(["Workspace media file does not exist"])
	return PackedStringArray()


func _connect_importer_signal(signal_name: StringName, callback: Callable) -> void:
	if _importer.has_signal(signal_name) and not _importer.is_connected(
		signal_name, callback):
		_importer.connect(signal_name, callback)


func _disconnect_importer() -> void:
	if not _importer is Object:
		return
	for value: Array in [
		[&"progress", Callable(self, "_on_import_progress")],
		[&"completed", Callable(self, "_on_import_completed")],
		[&"failed", Callable(self, "_on_import_failed")],
		[&"cancelled", Callable(self, "_on_import_cancelled")],
	]:
		var signal_name: StringName = value[0]
		var callback: Callable = value[1]
		if _importer.has_signal(signal_name) and _importer.is_connected(
			signal_name, callback):
			_importer.disconnect(signal_name, callback)
