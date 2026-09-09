## 将既有 Poly 服务适配到只读候选 Provider 边界，不改变其运动或协议校验。
class_name PolyBatchProvider
extends "res://client/services/batch_propagation_provider.gd"

const POLYGON_SERVICE := preload("res://client/services/polygon_propagation_service.gd")

var service = POLYGON_SERVICE.new()

func provider_id() -> StringName:
	return &"polygon_flow"

func availability() -> Dictionary:
	var python := ProjectSettings.globalize_path(service.python_path)
	var worker := ProjectSettings.globalize_path(service.cli_path)
	if not FileAccess.file_exists(python) or not FileAccess.file_exists(worker):
		return {"available": false, "reason": "Poly worker or project Python is missing; see README environment setup",
			"details": {"python": python, "worker": worker}}
	return {"available": true, "reason": "", "details": {}}

func begin(context: Dictionary) -> PackedStringArray:
	return service.begin(
		context.get("source"), context.get("store"), context.get("entries", []),
		int(context.get("key_index", -1)), float(context.get("similarity_threshold", 0.02)),
	)

func step() -> void:
	service.step()

func cancel() -> void:
	service.cancel()

func is_running() -> bool:
	return service.running

func progress_text() -> String:
	return service.progress_text()

func get_result() -> Dictionary:
	var candidate: Dictionary = service.result.duplicate(true)
	if not candidate.is_empty():
		candidate["provider_id"] = String(provider_id())
	return candidate

func validate_source() -> PackedStringArray:
	return service.validate_source()
