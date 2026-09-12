class_name CocoExportService
extends Node

const EXACT_JSON := preload("res://client/domain/exact_json.gd")

signal progress(value: Dictionary)
signal finished(result: Dictionary)

@export var python_path := "res://.venv/bin/python"
@export var worker_path := "res://python/coco_export.py"
@export var job_root := "user://coco-export-jobs"

var _pid := -1
var _request_thread: Thread
var _python_executable := ""
var _worker_absolute_path := ""
var _operation := ""
var _job_dir := ""
var _request_path := ""
var _result_path := ""
var _progress_path := ""
var _cancel_path := ""
var _cancel_requested := false
var _last_progress: Dictionary = {}
var _last_fraction := 0.0
var last_result: Dictionary = {}
var last_job_dir := ""


func start_prepare(context: Dictionary) -> PackedStringArray:
	return _start({
		"schema_version": 1,
		"operation": "prepare",
		"context": context.duplicate(true),
	})


func start_export(
	context: Dictionary,
	output_parent: String,
	expected_preparation_digest: String,
) -> PackedStringArray:
	return _start({
		"schema_version": 1,
		"operation": "export",
		"context": context.duplicate(true),
		"output_parent": ProjectSettings.globalize_path(output_parent).simplify_path(),
		"expected_preparation_digest": expected_preparation_digest,
	})


func _start(request: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if is_running():
		return PackedStringArray(["A COCO export worker is already running"])
	var project_python := OS.get_environment("PROJECT6_PYTHON").strip_edges()
	if project_python.is_empty():
		project_python = ProjectSettings.globalize_path(python_path).simplify_path()
	var worker := ProjectSettings.globalize_path(worker_path).simplify_path()
	if not FileAccess.file_exists(project_python):
		errors.append("Project Python was not found: %s" % project_python)
	if not FileAccess.file_exists(worker):
		errors.append("COCO export worker was not found: %s" % worker)
	var root := ProjectSettings.globalize_path(job_root).simplify_path().trim_suffix("/")
	if root.is_empty():
		errors.append("COCO export job root is empty")
	elif DirAccess.make_dir_recursive_absolute(root) != OK:
		errors.append("Could not create COCO export job root: %s" % root)
	if not errors.is_empty():
		return errors

	var job_id := "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_job_dir = root.path_join(job_id)
	last_job_dir = _job_dir
	if DirAccess.make_dir_absolute(_job_dir) != OK:
		_reset()
		return PackedStringArray(["Could not create COCO export job"])
	_request_path = _job_dir.path_join("request.json")
	_result_path = _job_dir.path_join("result.json")
	_progress_path = _job_dir.path_join("progress.json")
	_cancel_path = _job_dir.path_join("cancel.request")
	_operation = String(request.operation)
	_cancel_requested = false
	_last_progress.clear()
	_last_fraction = 0.0
	_python_executable = project_python
	_worker_absolute_path = worker
	_request_thread = Thread.new()
	var thread_error := _request_thread.start(
		_write_request.bind(_request_path, request))
	if thread_error != OK:
		_request_thread = null
		_cleanup_job()
		_reset()
		return PackedStringArray([
			"Could not start the COCO request writer: %s" % error_string(thread_error)])
	set_process(true)
	return PackedStringArray()


func cancel() -> void:
	if not is_running() or _cancel_requested:
		return
	_cancel_requested = true
	var file := FileAccess.open(_cancel_path, FileAccess.WRITE)
	if file != null:
		file.store_string("cancel\n")
		file.close()


func cancel_and_drain() -> void:
	cancel()
	while is_running():
		await get_tree().process_frame


func is_running() -> bool:
	return _request_thread != null or _pid > 0


func _process(_delta: float) -> void:
	if _request_thread != null:
		if _request_thread.is_alive():
			return
		var startup: Variant = _request_thread.wait_to_finish()
		_request_thread = null
		if not startup is Dictionary or not startup.get("success", false):
			_complete_without_process(_failure(
				"SAVE_FAILED",
				String(startup.get("error", "Could not write COCO export request"))
					if startup is Dictionary
					else "Could not write COCO export request",
			))
			return
		if _cancel_requested:
			_complete_without_process(_cancelled_result())
			return
		_pid = OS.create_process(_python_executable, PackedStringArray([
			_worker_absolute_path,
			"--request", _request_path,
			"--result", _result_path,
			"--progress-file", _progress_path,
			"--cancel-file", _cancel_path,
		]), false)
		if _pid <= 0:
			_complete_without_process(_failure(
				"BACKGROUND_START_FAILED", "Could not start the COCO export worker"))
		return
	if not is_running():
		return
	_poll_progress()
	if OS.is_process_running(_pid):
		return
	_finish_process(OS.get_process_exit_code(_pid))


func _poll_progress() -> void:
	var value: Variant = _read_json(_progress_path)
	if not value is Dictionary:
		return
	var payload := value as Dictionary
	if not _valid_progress(payload) or payload == _last_progress:
		return
	var fraction := float(payload.fraction)
	if fraction + 0.000000001 < _last_fraction:
		return
	_last_fraction = fraction
	_last_progress = payload.duplicate(true)
	progress.emit(payload.duplicate(true))


func _finish_process(exit_code: int) -> void:
	_poll_progress()
	var value: Variant = _read_json(_result_path)
	var result: Dictionary
	if value is Dictionary and _valid_result(value, _operation):
		result = value.duplicate(true)
	else:
		result = _failure(
			"PACKAGE_INVALID",
			"COCO export worker exited without a valid result (exit %d)" % exit_code,
		)
	if exit_code == 0 and not result.get("success", false):
		result = _failure(
			"PACKAGE_INVALID",
			"COCO export worker reported failure with a successful process exit",
		)
	elif exit_code != 0 and exit_code != 130 and result.get("success", false):
		result = _failure(
			"PACKAGE_INVALID",
			"COCO export worker process failed after reporting success",
		)
	elif exit_code == 130 and not result.get("cancelled", false):
		result = _failure(
			"PACKAGE_INVALID",
			"COCO export worker used the cancellation exit without a cancellation result",
		)
	last_result = result.duplicate(true)
	_pid = -1
	set_process(false)
	_cleanup_job()
	_reset()
	finished.emit(result)


func _complete_without_process(result: Dictionary) -> void:
	last_result = result.duplicate(true)
	set_process(false)
	_cleanup_job()
	_reset()
	finished.emit(result)


func _valid_result(value: Dictionary, operation: String) -> bool:
	for field: String in [
		"success", "errors", "issues", "warnings", "output_path", "package_id",
		"package_type", "task", "saved_revision", "reused", "cancelled",
		"package_saved_revision", "summary", "timings_ms",
	]:
		if not value.has(field):
			return false
	if (
		typeof(value.success) != TYPE_BOOL
		or not value.errors is Array
		or not value.issues is Array
		or not value.warnings is Array
		or typeof(value.output_path) != TYPE_STRING
		or typeof(value.package_id) != TYPE_STRING
		or value.package_type != "training_coco_v1"
		or value.task not in ["detection", "instance_segmentation"]
		or not _integer(value.saved_revision)
		or not _integer(value.package_saved_revision)
		or typeof(value.reused) != TYPE_BOOL
		or typeof(value.cancelled) != TYPE_BOOL
		or not value.summary is Dictionary
		or not value.timings_ms is Dictionary
	):
		return false
	for collection: Array in [value.errors, value.issues, value.warnings]:
		for item: Variant in collection:
			if collection == value.errors and typeof(item) != TYPE_STRING:
				return false
			if collection != value.errors and not item is Dictionary:
				return false
	if value.success:
		if String(value.package_id).length() != 64:
			return false
		if not value.has("preparation_digest") \
				or String(value.preparation_digest).length() != 64:
			return false
		if operation == "export" and (
			String(value.output_path).is_empty()
			or not DirAccess.dir_exists_absolute(String(value.output_path))
		):
			return false
		if operation == "prepare" and not String(value.output_path).is_empty():
			return false
	return true


func _valid_progress(value: Dictionary) -> bool:
	return (
		typeof(value.get("stage")) == TYPE_STRING
		and not String(value.stage).is_empty()
		and _finite(value.get("fraction"))
		and float(value.fraction) >= 0.0
		and float(value.fraction) <= 1.0
		and typeof(value.get("message")) == TYPE_STRING
	)


func _read_json(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	return EXACT_JSON.parse_string(text)


func _cleanup_job() -> void:
	if _job_dir.is_empty():
		return
	var root := ProjectSettings.globalize_path(job_root).simplify_path().trim_suffix("/")
	if _job_dir.get_base_dir() != root:
		return
	_remove_tree(_job_dir)


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for child_name: String in directory.get_directories():
		if directory.is_link(child_name):
			DirAccess.remove_absolute(path.path_join(child_name))
		else:
			_remove_tree(path.path_join(child_name))
	DirAccess.remove_absolute(path)


func _reset() -> void:
	_pid = -1
	_request_thread = null
	_python_executable = ""
	_worker_absolute_path = ""
	_operation = ""
	_job_dir = ""
	_request_path = ""
	_result_path = ""
	_progress_path = ""
	_cancel_path = ""
	_cancel_requested = false
	_last_progress.clear()
	_last_fraction = 0.0


func _failure(code: String, message: String) -> Dictionary:
	return {
		"success": false,
		"errors": ["%s: %s" % [code, message]],
		"issues": [{"code": code, "message": message}],
		"warnings": [],
		"output_path": "",
		"package_id": "",
		"package_type": "training_coco_v1",
		"task": "detection",
		"saved_revision": -1,
		"package_saved_revision": -1,
		"reused": false,
		"cancelled": false,
		"summary": {},
		"timings_ms": {},
	}


func _cancelled_result() -> Dictionary:
	var result := _failure("CANCELLED", "COCO export cancelled")
	result.errors = []
	result.issues = []
	result.cancelled = true
	return result


static func _write_request(path: String, request: Dictionary) -> Dictionary:
	var encoded := JSON.stringify(request, "", true, true) + "\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "error": "Could not write COCO export request"}
	file.store_string(encoded)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		return {
			"success": false,
			"error": "Could not finish the COCO export request: %s" % error_string(write_error),
		}
	return {"success": true}


func _finite(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
	)


func _integer(value: Variant) -> bool:
	return _finite(value) and float(value) == floorf(float(value))


func _exit_tree() -> void:
	if is_running():
		cancel()
	if _request_thread != null:
		_request_thread.wait_to_finish()
		_request_thread = null
		_cleanup_job()
		_reset()
