class_name VideoImportController
extends Node

signal progress(payload: Dictionary)
signal completed(output_path: String)
signal failed(message: String)
signal cancelled

const README_HINT := "See README: Video import prerequisites."
const PROGRESS_FIELDS := {
	"version": true,
	"state": true,
	"stage": true,
	"completed": true,
	"total": true,
	"fraction": true,
	"message": true,
}
const PROGRESS_STAGES := {"probe": true, "extract": true, "validate": true, "publish": true}
const PROGRESS_STATES := {"running": true, "completed": true, "failed": true, "cancelled": true}

@export var python_path := "res://.venv/bin/python"
@export var cli_path := "res://python/frame_source.py"
@export var job_root := "user://video-import-jobs"

var _pid := -1
var _input_path := ""
var _output_path := ""
var _job_dir := ""
var _result_path := ""
var _progress_path := ""
var _cancel_path := ""
var _staging_path := ""
var _last_progress: Dictionary = {}
var _last_fraction := 0.0
var _cancel_requested := false


func start(input: String, output: String) -> PackedStringArray:
	var errors := PackedStringArray()
	if is_running():
		errors.append("A video import is already running")
		return errors
	var normalized_input := ProjectSettings.globalize_path(input).simplify_path()
	var normalized_output := ProjectSettings.globalize_path(output).simplify_path().trim_suffix("/")
	if not FileAccess.file_exists(normalized_input):
		errors.append("Input video does not exist: %s" % normalized_input)
	if normalized_output.is_empty():
		errors.append("Output directory must be specified")
	elif DirAccess.dir_exists_absolute(normalized_output) or FileAccess.file_exists(normalized_output):
		errors.append("Output path already exists: %s" % normalized_output)
	elif not DirAccess.dir_exists_absolute(normalized_output.get_base_dir()):
		errors.append("Output parent directory does not exist: %s" % normalized_output.get_base_dir())
	var project_python := ProjectSettings.globalize_path(python_path).simplify_path()
	var import_cli := ProjectSettings.globalize_path(cli_path).simplify_path()
	if not FileAccess.file_exists(project_python):
		errors.append("Project Python was not found at %s. %s" % [project_python, README_HINT])
	if not FileAccess.file_exists(import_cli):
		errors.append("Video import CLI was not found at %s" % import_cli)
	if not errors.is_empty():
		return errors

	var jobs_root := ProjectSettings.globalize_path(job_root).simplify_path().trim_suffix("/")
	if DirAccess.make_dir_recursive_absolute(jobs_root) != OK:
		errors.append("Could not create video import job directory: %s" % jobs_root)
		return errors
	var job_id := "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_job_dir = jobs_root.path_join(job_id)
	if DirAccess.make_dir_absolute(_job_dir) != OK:
		errors.append("Could not create video import job: %s" % _job_dir)
		_reset_job_state()
		return errors

	_input_path = normalized_input
	_output_path = normalized_output
	_result_path = _job_dir.path_join("result.json")
	_progress_path = _job_dir.path_join("progress.json")
	_cancel_path = _job_dir.path_join("cancel.request")
	_staging_path = normalized_output.get_base_dir().path_join(
		".%s.import-%s" % [normalized_output.get_file(), job_id])
	_last_progress.clear()
	_last_fraction = 0.0
	_cancel_requested = false
	var arguments := PackedStringArray([
		import_cli,
		normalized_input,
		"--output", normalized_output,
		"--result-file", _result_path,
		"--progress-file", _progress_path,
		"--cancel-file", _cancel_path,
		"--staging-dir", _staging_path,
	])
	_pid = OS.create_process(project_python, arguments, false)
	if _pid <= 0:
		errors.append("Could not start the project Python video importer")
		_cleanup_job_files()
		_reset_job_state()
		return errors
	set_process(true)
	return errors


func cancel() -> void:
	if not is_running() or _cancel_requested:
		return
	_cancel_requested = true
	var file := FileAccess.open(_cancel_path, FileAccess.WRITE)
	if file != null:
		file.store_string("cancel\n")


func is_running() -> bool:
	return _pid > 0


func _process(_delta: float) -> void:
	if not is_running():
		return
	_poll_progress()
	if OS.is_process_running(_pid):
		return
	var exit_code := OS.get_process_exit_code(_pid)
	_finish_process(exit_code)


func _poll_progress() -> void:
	var value: Variant = _read_json(_progress_path)
	if not value is Dictionary:
		return
	var payload := value as Dictionary
	if not _valid_progress(payload):
		return
	var fraction := float(payload["fraction"])
	if fraction + 0.000000001 < _last_fraction:
		return
	if payload == _last_progress:
		return
	_last_fraction = fraction
	_last_progress = payload.duplicate(true)
	progress.emit(payload.duplicate(true))


func _finish_process(exit_code: int) -> void:
	_poll_progress()
	var output := _output_path
	var result_value: Variant = _read_json(_result_path)
	var result: Dictionary = result_value if result_value is Dictionary else {}
	var was_cancelled: bool = bool(result.get("cancelled", false)) or (
		_cancel_requested and exit_code == 130)
	var success: bool = exit_code == 0 and result.get("success") == true \
		and str(result.get("path", "")).simplify_path() == output \
		and DirAccess.dir_exists_absolute(output)
	var message: String = str(result.get("error", "Video import process exited without a valid result"))
	_pid = -1
	set_process(false)
	_cleanup_job_files()
	_reset_job_state()
	if success:
		completed.emit(output)
	elif was_cancelled:
		cancelled.emit()
	else:
		failed.emit(_with_recovery_hint(message))


func _valid_progress(payload: Dictionary) -> bool:
	if payload.size() != PROGRESS_FIELDS.size():
		return false
	for key: Variant in payload.keys():
		if typeof(key) != TYPE_STRING or not PROGRESS_FIELDS.has(key):
			return false
	if not _logical_integer(payload.get("version")) or int(payload["version"]) != 1:
		return false
	if not PROGRESS_STATES.has(payload.get("state")) or not PROGRESS_STAGES.has(payload.get("stage")):
		return false
	if not _logical_integer(payload.get("completed")) or int(payload["completed"]) < 0:
		return false
	if not _logical_integer(payload.get("total")) or int(payload["total"]) <= 0:
		return false
	if int(payload["completed"]) > int(payload["total"]):
		return false
	var fraction: Variant = payload.get("fraction")
	if not _finite_number(fraction) or float(fraction) < 0.0 or float(fraction) > 1.0:
		return false
	return typeof(payload.get("message")) == TYPE_STRING


func _read_json(path: String) -> Variant:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	return JSON.parse_string(file.get_as_text())


func _with_recovery_hint(message: String) -> String:
	var lower := message.to_lower()
	if "ffmpeg" in lower or "ffprobe" in lower:
		return "%s %s" % [message, README_HINT]
	return message


func _cleanup_job_files() -> void:
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
		_remove_tree(path.path_join(child_name))
	DirAccess.remove_absolute(path)


func _reset_job_state() -> void:
	_input_path = ""
	_output_path = ""
	_job_dir = ""
	_result_path = ""
	_progress_path = ""
	_cancel_path = ""
	_staging_path = ""
	_last_progress.clear()
	_last_fraction = 0.0
	_cancel_requested = false


func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))


func _logical_integer(value: Variant) -> bool:
	return _finite_number(value) and float(value) == floorf(float(value))


func _exit_tree() -> void:
	if is_running():
		cancel()
