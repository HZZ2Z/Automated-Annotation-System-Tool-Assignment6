## 批量计划可丢弃；此控制器不拥有标注或审核状态。
class_name BatchController
extends RefCounted

const SIMILARITY := preload("res://client/services/frame_similarity_service.gd")
const POLY_PROVIDER := preload("res://client/services/poly_batch_provider.gd")
const SAM_VIDEO_PROVIDER := preload("res://client/services/sam_video_batch_provider.gd")
const POLYGONS := preload("res://client/domain/polygon_ops.gd")
const MASK_OPS := preload("res://client/domain/mask_region_ops.gd")
const APPLY_PROPOSALS := preload("res://client/domain/commands/apply_propagation_command.gd")
const PROVIDER_METHODS := [
	"availability", "begin", "step", "cancel", "shutdown", "is_running", "progress_text", "get_result", "validate_source",
]
var _source: Variant
var _store: Variant
var _history: Variant
var _entries: Array = []
var _scanner = SIMILARITY.new()
var _providers: Dictionary = {&"sam_video": SAM_VIDEO_PROVIDER.new(), &"polygon_flow": POLY_PROVIDER.new()}
var _active_provider: Variant
var _strategy := "copy"
var _plan: Dictionary = {}
var _preview: Dictionary = {}
var _key_record: Dictionary = {}
var last_error := ""
var _sam_probe: Callable
var _sam_snapshot: Dictionary = {}
var _sam_live: Dictionary = {}
var _sam_request: Dictionary = {}
var _sam_started_ms := 0
var _sam_elapsed_ms := -1

## UI 提供只读选择/编辑探针；它不会进入 Provider 或 JSONL 协议。
func configure_sam_context(reader: Callable) -> PackedStringArray:
	if _strategy == "sam_video": cancel()
	_sam_probe = reader
	return PackedStringArray()

func start_sam_video_analysis(
	key_index: int,
	region_id: String,
	propagation_count: int,
	minimum_score: float = 0.50,
	maximum_area_change_percent: float = 0.0,
) -> PackedStringArray:
	cancel()
	_strategy = "sam_video"
	if _source == null or _store == null or not _sam_probe.is_valid():
		return PackedStringArray(["SAM requires a Source, Store and live selection/edit context; reopen the Batch page"])
	if region_id.is_empty() or propagation_count < 1 or propagation_count > 30:
		return PackedStringArray(["Select one committed Box/Poly and request 1–30 targets"])
	if not is_finite(minimum_score) or minimum_score < 0.50 or minimum_score > 1.0 \
			or not is_finite(maximum_area_change_percent) \
			or maximum_area_change_percent < 0.0 or maximum_area_change_percent > 500.0:
		return PackedStringArray(["SAM quality thresholds are outside their allowed ranges"])
	if key_index < 0 or key_index >= _entries.size() - 1:
		return PackedStringArray(["SAM requires at least one Source entry after the keyframe"])
	var live: Variant = _sam_probe.call()
	if not live is Dictionary or live.get("key_index") != key_index or live.get("region_id") != region_id or live.get("edit_pending") != false:
		return PackedStringArray(["Selection changed or an edit is incomplete; commit the selected Box/Poly first"])
	_sam_live = live.duplicate(true)
	_sam_snapshot = _store.freeze_snapshot().duplicate(true)
	_key_record = _store.get_corrected_record(int(_entries[key_index].frame_id))
	if _key_record.is_empty() or _duplicate_ids(_key_record.get("regions", [])):
		return PackedStringArray(["Keyframe is missing or has duplicate region IDs"])
	var selected := {}
	for region: Dictionary in _key_record.regions:
		if region.id == region_id: selected = region.duplicate(true)
	if selected.is_empty() or selected.has("box") == selected.has("polygon"):
		return PackedStringArray(["Selected region was deleted or is not one committed Box/Poly"])
	if not _source.has_method("load_image_snapshot_uncached"):
		return PackedStringArray(["SAM requires Source uncached image integrity support"])
	var image: Variant = _source.load_image_snapshot_uncached(key_index)
	if not image is Image or image.is_empty(): return PackedStringArray(["Keyframe image is unavailable"])
	var polygon: Variant = selected.get("polygon", POLYGONS.box_to_polygon(selected.get("box")))
	if not (polygon is Array or polygon is PackedVector2Array) or polygon.size() > 2048 or not POLYGONS.validate_simple_polygon(polygon) or not POLYGONS.points_fit_image(polygon, Vector2(image.get_size())):
		return PackedStringArray(["Anchor must be one simple Box/Poly inside the image"])
	var raster: Dictionary = MASK_OPS.rasterize_polygon_mask(polygon, image.get_size())
	if not raster.get("ok", false) or raster.mask.count(1) == image.get_width() * image.get_height():
		return PackedStringArray(["Anchor mask must be nonempty and smaller than the full image"])
	var targets: Array = []
	var risks: Array = []
	var stop := {}
	for index in range(key_index + 1, mini(key_index + propagation_count + 1, _entries.size())):
		var entry: Dictionary = _entries[index]
		var record: Dictionary = _store.get_corrected_record(int(entry.frame_id))
		if record.is_empty() or _duplicate_ids(record.get("regions", [])):
			return PackedStringArray(["Target record is missing or has duplicate region IDs"])
		if _store.is_verified(int(entry.frame_id)):
			stop = {"kind": "verified_target", "frame_id": int(entry.frame_id), "message": "已在已验证目标前停止。", "can_reanchor": false}
			break
		var previous: Dictionary = _entries[index - 1]
		if int(entry.frame_id) != int(previous.frame_id) + _sampling_step():
			risks.append({"kind": "sparse_frame_gap", "frame_id": int(entry.frame_id)})
		if entry.has("time_s") and previous.has("time_s") and (float(entry.time_s) - float(previous.time_s) > 0.1 or float(entry.time_s) <= float(previous.time_s)):
			risks.append({"kind": "sparse_time_gap", "frame_id": int(entry.frame_id)})
		targets.append(entry.duplicate(true))
	if targets.is_empty(): return PackedStringArray(["First SAM target is already verified; no candidate range"])
	if targets.size() < propagation_count and stop.is_empty():
		stop = {"kind": "source_end", "frame_id": int(targets[-1].frame_id), "message": "已到 Source 末尾。", "can_reanchor": false}
	var device := OS.get_environment("PROJECT6_SAM2_DEVICE").to_lower()
	if device.is_empty(): device = "auto"
	var service_context := {"session_id": str(_sam_snapshot.get("session_id", "batch-%d" % get_instance_id())),
		"request_nonce": "%d-%d" % [get_instance_id(), Time.get_ticks_usec()], "key_playback_index": key_index,
		"key_frame_id": int(_entries[key_index].frame_id), "store_revision": _store.current_revision(),
		"review_sha256": JSON.stringify(_sam_snapshot.review_state).sha256_text(),
		"key_record_sha256": JSON.stringify(_key_record).sha256_text(), "region_id": region_id,
		"propagation_count": targets.size(), "requested_device": device}
	if _entries[key_index].has("time_s"): service_context.key_time_s = _entries[key_index].time_s
	_sam_request = {"key_index": key_index, "region_id": region_id, "entries": _entries.duplicate(true),
		"session_snapshot": _sam_snapshot.duplicate(true), "review_state": _sam_snapshot.review_state.duplicate(true),
		"key_record": _key_record.duplicate(true), "region": selected, "target_entries": targets,
		"propagation_count": targets.size(), "requested_count": propagation_count, "image_size": image.get_size(),
		"minimum_score": minimum_score, "maximum_area_change_percent": maximum_area_change_percent,
		"service_context": service_context, "range_stop": stop, "risks": risks}
	_active_provider = _providers.get(&"sam_video")
	if _active_provider == null: return PackedStringArray(["SAM video provider is not configured"])
	var available: Dictionary = _active_provider.availability()
	if not available.get("available", false): return PackedStringArray([str(available.get("reason", "SAM video is unavailable"))])
	var context := _sam_request.duplicate(true)
	context.source = _source
	_sam_started_ms = Time.get_ticks_msec()
	var errors: PackedStringArray = _active_provider.begin(context)
	if errors.is_empty(): errors = _validate_sam_live()
	if not errors.is_empty():
		cancel()
		last_error = errors[0]
	return errors

func _validate_sam_live() -> PackedStringArray:
	var message := ""
	if not _sam_probe.is_valid() or _sam_probe.call() != _sam_live:
		message = "Selection, frame or pending edit changed; analyze again"
	elif _store == null or _store.freeze_snapshot() != _sam_snapshot:
		message = "Store, review, session or keyframe changed; analyze again"
	elif _active_provider == null:
		message = "SAM video provider is no longer active"
	else:
		var errors: PackedStringArray = _active_provider.validate_source()
		if not errors.is_empty(): message = errors[0]
	if message.is_empty(): return PackedStringArray()
	cancel()
	last_error = message
	return PackedStringArray([message])

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

func start_polygon_analysis(index: int, similarity_threshold: float = 0.10) -> PackedStringArray:
	cancel()
	_strategy = "polygon_flow"
	_active_provider = _providers.get(&"polygon_flow")
	if _active_provider == null:
		return PackedStringArray(["Poly propagation provider is not configured"])
	var errors: PackedStringArray = _active_provider.begin({"source": _source, "store": _store,
		"entries": _entries.duplicate(true), "key_index": index, "region_id": "", "max_entries": 30,
		"similarity_threshold": similarity_threshold, "frame_step": _sampling_step()})
	if errors.is_empty():
		_key_record = _store.get_corrected_record(int(_entries[index].frame_id))
	return errors

func configure_provider(provider_id: StringName, provider: Variant) -> PackedStringArray:
	var normalized_id: StringName = StringName(String(provider_id).strip_edges())
	if String(normalized_id).is_empty():
		return PackedStringArray(["Provider ID must not be empty"])
	if _providers.has(normalized_id):
		return PackedStringArray(["Provider ID is already registered"])
	if provider == null:
		return PackedStringArray(["Provider is missing required lifecycle methods"])
	for method: String in PROVIDER_METHODS:
		if not provider.has_method(method):
			return PackedStringArray(["Provider is missing required lifecycle methods"])
	_providers[normalized_id] = provider
	return PackedStringArray()

## 预检独立于候选分析；UI 通过此接口查询，不接触具体 Service。
func provider_availability(provider_id: StringName) -> Dictionary:
	var normalized_id := StringName(String(provider_id).strip_edges())
	if String(normalized_id).is_empty() or not _providers.has(normalized_id):
		return {"available": false, "reason": "Unknown propagation provider; select a registered provider", "details": {}}
	return _providers[normalized_id].availability().duplicate(true)

func step_provider_availability(provider_id: StringName) -> Dictionary:
	var normalized_id := StringName(String(provider_id).strip_edges())
	if String(normalized_id).is_empty() or not _providers.has(normalized_id):
		return provider_availability(normalized_id)
	var provider: Variant = _providers[normalized_id]
	# 运行中的推理只由 step_analysis 推进，保留其上下文校验和发布边界。
	if not provider.is_running(): provider.step()
	return provider.availability().duplicate(true)

func is_analyzing() -> bool:
	return _active_provider.is_running() if _active_provider != null else _scanner.running

func progress_text() -> String:
	return _active_provider.progress_text() if _active_provider != null else "正在查找相似帧…"

func step_analysis() -> void:
	if _active_provider != null:
		if _strategy == "sam_video" and not _validate_sam_live().is_empty(): return
		var stepping_provider: Variant = _active_provider
		stepping_provider.step()
		if _active_provider != stepping_provider: return
		if _active_provider.is_running(): return
		if _strategy == "sam_video" and not _validate_sam_live().is_empty(): return
		var provider_result: Dictionary = _active_provider.get_result()
		if not _active_provider.is_running() and not provider_result.is_empty():
			if not provider_result.errors.is_empty():
				_plan.clear()
				_preview.clear()
				last_error = provider_result.errors[0]
				return
			_plan = provider_result.duplicate(true)
			_plan["keyframe"] = int(_key_record.frame)
			if _strategy == "sam_video":
				if _sam_elapsed_ms < 0: _sam_elapsed_ms = Time.get_ticks_msec() - _sam_started_ms
				if _plan.get("runtime") is Dictionary:
					_plan.runtime["elapsed_ms"] = _sam_elapsed_ms
		return
	_scanner.step()
	if not _scanner.running and not _scanner.result.is_empty():
		if not _scanner.result.errors.is_empty():
			last_error = _scanner.result.errors[0]
			return
		_plan = _scanner.result.duplicate(true)
		_plan["keyframe"] = int(_key_record.frame)

func get_plan() -> Dictionary:
	if _strategy == "sam_video" and not _plan.is_empty() and not _validate_sam_live().is_empty(): return {}
	return _plan.duplicate(true)

func cancel() -> void:
	_scanner.cancel()
	if _active_provider != null:
		_active_provider.cancel()
	_active_provider = null
	_plan.clear()
	_preview.clear()
	_key_record.clear()
	_sam_snapshot.clear()
	_sam_live.clear()
	_sam_request.clear()
	_sam_elapsed_ms = -1
	last_error = ""

func shutdown() -> void:
	cancel()
	for provider: Variant in _providers.values():
		if provider != null and provider.has_method("shutdown"):
			provider.shutdown()

func find_next_contiguous_run(after_index: int, min_length: int = 2) -> Vector2i:
	if min_length < 2 or after_index < -1 or after_index >= _entries.size() - 1:
		return Vector2i(-1, -1)
	var run_start := -1
	var run_length := 0
	for index in range(maxi(after_index + 2, 1), _entries.size()):
		var previous: Variant = _entries[index - 1].get("frame_id")
		var current: Variant = _entries[index].get("frame_id")
		if typeof(previous) != TYPE_INT or typeof(current) != TYPE_INT:
			run_start = -1
			run_length = 0
			continue
		if int(current) == int(previous) + _sampling_step():
			if run_length == 0:
				run_start = index - 1
				run_length = 2
			else:
				run_length += 1
		else:
			if run_length >= min_length:
				return Vector2i(run_start, index - 1)
			run_start = -1
			run_length = 0
	return Vector2i(run_start, _entries.size() - 1) if run_length >= min_length else Vector2i(-1, -1)

func _sampling_step() -> int:
	if _source != null and _source.has_method("get_manifest"):
		return maxi(1, int(_source.get_manifest().get("frame_step", 1)))
	return 1

func preview(first: int, last: int, mode: String) -> Dictionary:
	_preview = {}
	if _strategy == "sam_video":
		var errors := _validate_sam_live()
		if not errors.is_empty(): return {"errors": errors}
	if _plan.is_empty() or first < int(_plan.start_index) or last > int(_plan.end_index) or first > int(_plan.key_index) or last < int(_plan.key_index) or mode not in ["overwrite", "merge"]:
		return {"errors": PackedStringArray(["Analyze again; range must stay inside the candidate and contain the keyframe"])}
	if _strategy == "sam_video": return _preview_region(first, last, mode)
	return _preview_whole_record(first, last, mode)

func _preview_whole_record(first: int, last: int, mode: String) -> Dictionary:
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

func _preview_region(first: int, last: int, mode: String) -> Dictionary:
	var after := {}
	var before := {}
	var added := 0
	var replaced := 0
	var changed := 0
	if first != int(_plan.key_index) or last <= first:
		return {"errors": PackedStringArray(["SAM preview requires a nonempty forward target range"])}
	for frame: Variant in _plan.target_regions:
		var index := -1
		for i in range(first + 1, int(_plan.end_index) + 1):
			if _entries[i].frame_id == frame: index = i
		var candidates: Variant = _plan.target_regions[frame]
		if index < 0 or not candidates is Array or candidates.size() != 1 or candidates[0].get("id") != _plan.region_id:
			cancel()
			return {"errors": PackedStringArray(["SAM proposal has a non-target frame or wrong region identity"])}
	for index in range(first + 1, last + 1):
		var frame := int(_entries[index].frame_id)
		var record: Dictionary = _store.get_corrected_record(frame)
		var candidates: Array = _plan.target_regions.get(frame, [])
		if record.is_empty() or _duplicate_ids(record.regions) or candidates.size() != 1:
			return {"errors": PackedStringArray(["SAM target or region candidate is missing"])}
		before[frame] = record.duplicate(true)
		var proposed := record.duplicate(true)
		var position := -1
		for i in range(proposed.regions.size()):
			if proposed.regions[i].id == _plan.region_id: position = i
		var shell: Dictionary = proposed.regions[position].duplicate(true) if position >= 0 else _sam_request.region.duplicate(true)
		shell.erase("box")
		shell.erase("polygon")
		shell["polygon"] = candidates[0].polygon.duplicate(true)
		if position >= 0:
			proposed.regions[position] = shell
			replaced += 1
		else:
			proposed.regions.append(shell)
			added += 1
		if proposed != record: changed += 1
		after[frame] = proposed
	_preview = {"errors": PackedStringArray(), "first": first, "last": last, "mode": mode,
		"changed_count": changed, "target_count": after.size(), "covered_count": last - first + 1,
		"added": added, "replaced": replaced, "removed": 0, "before": before, "after": after}
	return _preview.duplicate(true)

func proposed_record(frame_id: int) -> Dictionary:
	if _strategy == "sam_video" and not _preview.is_empty() and not _validate_sam_live().is_empty(): return {}
	return _preview.get("after", {}).get(frame_id, {}).duplicate(true)

func can_apply() -> bool:
	if _strategy == "sam_video" and not _plan.is_empty() and not _validate_sam_live().is_empty(): return false
	var confirmation_count: int = int(_preview.get("target_count", 0) if _strategy == "sam_video" else _preview.get("changed_count", 0))
	return not _plan.is_empty() and confirmation_count > 0

func apply_preview() -> PackedStringArray:
	if _strategy == "sam_video":
		var errors := _validate_sam_live()
		if not errors.is_empty(): return errors
	if _plan.is_empty() or _preview.is_empty():
		return PackedStringArray(["Preview expired; analyze again"])
	if _strategy == "sam_video" and int(_preview.target_count) == 0:
		return PackedStringArray(["SAM preview has no generated targets; analyze again"])
	if _strategy != "sam_video" and int(_preview.changed_count) == 0:
		return PackedStringArray(["Annotations already match; no batch was created"])
	if _strategy != "copy":
		if _active_provider == null:
			return PackedStringArray(["Batch propagation provider is not active; analyze again"])
		var source_errors: PackedStringArray = _active_provider.validate_source()
		if not source_errors.is_empty():
			return source_errors
	for frame_id: int in _preview.before:
		if _store.get_corrected_record(frame_id) != _preview.before[frame_id]:
			return PackedStringArray(["Target changed; analyze again"])
	if _strategy == "sam_video":
		var sam_marker := _sam_operation_marker()
		if sam_marker.is_empty():
			return PackedStringArray(["SAM runtime or accepted prefix is incomplete; analyze again"])
		var sam_command := APPLY_PROPOSALS.new(_key_record, _preview.before, _preview.after, sam_marker)
		return _history.execute(sam_command, _store)
	var edge_refinement := _edge_refinement_summary(_preview.first, _preview.last)
	if _strategy == "polygon_flow" and edge_refinement.is_empty():
		return PackedStringArray(["Poly edge diagnostics are missing; analyze again"])
	var marker := {"schema_version": 2 if _strategy == "polygon_flow" else 1,
		"mode": _preview.mode, "metric_id": _plan.metric_id, "threshold": _plan.threshold,
		"max_frames": _plan.max_frames, "start_index": _preview.first, "end_index": _preview.last,
		"keyframe_digest": JSON.stringify(_key_record).sha256_text(),
		"created_at": Time.get_datetime_string_from_system(true),
		"left_stop": _plan.left_stop, "right_stop": _plan.right_stop,
		"changed_count": _preview.changed_count, "covered_count": _preview.covered_count}
	marker["start_frame"] = int(_entries[_preview.first].frame_id)
	marker["end_frame"] = int(_entries[_preview.last].frame_id)
	if _strategy == "polygon_flow":
		marker["frame_step"] = int(_plan.get("frame_step", _sampling_step()))
		marker["edge_refinement"] = edge_refinement
	marker["expected_review_state"] = _store.snapshot_review_state()
	marker["expected_batch_operations"] = _store.snapshot_batch_operations()
	var command := APPLY_PROPOSALS.new(_key_record, _preview.before, _preview.after, marker)
	var errors: PackedStringArray = _history.execute(command, _store)
	return errors

func _sam_operation_marker() -> Dictionary:
	var runtime: Variant = _plan.get("runtime")
	if not runtime is Dictionary: return {}
	for field in ["checkpoint_sha256", "device", "model_version", "elapsed_ms"]:
		if not runtime.has(field): return {}
	var affected: Array = []
	var indices: Array = []
	var risk_summary: Array = []
	for index in range(int(_preview.first)+1, int(_preview.last)+1):
		var frame := int(_entries[index].frame_id)
		if not _preview.after.has(frame) or not _plan.target_regions.has(frame): return {}
		affected.append(frame)
		indices.append(index)
		var kinds: Array = []
		for risk: Variant in _plan.get("risks", []):
			if not risk is Dictionary or risk.get("frame_id") != frame: continue
			var kind: Variant = risk.get("kind")
			if kind in ["sparse_frame_gap", "sparse_time_gap"]: kind = "sparse_input"
			if kind in ["sparse_input", "area_change", "frame_difference", "flow_consistency"] and kind not in kinds: kinds.append(kind)
		if not kinds.is_empty(): risk_summary.append({"frame_id": frame, "kinds": kinds})
	if affected.size() != _preview.after.size(): return {}
	var stop_frame: Variant = null
	var stop_reason := ""
	if affected.size() < int(_plan.requested_count):
		if int(_preview.last) < int(_plan.end_index):
			stop_reason = "user_range"
			stop_frame = int(_entries[int(_preview.last)+1].frame_id)
		else:
			var stop: Variant = _plan.get("stop")
			if not stop is Dictionary or stop.is_empty(): return {}
			stop_reason = str(stop.get("kind", ""))
			if stop_reason != "source_end": stop_frame = stop.get("frame_id")
	return {"schema_version":3,"type":"range_propagate","mode":"merge","provider_id":"sam_video","metric_id":_plan.metric_id,
		"keyframe":_key_record.frame,"keyframe_playback_index":_preview.first,"keyframe_digest":_store.record_digest(int(_key_record.frame)),
		"region_id":_plan.region_id,"direction":"forward","requested_count":_plan.requested_count,"generated_count":affected.size(),
		"minimum_score":_sam_request.minimum_score,"maximum_area_change_percent":_sam_request.maximum_area_change_percent,
		"start_frame":_key_record.frame,"end_frame":affected[-1],"affected_frames":affected,"target_playback_indices":indices,
		"stop_frame":stop_frame,"stop_reason":stop_reason,"checkpoint_sha256":runtime.checkpoint_sha256,"device":runtime.device,
		"model_version":runtime.model_version,"elapsed_ms":runtime.elapsed_ms,"risk_summary":risk_summary,
		"created_at":Time.get_datetime_string_from_system(true),"expected_review_state":_sam_snapshot.review_state.duplicate(true),
		"expected_batch_operations":_sam_snapshot.batch_operations.duplicate(true)}

func _edge_refinement_summary(first: int, last: int) -> Dictionary:
	var items: Array = []
	var accepted := 0
	for index in range(first, last + 1):
		if index == int(_plan.key_index):
			continue
		var frame_id := int(_entries[index].frame_id)
		var frame_quality: Variant = _plan.get("quality", {}).get(frame_id)
		if not frame_quality is Dictionary:
			return {}
		var region_ids: Array = frame_quality.keys()
		region_ids.sort()
		for region_id: Variant in region_ids:
			var edge: Variant = frame_quality[region_id].get("edge") if frame_quality[region_id] is Dictionary else null
			if not edge is Dictionary or edge.get("attempted") != true:
				return {}
			var was_accepted: Variant = edge.get("accepted")
			if not was_accepted is bool:
				return {}
			if was_accepted:
				accepted += 1
			items.append({"frame_id": frame_id, "region_id": str(region_id),
				"accepted": was_accepted, "reason": edge.get("reason"),
				"raw_edge_score": edge.get("raw_edge_score"),
				"refined_edge_score": edge.get("refined_edge_score")})
	return {"attempted": items.size(), "accepted": accepted,
		"fallback": items.size() - accepted, "items": items}

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
