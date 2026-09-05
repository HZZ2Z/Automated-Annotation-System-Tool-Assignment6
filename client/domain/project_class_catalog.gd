class_name ProjectClassCatalog
extends RefCounted


const REGION_GEOMETRY := preload("res://client/domain/region_geometry.gd")


var _counts_by_frame: Dictionary = {} # frame -> {class: count}
var _kinds_by_frame: Dictionary = {} # frame -> {class: last observed kind}
var _project_totals: Dictionary = {} # class -> count
var _latest_kind: Dictionary = {} # class -> last observed valid kind
var _session_pairs: Array[Dictionary] = []
var _last_pair: Dictionary = {}


func rebuild(records: Array) -> PackedStringArray:
	var candidate_counts: Dictionary = {}
	var candidate_kinds: Dictionary = {}
	var candidate_totals: Dictionary = {}
	var candidate_latest: Dictionary = {}
	var seen_frames: Dictionary = {}
	var errors := PackedStringArray()
	for index in range(records.size()):
		var record: Variant = records[index]
		var record_errors := _validate_record(record, "records.%d" % index)
		if not record_errors.is_empty():
			errors.append_array(record_errors)
			continue
		var frame: int = int(record["frame"])
		if seen_frames.has(frame):
			errors.append("records.%d.frame: duplicate frame %d" % [index, frame])
			continue
		seen_frames[frame] = true
		var counts: Dictionary = _class_counts(record)
		var kinds: Dictionary = _class_kinds(record)
		candidate_counts[frame] = counts
		candidate_kinds[frame] = kinds
		for class_label: String in counts.keys():
			candidate_totals[class_label] = int(candidate_totals.get(class_label, 0)) + int(counts[class_label])
		for class_label: String in kinds.keys():
			candidate_latest[class_label] = kinds[class_label]
	if not errors.is_empty():
		return errors
	_counts_by_frame = candidate_counts
	_kinds_by_frame = candidate_kinds
	_project_totals = candidate_totals
	_latest_kind = candidate_latest
	return PackedStringArray()


func sync_record(record: Dictionary) -> PackedStringArray:
	var errors := _validate_record(record, "record")
	if not errors.is_empty():
		return errors
	var frame: int = int(record["frame"])
	var next_counts: Dictionary = _counts_by_frame.duplicate(true)
	var next_kinds: Dictionary = _kinds_by_frame.duplicate(true)
	var next_totals: Dictionary = _project_totals.duplicate(true)
	var old_counts: Dictionary = next_counts.get(frame, {})
	for class_label: String in old_counts.keys():
		var remaining := int(next_totals.get(class_label, 0)) - int(old_counts[class_label])
		if remaining > 0:
			next_totals[class_label] = remaining
		else:
			next_totals.erase(class_label)
	var replacement_counts: Dictionary = _class_counts(record)
	var replacement_kinds: Dictionary = _class_kinds(record)
	next_counts[frame] = replacement_counts
	next_kinds[frame] = replacement_kinds
	for class_label: String in replacement_counts.keys():
		next_totals[class_label] = int(next_totals.get(class_label, 0)) + int(replacement_counts[class_label])
	var next_latest := _latest_kinds_from(next_kinds, next_totals)
	for class_label: String in replacement_kinds.keys():
		next_latest[class_label] = replacement_kinds[class_label]
	_counts_by_frame = next_counts
	_kinds_by_frame = next_kinds
	_project_totals = next_totals
	_latest_kind = next_latest
	return PackedStringArray()


func project_rows(current_record: Dictionary, resolver: Variant) -> Array[Dictionary]:
	var current := _class_counts(current_record)
	var labels: Array = _project_totals.keys()
	labels.sort()
	var result: Array[Dictionary] = []
	for label: String in labels:
		result.append({
			"class": label,
			"color": resolver.color_for(label),
			"current_count": int(current.get(label, 0)),
		})
	return result


func frame_rows(current_record: Dictionary, resolver: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var regions: Variant = current_record.get("regions", [])
	if not regions is Array:
		return result
	for region_value: Variant in regions:
		if not region_value is Dictionary:
			continue
		var region: Dictionary = region_value
		var class_label := String(region.get("class", "")).strip_edges()
		result.append({
			"region_id": str(region.get("id", "")),
			"class": class_label,
			"kind": String(region.get("kind", "")).strip_edges(),
			"geometry": REGION_GEOMETRY.canonical_shape(region),
			"color": resolver.color_for(class_label),
		})
	return result


func remember(class_label: String, kind: String) -> void:
	var pair := {
		"class": class_label.strip_edges(),
		"kind": kind.strip_edges(),
	}
	if pair["class"].is_empty() or pair["kind"].is_empty():
		return
	var pair_key := _pair_key(pair)
	var next_pairs: Array[Dictionary] = []
	for existing: Dictionary in _session_pairs:
		if _pair_key(existing) != pair_key:
			next_pairs.append(existing)
	next_pairs.push_front(pair)
	_session_pairs = next_pairs
	_last_pair = pair.duplicate()


func suggestions(resolver: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary = {}
	for pair: Dictionary in _session_pairs:
		_append_suggestion(result, seen, pair, resolver)
	var labels: Array = _project_totals.keys()
	labels.sort()
	for class_label: String in labels:
		_append_suggestion(result, seen, {
			"class": class_label,
			"kind": String(_latest_kind.get(class_label, "")),
		}, resolver)
	return result


func last_pair() -> Dictionary:
	return _last_pair.duplicate()


func reset() -> void:
	_counts_by_frame.clear()
	_kinds_by_frame.clear()
	_project_totals.clear()
	_latest_kind.clear()
	_session_pairs.clear()
	_last_pair.clear()


func _validate_record(record: Variant, path: String) -> PackedStringArray:
	var errors := PackedStringArray()
	if not record is Dictionary:
		errors.append("%s: expected object" % path)
		return errors
	var frame: Variant = record.get("frame")
	if not _is_logical_integer(frame) or float(frame) < 0.0:
		errors.append("%s.frame: expected a non-negative integer" % path)
	var regions: Variant = record.get("regions")
	if not regions is Array:
		errors.append("%s.regions: expected array" % path)
		return errors
	for index in range(regions.size()):
		var region: Variant = regions[index]
		var region_path := "%s.regions.%d" % [path, index]
		if not region is Dictionary:
			errors.append("%s: expected object" % region_path)
			continue
		for field in ["class", "kind"]:
			var value: Variant = region.get(field)
			if typeof(value) != TYPE_STRING or String(value).strip_edges().is_empty():
				errors.append("%s.%s: expected a non-empty string" % [region_path, field])
	return errors


func _is_logical_integer(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value)) and float(value) == floorf(float(value))


func _class_counts(record: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var regions: Variant = record.get("regions", [])
	if not regions is Array:
		return result
	for region_value: Variant in regions:
		if not region_value is Dictionary:
			continue
		var class_label := String(region_value.get("class", "")).strip_edges()
		if class_label.is_empty():
			continue
		result[class_label] = int(result.get(class_label, 0)) + 1
	return result


func _class_kinds(record: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var regions: Variant = record.get("regions", [])
	if not regions is Array:
		return result
	for region_value: Variant in regions:
		if not region_value is Dictionary:
			continue
		var class_label := String(region_value.get("class", "")).strip_edges()
		var kind := String(region_value.get("kind", "")).strip_edges()
		if not class_label.is_empty() and not kind.is_empty():
			result[class_label] = kind
	return result


func _latest_kinds_from(frame_kinds: Dictionary, active_totals: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var frames: Array = frame_kinds.keys()
	frames.sort()
	for frame: int in frames:
		var kinds: Dictionary = frame_kinds[frame]
		for class_label: String in kinds.keys():
			if active_totals.has(class_label):
				result[class_label] = kinds[class_label]
	return result


func _append_suggestion(result: Array[Dictionary], seen: Dictionary, pair: Dictionary, resolver: Variant) -> void:
	var class_label := String(pair.get("class", "")).strip_edges()
	var kind := String(pair.get("kind", "")).strip_edges()
	if class_label.is_empty() or kind.is_empty():
		return
	var normalized := {"class": class_label, "kind": kind}
	var key := _pair_key(normalized)
	if seen.has(key):
		return
	seen[key] = true
	result.append({
		"class": class_label,
		"kind": kind,
		"color": resolver.color_for(class_label),
	})


func _pair_key(pair: Dictionary) -> String:
	return "%s\u001f%s" % [pair.get("class", ""), pair.get("kind", "")]
