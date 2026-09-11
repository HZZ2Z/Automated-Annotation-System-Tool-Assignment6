class_name WorkspaceCatalogController
extends Node

signal scan_started(path: String)
signal scan_progress(payload: Dictionary)
signal scan_finished(generation: int, result: Dictionary)

const CATALOG := preload("res://client/workspace/workspace_catalog.gd")
const BACKGROUND_JOB := preload("res://client/services/background_job.gd")
const COMPLETED_RESULT_LIMIT := 16


class ScanWorker extends RefCounted:
	func run(
		root: String,
		source_factory: Variant,
		preferred_id: String,
		token: Variant,
	) -> Dictionary:
		var candidate = CATALOG.new()
		candidate.configure_source_resolver(source_factory, preferred_id)
		var errors: PackedStringArray = candidate.scan(root, token)
		return {
			"success": errors.is_empty(),
			"cancelled": token.is_cancelled(),
			"errors": errors,
			"catalog": candidate if errors.is_empty() else null,
		}


var _job: Variant
var _worker := ScanWorker.new()
var _generation := 0
var _running_generation := -1
var _running_path := ""
var _queued_request: Dictionary = {}
var _completed_results := {}
var _catalog = CATALOG.new()


func _init() -> void:
	_ensure_job()


func start(
	path: String,
	source_factory: Variant,
	preferred_id: String = "",
) -> Dictionary:
	_ensure_job()
	_generation += 1
	var generation := _generation
	var normalized := ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	var request := {
		"generation": generation,
		"path": normalized,
		"source_factory": source_factory,
		"preferred_id": preferred_id,
	}
	if _job.is_running():
		_job.cancel()
		_cancel_queued_request()
		_queued_request = request
		return {"generation": generation, "errors": PackedStringArray()}
	var errors := _launch(request)
	return {"generation": generation, "errors": errors}


func wait_for(generation: int) -> Dictionary:
	if _completed_results.has(generation):
		return (_completed_results[generation] as Dictionary).duplicate(true)
	while true:
		var completion: Array = await scan_finished
		if int(completion[0]) == generation:
			return (completion[1] as Dictionary).duplicate(true)
	return _cancel_result(generation, true)


func cancel() -> void:
	_generation += 1
	_cancel_queued_request()
	if _job != null:
		_job.cancel()


func cancel_and_drain() -> void:
	cancel()
	while is_busy():
		await get_tree().process_frame


func is_busy() -> bool:
	return (
		_job != null and _job.is_running()
		or not _queued_request.is_empty()
	)


func generation() -> int:
	return _generation


func get_catalog() -> Variant:
	return _catalog


func _ensure_job() -> void:
	if _job != null:
		return
	_job = BACKGROUND_JOB.new()
	add_child(_job)
	_job.progress.connect(_on_job_progress)
	_job.finished.connect(_on_job_finished)


func _launch(request: Dictionary) -> PackedStringArray:
	_running_generation = int(request.generation)
	_running_path = String(request.path)
	var errors: PackedStringArray = _job.start(Callable(_worker, "run"), [
		_running_path,
		request.source_factory,
		String(request.preferred_id),
	])
	if not errors.is_empty():
		var failed := {
			"success": false,
			"cancelled": false,
			"stale": _running_generation != _generation,
			"errors": errors,
			"catalog": null,
			"generation": _running_generation,
		}
		_store_completion(_running_generation, failed)
		scan_finished.emit(_running_generation, failed.duplicate(true))
		_running_generation = -1
		_running_path = ""
		return errors
	scan_started.emit(_running_path)
	return PackedStringArray()


func _on_job_progress(payload: Dictionary) -> void:
	var snapshot := payload.duplicate(true)
	snapshot["generation"] = _running_generation
	if _running_generation == _generation:
		scan_progress.emit(snapshot)


func _on_job_finished(value: Dictionary) -> void:
	var finished_generation := _running_generation
	var result := value.duplicate(true)
	var errors_value: Variant = result.get("errors")
	if not errors_value is PackedStringArray:
		result.errors = PackedStringArray([
			"Workspace catalog worker errors must be PackedStringArray"])
		result.success = false
	result["generation"] = finished_generation
	result["stale"] = finished_generation != _generation
	result["cancelled"] = bool(result.get("cancelled", false))
	if (
		bool(result.get("success", false))
		and not bool(result.stale)
		and not bool(result.cancelled)
		and result.get("catalog") is Object
	):
		_catalog = result.catalog
	var next := _queued_request.duplicate()
	_queued_request.clear()
	_running_generation = -1
	_running_path = ""
	if not next.is_empty():
		_launch(next)
	_store_completion(finished_generation, result)
	scan_finished.emit(finished_generation, result.duplicate(true))


func _cancel_queued_request() -> void:
	if _queued_request.is_empty():
		return
	var generation := int(_queued_request.generation)
	var result := _cancel_result(generation, true)
	_store_completion(generation, result)
	scan_finished.emit(generation, result.duplicate(true))
	_queued_request.clear()


func _cancel_result(generation: int, stale: bool) -> Dictionary:
	return {
		"success": false,
		"cancelled": true,
		"stale": stale,
		"errors": PackedStringArray(["Workspace scan cancelled"]),
		"catalog": null,
		"generation": generation,
	}


func _store_completion(generation: int, result: Dictionary) -> void:
	_completed_results[generation] = result.duplicate(true)
	if _completed_results.size() <= COMPLETED_RESULT_LIMIT:
		return
	var generations: Array = _completed_results.keys()
	generations.sort()
	_completed_results.erase(generations[0])
