extends RefCounted
## Shared worker semantic checks for export reuse and both UI/CLI round parents.
## Artifact checksums alone cannot establish annotation/review/report consistency.
const EXACT = preload("res://client/domain/exact_json.gd")
const DIFF = preload("res://client/feedback/annotation_diff.gd")
const V1 = preload("res://client/domain/model_output_validator.gd")
const PATHS = ["data/corrected_annotations.jsonl","data/frame_map.jsonl","reports/diff.json","reports/diff.csv","reports/summary_by_class.csv"]

static func validate(manifest: Dictionary, texts: Dictionary, diff: Dictionary) -> PackedStringArray:
	var errors = PackedStringArray()
	var training = manifest.package_type == "training_update_v2"
	if manifest.schema_version != (2 if training else 1): errors.append("package type/schema mismatch")
	if training and manifest.baseline.kind == "unknown": errors.append("training requires known baseline")
	if (manifest.baseline.kind in ["empty","unknown"]) != (manifest.baseline.digest == null): errors.append("baseline kind/digest mismatch")
	var records = _jsonl(texts[PATHS[0]],errors)
	var mapping = _jsonl(texts[PATHS[1]],errors)
	var validator = V1.new()
	for record in records: errors.append_array(validator.validate_record(record))
	for mapped in mapping:
		if not mapped is Dictionary: errors.append("frame map must contain objects")
	if not errors.is_empty(): return errors
	var coverage = manifest.coverage
	var entries = manifest.source_frame_entries
	var entry_map = {}
	var source_ids = []
	var previous_time = -1.0
	for index in entries.size():
		var entry = entries[index]
		var frame = int(entry.frame_id)
		if entry_map.has(frame) or entry.frame != index: errors.append("source frame identity/playback indices invalid")
		entry_map[frame] = entry
		source_ids.append(frame)
		if entry.has("time_s"):
			if entry.time_s < previous_time: errors.append("source timestamps not ordered")
			previous_time = entry.time_s
	var included = _ids(coverage.included_frame_ids)
	var excluded = _ids(coverage.excluded_frame_ids)
	var verified = _ids(coverage.verified_frame_ids)
	var explicit = _ids(coverage.explicit_frame_ids)
	if not DIFF.equivalent(coverage.source_frame_ids,source_ids): errors.append("coverage source frame identity mismatch")
	if not _subset(verified,explicit) or not _subset(explicit,source_ids) or not _subset(included,source_ids) or not _subset(excluded,source_ids): errors.append("coverage references invalid source/explicit/verified frames")
	var ordered_included = []
	var ordered_excluded = []
	for frame in source_ids:
		if (frame in included) == (frame in excluded): errors.append("invalid coverage partition")
		if frame in included: ordered_included.append(frame)
		if frame in excluded: ordered_excluded.append(frame)
	if not DIFF.equivalent(included,ordered_included) or not DIFF.equivalent(excluded,ordered_excluded): errors.append("coverage order differs from Source")
	var counts = {"total_frames":source_ids.size(),"included_frames":included.size(),"excluded_frames":excluded.size()}
	for key in counts:
		if coverage[key] != counts[key] or manifest.summary[key] != counts[key] or diff.summary[key] != counts[key]: errors.append("incorrect coverage count: " + key)
	if coverage.policy != ("verified_only" if training else "all_frames_review"): errors.append("coverage policy does not match package type")
	if training:
		if included.is_empty() or not DIFF.equivalent(included,verified) or coverage.exclusion_reason != "not_content_verified": errors.append("training must include exactly nonempty verified coverage")
	elif not DIFF.equivalent(included,source_ids) or not excluded.is_empty() or coverage.exclusion_reason != "none": errors.append("review must include all source frames")
	if records.size() != included.size() or mapping.size() != included.size(): errors.append("artifact coverage mismatch")
	if not errors.is_empty(): return errors
	for index in included.size():
		var frame = int(included[index])
		var record = records[index]
		var mapped = mapping[index]
		var entry = entry_map[frame]
		if record.frame != frame or mapped.get("frame_id") != frame: errors.append("artifact frame order mismatch")
		if record.source != "human_corrected": errors.append("corrected source must be human_corrected")
		if DIFF.regions_by_id(record.regions).size() != record.regions.size(): errors.append("duplicate corrected region ID")
		if record.has("time_s") and (not entry.has("time_s") or record.time_s != entry.time_s): errors.append("provided annotation time differs from Source")
		var expected = entry.duplicate(true)
		expected.merge({"sample_id":"%s_%06d" % [manifest.media.media_id,frame],"explicit":frame in explicit,"verified":frame in verified,"review_status":"verified" if frame in verified else "unverified","annotation_status":("negative" if record.regions.is_empty() else "annotated") if frame in explicit else "unannotated"})
		if not DIFF.equivalent(mapped,expected): errors.append("frame map/sample ID/status differs from Source and coverage")
		var internal = record.duplicate(true)
		internal.source = manifest.media.source
		var accepted = manifest.review_state.get(str(frame),{}).get("accepted_digest")
		var digest = JSON.stringify(DIFF.normalize(internal),"",true,true).sha256_text()
		if (accepted == digest) != (frame in verified): errors.append("current content verification mismatch")
	for frame in manifest.review_state:
		if int(frame) not in explicit: errors.append("review state must refer to explicit source frames")
	for operation in manifest.batch_operations:
		for field in ["keyframe","start_frame","end_frame"]:
			if not entry_map.has(int(operation[field])): errors.append("batch provenance contains unknown source frame")
		if operation.start_frame > operation.end_frame: errors.append("batch range is reversed")
		if operation.has("metric_id"):
			if not (operation.start_frame <= operation.keyframe and operation.keyframe <= operation.end_frame): errors.append("batch metric range must contain keyframe")
			if operation.start_index > operation.end_index or operation.covered_count != operation.end_index-operation.start_index+1 or operation.covered_count > operation.max_frames or operation.changed_count != operation.affected_frames.size() or operation.changed_count >= operation.covered_count: errors.append("batch metric counts/range inconsistent")
		for frame in operation.affected_frames:
			if not entry_map.has(int(frame)) or frame == operation.keyframe or frame < operation.start_frame or frame > operation.end_frame: errors.append("batch contains invalid target")
	if manifest.summary.verified_frames != verified.size(): errors.append("verified frame count mismatch")
	if not errors.is_empty(): return errors
	errors.append_array(_validate_diff(manifest,records,diff,texts))
	return errors

static func _validate_diff(manifest: Dictionary, records: Array, diff: Dictionary, texts: Dictionary) -> PackedStringArray:
	var errors = PackedStringArray()
	var available = manifest.baseline.kind != "unknown"
	if diff.available != available or manifest.summary.audit_available != available: errors.append("audit availability inconsistent with baseline kind")
	var expected_ids = _ids(manifest.coverage.included_frame_ids) if available else []
	expected_ids.sort()
	var actual_ids = []
	for frame in diff.frames: actual_ids.append(frame.frame_id)
	if not DIFF.equivalent(actual_ids,expected_ids): return PackedStringArray(["audit frame coverage mismatch"])
	var current = DIFF.records_by_frame(records)
	var baseline = []
	var validator = V1.new()
	for frame in diff.frames:
		var after = DIFF.regions_by_id(current[int(frame.frame_id)].regions)
		var before = {} if manifest.baseline.kind == "empty" else after.duplicate(true)
		var seen = {}
		var grouped = {}
		for event in frame.events:
			var key = [event.region_id,event.type]
			if seen.has(key): errors.append("duplicate audit event")
			seen[key] = true
			for region in [event.before,event.after]:
				if region != null:
					errors.append_array(validator.validate_record({"schema_version":1,"source":"audit","frame":0,"regions":[region]}))
					if region.get("id") != event.region_id: errors.append("audit region ID mismatch")
			if not DIFF.equivalent(event.after,after.get(event.region_id)): errors.append("audit after differs from corrected region")
			if grouped.has(event.region_id):
				if not DIFF.equivalent(grouped[event.region_id],[event.before,event.after]): errors.append("same-region events have inconsistent before/after")
			else: grouped[event.region_id] = [event.before,event.after]
			if event.before == null: before.erase(event.region_id)
			else: before[event.region_id] = event.before
		if manifest.baseline.kind == "empty": before = {}
		baseline.append({"frame":frame.frame_id,"regions":before.values()})
	if not errors.is_empty(): return errors
	# Rebuild from the claimed before values. This independently recounts categories,
	# unique regions, frame/class totals and detects missing categories. Raw model
	# authenticity cannot be established without its original records (same as Python).
	var rebuilt = DIFF.build_diff({"baseline_kind":manifest.baseline.kind,"baseline_records":baseline,"records":records,"frame_entries":manifest.source_frame_entries},_ids(manifest.coverage.included_frame_ids))
	if not DIFF.equivalent(diff.summary,rebuilt.summary) or not DIFF.equivalent(diff.by_class,rebuilt.by_class): errors.append("audit totals or per-class counts inconsistent with events")
	for key in rebuilt.summary:
		if manifest.summary[key] != rebuilt.summary[key]: errors.append("manifest audit summary differs from event counts")
	for index in diff.frames.size():
		var frame = diff.frames[index]
		var expected = rebuilt.frames[index]
		if not DIFF.equivalent(frame.counts,expected.counts) or frame.changed_regions != expected.changed_regions: errors.append("audit per-frame counts mismatch")
		if manifest.baseline.kind == "empty" and not DIFF.equivalent(frame.events,expected.events): errors.append("empty baseline audit must exactly add every current region in ID order")
		var expected_events = {}
		for event in expected.events: expected_events[[event.region_id,event.type]] = event
		if frame.events.size() != expected_events.size(): errors.append("audit omits or adds a change category")
		for event in frame.events:
			if not DIFF.equivalent(event,expected_events.get([event.region_id,event.type])): errors.append("audit event does not describe claimed change")
	errors.append_array(_validate_csv(diff,texts))
	return errors

static func _validate_csv(diff: Dictionary, texts: Dictionary) -> PackedStringArray:
	var errors = PackedStringArray()
	var events = _csv(texts[PATHS[3]],errors)
	var classes = _csv(texts[PATHS[4]],errors)
	if events.is_empty() or events[0] != ["frame_id","region_id","type","before","after"]: return PackedStringArray(["event CSV header mismatch"])
	if classes.is_empty() or classes[0] != ["class"] + DIFF.CLASS_COUNTS: return PackedStringArray(["class CSV header mismatch"])
	var expected = []
	for frame in diff.frames:
		for event in frame.events: expected.append([frame.frame_id,event.region_id,event.type,event.before,event.after])
	var parsed = []
	for row in events.slice(1):
		if row.size() != 5 or not row[0].is_valid_int(): errors.append("malformed CSV event row"); continue
		var before = EXACT.new()
		var after = EXACT.new()
		if before.parse(row[3]) != OK or after.parse(row[4]) != OK: errors.append("malformed CSV event JSON"); continue
		parsed.append([int(row[0]),row[1],row[2],before.data,after.data])
	if not DIFF.equivalent(parsed,expected): errors.append("event CSV differs from JSON audit")
	parsed = []
	for row in classes.slice(1):
		if row.size() != 1+DIFF.CLASS_COUNTS.size(): errors.append("malformed class CSV row"); continue
		var item = {"class":row[0]}
		for index in DIFF.CLASS_COUNTS.size():
			if not row[index+1].is_valid_int(): errors.append("invalid class CSV count")
			item[DIFF.CLASS_COUNTS[index]] = int(row[index+1])
		parsed.append(item)
	if not DIFF.equivalent(parsed,diff.by_class): errors.append("class CSV differs from JSON audit")
	return errors

static func _jsonl(text: String, errors: PackedStringArray) -> Array:
	var values = []
	if text.is_empty(): return values
	for line in text.trim_suffix("\n").split("\n"):
		var parser = EXACT.new()
		if parser.parse(line) != OK: errors.append("invalid JSONL artifact: " + parser.get_error_message())
		else: values.append(parser.data)
	return values

static func _ids(values: Array) -> Array:
	return values.map(func(value): return int(value))

static func _subset(values: Array, container: Array) -> bool:
	for value in values:
		if value not in container: return false
	return true

static func _csv(text: String, errors: PackedStringArray) -> Array:
	var rows = []
	var row = []
	var value = ""
	var quoted = false
	var closed = false
	var index = 0
	while index < text.length():
		var c = text[index]
		if quoted:
			if c == '"':
				if index+1 < text.length() and text[index+1] == '"': value += '"'; index += 1
				else: quoted = false; closed = true
			else: value += c
		elif c == '"' and value.is_empty() and not closed: quoted = true
		elif c == ",": row.append(value); value = ""; closed = false
		elif c == "\n" or c == "\r":
			if c == "\r" and index+1 < text.length() and text[index+1] == "\n": index += 1
			row.append(value); rows.append(row); row = []; value = ""; closed = false
		elif closed or c == '"': errors.append("malformed quoted CSV field"); return []
		else: value += c
		index += 1
	if quoted: errors.append("unterminated CSV quote")
	if not row.is_empty() or not value.is_empty() or closed: row.append(value); rows.append(row)
	return rows
