## Pure-data session loading and saving. Invoke from BackgroundJob or a CLI worker.
extends RefCounted

const STORE := preload("res://client/domain/annotation_store.gd")
const CODEC := preload("res://client/workspace/review_session_codec.gd")
const DOCUMENT := preload("res://client/workspace/atomic_document.gd")
const LEGACY_FIELDS := ["schema_version", "media_id", "media_type", "source_relative_path", "source_sha256", "frame_digits", "frames"]

func open_session(options: Dictionary, token: Variant = null) -> Dictionary:
	if token != null and token.is_cancelled(): return _failure("Session opening cancelled")
	var path := String(options.get("path", ""))
	if path.is_empty(): return _failure("Session path is required")
	var document = DOCUMENT.new()
	var existing := FileAccess.file_exists(path)
	var disk_sha := ""
	var backup := false
	var decoded: Dictionary
	if existing:
		var read: Dictionary = document.read_document(path)
		if not read.success: return read
		disk_sha = read.sha256
		if read.payload.get("schema_version") == 3:
			decoded = CODEC.new().decode(read.payload)
		else:
			decoded = _decode_legacy(read.payload, options)
			backup = true
	else:
		if DirAccess.dir_exists_absolute(path): return _failure("Session path is occupied by a directory")
		decoded = _new_snapshot(options)
	if not decoded.errors.is_empty(): return _failure("; ".join(decoded.errors))
	var snapshot: Dictionary = decoded.snapshot
	var identity_errors := _check_identity(snapshot, options)
	if not identity_errors.is_empty(): return _failure("; ".join(identity_errors))
	if options.has("source_root"):
		snapshot = snapshot.duplicate()
		snapshot["source_root"] = options.source_root
	var store = STORE.new()
	var errors := restore_store(store, snapshot)
	if not errors.is_empty(): return _failure("; ".join(errors))
	return {"success":true,"errors":[],"snapshot":store.freeze_snapshot(),"store":store,"path":path,"disk_sha256":disk_sha,"backup_existing":backup,"needs_save":not existing or backup}

func save_snapshot(snapshot: Dictionary, options: Dictionary, token: Variant = null) -> Dictionary:
	var started := Time.get_ticks_usec()
	if token != null: token.report_progress({"stage":"save", "message":"Validating session"})
	var codec = CODEC.new()
	var payload := codec.encode(snapshot)
	var write_options := options.duplicate()
	write_options["validate"] = Callable(self, "_validate_v3")
	var result: Dictionary = DOCUMENT.new().write_document(payload, write_options, token)
	result["session_id"] = snapshot.get("session_id", "")
	result["revision"] = snapshot.get("revision", -1)
	result["elapsed_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	return result

func restore_store(store: Variant, snapshot: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = store.load_model_records(CODEC.baseline_display_records(snapshot))
	if errors.is_empty(): errors = store.configure_session(snapshot)
	if errors.is_empty(): errors = store.restore_corrected(snapshot.records, snapshot.review_state, snapshot.batch_operations)
	return errors

func _validate_v3(payload: Dictionary) -> PackedStringArray:
	return CODEC.new().decode(payload).errors

func _new_snapshot(options: Dictionary) -> Dictionary:
	var context := _context(options)
	var records: Array = options.get("seed_records", []).duplicate(true)
	var explicit: Array = []
	var by_frame := {}
	for record: Variant in records:
		if not record is Dictionary or not STORE._valid_frame_number(record.get("frame")): return _decode_failure("Seed contains invalid frame")
		if by_frame.has(int(record.frame)): return _decode_failure("Seed contains duplicate frame")
		by_frame[int(record.frame)] = record
		explicit.append(int(record.frame))
	var display: Array = []
	for entry: Dictionary in context.frame_entries:
		if by_frame.has(int(entry.frame_id)):
			display.append(by_frame[int(entry.frame_id)])
		elif context.baseline_kind == "model":
			return _decode_failure("Model baseline must cover every source frame")
		else:
			display.append(_empty_record(context.source, entry))
	if by_frame.size() != explicit.size() or explicit.size() > display.size(): return _decode_failure("Seed frame coverage is invalid")
	context["explicit_frames"] = explicit
	var store = STORE.new()
	var errors: PackedStringArray = store.load_model_records(display)
	if errors.is_empty(): errors = store.configure_session(context)
	return {"snapshot":store.freeze_snapshot() if errors.is_empty() else {}, "errors":errors}

func _decode_legacy(payload: Variant, options: Dictionary) -> Dictionary:
	if not payload is Dictionary or (payload.get("schema_version") != 1 and payload.get("schema_version") != 2): return _decode_failure("Expected Media Label V1, V2 or V3")
	var fields := LEGACY_FIELDS.duplicate()
	if payload.schema_version == 2: fields.append_array(["review_state","batch_operations"])
	for field: String in fields:
		if not payload.has(field): return _decode_failure("Legacy %s is missing" % field)
	for field: Variant in payload:
		if field not in fields: return _decode_failure("Unexpected legacy field %s" % str(field))
	if payload.frame_digits != 6 or not payload.frames is Dictionary: return _decode_failure("Invalid legacy frames/frame_digits")
	for field: String in ["media_id","media_type","source_relative_path","source_sha256"]:
		if payload.get(field) != options.get(field): return _decode_failure("Legacy %s does not match selected media" % field)
	var context := _context(options)
	context.baseline_kind = "unknown"
	context.round_id = "legacy"
	context.model_revision = "unknown"
	context.explicit_frames = []
	var empty: Array = []
	var corrected: Array = []
	var frame_ids := {}
	for entry: Dictionary in context.frame_entries:
		var frame := int(entry.frame_id)
		frame_ids[str(frame)] = true
		var record := _empty_record(context.source, entry)
		empty.append(record)
		if payload.frames.has(str(frame)):
			corrected.append(payload.frames[str(frame)])
			context.explicit_frames.append(frame)
		else:
			corrected.append(record)
	for key: Variant in payload.frames:
		if not key is String or not frame_ids.has(key): return _decode_failure("Legacy frame key is not in source: %s" % str(key))
	empty = CODEC.baseline_display_records({"baseline_kind":"unknown","source":context.source,"frame_entries":context.frame_entries,"records":payload.frames.values()})
	var store = STORE.new()
	var errors: PackedStringArray = store.load_model_records(empty)
	if errors.is_empty(): errors = store.configure_session(context)
	var reviews: Dictionary = payload.get("review_state", {}).duplicate(true) if payload.get("review_state", {}) is Dictionary else {}
	var operations: Variant = payload.get("batch_operations", [])
	if errors.is_empty(): errors = store.restore_corrected(corrected, payload.get("review_state", {}), operations)
	if not errors.is_empty(): return {"snapshot":{},"errors":errors}
	# Preserve only verification that actually matched the legacy content. Source
	# projection is not an edit; stale reviews remain stale after migration.
	for key: Variant in reviews:
		var frame := int(key)
		if reviews[key].get("accepted_digest") == store.legacy_record_digest(frame):
			reviews[key]["accepted_digest"] = store.record_digest(frame)
		if frame not in context.explicit_frames: context.explicit_frames.append(frame)
	errors = store.configure_session(context)
	if errors.is_empty(): errors = store.restore_corrected(corrected, reviews, operations)
	return {"snapshot":store.freeze_snapshot() if errors.is_empty() else {},"errors":errors}

func _context(options: Dictionary) -> Dictionary:
	var result := options.duplicate(true)
	result["session_id"] = options.get("session_id", (String(options.get("path", "")) + "|" + String(options.get("media_id", ""))).sha256_text())
	result["source"] = options.get("source", options.get("media_id", ""))
	result["revision"] = options.get("revision", 0)
	result["round_id"] = options.get("round_id", "initial")
	result["model_revision"] = options.get("model_revision", "unknown")
	result["taxonomy_version"] = options.get("taxonomy_version", "unknown")
	result["baseline_kind"] = options.get("baseline_kind", "empty")
	return result

func _check_identity(snapshot: Dictionary, options: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for field: String in ["media_id","media_type","source_relative_path","source_sha256","source"]:
		if snapshot.get(field) != options.get(field, options.get("media_id") if field == "source" else null): errors.append("%s does not match selected source" % field)
	var normalizer = STORE.new()
	if normalizer._canonicalize(snapshot.frame_entries) != normalizer._canonicalize(options.get("frame_entries")): errors.append("Frame mapping or timestamps changed; reopen the original source")
	return errors

func _empty_record(source: String, entry: Dictionary) -> Dictionary:
	var result := {"schema_version":1,"source":source,"frame":entry.frame_id,"regions":[]}
	if entry.has("time_s"): result["time_s"] = entry.time_s
	return result

func _failure(message: String) -> Dictionary:
	return {"success":false,"errors":[message]}

func _decode_failure(message: String) -> Dictionary:
	return {"snapshot":{},"errors":PackedStringArray([message])}
