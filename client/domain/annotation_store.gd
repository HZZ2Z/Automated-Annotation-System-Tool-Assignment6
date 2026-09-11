class_name AnnotationStore
extends RefCounted


signal corrected_records_replaced(frames: PackedInt64Array)
signal review_state_changed()


const STREAM_JSON := preload("res://client/domain/stream_json.gd")
const VALIDATOR_SCRIPT := preload("res://client/domain/model_output_validator.gd")

var _review_state: Dictionary = {}
var _model_records: Dictionary = {}
var _corrected_records: Dictionary = {}
var _dirty_frames: Dictionary = {}
var _batch_operations: Array[Dictionary] = []
var _validator = VALIDATOR_SCRIPT.new()
var _session: Dictionary = {}
var _revision := 0
var _explicit_frames: Dictionary = {}
var _baseline_digest := ""
var _snapshot_baseline_digest := ""
var _frame_order: Array = []


func load_model_records(records: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not records is Array:
		errors.append("$: expected array of model output records")
		return errors
	var next_model := {}
	var seen_frames := {}
	for index in range(records.size()):
		var record: Variant = records[index]
		var record_errors: PackedStringArray = _validator.validate_record(record)
		if record_errors.is_empty():
			var region_ids := {}
			for region_index in range(record.regions.size()):
				var region_id: String = record.regions[region_index].id
				if region_ids.has(region_id):
					record_errors.append("regions.%d.id: duplicate region ID %s" % [region_index, region_id])
				region_ids[region_id] = true
		for error: String in record_errors:
			errors.append(_prefix_record_error(index, error))
		if not record is Dictionary:
			continue
		var frame_value: Variant = record.get("frame")
		if _is_logical_integer(frame_value) and frame_value >= 0:
			var frame := int(frame_value)
			if seen_frames.has(frame):
				errors.append("records.%d.frame: duplicate frame %d" % [index, frame])
			else:
				seen_frames[frame] = true
			if record_errors.is_empty() and not next_model.has(frame):
				next_model[frame] = _immutable_copy(record)
	if not errors.is_empty():
		return errors
	_model_records = next_model
	_corrected_records = next_model.duplicate()
	_frame_order = next_model.keys()
	_frame_order.sort()
	_session = {}
	_revision = 0
	_explicit_frames = {}
	for frame: int in _frame_order:
		_explicit_frames[frame] = true
	var ordered: Array = []
	for frame: int in _frame_order:
		ordered.append(_model_records[frame])
	var digests: Dictionary = STREAM_JSON.record_digests(ordered)
	_baseline_digest = digests.legacy
	_snapshot_baseline_digest = digests.current
	_dirty_frames.clear()
	_batch_operations.clear()
	_review_state.clear()
	return errors


func get_model_record(frame: int) -> Dictionary:
	var record: Variant = _model_records.get(frame)
	if not record is Dictionary:
		return {}
	return record.duplicate(true)


func get_corrected_record(frame: int) -> Dictionary:
	var record: Variant = _corrected_records.get(frame)
	if not record is Dictionary:
		return {}
	return record.duplicate(true)


static func _model_output_projection(record: Variant) -> Variant:
	if not record is Dictionary:
		return record
	var result: Dictionary = record.duplicate()
	var regions: Variant = result.get("regions")
	if regions is Array:
		var projected: Array = []
		for value: Variant in regions:
			if value is Dictionary and value.has("filled"):
				value = value.duplicate()
				value.erase("filled")
			projected.append(value)
		result["regions"] = projected
	return result


func replace_corrected_record(frame: int, record: Variant) -> PackedStringArray:
	var errors := _validate_replacement(frame, record)
	if not errors.is_empty():
		return errors
	_corrected_records[frame] = _immutable_copy(record)
	_dirty_frames[frame] = true
	_explicit_frames[frame] = true
	_revision += 1
	corrected_records_replaced.emit(PackedInt64Array([frame]))
	return errors


func replace_corrected_records(replacements: Dictionary, operation: Dictionary = {}) -> PackedStringArray:
	return _replace_corrected_records(replacements, operation, -1)


func restore_corrected_records(replacements: Dictionary, operation_count: int) -> PackedStringArray:
	return _replace_corrected_records(replacements, {}, clampi(operation_count, 0, _batch_operations.size()))


func replace_corrected_records_with_reviews(replacements: Dictionary, operation: Dictionary,
		verified_frame_ids: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	var frames: Array[int] = []
	if replacements.is_empty():
		return PackedStringArray(["replacements: expected at least one frame"])
	for frame_value: Variant in replacements:
		if not _is_logical_integer(frame_value):
			errors.append("replacements.%s: frame key must be an integer" % str(frame_value))
		else:
			frames.append(int(frame_value))
	frames.sort()
	var verified: Array[int] = []
	var seen := {}
	if not (verified_frame_ids is Array or verified_frame_ids is PackedInt64Array or verified_frame_ids is PackedInt32Array):
		errors.append("verified_frame_ids: expected frame array")
	else:
		for frame_value: Variant in verified_frame_ids:
			if typeof(frame_value) != TYPE_INT or seen.has(frame_value):
				errors.append("verified_frame_ids: invalid or duplicate frame ID")
			else:
				seen[frame_value] = true
				verified.append(int(frame_value))
	verified.sort()
	if verified != frames:
		errors.append("verified_frame_ids: must exactly match changed frames")
	if operation.is_empty():
		errors.append("operation: expected batch audit marker")
	if operation.get("schema_version") == 3:
		if not _same_frame_set(operation.get("affected_frames"), frames) or operation.get("generated_count") != frames.size():
			errors.append("SAM operation: audit must exactly name the generated target frames")
		for frame: int in frames:
			if frame == operation.get("keyframe"):
				errors.append("SAM operation: generated targets must exclude the keyframe")
	var candidate_records := _corrected_records.duplicate()
	for frame: int in frames:
		for error: String in _validate_replacement(frame, replacements[frame]):
			errors.append("replacements.%d.%s" % [frame, error])
		if not errors.is_empty():
			continue
		candidate_records[frame] = _immutable_copy(replacements[frame])
	if not errors.is_empty():
		return errors
	var candidate_reviews := _review_state.duplicate(true)
	for frame: int in verified:
		candidate_reviews[str(frame)] = {"accepted_digest": _record_digest_value(candidate_records[frame])}
	var candidate_operations := _batch_operations.duplicate(true)
	candidate_operations.append(operation.duplicate(true))
	errors.append_array(validate_workflow_state(candidate_reviews, candidate_operations, candidate_records, _session.get("frame_entries")))
	if not errors.is_empty():
		return errors
	_install_corrected_records_with_reviews(candidate_records, candidate_reviews, candidate_operations, frames)
	return errors


func restore_corrected_records_with_reviews(replacements: Dictionary, operation_count: int,
		review_state: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if replacements.is_empty():
		return PackedStringArray(["replacements: expected at least one frame"])
	if operation_count < 0 or operation_count > _batch_operations.size():
		return PackedStringArray(["operation_count: outside current batch history"])
	var frames: Array[int] = []
	var candidate_records := _corrected_records.duplicate()
	for frame_value: Variant in replacements:
		if not _is_logical_integer(frame_value):
			errors.append("replacements.%s: frame key must be an integer" % str(frame_value))
			continue
		var frame := int(frame_value)
		frames.append(frame)
		for error: String in _validate_replacement(frame, replacements[frame_value]):
			errors.append("replacements.%d.%s" % [frame, error])
		if errors.is_empty():
			candidate_records[frame] = _immutable_copy(replacements[frame_value])
	if not errors.is_empty():
		return errors
	frames.sort()
	var candidate_reviews := review_state.duplicate(true)
	var candidate_operations := _batch_operations.duplicate(true)
	candidate_operations.resize(operation_count)
	errors.append_array(validate_workflow_state(candidate_reviews, candidate_operations, candidate_records, _session.get("frame_entries")))
	if not errors.is_empty():
		return errors
	_install_corrected_records_with_reviews(candidate_records, candidate_reviews, candidate_operations, frames)
	return errors


func _install_corrected_records_with_reviews(candidate_records: Dictionary, candidate_reviews: Dictionary,
		candidate_operations: Array, frames: Array[int]) -> void:
	_corrected_records = candidate_records
	_review_state = candidate_reviews
	_batch_operations.assign(candidate_operations)
	for frame: int in frames:
		_dirty_frames[frame] = true
		_explicit_frames[frame] = true
	_revision += 1
	corrected_records_replaced.emit(PackedInt64Array(frames))
	review_state_changed.emit()


func _replace_corrected_records(replacements: Dictionary, operation: Dictionary, restore_operation_count: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if replacements.is_empty():
		return PackedStringArray(["replacements: expected at least one frame"])
	var frames: Array[int] = []
	for frame_value: Variant in replacements:
		if not _is_logical_integer(frame_value):
			errors.append("replacements.%s: frame key must be an integer" % str(frame_value))
		else:
			frames.append(int(frame_value))
	if not errors.is_empty():
		return errors
	frames.sort()
	for frame: int in frames:
		for error: String in _validate_replacement(frame, replacements[frame]):
			errors.append("replacements.%d.%s" % [frame, error])
	if not errors.is_empty():
		return errors
	if not operation.is_empty():
		errors.append_array(validate_workflow_state(_review_state, [operation], _corrected_records, _session.get("frame_entries")))
		if not errors.is_empty():
			return errors
	for frame: int in frames:
		_corrected_records[frame] = _immutable_copy(replacements[frame])
		_dirty_frames[frame] = true
		_explicit_frames[frame] = true
	if not operation.is_empty():
		_batch_operations.append(operation.duplicate(true))
	if restore_operation_count >= 0:
		_batch_operations.resize(restore_operation_count)
	_revision += 1
	# 帧数据和传播日志都更新后再通知订阅者。
	corrected_records_replaced.emit(PackedInt64Array(frames))
	return errors


func snapshot_batch_operations() -> Array:
	return _batch_operations.duplicate(true)


func get_frame_count() -> int:
	return _model_records.size()


func get_dirty_frames() -> PackedInt64Array:
	var frames: Array = _dirty_frames.keys()
	frames.sort()
	var result := PackedInt64Array()
	for frame: int in frames:
		result.append(frame)
	return result


func clear_dirty() -> void:
	_dirty_frames.clear()


func snapshot_corrected() -> Array:
	var result: Array = []
	for record: Dictionary in _sorted_record_copies(_corrected_records):
		result.append(_model_output_projection(record))
	return result


func model_digest() -> String:
	return _baseline_digest


func _validate_replacement(frame: int, record: Variant) -> PackedStringArray:
	return validate_replacement(frame, record, _model_records, _corrected_records, _session, _validator)


static func validate_replacement(frame: int, record: Variant, model_records: Dictionary, corrected_records: Dictionary, session: Dictionary, validator: Variant = null) -> PackedStringArray:
	if validator == null: validator = VALIDATOR_SCRIPT.new()
	var errors: PackedStringArray = validator.validate_record(_model_output_projection(record))
	if not corrected_records.has(frame):
		errors.append("frame: frame %d does not exist" % frame)
	if record is Dictionary:
		if not session.is_empty():
			if record.get("source") != session.source:
				errors.append("source: must match session source")
			var original: Dictionary = model_records.get(frame, {})
			if record.has("time_s") != original.has("time_s") or record.get("time_s") != original.get("time_s"):
				errors.append("time_s: must preserve source timestamp including absence")
		var seen_ids := {}
		var regions: Variant = record.get("regions")
		if regions is Array:
			for region: Variant in regions:
				if region is Dictionary:
					if region.has("filled") and not region.filled is bool:
						errors.append("regions.filled: expected boolean internal display flag")
					var region_id: Variant = region.get("id")
					if seen_ids.has(region_id):
						errors.append("regions: duplicate region ID %s" % str(region_id))
					seen_ids[region_id] = true
		var record_frame: Variant = record.get("frame")
		if not _is_logical_integer(record_frame) or int(record_frame) != frame:
			errors.append("frame: record frame must match key %d" % frame)
	return errors


func _sorted_record_copies(records: Dictionary) -> Array:
	var frames: Array = records.keys()
	frames.sort()
	var result: Array = []
	for frame: int in frames:
		result.append(records[frame].duplicate(true))
	return result


static func _canonicalize(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var result := {}
		for key: Variant in keys:
			result[key] = _canonicalize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_canonicalize(item))
		return result
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return float(value)
	return value


func _prefix_record_error(index: int, error: String) -> String:
	if error.begins_with("$:"):
		return "records.%d:%s" % [index, error.substr(2)]
	return "records.%d.%s" % [index, error]


static func _is_logical_integer(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value)) and float(value) == floorf(float(value))


func record_digest(frame: int) -> String:
	# Normalize numeric JSON values so saved/reopened geometry hashes identically.
	return _record_digest_value(get_corrected_record(frame))


static func _record_digest_value(record: Variant) -> String:
	return JSON.stringify(_canonicalize(_model_output_projection(record)), "", true, true).sha256_text()


func legacy_record_digest(frame: int) -> String:
	# V1/V2 migration must validate the old digest before rebinding verification.
	return JSON.stringify(_canonicalize(_model_output_projection(get_corrected_record(frame)))).sha256_text()


func is_verified(frame: int) -> bool:
	return _corrected_records.has(frame) and _review_state.has(str(frame)) and _review_state[str(frame)]["accepted_digest"] == record_digest(frame)


func snapshot_review_state() -> Dictionary:
	return _review_state.duplicate(true)


func load_workflow_state(review_state: Variant, batch_operations: Variant) -> PackedStringArray:
	var errors := validate_workflow_state(review_state, batch_operations, _corrected_records, _session.get("frame_entries"))
	if not errors.is_empty():
		return errors
	batch_operations = _normalize_sam_operations(batch_operations)
	if _review_state != review_state or _batch_operations != batch_operations:
		_revision += 1
	_review_state = review_state.duplicate(true)
	_batch_operations.assign(batch_operations.duplicate(true))
	for key: String in _review_state:
		_explicit_frames[int(key)] = true
	review_state_changed.emit()
	return errors


## JSON 数字读取为 float；v3 已验证的整数恢复为原始类型，旧版审计保持原样。
static func _normalize_sam_operations(operations: Array) -> Array:
	var normalized := operations.duplicate(true)
	for operation: Dictionary in normalized:
		if operation.get("schema_version") != 3: continue
		for field: String in ["schema_version", "keyframe", "keyframe_playback_index", "requested_count", "generated_count", "start_frame", "end_frame", "elapsed_ms"]:
			operation[field] = int(operation[field])
		if operation.stop_frame != null: operation.stop_frame = int(operation.stop_frame)
		for field: String in ["affected_frames", "target_playback_indices"]:
			for index in range(operation[field].size()): operation[field][index] = int(operation[field][index])
		for item: Dictionary in operation.risk_summary: item.frame_id = int(item.frame_id)
	return normalized


static func validate_workflow_state(reviews: Variant, operations: Variant, frames: Dictionary, frame_entries: Variant = null) -> PackedStringArray:
	var errors := PackedStringArray()
	if not reviews is Dictionary or not operations is Array:
		return PackedStringArray(["workflow: expected review object and batch array"])
	var digest_pattern := RegEx.new()
	digest_pattern.compile("^[0-9a-f]{64}$")
	for key: Variant in reviews:
		if not key is String or not key.is_valid_int() or str(int(key)) != key or not frames.has(int(key)):
			errors.append("review_state: unknown or invalid frame key %s" % str(key))
			continue
		var value: Variant = reviews[key]
		if not value is Dictionary or value.size() != 1 or not value.get("accepted_digest") is String:
			errors.append("review_state.%s: expected accepted_digest" % key)
		elif digest_pattern.search(value["accepted_digest"]) == null:
			errors.append("review_state.%s: expected SHA256 digest" % key)
	for operation: Variant in operations:
		errors.append_array(_validate_batch_operation(operation, frames, digest_pattern, frame_entries))
	return errors


static func _valid_frame_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) == floorf(float(value)) and float(value) >= 0.0


static func _validate_batch_operation(operation: Variant, frames: Dictionary, digest_pattern: RegEx, frame_entries: Variant = null) -> PackedStringArray:
	var errors := PackedStringArray()
	if not operation is Dictionary:
		return PackedStringArray(["batch_operations: expected objects"])
	var schema_value: Variant = operation.get("schema_version")
	var schema := int(schema_value) if _valid_frame_number(schema_value) else -1
	if schema == 3:
		return _validate_sam_video_operation(operation, frames, digest_pattern, frame_entries)
	var v1_fields := ["schema_version", "type", "mode", "keyframe", "start_frame", "end_frame", "affected_frames", "metric", "metric_id", "threshold", "max_frames", "keyframe_digest", "created_at", "start_index", "end_index", "left_stop", "right_stop", "changed_count", "covered_count"]
	var v2_fields := ["schema_version", "type", "mode", "keyframe", "start_frame", "end_frame", "affected_frames", "metric_id", "threshold", "max_frames", "keyframe_digest", "created_at", "start_index", "end_index", "left_stop", "right_stop", "changed_count", "covered_count", "edge_refinement"]
	var allowed_fields: Array = (v2_fields + ["frame_step"]) if schema == 2 else v1_fields
	for field: Variant in operation:
		if field not in allowed_fields:
			errors.append("batch_operations: unexpected field %s" % str(field))
	if schema == 2:
		for field: String in v2_fields:
			if not operation.has(field):
				errors.append("batch_operations.%s: required for v2 Poly audit" % field)
	if operation.get("type") != "range_propagate" or operation.get("mode") not in ["overwrite", "merge"] or schema not in [1, 2]:
		errors.append("batch_operations: invalid operation type, mode or version")
	var range_valid := true
	for field: String in ["keyframe", "start_frame", "end_frame"]:
		var value: Variant = operation.get(field)
		if not _valid_frame_number(value) or not frames.has(int(value)):
			errors.append("batch_operations.%s: invalid frame" % field)
			range_valid = false
	if range_valid and operation.start_frame > operation.end_frame:
		errors.append("batch_operations: start_frame must not exceed end_frame")
	var affected: Variant = operation.get("affected_frames")
	if not affected is Array or affected.is_empty():
		errors.append("batch_operations.affected_frames: expected nonempty array")
	else:
		var seen := {}
		for frame: Variant in affected:
			if not _valid_frame_number(frame) or not frames.has(int(frame)) or seen.has(int(frame)):
				errors.append("batch_operations.affected_frames: invalid or duplicate frame")
			else:
				seen[int(frame)] = true
				if range_valid and (frame < operation.start_frame or frame > operation.end_frame or frame == operation.keyframe):
					errors.append("batch_operations.affected_frames: target must be in range and exclude keyframe")
	if operation.has("metric_id"):
		for field: String in ["threshold", "max_frames", "keyframe_digest", "created_at", "start_index", "end_index", "left_stop", "right_stop", "changed_count", "covered_count"]:
			if not operation.has(field):
				errors.append("batch_operations.%s: required for metric audit" % field)
		if range_valid and (operation.keyframe < operation.start_frame or operation.keyframe > operation.end_frame):
			errors.append("batch_operations: metric range must contain keyframe")
	for field: String in ["metric", "metric_id", "left_stop", "right_stop"]:
		if operation.has(field) and (not operation[field] is String or operation[field].strip_edges().is_empty()):
			errors.append("batch_operations.%s: expected nonempty text" % field)
	if operation.has("threshold"):
		var threshold: Variant = operation.threshold
		if (typeof(threshold) != TYPE_INT and typeof(threshold) != TYPE_FLOAT) or not is_finite(float(threshold)) or float(threshold) <= 0.0 or float(threshold) > 1.0:
			errors.append("batch_operations.threshold: expected finite number in (0, 1]")
	for field: String in ["max_frames", "start_index", "end_index", "changed_count", "covered_count"]:
		if operation.has(field) and (not _valid_frame_number(operation[field]) or (field in ["max_frames", "changed_count", "covered_count"] and operation[field] == 0)):
			errors.append("batch_operations.%s: invalid integer" % field)
	var frame_step := 1
	if operation.has("frame_step"):
		if not _valid_frame_number(operation.frame_step) or int(operation.frame_step) < 1:
			errors.append("batch_operations.frame_step: expected positive integer")
		else:
			frame_step = int(operation.frame_step)
	if schema == 2 and range_valid and affected is Array:
		for frame: Variant in affected:
			if _valid_frame_number(frame) and (int(frame) - int(operation.start_frame)) % frame_step != 0:
				errors.append("batch_operations.affected_frames: target must match frame_step")
	if operation.has("keyframe_digest") and (not operation.keyframe_digest is String or digest_pattern.search(operation.keyframe_digest) == null):
		errors.append("batch_operations.keyframe_digest: expected SHA256")
	if operation.has("created_at"):
		var timestamp_pattern := RegEx.new()
		timestamp_pattern.compile("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](Z)?$")
		if not operation.created_at is String or timestamp_pattern.search(operation.created_at) == null:
			errors.append("batch_operations.created_at: expected ISO timestamp")
	if errors.is_empty() and operation.has("metric_id"):
		if operation.start_index > operation.end_index or operation.covered_count != operation.end_index - operation.start_index + 1 or operation.covered_count > operation.max_frames:
			errors.append("batch_operations: inconsistent covered range")
		if operation.changed_count != affected.size() or operation.changed_count >= operation.covered_count:
			errors.append("batch_operations: inconsistent changed count")
	if schema == 2:
		errors.append_array(_validate_edge_refinement(operation, frames, frame_step))
	return errors


## v3 只记录单区域前向候选的确认摘要；瞬时推理内容不可进入持久化审计。
static func _validate_sam_video_operation(operation: Dictionary, frames: Dictionary, digest_pattern: RegEx, frame_entries: Variant) -> PackedStringArray:
	var fields := ["schema_version", "type", "mode", "provider_id", "metric_id", "keyframe",
		"keyframe_playback_index", "keyframe_digest", "region_id", "direction", "requested_count", "generated_count",
		"start_frame", "end_frame", "affected_frames", "target_playback_indices", "stop_frame", "stop_reason",
		"checkpoint_sha256", "device", "model_version", "elapsed_ms", "risk_summary", "created_at"]
	var errors := PackedStringArray()
	for field: Variant in operation:
		if field not in fields: errors.append("SAM audit: unexpected field %s" % str(field))
	for field: String in fields:
		if not operation.has(field): errors.append("SAM audit.%s: required" % field)
	if not errors.is_empty(): return errors
	if operation.type != "range_propagate" or operation.mode != "merge" or operation.provider_id != "sam_video" or operation.metric_id != "sam-video-v1" or operation.direction != "forward":
		errors.append("SAM audit: invalid type, mode, provider, metric or direction")
	for field: String in ["keyframe", "start_frame", "end_frame"]:
		if not _valid_frame_number(operation[field]) or not frames.has(int(operation[field])):
			errors.append("SAM audit.%s: unknown Source frame" % field)
	for field: String in ["keyframe_playback_index", "requested_count", "generated_count", "elapsed_ms"]:
		if not _valid_frame_number(operation[field]) or float(operation[field]) > 9007199254740991.0:
			errors.append("SAM audit.%s: expected bounded nonnegative integer" % field)
	if not _sam_audit_text(operation.region_id, 128): errors.append("SAM audit.region_id: invalid bounded identity")
	var version_pattern := RegEx.new()
	version_pattern.compile("^[A-Za-z0-9][A-Za-z0-9._+\\-]{0,63}\\z")
	if not operation.model_version is String or version_pattern.search(operation.model_version) == null:
		errors.append("SAM audit.model_version: expected bounded runtime version")
	if operation.device not in ["cpu", "cuda"]: errors.append("SAM audit.device: expected actual cpu or cuda device")
	for field: String in ["keyframe_digest", "checkpoint_sha256"]:
		if not operation[field] is String or operation[field].length() != 64 or digest_pattern.search(operation[field]) == null:
			errors.append("SAM audit.%s: expected SHA256" % field)
	var timestamp_pattern := RegEx.new()
	timestamp_pattern.compile("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](Z)?$")
	if not _sam_audit_text(operation.created_at, 20) or timestamp_pattern.search(operation.created_at) == null:
		errors.append("SAM audit.created_at: expected ISO timestamp")
	if not operation.affected_frames is Array or not operation.target_playback_indices is Array:
		errors.append("SAM audit: expected target frame and playback arrays")
	if not operation.risk_summary is Array or operation.risk_summary.size() > 30:
		errors.append("SAM audit.risk_summary: expected at most 30 items")
	if operation.stop_reason not in ["", "source_end", "verified_target", "model_topology", "user_range"]:
		errors.append("SAM audit.stop_reason: expected bounded stop category")
	if not errors.is_empty(): return errors
	var count := int(operation.generated_count)
	var requested := int(operation.requested_count)
	var key_index := int(operation.keyframe_playback_index)
	var order := _sam_playback_order(frame_entries, frames)
	if order.is_empty():
		return PackedStringArray(["SAM audit: trusted complete Source playback entries are required"])
	if requested < 1 or requested > 30 or count < 1 or count > requested or operation.affected_frames.size() != count or operation.target_playback_indices.size() != count:
		return PackedStringArray(["SAM audit: inconsistent bounded target counts"])
	if key_index >= order.size() or key_index + count >= order.size() or order[key_index] != operation.keyframe:
		return PackedStringArray(["SAM audit: key/playback identity or target range differs from Source"])
	for offset in range(count):
		var frame: Variant = operation.affected_frames[offset]
		var index: Variant = operation.target_playback_indices[offset]
		if not _valid_frame_number(frame) or not _valid_frame_number(index) or index != key_index + offset + 1 or frame != order[key_index + offset + 1]:
			errors.append("SAM audit: targets must be the exact ordered forward Source prefix")
	if operation.start_frame != operation.keyframe or operation.end_frame != operation.affected_frames[-1]:
		errors.append("SAM audit: range must exactly cover key and accepted targets")
	if count == requested:
		if operation.stop_frame != null or operation.stop_reason != "": errors.append("SAM audit: complete request cannot have a stop")
	elif operation.stop_reason == "source_end":
		if operation.stop_frame != null or key_index + count != order.size()-1:
			errors.append("SAM audit: Source end must follow the last accepted Source frame")
	elif operation.stop_reason in ["verified_target", "model_topology", "user_range"]:
		if key_index + count + 1 >= order.size() or not _valid_frame_number(operation.stop_frame) or operation.stop_frame != order[key_index + count + 1]:
			errors.append("SAM audit: stop must name the first excluded Source frame")
	else: errors.append("SAM audit: truncated request needs a stop category")
	var previous_risk_index := -1
	for item: Variant in operation.risk_summary:
		if not item is Dictionary or item.size() != 2 or not item.has("frame_id") or not item.has("kinds"):
			errors.append("SAM audit.risk_summary: expected exact frame_id and kinds")
			continue
		var risk_index: int = operation.affected_frames.find(item.frame_id)
		if not _valid_frame_number(item.frame_id) or risk_index < 0 or risk_index <= previous_risk_index:
			errors.append("SAM audit.risk_summary: unique accepted targets must be ordered")
		previous_risk_index = risk_index
		if not item.kinds is Array or item.kinds.is_empty() or item.kinds.size() > 4:
			errors.append("SAM audit.risk_summary.kinds: expected one to four categories")
			continue
		var seen := {}
		for kind: Variant in item.kinds:
			if kind not in ["sparse_input", "area_change", "frame_difference", "flow_consistency"] or seen.has(kind):
				errors.append("SAM audit.risk_summary.kinds: unknown or duplicate category")
			seen[kind] = true
	return errors


static func _sam_audit_text(value: Variant, limit: int) -> bool:
	if not value is String or value.is_empty() or value.length() > limit or value.contains("/") or value.contains("\\"):
		return false
	for index in range(value.length()):
		if value.unicode_at(index) < 32 or value.unicode_at(index) == 127: return false
	return not value.strip_edges().is_empty()


## 播放序号与原始 frame_id 是两种身份；禁止从原始编号排序推断播放顺序。
static func _sam_playback_order(frame_entries: Variant, frames: Dictionary) -> Array:
	if not frame_entries is Array or frame_entries.is_empty() or frame_entries.size() != frames.size(): return []
	var order: Array = []
	var seen := {}
	for index in range(frame_entries.size()):
		var entry: Variant = frame_entries[index]
		if not entry is Dictionary or not _valid_frame_number(entry.get("frame")) or entry.frame != index or not _valid_frame_number(entry.get("frame_id")):
			return []
		var frame := int(entry.frame_id)
		if not frames.has(frame) or seen.has(frame): return []
		seen[frame] = true
		order.append(frame)
	return order


static func _same_frame_set(affected: Variant, changed: Array) -> bool:
	if not affected is Array or affected.size() != changed.size(): return false
	var seen := {}
	for value: Variant in affected:
		if not _valid_frame_number(value): return false
		var frame := int(value)
		if frame not in changed or seen.has(frame): return false
		seen[frame] = true
	return true


static func _validate_edge_refinement(operation: Dictionary, frames: Dictionary, frame_step: int = 1) -> PackedStringArray:
	var errors := PackedStringArray()
	if operation.get("metric_id") != "poly-sim-flow-edge-v1":
		errors.append("batch_operations.metric_id: invalid Poly edge algorithm")
	if operation.get("max_frames") != 30:
		errors.append("batch_operations.max_frames: Poly edge audit must use 30")
	if _valid_frame_number(operation.get("start_frame")) and _valid_frame_number(operation.get("end_frame")) and _valid_frame_number(operation.get("covered_count")):
		if int(operation.end_frame) - int(operation.start_frame) != (int(operation.covered_count) - 1) * frame_step:
			errors.append("batch_operations: real and playback ranges differ")
	for field: String in ["left_stop", "right_stop"]:
		if operation.get(field) is String and operation[field].length() > 512:
			errors.append("batch_operations.%s: reason is too long" % field)
	var summary: Variant = operation.get("edge_refinement")
	if not summary is Dictionary or summary.size() != 4:
		return PackedStringArray(["batch_operations.edge_refinement: expected exact summary fields"])
	for field: String in ["attempted", "accepted", "fallback", "items"]:
		if not summary.has(field):
			errors.append("batch_operations.edge_refinement.%s: required" % field)
	if not errors.is_empty():
		return errors
	for field: String in ["attempted", "accepted", "fallback"]:
		if not _valid_frame_number(summary[field]):
			errors.append("batch_operations.edge_refinement.%s: invalid count" % field)
	var items: Variant = summary.items
	if not items is Array:
		return PackedStringArray(["batch_operations.edge_refinement.items: expected array"])
	# Historical audit identity is self-contained in the immutable item matrix.
	# It must not depend on later edits to the current keyframe geometry.
	var reference_ids := {}
	var keyframe: int = int(operation.get("keyframe", -1))
	var target_set := {}
	if _valid_frame_number(operation.get("start_frame")) and _valid_frame_number(operation.get("covered_count")):
		var start_frame := int(operation.start_frame)
		if (keyframe - start_frame) % frame_step != 0:
			errors.append("batch_operations.keyframe: must match frame_step")
		for offset: int in range(int(operation.covered_count)):
			var frame_id := start_frame + offset * frame_step
			if not frames.has(frame_id):
				errors.append("batch_operations: sampled range contains an unknown frame")
			elif frame_id != keyframe:
				target_set[frame_id] = true
	var seen := {}
	var accepted_count := 0
	var fallback_count := 0
	for item: Variant in items:
		if not item is Dictionary or item.size() != 6:
			errors.append("batch_operations.edge_refinement.items: invalid item shape")
			continue
		for field: String in ["frame_id", "region_id", "accepted", "reason", "raw_edge_score", "refined_edge_score"]:
			if not item.has(field):
				errors.append("batch_operations.edge_refinement.items: missing %s" % field)
		if not _valid_frame_number(item.get("frame_id")) or not target_set.has(int(item.get("frame_id", -1))):
			errors.append("batch_operations.edge_refinement.items: frame must be a covered target")
		var region_id: Variant = item.get("region_id")
		if not region_id is String or region_id.is_empty() or region_id.length() > 256:
			errors.append("batch_operations.edge_refinement.items: invalid reference region ID")
		else:
			reference_ids[region_id] = true
		var identity := "%s\u001f%s" % [str(item.get("frame_id")), str(region_id)]
		if seen.has(identity):
			errors.append("batch_operations.edge_refinement.items: duplicate frame/region")
		seen[identity] = true
		if not item.get("accepted") is bool:
			errors.append("batch_operations.edge_refinement.items: accepted must be boolean")
		elif item.accepted:
			accepted_count += 1
		else:
			fallback_count += 1
		var reason: Variant = item.get("reason")
		if not reason is String or reason.is_empty() or reason.length() > 160:
			errors.append("batch_operations.edge_refinement.items: invalid reason")
		else:
			for value: int in reason.to_utf8_buffer():
				if value < 32:
					errors.append("batch_operations.edge_refinement.items: reason contains control characters")
					break
		for field: String in ["raw_edge_score", "refined_edge_score"]:
			var score: Variant = item.get(field)
			if (typeof(score) != TYPE_INT and typeof(score) != TYPE_FLOAT) or not is_finite(float(score)) or float(score) < 0.0 or float(score) > 1.0:
				errors.append("batch_operations.edge_refinement.items.%s: invalid score" % field)
	if reference_ids.is_empty():
		errors.append("batch_operations.edge_refinement: audit has no reference Poly IDs")
	var expected_items := target_set.size() * reference_ids.size()
	if items.size() > 29 * reference_ids.size() or items.size() != expected_items:
		errors.append("batch_operations.edge_refinement.items: inconsistent bounded item count")
	if _valid_frame_number(summary.attempted) and int(summary.attempted) != items.size():
		errors.append("batch_operations.edge_refinement.attempted: inconsistent count")
	if _valid_frame_number(summary.accepted) and int(summary.accepted) != accepted_count:
		errors.append("batch_operations.edge_refinement.accepted: inconsistent count")
	if _valid_frame_number(summary.fallback) and int(summary.fallback) != fallback_count:
		errors.append("batch_operations.edge_refinement.fallback: inconsistent count")
	return errors


# These session APIs contain no IO. Load/validation belongs to the worker that
# constructs the store; freeze only publishes already immutable record values.
func configure_session(context: Dictionary) -> PackedStringArray:
	var errors := validate_session_context(context, _model_records, _corrected_records, _frame_order)
	if not errors.is_empty(): return errors
	_session = {}
	for field: String in ["session_id", "media_id", "media_type", "source_relative_path", "source", "source_sha256", "round_id", "model_revision", "taxonomy_version", "baseline_kind", "source_root"]:
		if context.has(field):
			_session[field] = context[field]
	_session["source_sha256"] = context.get("source_sha256")
	_session["frame_entries"] = _immutable_copy(context.frame_entries)
	_revision = int(context.get("revision", 0))
	_explicit_frames = {}
	for frame: Variant in context.get("explicit_frames", _frame_order):
		_explicit_frames[int(frame)] = true
	return errors


static func validate_session_context(context: Dictionary, model_records: Dictionary, corrected_records: Dictionary, frame_order: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	for field: String in ["session_id", "media_id", "media_type", "source_relative_path", "source", "round_id", "model_revision", "taxonomy_version"]:
		if not context.get(field) is String or context[field].is_empty():
			errors.append("%s: expected nonempty session text" % field)
	if context.get("media_type") not in ["image", "video", "image_sequence"]:
		errors.append("media_type: invalid type")
	var id_pattern := RegEx.new()
	id_pattern.compile("^[A-Za-z0-9](?:[A-Za-z0-9_]{0,62}[A-Za-z0-9])?$")
	if context.get("media_id") is String and id_pattern.search(context.media_id) == null:
		errors.append("media_id: invalid portable identity")
	if context.get("source_relative_path") is String:
		var path: String = context.source_relative_path
		if path.is_absolute_path() or path.contains("\\") or ".." in path.split("/") or path.contains(":"):
			errors.append("source_relative_path: expected contained POSIX path")
	var digest_pattern := RegEx.new()
	digest_pattern.compile("^[0-9a-f]{64}$")
	if context.get("source_sha256") != null and (not context.source_sha256 is String or digest_pattern.search(context.source_sha256) == null):
		errors.append("source_sha256: expected SHA256 or null")
	if context.has("source_root") and not context.source_root is String:
		errors.append("source_root: expected local path string")
	if context.get("baseline_kind") not in ["model", "imported_labels", "empty", "unknown"]:
		errors.append("baseline_kind: invalid origin")
	if not _valid_frame_number(context.get("revision", 0)):
		errors.append("revision: expected nonnegative integer")
	var entries: Variant = context.get("frame_entries")
	var explicit: Variant = context.get("explicit_frames", frame_order)
	var frame_map := {}
	var previous_time := -1.0
	if not entries is Array or entries.is_empty() or entries.size() != corrected_records.size():
		errors.append("frame_entries: expected exact source frame set")
	else:
		for index in range(entries.size()):
			var entry: Variant = entries[index]
			if not entry is Dictionary or not _valid_frame_number(entry.get("frame_id")) or not _valid_frame_number(entry.get("frame")) or entry.frame != index:
				errors.append("frame_entries: invalid playback/original identity")
				continue
			for field: Variant in entry:
				if field not in ["frame", "frame_id", "time_s", "image_path"]:
					errors.append("frame_entries: unexpected field %s" % str(field))
			if entry.has("image_path") and (not entry.image_path is String or not _contained_path(entry.image_path)):
				errors.append("frame_entries.image_path: expected contained POSIX path")
			if entry.has("time_s"):
				var time: Variant = entry.time_s
				if typeof(time) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(time)) or float(time) < previous_time or float(time) < 0:
					errors.append("frame_entries.time_s: expected ordered finite timestamp")
				else:
					previous_time = float(time)
			var frame := int(entry.frame_id)
			if frame > 999999:
				errors.append("frame_entries: original frame ID exceeds six digits")
			if frame_map.has(frame) or not corrected_records.has(frame):
				errors.append("frame_entries: duplicate or unknown frame")
			else:
				frame_map[frame] = true
				var record: Dictionary = model_records[frame]
				if record.source != context.get("source") or (record.has("time_s") and (not entry.has("time_s") or record.time_s != entry.time_s)):
					errors.append("frame_entries: source or timestamp differs from loaded record")
	var next_explicit := {}
	if not explicit is Array:
		errors.append("explicit_frames: expected array")
	else:
		for frame: Variant in explicit:
			if not _valid_frame_number(frame) or not frame_map.has(int(frame)) or next_explicit.has(int(frame)):
				errors.append("explicit_frames: duplicate or unknown frame")
			else:
				next_explicit[int(frame)] = true
	return errors


func current_revision() -> int:
	return _revision


func restore_corrected(records: Variant, review_state: Variant, batch_operations: Variant) -> PackedStringArray:
	if not records is Array or records.size() != _corrected_records.size():
		return PackedStringArray(["records: expected exact complete frame set"])
	var errors := PackedStringArray()
	var next := {}
	for record: Variant in records:
		if not record is Dictionary or not _valid_frame_number(record.get("frame")):
			errors.append("records: invalid frame")
			continue
		var frame := int(record.frame)
		if next.has(frame):
			errors.append("records: duplicate frame")
		errors.append_array(_validate_replacement(frame, record))
		next[frame] = record
	errors.append_array(validate_workflow_state(review_state, batch_operations, next, _session.get("frame_entries")))
	if not errors.is_empty():
		return errors
	for frame: int in next:
		next[frame] = _model_records[frame] if next[frame] == _model_records.get(frame) else _immutable_copy(next[frame])
	_corrected_records = next
	_review_state = review_state.duplicate(true)
	_batch_operations.assign(_normalize_sam_operations(batch_operations))
	_dirty_frames.clear()
	corrected_records_replaced.emit(PackedInt64Array(_frame_order))
	review_state_changed.emit()
	return errors


func freeze_snapshot() -> Dictionary:
	var snapshot := _session.duplicate()
	snapshot["schema_version"] = 1
	snapshot["revision"] = _revision
	snapshot["baseline_kind"] = _session.get("baseline_kind", "model")
	snapshot["baseline_digest"] = _snapshot_baseline_digest if snapshot.baseline_kind in ["model", "imported_labels"] else null
	var baseline: Array = []
	var corrected: Array = []
	for frame: int in _frame_order:
		if snapshot.baseline_kind in ["model", "imported_labels"]:
			baseline.append(_model_records[frame])
		corrected.append(_corrected_records[frame])
	baseline.make_read_only()
	corrected.make_read_only()
	snapshot["baseline_records"] = baseline
	snapshot["records"] = corrected
	var explicit: Array = _explicit_frames.keys()
	explicit.sort()
	explicit.make_read_only()
	snapshot["explicit_frames"] = explicit
	snapshot["review_state"] = _immutable_copy(_review_state)
	snapshot["batch_operations"] = _immutable_copy(_batch_operations)
	snapshot.make_read_only()
	return snapshot


# 只有整棵容器树均不可变时才共享；浅只读容器仍需隔离可变子节点。
static func _deeply_immutable(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only(): return false
		for key: Variant in value:
			if not _deeply_immutable(value[key]): return false
	elif value is Array:
		if not value.is_read_only(): return false
		for child: Variant in value:
			if not _deeply_immutable(child): return false
	return true


static func _immutable_copy(value: Variant) -> Variant:
	if _deeply_immutable(value): return value
	if value is Dictionary:
		var result := {}
		for key: Variant in value:
			result[key] = _immutable_copy(value[key])
		result.make_read_only()
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_immutable_copy(item))
		result.make_read_only()
		return result
	return value


static func _contained_path(path: String) -> bool:
	return not path.is_empty() and not path.is_absolute_path() and not path.contains("\\") and ".." not in path.split("/") and not path.contains(":")
