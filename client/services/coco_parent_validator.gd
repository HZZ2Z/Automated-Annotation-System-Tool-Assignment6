class_name CocoParentValidator
extends RefCounted

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
const PACKAGE := preload("res://client/feedback/training_package.gd")
const DIGEST_PATTERN := "^[0-9a-f]{64}$"


## Run the shared Python package validator from the caller's existing
## BackgroundJob.  The subprocess sees only this owned control directory and
## returns a detached parent descriptor; no active Store or Source is exposed.
static func read_descriptor(package_path: String, token: Variant = null) -> Dictionary:
	return _run_operation(package_path, "parent_descriptor", token)


## Validate a detached training package and return SourceStage-compatible pure data.
## This uses the same cancellable worker and never writes inside the package.
static func read_source_projection(
	package_path: String,
	token: Variant = null,
) -> Dictionary:
	return _run_operation(package_path, "source_projection", token)


static func _run_operation(
	package_path: String,
	operation: String,
	token: Variant,
) -> Dictionary:
	var python := OS.get_environment("PROJECT6_PYTHON").strip_edges()
	if python.is_empty():
		python = ProjectSettings.globalize_path("res://.venv/bin/python").simplify_path()
	var worker := ProjectSettings.globalize_path("res://python/coco_export.py").simplify_path()
	if not FileAccess.file_exists(python):
		return _failure("COCO parent validator Python was not found: %s" % python)
	if not FileAccess.file_exists(worker):
		return _failure("COCO parent validator worker was not found: %s" % worker)
	var job := "/tmp/project6-coco-parent-%d-%d" % [
		OS.get_process_id(), Time.get_ticks_usec()]
	if DirAccess.make_dir_absolute(job) != OK:
		return _failure("Could not create the COCO parent validation job")
	var request_path := job.path_join("request.json")
	var result_path := job.path_join("result.json")
	var progress_path := job.path_join("progress.json")
	var cancel_path := job.path_join("cancel.request")
	var request := {
		"schema_version": 1,
		"operation": operation,
		"package_path": ProjectSettings.globalize_path(package_path).simplify_path(),
	}
	var write_error := _write_text(
		request_path, JSON.stringify(request, "", true, true) + "\n")
	if not write_error.is_empty():
		_remove_owned_job(job)
		return _failure(write_error)
	var pid := OS.create_process(python, PackedStringArray([
		worker,
		"--request", request_path,
		"--result", result_path,
		"--progress-file", progress_path,
		"--cancel-file", cancel_path,
	]), false)
	if pid <= 0:
		_remove_owned_job(job)
		return _failure("Could not start the COCO parent validator")
	var cancel_sent := false
	var timed_out := false
	var last_progress := ""
	var deadline := Time.get_ticks_msec() + 120000
	while OS.is_process_running(pid):
		if (
			token != null
			and token.has_method("report_progress")
			and FileAccess.file_exists(progress_path)
		):
			var progress_text := FileAccess.get_file_as_string(progress_path)
			if not progress_text.is_empty() and progress_text != last_progress:
				last_progress = progress_text
				var progress_value: Variant = EXACT_JSON.parse_string(progress_text)
				if progress_value is Dictionary:
					token.report_progress((progress_value as Dictionary).duplicate(true))
		if PACKAGE.cancelled(token) and not cancel_sent:
			_write_text(cancel_path, "cancel\n")
			cancel_sent = true
		if Time.get_ticks_msec() >= deadline:
			if not cancel_sent:
				_write_text(cancel_path, "cancel\n")
				cancel_sent = true
				timed_out = true
				deadline = Time.get_ticks_msec() + 2000
			else:
				OS.kill(pid)
				break
		OS.delay_msec(10)
	var exit_code := OS.get_process_exit_code(pid)
	var value: Variant = null
	if FileAccess.file_exists(result_path):
		value = EXACT_JSON.parse_string(FileAccess.get_file_as_string(result_path))
	var result := _validate_result(value, exit_code, operation)
	if timed_out:
		result = _failure("COCO parent validation timed out")
	elif cancel_sent or PACKAGE.cancelled(token):
		result = {"success": false, "errors": [], "issues": [], "cancelled": true}
	_remove_owned_job(job)
	return result


static func _validate_result(
	value: Variant,
	exit_code: int,
	operation: String = "parent_descriptor",
) -> Dictionary:
	if not value is Dictionary:
		return _failure("COCO parent validator returned no valid JSON result")
	if typeof(value.get("success")) != TYPE_BOOL \
			or not value.get("errors") is Array \
			or not value.get("issues") is Array \
			or typeof(value.get("cancelled")) != TYPE_BOOL:
		return _failure("COCO parent validator result has an invalid contract")
	if value.cancelled:
		return {"success": false, "errors": [], "issues": [], "cancelled": true}
	if not value.success:
		if exit_code == 0:
			return _failure("COCO parent validator failed with a successful process exit")
		return value.duplicate(true)
	var result_field := (
		"projection" if operation == "source_projection" else "descriptor")
	if exit_code != 0 or not value.get(result_field) is Dictionary:
		return _failure("COCO parent validator process or descriptor is invalid")
	if operation == "source_projection":
		return _validate_projection(value)
	var descriptor: Dictionary = value.descriptor
	var required := [
		"package_type", "package_id", "media", "round_id", "model_revision",
		"taxonomy_version", "baseline", "source_frame_entries",
		"category_table_sha256",
	]
	for field: String in required:
		if not descriptor.has(field):
			return _failure("COCO parent descriptor is missing %s" % field)
	var pattern := RegEx.new()
	pattern.compile(DIGEST_PATTERN)
	if descriptor.package_type != "training_coco_v1" \
			or not descriptor.package_id is String \
			or pattern.search(descriptor.package_id) == null \
			or not descriptor.category_table_sha256 is String \
			or pattern.search(descriptor.category_table_sha256) == null \
			or not descriptor.media is Dictionary \
			or not descriptor.baseline is Dictionary \
			or not descriptor.source_frame_entries is Array:
		return _failure("COCO parent descriptor fields are invalid")
	return value.duplicate(true)


static func _validate_projection(value: Dictionary) -> Dictionary:
	var projection: Dictionary = value.projection
	for field: String in [
		"package_id", "task", "manifest", "frame_entries", "records",
		"artifacts", "statistics",
	]:
		if not projection.has(field):
			return _failure("COCO source projection is missing %s" % field)
	var pattern := RegEx.new()
	pattern.compile(DIGEST_PATTERN)
	if (
		typeof(projection.package_id) != TYPE_STRING
		or pattern.search(projection.package_id) == null
		or String(projection.task) not in ["detection", "instance_segmentation"]
		or not projection.manifest is Dictionary
		or not projection.frame_entries is Array
		or not projection.records is Array
		or not projection.artifacts is Array
		or not projection.statistics is Dictionary
		or projection.frame_entries.is_empty()
		or projection.frame_entries.size() != projection.records.size()
	):
		return _failure("COCO source projection fields are invalid")
	return value.duplicate(true)


static func _write_text(path: String, value: String) -> String:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Could not write COCO parent validation control file"
	file.store_string(value)
	file.flush()
	var error := file.get_error()
	file.close()
	return "" if error == OK else "Could not finish COCO parent validation control file"


static func _remove_owned_job(path: String) -> void:
	if path.get_base_dir() != "/tmp" or not path.get_file().begins_with(
			"project6-coco-parent-"):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for child_name: String in directory.get_directories():
		var child := path.path_join(child_name)
		var child_directory := DirAccess.open(child)
		if child_directory != null and child_directory.get_files().is_empty() \
				and child_directory.get_directories().is_empty():
			DirAccess.remove_absolute(child)
	DirAccess.remove_absolute(path)


static func _failure(message: String) -> Dictionary:
	return {
		"success": false,
		"errors": [message],
		"issues": [{"code": "PARENT_PACKAGE_MISMATCH", "message": message}],
		"cancelled": false,
	}
