class_name ReviewSessionCodec
extends RefCounted

const STREAM_JSON := preload("res://client/domain/stream_json.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const VALIDATOR := preload("res://client/domain/model_output_validator.gd")
const FIELDS := ["schema_version", "session_id", "media_id", "media_type", "source_relative_path", "source", "source_sha256", "round_id", "model_revision", "taxonomy_version", "revision", "baseline_kind", "baseline_digest", "baseline_records", "frame_entries", "explicit_frames", "review_state", "batch_operations", "frame_digits", "frames"]


# Worker-only serialization boundary. Internal source and raw baseline stay intact.
func encode(snapshot: Dictionary) -> Dictionary:
	var payload := {}
	for field: String in FIELDS:
		if snapshot.has(field):
			var value: Variant = snapshot[field]
			payload[field] = STORE._immutable_copy(value)
	payload["schema_version"] = 3
	payload["frame_digits"] = 6
	var explicit := {}
	for frame: Variant in snapshot.get("explicit_frames", []):
		explicit[int(frame)] = true
	var frames := {}
	for record: Dictionary in snapshot.get("records", []):
		if explicit.has(int(record.frame)):
			var projected: Dictionary = STORE._model_output_projection(record)
			projected.source = "human_corrected"
			frames[str(int(record.frame))] = STORE._immutable_copy(projected)
	payload["frames"] = frames
	return payload


func decode(payload: Variant, token: Variant = null) -> Dictionary:
	return _decode(payload, token, true)


func validate_v3(payload: Variant, token: Variant = null) -> PackedStringArray:
	return _decode(payload, token, false).errors


func _decode(payload: Variant, token: Variant, materialize: bool) -> Dictionary:
	if token != null and token.is_cancelled(): return _failure("Session validation cancelled")
	var errors := PackedStringArray()
	if not payload is Dictionary:
		return _failure("$: expected V3 session object")
	for field: String in FIELDS:
		if not payload.has(field): errors.append("%s: required field missing" % field)
	for field: Variant in payload:
		if field not in FIELDS: errors.append("%s: unexpected field" % str(field))
	if not errors.is_empty(): return {"snapshot": {}, "errors": errors}
	if not payload.source is String or payload.source.is_empty():
		return _failure("source: expected nonempty internal source text")
	if not STORE._valid_frame_number(payload.schema_version) or payload.schema_version != 3 or not STORE._valid_frame_number(payload.frame_digits) or payload.frame_digits != 6:
		return _failure("schema_version/frame_digits: expected 3/6")
	if not payload.baseline_records is Array or not payload.frame_entries is Array or not payload.explicit_frames is Array or not payload.frames is Dictionary:
		return _failure("session: invalid baseline, frame map or explicit frame containers")
	var baseline := {}
	var validator = VALIDATOR.new()
	for record: Variant in payload.baseline_records:
		if token != null and token.is_cancelled(): return _failure("Session validation cancelled")
		errors.append_array(validator.validate_record(record))
		if record is Dictionary and STORE._valid_frame_number(record.get("frame")):
			if baseline.has(int(record.frame)): errors.append("baseline_records: duplicate frame")
			baseline[int(record.frame)] = record
			var region_ids := {}
			for region: Variant in (record.regions if record.get("regions") is Array else []):
				if region is Dictionary:
					if region_ids.has(region.get("id")): errors.append("baseline_records: duplicate region ID")
					region_ids[region.get("id")] = true
	if not errors.is_empty(): return {"snapshot": {}, "errors": errors}
	var known: bool = payload.baseline_kind in ["model", "imported_labels"]
	if not known and not baseline.is_empty():
		return _failure("baseline_records: empty/unknown origins cannot contain model records")
	var display: Array = []
	var frame_map := {}
	for entry: Variant in payload.frame_entries:
		if not entry is Dictionary or not STORE._valid_frame_number(entry.get("frame_id")):
			return _failure("frame_entries: invalid original frame identity")
		var frame := int(entry.frame_id)
		frame_map[frame] = true
		if known and not baseline.has(frame): return _failure("baseline_records: incomplete frame set")
		var record: Dictionary = baseline[frame] if known else _empty_display_record(payload.source, entry, payload.frames.get(str(frame)))
		display.append(record)
	if known and baseline.size() != frame_map.size(): return _failure("baseline_records: unexpected frame")
	var models := {}
	for record: Dictionary in display:
		if models.has(int(record.frame)): errors.append("records: duplicate frame")
		models[int(record.frame)] = record
		errors.append_array(validator.validate_record(record))
	var order: Array = models.keys()
	order.sort()
	if errors.is_empty(): errors.append_array(STORE.validate_session_context(payload, models, models, order))
	if not errors.is_empty(): return {"snapshot": {}, "errors": errors}
	var expected_digest: Variant = null
	if known:
		var ordered: Array = []
		for frame: int in order: ordered.append(models[frame])
		expected_digest = STREAM_JSON.record_digests(ordered).current
	if payload.baseline_digest != expected_digest: return _failure("baseline_digest: differs from immutable baseline")
	var explicit := {}
	for frame: Variant in payload.explicit_frames: explicit[int(frame)] = true
	if payload.frames.size() != explicit.size(): return _failure("frames: must exactly match explicit_frames")
	var corrections := {}
	for key: Variant in payload.frames:
		if token != null and token.is_cancelled(): return _failure("Session validation cancelled")
		if not key is String or not key.is_valid_int() or str(int(key)) != key or not explicit.has(int(key)):
			return _failure("frames: invalid or unexpected original frame key")
		var record: Variant = payload.frames[key]
		var record_errors: PackedStringArray = validator.validate_record(record)
		errors.append_array(record_errors)
		if not record_errors.is_empty(): continue
		if record.get("source") != "human_corrected" or record.get("frame") != int(key):
			errors.append("frames.%s: wrong projection or frame identity" % key)
		var internal: Dictionary = record.duplicate()
		internal.source = payload.source
		corrections[int(key)] = internal
	if not errors.is_empty(): return {"snapshot": {}, "errors": errors}
	for index in range(display.size()):
		var frame := int(display[index].frame)
		if corrections.has(frame): display[index] = corrections[frame]
	if payload.review_state is Dictionary:
		for key: Variant in payload.review_state:
			if not key is String or not key.is_valid_int() or not explicit.has(int(key)):
				errors.append("review_state: reviewed frames must be explicit")
	if not errors.is_empty(): return {"snapshot": {}, "errors": errors}
	for record: Dictionary in display:
		errors.append_array(STORE.validate_replacement(int(record.frame), record, models, models, payload, validator))
	errors.append_array(STORE.validate_workflow_state(payload.review_state, payload.batch_operations, models, payload.frame_entries))
	if not errors.is_empty(): return {"snapshot": {}, "errors": errors}
	if not materialize: return {"snapshot": {}, "errors": errors}
	# 输入 JSON 只在发布快照时隔离一次；未修改帧复用冻结后的 baseline。
	var immutable_baseline: Array = []
	var immutable_models := {}
	for frame: int in order:
		immutable_models[frame] = STORE._immutable_copy(models[frame])
		if known: immutable_baseline.append(immutable_models[frame])
	var corrected: Array = []
	var by_frame := {}
	for record: Dictionary in display: by_frame[int(record.frame)] = record
	for frame: int in order:
		corrected.append(immutable_models[frame] if by_frame[frame] == models[frame] else STORE._immutable_copy(by_frame[frame]))
	var snapshot := {}
	for field: String in FIELDS:
		if field not in ["frames", "frame_digits"]: snapshot[field] = payload[field]
	snapshot.schema_version = 1
	snapshot.revision = int(payload.revision)
	var explicit_order: Array = explicit.keys()
	explicit_order.sort()
	snapshot.explicit_frames = explicit_order
	snapshot.baseline_records = immutable_baseline
	snapshot["records"] = corrected
	return {"snapshot": STORE._immutable_copy(snapshot), "errors": errors}


# 验证内部快照及其可持久化投影；不构造 Store，也不复制整组几何。
func validate_snapshot(snapshot: Dictionary, token: Variant = null) -> PackedStringArray:
	if token != null and token.is_cancelled(): return PackedStringArray(["Snapshot validation cancelled"])
	var errors := PackedStringArray()
	# 编码前先校验容器与显式帧元素，避免迭代/整数转换触发运行时错误。
	for field: String in ["records", "baseline_records", "frame_entries", "explicit_frames", "batch_operations"]:
		if not snapshot.get(field) is Array: errors.append("snapshot.%s: expected Array" % field)
	if not snapshot.get("review_state") is Dictionary: errors.append("snapshot.review_state: expected Dictionary")
	if not errors.is_empty(): return errors
	for frame: Variant in snapshot.explicit_frames:
		if not STORE._valid_frame_number(frame): errors.append("explicit_frames: invalid frame")
	if not errors.is_empty(): return errors
	var records: Array = snapshot.records
	var record_map := {}
	var validator = VALIDATOR.new()
	for record: Variant in records:
		if token != null and token.is_cancelled(): return PackedStringArray(["Snapshot validation cancelled"])
		errors.append_array(validator.validate_record(STORE._model_output_projection(record)))
		if record is Dictionary and STORE._valid_frame_number(record.get("frame")):
			if record_map.has(int(record.frame)): errors.append("records: duplicate frame")
			record_map[int(record.frame)] = record
	if not errors.is_empty(): return errors
	# encode 只创建显式帧的浅投影；共享已冻结的大型几何容器。
	var payload := encode(snapshot)
	errors = validate_v3(payload, token)
	if not errors.is_empty(): return errors
	var known: bool = snapshot.baseline_kind in ["model", "imported_labels"]
	var baseline := {}
	for record: Dictionary in snapshot.baseline_records: baseline[int(record.frame)] = record
	var explicit := {}
	for frame: Variant in snapshot.explicit_frames: explicit[int(frame)] = true
	if record_map.size() != snapshot.frame_entries.size(): errors.append("records: incomplete reconstructed frame set")
	for entry: Dictionary in snapshot.frame_entries:
		var frame := int(entry.frame_id)
		if not record_map.has(frame):
			errors.append("records: missing reconstructed frame")
			continue
		if record_map[frame].source != snapshot.source:
			errors.append("records: source differs from reconstructed content")
		if not explicit.has(frame):
			var expected: Dictionary = baseline[frame] if known else _empty_display_record(snapshot.source, entry)
			if STORE._canonicalize(STORE._model_output_projection(record_map[frame])) != STORE._canonicalize(expected):
				errors.append("records: implicit frame differs from reconstructed content")
	return errors


static func _failure(message: String) -> Dictionary:
	return {"snapshot": {}, "errors": PackedStringArray([message])}


# Use only with an already decoded/validated snapshot. Unknown or empty origins
# need complete empty display records without inventing a baseline or timestamp.
static func baseline_display_records(snapshot: Dictionary) -> Array:
	if snapshot.get("baseline_kind") in ["model", "imported_labels"]:
		return snapshot.baseline_records
	var annotations := {}
	for record: Dictionary in snapshot.get("records", []):
		annotations[int(record.frame)] = record
	var result: Array = []
	for entry: Dictionary in snapshot.frame_entries:
		result.append(_empty_display_record(snapshot.source, entry, annotations.get(int(entry.frame_id))))
	return result


static func _empty_display_record(source: String, entry: Dictionary, annotation: Variant = null) -> Dictionary:
	var record := {"schema_version":1, "source":source, "frame":entry.frame_id, "regions":[]}
	# An explicit legacy record owns timestamp presence, even when Source knows
	# the time. Only missing annotations may take their display time from Source.
	var timestamp_origin: Dictionary = annotation if annotation is Dictionary else entry
	if timestamp_origin.has("time_s"): record["time_s"] = timestamp_origin.time_s
	return record
