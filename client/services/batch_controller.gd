## 批量计划可丢弃；此控制器不拥有标注或审核状态。
class_name BatchController
extends RefCounted

const SIMILARITY := preload("res://client/services/frame_similarity_service.gd")
const PROPAGATE := preload("res://client/domain/commands/propagate_range_command.gd")
const POLYGON := preload("res://client/services/polygon_propagation_service.gd")
const APPLY_PROPOSALS := preload("res://client/domain/commands/apply_propagation_command.gd")
var _source: Variant
var _store: Variant
var _history: Variant
var _entries: Array = []
var _scanner = SIMILARITY.new()
var _polygon = POLYGON.new()
var _strategy := "copy"
var _plan: Dictionary = {}
var _preview: Dictionary = {}
var _key_record: Dictionary = {}
var last_error := ""

func configure(source: Variant, store: Variant, history: Variant, entries: Array) -> void:
	if _store != null:
		if _store.corrected_records_replaced.is_connected(_invalidate):
			_store.corrected_records_replaced.disconnect(_invalidate)
		if _store.has_signal("review_state_changed") and _store.review_state_changed.is_connected(_invalidate):
			_store.review_state_changed.disconnect(_invalidate)
	cancel()
	_source = source
	_store = store
	_history = history
	_entries = entries.duplicate(true)
	if _store != null:
		_store.corrected_records_replaced.connect(_invalidate)
		if _store.has_signal("review_state_changed"):
			_store.review_state_changed.connect(_invalidate)

func start_analysis(index: int, threshold: float) -> PackedStringArray:
	cancel()
	_strategy = "copy"
	var errors: PackedStringArray = _scanner.begin(_source, _store, _entries, index, threshold)
	if errors.is_empty():
		_key_record = _store.get_corrected_record(int(_entries[index].frame_id))
	return errors

func start_polygon_analysis(index: int) -> PackedStringArray:
	cancel()
	_strategy = "polygon_flow"
	var errors: PackedStringArray = _polygon.begin(_source, _store, _entries, index)
	if errors.is_empty():
		_key_record = _store.get_corrected_record(int(_entries[index].frame_id))
	return errors

func is_analyzing() -> bool:
	return _polygon.running if _strategy == "polygon_flow" else _scanner.running

func progress_text() -> String:
	return _polygon.progress_text() if _strategy == "polygon_flow" else "正在查找相似帧…"

func step_analysis() -> void:
	var worker = _polygon if _strategy == "polygon_flow" else _scanner
	worker.step()
	if not worker.running and not worker.result.is_empty():
		if not worker.result.errors.is_empty():
			last_error = worker.result.errors[0]
			return
		_plan = worker.result.duplicate(true)
		_plan["keyframe"] = int(_key_record.frame)

func get_plan() -> Dictionary:
	return _plan.duplicate(true)

func cancel() -> void:
	_scanner.cancel()
	_polygon.cancel()
	_plan.clear()
	_preview.clear()
	_key_record.clear()
	last_error = ""

func preview(first: int, last: int, mode: String) -> Dictionary:
	_preview = {}
	if _plan.is_empty() or first < int(_plan.start_index) or last > int(_plan.end_index) or first > int(_plan.key_index) or last < int(_plan.key_index) or mode not in ["overwrite", "merge"]:
		return {"errors": PackedStringArray(["Analyze again; range must stay inside the candidate and contain the keyframe"])}
	if _strategy == "polygon_flow" and mode != "merge":
		return {"errors": PackedStringArray(["Poly propagation only merges matching polygon IDs"])}
	var after := {}
	var before := {}
	var added := 0
	var replaced := 0
	var removed := 0
	var changed := 0
	for index in range(first, last + 1):
		if index == int(_plan.key_index):
			continue
		var frame_id := int(_entries[index].frame_id)
		var record: Dictionary = _store.get_corrected_record(frame_id)
		if record.is_empty() or _duplicate_ids(record.regions) or _duplicate_ids(_key_record.regions):
			return {"errors": PackedStringArray(["Missing target or duplicate region ID"])}
		before[frame_id] = record.duplicate(true)
		var proposed := record.duplicate(true)
		var source_regions: Array = _key_record.regions.duplicate(true)
		if _strategy == "polygon_flow":
			source_regions = _plan.target_regions.get(frame_id, []).duplicate(true)
			if source_regions.is_empty():
				return {"errors": PackedStringArray(["Poly candidate is missing a target frame"])}
			for region: Dictionary in source_regions:
				for original: Dictionary in _key_record.regions:
					if original.id == region.id and original.has("filled"):
						region["filled"] = original.filled
		var source_ids := {}
		var target_ids := {}
		for region: Dictionary in source_regions:
			source_ids[region.id] = true
		for region: Dictionary in record.regions:
			target_ids[region.id] = true
		proposed.regions = source_regions.duplicate(true) if mode == "overwrite" else _merge(record.regions, source_regions)
		if proposed.regions != record.regions:
			changed += 1
		for id: String in source_ids:
			if target_ids.has(id):
				replaced += 1
			else:
				added += 1
		if mode == "overwrite":
			for id: String in target_ids:
				if not source_ids.has(id):
					removed += 1
		after[frame_id] = proposed
	_preview = {"errors": PackedStringArray(), "first": first, "last": last, "mode": mode,
		"changed_count": changed, "target_count": after.size(), "covered_count": last - first + 1,
		"added": added, "replaced": replaced, "removed": removed, "before": before, "after": after}
	return _preview.duplicate(true)

func proposed_record(frame_id: int) -> Dictionary:
	return _preview.get("after", {}).get(frame_id, {}).duplicate(true)

func can_apply() -> bool:
	return not _plan.is_empty() and int(_preview.get("changed_count", 0)) > 0

func apply_preview() -> PackedStringArray:
	if _plan.is_empty() or _preview.is_empty():
		return PackedStringArray(["Preview expired; analyze again"])
	if int(_preview.changed_count) == 0:
		return PackedStringArray(["Annotations already match; no batch was created"])
	if _strategy == "polygon_flow":
		var source_errors: PackedStringArray = _polygon.validate_source()
		if not source_errors.is_empty():
			return source_errors
	for frame_id: int in _preview.before:
		if _store.get_corrected_record(frame_id) != _preview.before[frame_id]:
			return PackedStringArray(["Target changed; analyze again"])
	var marker := {"metric_id": _plan.metric_id, "threshold": _plan.threshold,
		"max_frames": _plan.max_frames, "start_index": _preview.first, "end_index": _preview.last,
		"keyframe_digest": JSON.stringify(_key_record).sha256_text(),
		"created_at": Time.get_datetime_string_from_system(true),
		"left_stop": _plan.left_stop, "right_stop": _plan.right_stop,
		"changed_count": _preview.changed_count, "covered_count": _preview.covered_count}
	var command: Variant
	if _strategy == "polygon_flow":
		marker["start_frame"] = int(_entries[_preview.first].frame_id)
		marker["end_frame"] = int(_entries[_preview.last].frame_id)
		command = APPLY_PROPOSALS.new(_key_record, _preview.before, _preview.after, marker)
	else:
		command = PROPAGATE.new(_plan.keyframe, int(_entries[_preview.first].frame_id), int(_entries[_preview.last].frame_id), _preview.mode)
	# 命令提供附加标记入口；基础四参数接口仍供已有编辑插件使用。
	if command.has_method("set_metadata"):
		command.set_metadata(marker)
	var errors: PackedStringArray = _history.execute(command, _store)
	return errors

func _invalidate(_frames: Variant = null) -> void:
	cancel()
	last_error = "Annotations or verification changed; analyze again"

static func _duplicate_ids(regions: Array) -> bool:
	var ids := {}
	for region: Dictionary in regions:
		if ids.has(region.id):
			return true
		ids[region.id] = true
	return false

static func _merge(target: Array, source: Array) -> Array:
	var result := target.duplicate(true)
	var positions := {}
	for i in range(result.size()):
		positions[result[i].id] = i
	for region: Dictionary in source:
		if positions.has(region.id):
			result[int(positions[region.id])] = region.duplicate(true)
		else:
			result.append(region.duplicate(true))
	return result
