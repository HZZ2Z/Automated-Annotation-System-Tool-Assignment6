class_name WorkspaceMediaController
extends Node


signal media_ready(payload: Dictionary)
signal media_failed(message: String)
signal import_started(input_path: String, output_path: String)
signal import_progress(payload: Dictionary)
signal import_cancelled

const PATHS_SCRIPT := preload("res://client/workspace/workspace_paths.gd")


var _workspace_root := ""
var _importer: Variant
var _source_factory: Variant
var _pending_entry: Dictionary = {}
var _pending_cache_path := ""


func configure(
	workspace_root: String,
	importer: Variant,
	source_factory: Variant
) -> void:
	_disconnect_importer()
	_workspace_root = ProjectSettings.globalize_path(
		workspace_root).simplify_path().trim_suffix("/")
	_importer = importer
	_source_factory = source_factory
	if _importer is Object:
		_connect_importer_signal("progress", _on_import_progress)
		_connect_importer_signal("completed", _on_import_completed)
		_connect_importer_signal("failed", _on_import_failed)
		_connect_importer_signal("cancelled", _on_import_cancelled)


func select_media(media_entry: Dictionary) -> PackedStringArray:
	if is_busy():
		return PackedStringArray(["A media selection is already being prepared"])
	var errors := _entry_errors(media_entry)
	if not errors.is_empty():
		return errors
	match String(media_entry["media_type"]):
		"image":
			return _open_image(media_entry)
		"image_sequence":
			return _open_sequence(media_entry)
		"video":
			return _open_or_import_video(media_entry)
	return PackedStringArray(["Unsupported workspace media type"])


func is_busy() -> bool:
	return (
		not _pending_entry.is_empty()
		or (
			_importer is Object
			and _importer.has_method("is_running")
			and bool(_importer.is_running())
		)
	)


func cancel() -> void:
	if (
		_importer is Object
		and _importer.has_method("cancel")
		and _importer.has_method("is_running")
		and bool(_importer.is_running())
	):
		_importer.cancel()


func _open_image(media_entry: Dictionary) -> PackedStringArray:
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
	})
	return PackedStringArray()


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
	})
	return PackedStringArray()


func _open_source(locator: String) -> Dictionary:
	if not _source_factory is Object or not _source_factory.has_method("open"):
		return {
			"source": null,
			"plugin_id": "",
			"errors": PackedStringArray(["Source factory is unavailable"]),
		}
	var value: Variant = _source_factory.open(locator)
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
	if (
		entry["media_type"] == "image_sequence"
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
