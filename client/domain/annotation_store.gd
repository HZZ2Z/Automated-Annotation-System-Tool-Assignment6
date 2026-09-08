class_name AnnotationStore
extends RefCounted


signal corrected_records_replaced(frames: PackedInt64Array)
signal review_state_changed()


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
	_baseline_digest = JSON.stringify(_canonicalize(_sorted_record_copies(_model_records))).sha256_text()
	_snapshot_baseline_digest = JSON.stringify(_canonicalize(_sorted_record_copies(_model_records)), "", true, true).sha256_text()
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


func _model_output_projection(record: Variant) -> Variant:
	if not record is Dictionary:
		return record
	var result: Dictionary = record.duplicate(true)
	var regions: Variant = result.get("regions")
	if regions is Array:
		for value: Variant in regions:
			if value is Dictionary:
				value.erase("filled")
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
		errors.append_array(validate_workflow_state(_review_state, [operation], _corrected_records))
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
	var errors: PackedStringArray = _validator.validate_record(_model_output_projection(record))
	if not _corrected_records.has(frame):
		errors.append("frame: frame %d does not exist" % frame)
	if record is Dictionary:
		if not _session.is_empty():
			if record.get("source") != _session.source:
				errors.append("source: must match session source")
			var original: Dictionary = _model_records.get(frame, {})
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


func _canonicalize(value: Variant) -> Variant:
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


func _is_logical_integer(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value)) and float(value) == floorf(float(value))


func record_digest(frame: int) -> String:
	# Normalize numeric JSON values so saved/reopened geometry hashes identically.
	return JSON.stringify(_canonicalize(_model_output_projection(get_corrected_record(frame))), "", true, true).sha256_text()


func legacy_record_digest(frame: int) -> String:
	# V1/V2 migration must validate the old digest before rebinding verification.
	return JSON.stringify(_canonicalize(_model_output_projection(get_corrected_record(frame)))).sha256_text()


func is_verified(frame: int) -> bool:
	return _corrected_records.has(frame) and _review_state.has(str(frame)) and _review_state[str(frame)]["accepted_digest"] == record_digest(frame)


func snapshot_review_state() -> Dictionary:
	return _review_state.duplicate(true)


func load_workflow_state(review_state: Variant, batch_operations: Variant) -> PackedStringArray:
	var errors := validate_workflow_state(review_state, batch_operations, _corrected_records)
	if not errors.is_empty():
		return errors
	if _review_state != review_state or _batch_operations != batch_operations:
		_revision += 1
	_review_state = review_state.duplicate(true)
	_batch_operations.assign(batch_operations.duplicate(true))
	for key: String in _review_state:
		_explicit_frames[int(key)] = true
	review_state_changed.emit()
	return errors


static func validate_workflow_state(reviews: Variant, operations: Variant, frames: Dictionary) -> PackedStringArray:
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
		errors.append_array(_validate_batch_operation(operation, frames, digest_pattern))
	return errors


static func _valid_frame_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) == floorf(float(value)) and float(value) >= 0.0


static func _validate_batch_operation(operation: Variant, frames: Dictionary, digest_pattern: RegEx) -> PackedStringArray:
	var errors := PackedStringArray()
	if not operation is Dictionary:
		return PackedStringArray(["batch_operations: expected objects"])
	for field: Variant in operation:
		if field not in ["schema_version", "type", "mode", "keyframe", "start_frame", "end_frame", "affected_frames", "metric", "metric_id", "threshold", "max_frames", "keyframe_digest", "created_at", "start_index", "end_index", "left_stop", "right_stop", "changed_count", "covered_count"]:
			errors.append("batch_operations: unexpected field %s" % str(field))
	if operation.get("type") != "range_propagate" or operation.get("mode") not in ["overwrite", "merge"] or not _valid_frame_number(operation.get("schema_version")) or operation.get("schema_version") != 1:
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
	return errors


# These session APIs contain no IO. Load/validation belongs to the worker that
# constructs the store; freeze only publishes already immutable record values.
func configure_session(context: Dictionary) -> PackedStringArray:
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
	var explicit: Variant = context.get("explicit_frames", _frame_order)
	var frame_map := {}
	var previous_time := -1.0
	if not entries is Array or entries.is_empty() or entries.size() != _corrected_records.size():
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
			if frame_map.has(frame) or not _corrected_records.has(frame):
				errors.append("frame_entries: duplicate or unknown frame")
			else:
				frame_map[frame] = true
				var record: Dictionary = _model_records[frame]
				if record.source != context.get("source") or record.has("time_s") != entry.has("time_s") or record.get("time_s") != entry.get("time_s"):
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
	if not errors.is_empty():
		return errors
	_session = {}
	for field: String in ["session_id", "media_id", "media_type", "source_relative_path", "source", "source_sha256", "round_id", "model_revision", "taxonomy_version", "baseline_kind", "source_root"]:
		if context.has(field):
			_session[field] = context[field]
	_session["source_sha256"] = context.get("source_sha256")
	_session["frame_entries"] = _immutable_copy(entries)
	_revision = int(context.get("revision", 0))
	_explicit_frames = next_explicit
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
	errors.append_array(validate_workflow_state(review_state, batch_operations, next))
	if not errors.is_empty():
		return errors
	for frame: int in next:
		next[frame] = _immutable_copy(next[frame])
	_corrected_records = next
	_review_state = review_state.duplicate(true)
	_batch_operations.assign(batch_operations.duplicate(true))
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


static func _immutable_copy(value: Variant) -> Variant:
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
