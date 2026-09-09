## 单帧模型辅助状态机：拥有提示、候选和提交快照，但不读写 Store 也不启动 worker。
class_name ModelAssistSession
extends RefCounted

const UNAVAILABLE := &"unavailable"
const READY := &"ready"
const REQUESTING := &"requesting"
const CANDIDATE := &"candidate"
const INVALID := &"invalid"
const FAILED := &"failed"
const AWAITING_CLASS := &"awaiting_class"
const MAX_POINTS := 64
const CANDIDATE_FIELDS := ["mask", "ok", "polygon", "reason", "score"]

var _phase: StringName = UNAVAILABLE
var _frame_id := -1
var _playback_index := -1
var _before: Dictionary = {}
var _image_size := Vector2i.ZERO
var _preflight: Dictionary = {}
var _target_mode: StringName = &"creation"
var _target_region_id := ""
var _target_region: Dictionary = {}
var _target_locked := false
var _point_prompts: Array[Dictionary] = []
var _prompt_box: Variant = null
var _prompt_history: Array[Dictionary] = []
var _prompt_revision := 0
var _active_token := -1
var _request_context: Dictionary = {}
var _candidates: Array[Dictionary] = []
var _candidate_index := -1
var _message := ""


func begin(
	frame_id: int,
	playback_index: int,
	record: Dictionary,
	selected_region_id: String,
	image_size: Vector2i,
	preflight: Dictionary,
) -> void:
	reset()
	_frame_id = frame_id
	_playback_index = playback_index
	_before = record.duplicate(true)
	_image_size = image_size
	_preflight = preflight.duplicate(true)
	_target_region = _find_region(_before, selected_region_id)
	if not _target_region.is_empty() and not _region_polygon(_target_region).is_empty():
		_target_mode = &"correction"
		_target_region_id = selected_region_id
	else:
		_target_mode = &"creation"
		_target_region_id = ""
	if _valid_begin() and preflight.get("ok", false) and preflight.get("status") == "ready":
		_phase = READY
		_message = "点击图像添加正向提示；Shift+点击添加负向提示。"
	else:
		_phase = UNAVAILABLE
		_message = str(preflight.get("message", "模型辅助不可用。"))


func add_point(point: Vector2, positive: bool) -> Dictionary:
	if not _can_edit_prompts():
		return _change_result(false, -1, "当前状态不能添加提示。")
	if _point_prompts.size() >= MAX_POINTS:
		return _change_result(false, -1, "提示点最多 64 个。")
	if not _point_in_image(point):
		return _change_result(false, -1, "提示点必须位于当前图像内。")
	var previous := _prompt_state()
	_point_prompts.append({"point": point, "label": 1 if positive else 0})
	return _finish_prompt_change(previous)


func set_box(box: Rect2) -> Dictionary:
	if not _can_edit_prompts():
		return _change_result(false, -1, "当前状态不能设置提示框。")
	var normalized := box.abs()
	if (
		normalized.size.x <= 0.0
		or normalized.size.y <= 0.0
		or not _point_in_image(normalized.position)
		or normalized.end.x > _image_size.x
		or normalized.end.y > _image_size.y
	):
		return _change_result(false, -1, "提示框必须为图像内的非空矩形。")
	var previous := _prompt_state()
	_prompt_box = normalized
	return _finish_prompt_change(previous)


func undo_prompt() -> Dictionary:
	if not _can_edit_prompts() or _prompt_history.is_empty():
		return _change_result(false, -1, "没有可撤销的提示。")
	var cancel_token := _active_token
	var previous: Dictionary = _prompt_history.pop_back()
	_restore_prompt_state(previous)
	_advance_prompt_revision()
	return _change_result(true, cancel_token, "")


func begin_request(token: int, context: Dictionary) -> bool:
	if token <= 0 or not _target_locked or not _has_prompts() or not _request_context_matches(context):
		return false
	_active_token = token
	_request_context = context.duplicate(true)
	_candidates.clear()
	_candidate_index = -1
	_phase = REQUESTING
	_message = "正在生成候选…"
	return true


func accept(token: int, candidates: Array) -> bool:
	if token <= 0 or token != _active_token or _phase != REQUESTING or candidates.size() > 3:
		return false
	var normalized: Array[Dictionary] = []
	for candidate: Variant in candidates:
		if not candidate is Dictionary:
			return false
		var copy := _normalize_candidate(candidate)
		if copy.is_empty():
			return false
		normalized.append(copy)
	_active_token = -1
	_candidates = normalized
	_candidate_index = 0 if not normalized.is_empty() else -1
	if normalized.is_empty():
		_phase = INVALID
		_message = "模型未返回可检查的候选。"
	else:
		_sync_candidate_state()
	return true


func fail(token: int, reason: String) -> bool:
	if token <= 0 or token != _active_token or _phase != REQUESTING:
		return false
	_active_token = -1
	_candidates.clear()
	_candidate_index = -1
	_phase = FAILED
	_message = "推理失败，当前标注未修改；可重试或按 Escape 取消。"
	if not reason.is_empty():
		_message += " " + reason
	return true


func retry() -> Dictionary:
	if not _target_locked or not _has_prompts() or _phase not in [FAILED, INVALID, CANDIDATE, READY]:
		return _change_result(false, -1, "当前没有可重试的提示。")
	var cancel_token := _active_token
	_advance_prompt_revision()
	return _change_result(true, cancel_token, "")


func cycle(delta: int) -> void:
	if _phase not in [CANDIDATE, INVALID] or _candidates.size() < 2 or delta == 0:
		return
	_candidate_index = posmod(_candidate_index + delta, _candidates.size())
	_sync_candidate_state()


func await_class_assignment() -> bool:
	if _phase != CANDIDATE or _target_mode != &"creation" or not _current_candidate().get("ok", false):
		return false
	_phase = AWAITING_CLASS
	_message = "请为新区域选择类别和类型。"
	return true


func cancel() -> int:
	var token := _active_token
	_target_locked = false
	_point_prompts.clear()
	_prompt_box = null
	_prompt_history.clear()
	_prompt_revision = 0
	_active_token = -1
	_request_context.clear()
	_candidates.clear()
	_candidate_index = -1
	if _preflight.get("ok", false) and _preflight.get("status") == "ready" and _valid_begin():
		_phase = READY
		_message = "点击图像添加正向提示；Shift+点击添加负向提示。"
	else:
		_phase = UNAVAILABLE
		_message = str(_preflight.get("message", "模型辅助不可用。"))
	return token


func request_snapshot() -> Dictionary:
	if not _target_locked:
		return {}
	var points: Array = []
	var labels: Array = []
	for prompt: Dictionary in _point_prompts:
		var point: Vector2 = prompt.point
		points.append([point.x, point.y])
		labels.append(int(prompt.label))
	var box: Variant = null
	if _prompt_box is Rect2:
		var rectangle: Rect2 = _prompt_box
		box = [rectangle.position.x, rectangle.position.y, rectangle.end.x, rectangle.end.y]
	return {
		"frame_id": _frame_id,
		"playback_index": _playback_index,
		"selected_region_id": _target_region_id,
		"target_mode": _target_mode,
		"prompt_revision": _prompt_revision,
		"prompts": {"points": points, "labels": labels, "box": box},
	}


func commit_snapshot() -> Dictionary:
	var allowed := (_phase == CANDIDATE and _target_mode == &"correction") or (_phase == AWAITING_CLASS and _target_mode == &"creation")
	var candidate := _current_candidate()
	if not allowed or not candidate.get("ok", false):
		return {}
	return {
		"mode": &"replace" if _target_mode == &"correction" else &"add",
		"frame_id": _frame_id,
		"playback_index": _playback_index,
		"before": _before.duplicate(true),
		"region_id": _target_region_id,
		"polygon": candidate.polygon.duplicate(),
		"image_size": _image_size,
		"prompt_revision": _prompt_revision,
		"request_context": _request_context.duplicate(true),
		"score": float(candidate.score),
	}


func snapshot() -> Dictionary:
	var draft_active := _target_locked
	return {
		"phase": _phase,
		"overlay": _overlay_snapshot() if draft_active else {},
		"session_panel": _session_panel(),
		"navigation_blocked": draft_active,
		"draft_active": draft_active,
		"message": _message,
	}


func reset() -> void:
	_phase = UNAVAILABLE
	_frame_id = -1
	_playback_index = -1
	_before.clear()
	_image_size = Vector2i.ZERO
	_preflight.clear()
	_target_mode = &"creation"
	_target_region_id = ""
	_target_region.clear()
	_target_locked = false
	_point_prompts.clear()
	_prompt_box = null
	_prompt_history.clear()
	_prompt_revision = 0
	_active_token = -1
	_request_context.clear()
	_candidates.clear()
	_candidate_index = -1
	_message = ""


func _finish_prompt_change(previous: Dictionary) -> Dictionary:
	var cancel_token := _active_token
	_prompt_history.append(previous)
	_target_locked = true
	_advance_prompt_revision()
	return _change_result(true, cancel_token, "")


func _advance_prompt_revision() -> void:
	_prompt_revision += 1
	_active_token = -1
	_request_context.clear()
	_candidates.clear()
	_candidate_index = -1
	_phase = READY
	_message = "提示已更新，可生成新候选。"


func _change_result(changed: bool, cancel_token: int, reason: String) -> Dictionary:
	return {
		"changed": changed,
		"cancel_token": cancel_token,
		"request": request_snapshot(),
		"message": reason,
	}


func _prompt_state() -> Dictionary:
	return {"points": _point_prompts.duplicate(true), "box": _prompt_box}


func _restore_prompt_state(value: Dictionary) -> void:
	_point_prompts = value.get("points", []).duplicate(true)
	_prompt_box = value.get("box")


func _request_context_matches(context: Dictionary) -> bool:
	return (
		context.get("session_id") is String
		and not str(context.get("session_id")).is_empty()
		and int(context.get("frame_id", -1)) == _frame_id
		and int(context.get("playback_index", -1)) == _playback_index
		and context.get("selected_region_id") == _target_region_id
		and int(context.get("prompt_revision", -1)) == _prompt_revision
		and _digest_valid(context.get("image_sha256"))
		and _digest_valid(context.get("record_sha256"))
	)


func _sync_candidate_state() -> void:
	var candidate := _current_candidate()
	if candidate.get("ok", false):
		_phase = CANDIDATE
		_message = "候选 %d/%d 已通过单环 Poly 安全门。" % [_candidate_index + 1, _candidates.size()]
	else:
		_phase = INVALID
		_message = "候选无法表达为单环 Poly：%s。" % str(candidate.get("reason", "未知原因"))


func _current_candidate() -> Dictionary:
	if _candidate_index < 0 or _candidate_index >= _candidates.size():
		return {}
	return _candidates[_candidate_index]


func _normalize_candidate(value: Dictionary) -> Dictionary:
	if not _keys_equal(value, CANDIDATE_FIELDS):
		return {}
	if not value.get("ok") is bool or not value.get("reason") is String or not _finite_number(value.get("score")):
		return {}
	var polygon: Variant = value.get("polygon")
	var mask: Variant = value.get("mask")
	if not polygon is PackedVector2Array or not mask is Dictionary:
		return {}
	if value.ok:
		var copied_mask := _copy_mask(mask)
		if polygon.size() < 3 or copied_mask.is_empty():
			return {}
		return {"ok": true, "polygon": polygon.duplicate(), "mask": copied_mask, "reason": value.reason, "score": float(value.score)}
	if value.reason.is_empty():
		return {}
	return {"ok": false, "polygon": PackedVector2Array(), "mask": {}, "reason": value.reason, "score": float(value.score)}


func _copy_mask(value: Dictionary) -> Dictionary:
	var roi: Variant = value.get("roi")
	var mask: Variant = value.get("mask")
	if not roi is Rect2i or not mask is PackedByteArray or roi.size.x <= 0 or roi.size.y <= 0 or roi.size.x * roi.size.y != mask.size():
		return {}
	return {"roi": roi, "mask": mask.duplicate()}


func _overlay_snapshot() -> Dictionary:
	var positive := PackedVector2Array()
	var negative := PackedVector2Array()
	for prompt: Dictionary in _point_prompts:
		if int(prompt.label) == 1:
			positive.append(prompt.point)
		else:
			negative.append(prompt.point)
	var candidate := _current_candidate()
	var polygon := PackedVector2Array()
	var mask := {}
	if candidate.get("ok", false):
		polygon = candidate.polygon.duplicate()
		mask = _copy_mask(candidate.mask)
	elif _target_mode == &"correction":
		polygon = _region_polygon(_target_region)
	var overlay := {
		"phase": _phase,
		"positive_points": positive,
		"negative_points": negative,
		"candidate_polygon": polygon,
		"mask_preview": mask,
		"message": _message,
		"fill_color": Color("#22c55e") if _phase == CANDIDATE else Color("#ef4444") if _phase == INVALID else Color("#22d3ee"),
	}
	if _prompt_box is Rect2:
		overlay["prompt_box"] = _prompt_box
	if _target_mode == &"correction":
		overlay["suppress_region_id"] = _target_region_id
	return overlay


func _session_panel() -> Dictionary:
	var actions: Array[Dictionary] = []
	match _phase:
		UNAVAILABLE:
			actions.append(_action(&"recheck_model_assist", "Recheck", true, true))
		READY:
			if _target_locked:
				actions.append(_action(&"retry_model_assist", "Generate", _has_prompts(), true))
				actions.append(_action(&"cancel_model_assist", "Cancel", true, false))
			else:
				actions.append(_action(&"recheck_model_assist", "Recheck", true, false))
		REQUESTING:
			actions.append(_action(&"cancel_model_assist", "Cancel", true, false))
		CANDIDATE:
			actions.append(_action(&"apply_model_assist", "Apply", true, true))
			if _candidates.size() > 1:
				actions.append(_action(&"cycle_model_assist_candidate", "Next candidate", true, false))
			actions.append(_action(&"cancel_model_assist", "Cancel", true, false))
		INVALID:
			if _candidates.size() > 1:
				actions.append(_action(&"cycle_model_assist_candidate", "Next candidate", true, false))
			actions.append(_action(&"retry_model_assist", "Retry", _has_prompts(), false))
			actions.append(_action(&"cancel_model_assist", "Cancel", true, false))
		FAILED:
			actions.append(_action(&"retry_model_assist", "Retry", _has_prompts(), true))
			actions.append(_action(&"cancel_model_assist", "Cancel", true, false))
		AWAITING_CLASS:
			actions.append(_action(&"cancel_model_assist", "Cancel", true, false))
	return {
		"tool_id": &"model_assist",
		"status": str(_phase),
		"badge": str(_preflight.get("badge", "")),
		"summary": _summary(),
		"actions": actions,
	}


func _summary() -> String:
	var positive := 0
	for prompt: Dictionary in _point_prompts:
		positive += 1 if int(prompt.label) == 1 else 0
	var negative := _point_prompts.size() - positive
	var box_count := 1 if _prompt_box is Rect2 else 0
	var candidate_text := ""
	if not _candidates.is_empty():
		candidate_text = " · 候选 %d/%d" % [_candidate_index + 1, _candidates.size()]
	return "正点 %d · 负点 %d · 框 %d%s" % [positive, negative, box_count, candidate_text]


func _action(id: StringName, label: String, enabled: bool, primary: bool) -> Dictionary:
	return {"id": id, "label": label, "enabled": enabled, "primary": primary}


func _region_polygon(region: Dictionary) -> PackedVector2Array:
	var polygon: Variant = region.get("polygon")
	if polygon is Array:
		var result := PackedVector2Array()
		for vertex: Variant in polygon:
			if not vertex is Array or vertex.size() != 2 or not _finite_number(vertex[0]) or not _finite_number(vertex[1]):
				return PackedVector2Array()
			result.append(Vector2(float(vertex[0]), float(vertex[1])))
		return result if result.size() >= 3 else PackedVector2Array()
	var box: Variant = region.get("box")
	if not box is Array or box.size() != 4:
		return PackedVector2Array()
	for coordinate: Variant in box:
		if not _finite_number(coordinate):
			return PackedVector2Array()
	var x := float(box[0])
	var y := float(box[1])
	var width := float(box[2])
	var height := float(box[3])
	if x < 0.0 or y < 0.0 or width <= 0.0 or height <= 0.0:
		return PackedVector2Array()
	return PackedVector2Array([Vector2(x, y), Vector2(x + width, y), Vector2(x + width, y + height), Vector2(x, y + height)])


func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	var regions: Variant = record.get("regions", [])
	if regions is Array:
		for region: Variant in regions:
			if region is Dictionary and region.get("id") == region_id:
				return region.duplicate(true)
	return {}


func _valid_begin() -> bool:
	return _frame_id >= 0 and _playback_index >= 0 and _image_size.x > 0 and _image_size.y > 0 and _before.get("regions") is Array


func _can_edit_prompts() -> bool:
	return _phase in [READY, REQUESTING, CANDIDATE, INVALID, FAILED]


func _has_prompts() -> bool:
	return not _point_prompts.is_empty() or _prompt_box is Rect2


func _point_in_image(point: Vector2) -> bool:
	return is_finite(point.x) and is_finite(point.y) and point.x >= 0.0 and point.y >= 0.0 and point.x < _image_size.x and point.y < _image_size.y


func _digest_valid(value: Variant) -> bool:
	if not value is String or value.length() != 64 or value != value.to_lower():
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _keys_equal(value: Dictionary, expected: Array) -> bool:
	var actual: Array = value.keys()
	actual.sort()
	var sorted_expected := expected.duplicate()
	sorted_expected.sort()
	return actual == sorted_expected
