class_name ReviewSessionCodec
extends RefCounted

const STORE := preload("res://client/domain/annotation_store.gd")
const VALIDATOR := preload("res://client/domain/model_output_validator.gd")
const FIELDS := ["schema_version", "session_id", "media_id", "media_type", "source_relative_path", "source", "source_sha256", "round_id", "model_revision", "taxonomy_version", "revision", "baseline_kind", "baseline_digest", "baseline_records", "frame_entries", "explicit_frames", "review_state", "batch_operations", "frame_digits", "frames"]


# Worker-only serialization boundary. Internal source and raw baseline stay intact.
func encode(snapshot: Dictionary) -> Dictionary:
	var payload := {}
	for field: String in FIELDS:
		if snapshot.has(field):
			var value: Variant = snapshot[field]
			payload[field] = value.duplicate(true) if value is Dictionary or value is Array else value
	payload["schema_version"] = 3
	payload["frame_digits"] = 6
	var explicit := {}
	for frame: Variant in snapshot.get("explicit_frames", []):
		explicit[int(frame)] = true
	var frames := {}
	for record: Dictionary in snapshot.get("records", []):
		if explicit.has(int(record.frame)):
			var projected := record.duplicate(true)
			projected.source = "human_corrected"
			for region: Dictionary in projected.regions:
				region.erase("filled")
			frames[str(int(record.frame))] = projected
	payload["frames"] = frames
	return payload


func decode(payload: Variant) -> Dictionary:
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
		var record: Dictionary = baseline[frame].duplicate(true) if known else _empty_display_record(payload.source, entry, payload.frames.get(str(frame)))
		display.append(record)
	if known and baseline.size() != frame_map.size(): return _failure("baseline_records: unexpected frame")
	var store = STORE.new()
	errors.append_array(store.load_model_records(display))
	if errors.is_empty(): errors.append_array(store.configure_session(payload))
	if not errors.is_empty(): return {"snapshot": {}, "errors": errors}
	var expected_digest: Variant = store.freeze_snapshot().baseline_digest
	if payload.baseline_digest != expected_digest: return _failure("baseline_digest: differs from immutable baseline")
	var explicit := {}
	for frame: Variant in payload.explicit_frames: explicit[int(frame)] = true
	if payload.frames.size() != explicit.size(): return _failure("frames: must exactly match explicit_frames")
	var corrections := {}
	for key: Variant in payload.frames:
		if not key is String or not key.is_valid_int() or str(int(key)) != key or not explicit.has(int(key)):
			return _failure("frames: invalid or unexpected original frame key")
		var record: Variant = payload.frames[key]
		errors.append_array(validator.validate_record(record))
		if not record is Dictionary: continue
		if record.get("source") != "human_corrected" or record.get("frame") != int(key):
			errors.append("frames.%s: wrong projection or frame identity" % key)
		var internal: Dictionary = record.duplicate(true)
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
	errors.append_array(store.restore_corrected(display, payload.review_state, payload.batch_operations))
	if not errors.is_empty(): return {"snapshot": {}, "errors": errors}
	return {"snapshot": store.freeze_snapshot(), "errors": errors}


static func _failure(message: String) -> Dictionary:
	return {"snapshot": {}, "errors": PackedStringArray([message])}


# Use only with an already decoded/validated snapshot. Unknown or empty origins
# need complete empty display records without inventing a baseline or timestamp.
static func baseline_display_records(snapshot: Dictionary) -> Array:
	if snapshot.get("baseline_kind") in ["model", "imported_labels"]:
		return snapshot.baseline_records.duplicate(true)
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
