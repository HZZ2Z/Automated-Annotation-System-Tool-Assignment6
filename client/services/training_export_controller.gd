## 导出只消费已保存的冻结版本；主线程负责会话检查，工作线程只接收快照和插件。
extends Node

signal progress(value: Dictionary)
signal state_changed

const JOB := preload("res://client/services/background_job.gd")
const PACKAGE := preload("res://client/feedback/training_package.gd")
const MODEL_ROUND := preload("res://client/workspace/model_round_controller.gd")
const REVIEW := preload("res://client/domain/commands/review_frames_command.gd")
const CODEC := preload("res://client/workspace/review_session_codec.gd")
const COCO_SERVICE := preload("res://client/services/coco_export_service.gd")
const COCO_KIND := "training_coco_v1"
const KINDS := ["training_update_v2", "review_export_v1", COCO_KIND]

var _host: Variant
var _job: Variant
var _coco_service: Variant
var _package = PACKAGE.new()
var _snapshot: Dictionary = {}
var _store: Variant
var _session: Variant
var _source: Variant
var _plugin: Variant
var _session_id := ""
var _revision := -1
var _generation := 0
var _phase := ""
var _composing := false
var _coco_context: Dictionary = {}
var _coco_preparation_digest := ""
var last_result: Dictionary = {}

func setup(host: Variant) -> void:
	_host = host
	_job = JOB.new()
	add_child(_job)
	_job.progress.connect(func(value: Dictionary): progress.emit(value))
	_coco_service = COCO_SERVICE.new()
	add_child(_coco_service)
	_coco_service.progress.connect(func(value: Dictionary): progress.emit(value))

func prepare() -> Dictionary:
	if is_busy(): return _error("An export task is already running")
	return await _prepare()

## 普通导出入口：先保存，再为可信旧会话绑定基线，最后返回人工可读计数。
func prepare_one_click() -> Dictionary:
	if is_busy(): return _error("An export task is already running")
	_composing = true
	var prepared := await _prepare()
	if not prepared.get("success", false):
		if prepared.get("cancelled", false) or prepared.get("stale", false):
			prepared["error_code"] = "stale_context"
			prepared["stale"] = true
			prepared["cancelled"] = prepared.get("cancelled", false) \
				or int(prepared.get("generation", -1)) != _generation
		return _end_composing(prepared)
	var generation := int(prepared.generation)
	var auto_baseline_bound := false
	if _snapshot.get("baseline_kind") == "unknown":
		var descriptor: Dictionary = _host._workspace_label_store.baseline_descriptor()
		if descriptor.is_empty():
			_snapshot = {}
			return _end_composing(_coded_error(
				"baseline_input_required",
				"Original annotations are required before training export",
			))
		var bound := await _auto_bind_unknown(_snapshot, descriptor, generation)
		if not bound.get("success", false):
			_snapshot = {}
			return _end_composing(bound)
		auto_baseline_bound = true
	var result := _one_click_summary(_snapshot)
	result.merge(_context(generation), false)
	result.success = true
	result["auto_baseline_bound"] = auto_baseline_bound
	return _end_composing(result)


func supports_coco_export() -> bool:
	var source: Variant = _host._source if _host != null else null
	return (
		source != null
		and source.has_method("get_export_descriptor")
		and not source.get_export_descriptor().is_empty()
	)


## Pure training export: consume existing content verification without changing
## review state, then ask the shared Python worker for an exact preview.
func prepare_coco(
	task: String = "detection",
	selected_frame_ids: Variant = null,
	segmentation_attested: bool = false,
	allow_box_only_fallback: bool = false,
) -> Dictionary:
	if is_busy(): return _error("An export task is already running")
	_composing = true
	var prepared := await _prepare(false)
	if not prepared.get("success", false):
		return _end_composing(prepared)
	var generation := int(prepared.generation)
	if not supports_coco_export():
		return _end_composing(_coded_error(
			"source_metadata_required",
			"Current Source does not provide training_coco_v1 export metadata",
		))
	var descriptor: Dictionary = _source.get_export_descriptor()
	var options := {
		"task": task,
		"segmentation_attested": segmentation_attested,
		"allow_box_only_fallback": allow_box_only_fallback,
	}
	if selected_frame_ids != null:
		options["selected_frame_ids"] = Array(selected_frame_ids)
	_coco_context = {
		"schema_version": 1,
		"package_type": COCO_KIND,
		"saved_snapshot": CODEC.new().encode(_snapshot),
		"source_descriptor": descriptor.duplicate(true),
		"export_options": options,
		"preparation_token": {
			"session_id": _session_id,
			"saved_revision": _revision,
		},
	}
	var errors: PackedStringArray = _coco_service.start_prepare(_coco_context)
	if not errors.is_empty():
		_clear_coco_preview()
		return _end_composing(_coded_error("background_start_failed", errors))
	_set_phase("coco_preview")
	var returned: Dictionary = await _coco_service.finished
	_set_phase("")
	var result := _decorate_coco_result(returned, generation)
	if (
		generation != _generation
		or not _same_session()
		or _store.current_revision() != _revision
		or _session.saved_revision() < _revision
	):
		_clear_coco_preview()
		var stale := _stale_error(
			generation, "Session or content changed during COCO export preparation")
		stale.merge({
			"issues": [{"code": "STALE_CONTEXT", "message": stale.errors[0]}],
			"package_type": COCO_KIND,
			"task": task,
		}, true)
		return _end_composing(stale)
	if result.get("success", false):
		_coco_preparation_digest = String(result.get("preparation_digest", ""))
	else:
		_clear_coco_preview()
	return _end_composing(result)


## Confirmation acknowledges scope only; it never creates review records. The
## worker re-prepares and rehashes the frozen inputs before atomic publication.
func publish_coco(output_parent: String, scope_attested: bool) -> Dictionary:
	if is_busy(): return _error("An export task is already running")
	if not scope_attested:
		return _coded_error(
			"attestation_required",
			"Confirm the included Source-frame scope and zero-target semantics",
		)
	var errors := _prepared_errors(COCO_KIND)
	if output_parent.strip_edges().is_empty():
		errors.append("Choose an output directory")
	if _coco_context.is_empty() or _coco_preparation_digest.is_empty():
		errors.append("Prepare a COCO export preview first")
	if not errors.is_empty():
		return _coded_error(
			"stale_context" if not _same_session() else "prepare_required", errors)
	if _store.current_revision() != _revision or _session.saved_revision() < _revision:
		var stale := _coded_error(
			"stale_context", "Content changed after COCO preview; prepare again")
		stale.stale = true
		return stale
	_composing = true
	var generation := _generation
	errors = _coco_service.start_export(
		_coco_context,
		ProjectSettings.globalize_path(output_parent.strip_edges()).simplify_path(),
		_coco_preparation_digest,
	)
	if not errors.is_empty():
		return _end_composing(_coded_error("background_start_failed", errors))
	_set_phase("coco_publish")
	var returned: Dictionary = await _coco_service.finished
	_set_phase("")
	var result := _decorate_coco_result(returned, generation)
	last_result = result
	return _end_composing(result)


## 审核声明只确认已写入的非空帧；保存成功后才冻结并发布同一代快照。
func confirm_and_publish(output_parent: String, attested: bool) -> Dictionary:
	if is_busy(): return _error("An export task is already running")
	if not attested:
		return _coded_error("attestation_required", "Confirm that the written annotations were reviewed")
	var errors := _prepared_errors("training_update_v2")
	if not errors.is_empty():
		return _coded_error("stale_context" if not _same_session() else "prepare_required", errors)
	if _store.current_revision() != _revision:
		var stale := _coded_error("stale_context", "Content changed after export preparation; prepare again")
		stale.stale = true
		return stale
	_composing = true
	var generation := _generation
	var pending := PackedInt64Array()
	for frame: int in _written_nonempty_ids(_snapshot):
		if not _store.is_verified(frame):
			pending.append(frame)
	if not pending.is_empty():
		errors = _host._history.execute(REVIEW.new(pending, true), _store)
		if not errors.is_empty():
			return _end_composing(_coded_error("review_failed", errors))
	var review_revision: int = _store.current_revision()
	errors = await _session.save_through(review_revision)
	if not errors.is_empty():
		return _end_composing(_coded_error("save_failed", errors))
	if generation != _generation or not _same_session() or _store.current_revision() != review_revision:
		var stale := _coded_error("stale_context", "Content changed while saving the review; prepare again")
		stale.stale = true
		if generation != _generation: stale.cancelled = true
		return _end_composing(stale)
	_revision = review_revision
	_snapshot = _store.freeze_snapshot()
	var previewed := await _run_worker("preview", Callable(_package, "preview"), {"kind":"training_update_v2"})
	if not previewed.get("success", false):
		var code := "stale_context" if previewed.get("stale", false) or generation != _generation else "preview_failed"
		previewed["error_code"] = code
		return _end_composing(previewed)
	if not _valid_live_revision(generation, review_revision):
		return _end_composing(_stale_error(
			generation,
			"Session or content changed during export preview; prepare again",
		))
	var published := await _publish(output_parent, "training_update_v2")
	if not published.get("success", false) and not published.has("error_code"):
		published["error_code"] = "stale_context" if published.get("stale", false) or generation != _generation else "publication_failed"
	return _end_composing(published)

func _prepare(require_feedback: bool = true) -> Dictionary:
	_generation += 1
	var generation := _generation
	_snapshot = {}
	_clear_coco_preview()
	state_changed.emit()
	var errors := _entry_errors(require_feedback)
	if not errors.is_empty(): return _error(errors)
	_store = _host._store
	_session = _host._workspace_session
	_source = _host._source
	_plugin = _host._feedback_plugin
	_session_id = String(_session.status().session_id)
	_revision = _store.current_revision()
	_host.pause()
	_set_phase("prepare")
	# 取消不会中断保存协程；状态一直保留到该协程真正退出。
	errors = await _session.save_through(_revision)
	var result := _context(generation)
	if generation != _generation:
		result.cancelled = true
		result.error_code = "stale_context"
	elif not _same_session():
		result.stale = true
		result.error_code = "stale_context"
		result.errors.append("Session changed while preparing export")
	elif not errors.is_empty():
		result.errors = errors
		result.error_code = "save_failed"
		result.issues = []
		for message: String in errors:
			result.issues.append({"code": "SAVE_FAILED", "message": message})
	elif _store.current_revision() != _revision or _session.saved_revision() < _revision:
		result.stale = true
		result.error_code = "stale_context"
		result.errors.append("Content changed during export preparation; prepare again")
	else:
		_snapshot = _store.freeze_snapshot()
		result.success = true
	_set_phase("")
	return result

func preview(kind: String = "training_update_v2") -> Dictionary:
	if is_busy(): return _error("An export task is already running")
	var errors := _prepared_errors(kind)
	if not errors.is_empty(): return _error(errors)
	return await _run_worker("preview", Callable(_package,"preview"), {"kind":kind})

func publish(output_parent: String, kind: String = "training_update_v2") -> Dictionary:
	if is_busy(): return _error("An export task is already running")
	return await _publish(output_parent,kind)

func _publish(output_parent: String, kind: String) -> Dictionary:
	var errors := _prepared_errors(kind)
	if output_parent.strip_edges().is_empty(): errors.append("Choose an output directory")
	if not errors.is_empty(): return _error(errors)
	# 插件和快照在 prepare 时绑定；以后编辑或更换插件不会改变本次任务。
	var result := await _run_worker("publish", Callable(_plugin,"export_package"), {
		"kind":kind,"output_parent":ProjectSettings.globalize_path(output_parent.strip_edges()).simplify_path()})
	last_result = result
	return result

func export_current(output_parent: String, kind: String = "training_update_v2") -> Dictionary:
	if is_busy(): return _error("An export task is already running")
	if kind not in KINDS: return _error("Unsupported package kind: " + kind)
	_composing = true
	var prepared := await _prepare()
	var result: Dictionary = prepared
	if prepared.success:
		result = await _publish(output_parent,kind)
	_composing = false
	state_changed.emit()
	return result


func _auto_bind_unknown(snapshot: Dictionary, descriptor: Dictionary, generation: int) -> Dictionary:
	var context := {
		"snapshot": snapshot,
		"save_options": _host._workspace_label_store.save_options(),
	}
	var prepared := await _run_service(
		"baseline_prepare",
		Callable(MODEL_ROUND, "prepare_auto_baseline_binding"),
		[context, descriptor],
		generation,
	)
	if not prepared.get("success", false):
		return _service_failure(prepared, generation, "baseline_binding_failed")
	if not _valid_live_revision(generation, int(snapshot.revision)):
		return _stale_error(generation, "Session changed while preparing the original baseline")
	var staged: Dictionary = _host.stage_review_replacement(prepared.get("store"))
	if not staged.get("success", false):
		return _coded_error("baseline_binding_failed", staged.get("errors", ["Cannot stage the restored baseline"]))
	if staged.store.current_revision() != int(prepared.snapshot.revision):
		_host.discard_review_replacement(staged)
		return _coded_error("baseline_binding_failed", "Edit activation changed the restored baseline")
	var worker_input := prepared.duplicate()
	worker_input.erase("store")
	var committed := await _run_service(
		"baseline_commit",
		Callable(MODEL_ROUND, "commit_auto_baseline_binding"),
		[context, worker_input, descriptor],
		generation,
	)
	if not committed.get("success", false):
		_host.discard_review_replacement(staged)
		return _service_failure(committed, generation, "baseline_binding_failed")
	# The commit may have reached disk just before cancellation. Its saved result
	# remains authoritative and must be adopted to keep Main and disk consistent.
	if not _same_session() or _store.current_revision() != int(snapshot.revision) \
			or _session.saved_revision() < int(snapshot.revision):
		_host.discard_review_replacement(staged)
		return _stale_error(generation, "Session changed while saving the original baseline")
	_host.adopt_review_replacement(committed, staged)
	_store = _host._store
	_session = _host._workspace_session
	_source = _host._source
	_session_id = String(_session.status().session_id)
	_revision = _store.current_revision()
	_snapshot = _store.freeze_snapshot()
	if generation != _generation:
		_snapshot = {}
		return _stale_error(generation, "Original baseline was saved before cancellation completed")
	return {"success":true,"errors":PackedStringArray()}


func _run_service(phase: String, work: Callable, args: Array, generation: int) -> Dictionary:
	var errors: PackedStringArray = _job.start(work, args)
	if not errors.is_empty():
		return _coded_error("background_start_failed", errors)
	_set_phase(phase)
	var result: Dictionary = await _job.finished
	_set_phase("")
	if generation != _generation:
		result["cancelled"] = true
	return result


func _valid_live_revision(generation: int, revision: int) -> bool:
	return generation == _generation and _same_session() and _store.current_revision() == revision \
		and _session.saved_revision() >= revision


func _service_failure(result: Dictionary, generation: int, code: String) -> Dictionary:
	if generation != _generation or result.get("cancelled", false) or not _same_session():
		return _stale_error(generation, "Export preparation was cancelled or superseded")
	var failure := _coded_error(code, result.get("errors", ["Export preparation failed"]))
	return failure


func _stale_error(generation: int, message: String) -> Dictionary:
	var result := _coded_error("stale_context", message)
	result.stale = true
	result.cancelled = generation != _generation
	return result


func _one_click_summary(snapshot: Dictionary) -> Dictionary:
	var annotated := 0
	var verified := 0
	var verified_empty := 0
	var pending_attestation := 0
	for record: Dictionary in snapshot.get("records", []):
		var nonempty: bool = not record.get("regions", []).is_empty()
		var accepted: bool = PACKAGE.is_verified(snapshot, record)
		if nonempty: annotated += 1
		if accepted: verified += 1
		if accepted and not nonempty: verified_empty += 1
		if nonempty and not accepted: pending_attestation += 1
	return {
		"total_frames": snapshot.get("frame_entries", []).size(),
		"annotated_frames": annotated,
		"already_verified_frames": verified,
		"verified_empty_frames": verified_empty,
		"will_export_frames": annotated + verified_empty,
		"needs_attestation": pending_attestation > 0,
	}


func _written_nonempty_ids(snapshot: Dictionary) -> PackedInt64Array:
	var ids := PackedInt64Array()
	for record: Dictionary in snapshot.get("records", []):
		if not record.get("regions", []).is_empty():
			ids.append(int(record.frame))
	ids.sort()
	return ids


func _end_composing(result: Dictionary) -> Dictionary:
	_composing = false
	state_changed.emit()
	return result


func _coded_error(code: String, errors: Variant) -> Dictionary:
	var result := _error(errors)
	result["error_code"] = code
	return result

func cancel() -> void:
	_generation += 1
	_snapshot = {}
	_clear_coco_preview()
	if _job != null: _job.cancel()
	if _coco_service != null: _coco_service.cancel()
	state_changed.emit()

func cancel_and_drain() -> void:
	cancel()
	if _coco_service != null:
		await _coco_service.cancel_and_drain()
	while is_busy(): await get_tree().process_frame

func is_busy() -> bool:
	return (
		_composing
		or not _phase.is_empty()
		or (_job != null and _job.is_running())
		or (_coco_service != null and _coco_service.is_running())
	)

func is_publishing() -> bool: return _phase in ["publish", "coco_publish"]
func get_snapshot() -> Dictionary: return _snapshot
func generation() -> int: return _generation

func belongs_to_current_session(result: Dictionary) -> bool:
	return _same_session() and result.get("session_id", "") == _session_id

func can_present(result: Dictionary) -> bool:
	return belongs_to_current_session(result) and int(result.get("generation",-1)) == _generation

func _run_worker(phase: String, work: Callable, options: Dictionary) -> Dictionary:
	var generation := _generation
	var errors: PackedStringArray = _job.start(work,[_snapshot,options])
	if not errors.is_empty(): return _error(errors)
	_set_phase(phase)
	var returned: Dictionary = await _job.finished
	var result := _context(generation)
	result.merge(returned,true)
	# 结果身份由控制器提供，不信任插件覆盖会话或请求代次。
	result.session_id = _session_id
	result.revision = _revision
	result.generation = generation
	result.stale = not _same_session()
	if generation != _generation:
		result["cancel_requested"] = true
		if not result.success: result.cancelled = true
	_set_phase("")
	return result

func _entry_errors(require_feedback: bool = true) -> PackedStringArray:
	if _host == null or _host._source == null or _host._current_frame < 0:
		return PackedStringArray(["Open a source before exporting"])
	if _host._is_class_dialog_active(): return _host._modal_refusal("Export")
	if _host._review_workflow != null and _host._review_workflow.is_busy():
		return PackedStringArray(["Finish the active session transition before exporting"])
	if _host._workspace_media_controller != null and _host._workspace_media_controller.is_busy():
		return PackedStringArray(["Finish preparing the selected media before exporting"])
	if _host._video_import_controller != null and _host._video_import_controller.is_running():
		return PackedStringArray(["Finish video import before exporting"])
	if not _host._prepare_edit_navigation():
		return PackedStringArray([_host._edit_navigation_message()])
	if require_feedback and (_host._feedback_plugin == null or not _host._feedback_plugin.has_method("export_package")):
		return PackedStringArray(["Current Feedback plugin does not support training_update_v2 export_package"])
	if _host._workspace_session == null or String(_host._workspace_session.status().session_id).is_empty():
		return PackedStringArray(["No committed review session is available for export"])
	return PackedStringArray()

func _prepared_errors(kind: String) -> PackedStringArray:
	if kind not in KINDS: return PackedStringArray(["Unsupported package kind: " + kind])
	if _snapshot.is_empty(): return PackedStringArray(["Prepare a saved export snapshot first"])
	if not _same_session(): return PackedStringArray(["Session changed; prepare export again"])
	if _host._is_class_dialog_active(): return _host._modal_refusal("Export")
	if _host._review_workflow.is_busy(): return PackedStringArray(["Finish the active session transition before exporting"])
	return PackedStringArray()

func _same_session() -> bool:
	return _host != null and _session != null and _host._workspace_session == _session \
		and _host._store == _store and _host._source == _source \
		and String(_session.status().session_id) == _session_id

func _context(generation: int) -> Dictionary:
	return {"success":false,"errors":PackedStringArray(),"cancelled":false,"stale":false,
		"generation":generation,"session_id":_session_id,"revision":_revision}

func _error(errors: Variant) -> Dictionary:
	var result := _context(_generation)
	result.errors = PackedStringArray([errors]) if errors is String else PackedStringArray(errors)
	return result


func _decorate_coco_result(returned: Dictionary, generation: int) -> Dictionary:
	var result := _context(generation)
	result.merge(returned, true)
	result["session_id"] = _session_id
	result["revision"] = _revision
	result["generation"] = generation
	result["stale"] = not _same_session()
	if generation != _generation:
		result["cancel_requested"] = true
		if not result.get("success", false):
			result["cancelled"] = true
	if not result.get("success", false) and not result.has("error_code"):
		var issues: Array = result.get("issues", [])
		result["error_code"] = (
			String(issues[0].get("code", "package_invalid")).to_lower()
			if not issues.is_empty() and issues[0] is Dictionary
			else "package_invalid"
		)
	return result


func _clear_coco_preview() -> void:
	_coco_context = {}
	_coco_preparation_digest = ""

func _set_phase(value: String) -> void:
	_phase = value
	state_changed.emit()
