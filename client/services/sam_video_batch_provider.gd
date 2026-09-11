## 只消费 Service 已验证的内存 Poly；不读取候选文件，也不接收 Store/历史写能力。
class_name SamVideoBatchProvider
extends "res://client/services/batch_propagation_provider.gd"

const SERVICE := preload("res://client/services/sam_video_service.gd")
const POLYGONS := preload("res://client/domain/polygon_ops.gd")
var service: Variant = SERVICE.new()
var _context: Dictionary = {}
var _begun := false

func provider_id() -> StringName: return &"sam_video"

func availability() -> Dictionary:
	var state: Dictionary = service.preflight()
	return {"available": state.get("ok", false) and not state.get("busy", false),
		"reason": state.get("message", ""), "details": state.duplicate(true)}

func begin(context: Dictionary) -> PackedStringArray:
	_context = context.duplicate(true)
	# 能力对象仅作单独 Source 参数；不可跨入推理上下文或公开结果。
	_context.erase("source")
	_context.erase("store")
	_context.erase("history")
	var errors: PackedStringArray = service.begin(_context.get("service_context", {}).duplicate(true),
		context.get("source"), _context.get("entries", []).duplicate(true), _context.get("region", {}).duplicate(true))
	_begun = errors.is_empty()
	return errors

func step() -> void: service.step()
func cancel() -> void:
	_begun = false
	_context.clear()
	service.cancel()
func is_running() -> bool: return service.is_running()
func progress_text() -> String: return service.progress_text()
func validate_source() -> PackedStringArray: return service.validate_source()

func get_result() -> Dictionary:
	if not _begun or is_running(): return {}
	var raw: Dictionary = service.get_result()
	if raw.is_empty(): return {}
	if not raw.get("errors", []).is_empty(): return _failure(str(raw.errors[0]))
	var bound: Variant = raw.get("context")
	if not bound is Dictionary: return _failure("SAM video context is missing")
	for key in _context.get("service_context", {}):
		if not bound.has(key) or bound[key] != _context.service_context[key]:
			return _failure("SAM video context changed")
	var proposals: Variant = raw.get("proposals")
	var targets: Array = _context.get("target_entries", [])
	if not proposals is Array or proposals.size() > targets.size(): return _failure("SAM video proposal count is invalid")
	var bound_targets: Variant = bound.get("targets")
	if not bound_targets is Array or bound_targets.size() != targets.size():
		return _failure("SAM video frozen target context is invalid")
	var frozen_image_sha256 := {}
	for offset in range(targets.size()):
		var target: Dictionary = targets[offset]
		var descriptor: Variant = bound_targets[offset]
		var index: int = int(_context.key_index) + offset + 1
		if not descriptor is Dictionary or descriptor.get("playback_index") != index \
				or descriptor.get("frame_id") != target.frame_id \
				or not _digest_valid(descriptor.get("entry_sha256")) \
				or not _digest_valid(descriptor.get("image_sha256")):
			return _failure("SAM video frozen target identity is invalid")
		if descriptor.has("time_s") != target.has("time_s") \
				or (target.has("time_s") and descriptor.time_s != target.time_s):
			return _failure("SAM video frozen target timestamp changed")
		frozen_image_sha256[index] = descriptor.image_sha256
	var stop_text: Variant = raw.get("stop", "")
	if not stop_text is String or (proposals.size() < targets.size()) == stop_text.is_empty():
		return _failure("SAM video prefix stop is inconsistent")
	var regions := {}
	var quality := {}
	var accepted_image_sha256 := {}
	for offset in range(proposals.size()):
		var proposal: Variant = proposals[offset]
		var target: Dictionary = targets[offset]
		var index: int = int(_context.key_index) + offset + 1
		if not proposal is Dictionary or proposal.get("playback_index") != index or proposal.get("frame_id") != target.frame_id or proposal.get("region_id") != _context.region_id or proposal.get("object_id") != 1:
			return _failure("SAM video proposal has a non-target or wrong region identity")
		if proposal.has("time_s") != target.has("time_s") or (target.has("time_s") and proposal.time_s != target.time_s):
			return _failure("SAM video proposal timestamp changed")
		var polygon: Variant = proposal.get("polygon")
		if not (polygon is Array or polygon is PackedVector2Array) or polygon.size() > 2048 or not POLYGONS.validate_simple_polygon(polygon):
			return _failure("SAM video Service returned an invalid validated polygon")
		if _context.has("image_size") and not POLYGONS.points_fit_image(polygon, Vector2(_context.image_size)):
			return _failure("SAM video validated polygon leaves the image")
		var points: Array = []
		for point in polygon:
			points.append([point.x, point.y] if point is Vector2 else point.duplicate())
		regions[int(target.frame_id)] = [{"id": _context.region_id, "polygon": points}]
		quality[int(target.frame_id)] = {_context.region_id: {"score": proposal.get("mask", {}).get("score")}}
		accepted_image_sha256[index] = frozen_image_sha256[index]
	var stop: Dictionary = _context.get("range_stop", {}).duplicate(true)
	if not stop_text.is_empty():
		stop = {"kind": "model_topology", "frame_id": int(targets[proposals.size()].frame_id),
			"message": stop_text.left(512), "can_reanchor": true}
	var public_context := _context.duplicate(true)
	public_context.erase("service_context")
	return {"errors": PackedStringArray(), "provider_id": "sam_video", "metric_id": "sam-video-v1",
		"key_index": _context.key_index, "start_index": _context.key_index,
		"end_index": int(_context.key_index) + proposals.size(), "keyframe": int(_context.entries[_context.key_index].frame_id),
		"region_id": _context.region_id, "target_regions": regions, "quality": quality,
		"target_image_sha256": accepted_image_sha256,
		"risks": _context.get("risks", []).duplicate(true), "stop": stop,
		"requested_count": _context.get("requested_count", targets.size()), "generated_count": proposals.size(),
		"runtime": raw.get("runtime", {}).duplicate(true), "context": public_context}

func _failure(message: String) -> Dictionary:
	return {"errors": PackedStringArray([message]), "provider_id": "sam_video"}

func _digest_valid(value: Variant) -> bool:
	if not value is String or value.length() != 64 or value != value.to_lower():
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true
