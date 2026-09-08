class_name WorkspaceSession
extends Node

signal saved(session_id: String, revision: int)
signal failed(session_id: String, revision: int, errors: PackedStringArray)
signal persistence_failed(message: String)
signal state_changed(state: Dictionary)

const JOB := preload("res://client/services/background_job.gd")
const REPOSITORY := preload("res://client/workspace/session_repository.gd")
const SAVE_DELAY_SECONDS := 0.3
const MAX_REQUEST_SECONDS := 2.0

var _store: Variant
var _label_store: Variant
var _job: Variant
var _worker := Callable()
var _repository = REPOSITORY.new()
var _pause_callback := Callable()
var _status_callback := Callable()
var _session_id := ""
var _saved_revision := -1
var _active_revision := -1
var _pending := false
var _blocked := false
var _idle := 0.0
var _age := 0.0
var _last_saved := ""
var _last_errors := PackedStringArray()
var _suspended := false

func _ready() -> void:
	_job = JOB.new()
	add_child(_job)
	_job.finished.connect(_on_finished)
	set_process(false)

func set_save_worker(worker: Callable) -> void:
	assert(not is_saving())
	_worker = worker

func bind(store: Variant,label_store: Variant,pause_callback: Callable,status_callback: Callable) -> void:
	assert(not is_saving(), "Settle running save before changing media")
	unbind()
	_store = store
	_label_store = label_store
	_pause_callback = pause_callback
	_status_callback = status_callback
	var errors: PackedStringArray = _label_store.bind_store(_store)
	if not errors.is_empty():
		_report_failure(_store.current_revision(),errors)
		return
	_session_id = _store.freeze_snapshot().session_id
	_saved_revision = _label_store.saved_revision()
	_store.corrected_records_replaced.connect(_on_records_replaced)
	_store.review_state_changed.connect(_on_changed)
	if has_unsaved_changes(): _on_changed()
	_emit_state()

func unbind() -> void:
	assert(not is_saving(), "Settle running save before unbinding")
	if _store != null:
		if _store.corrected_records_replaced.is_connected(_on_records_replaced): _store.corrected_records_replaced.disconnect(_on_records_replaced)
		if _store.review_state_changed.is_connected(_on_changed): _store.review_state_changed.disconnect(_on_changed)
	_store = null
	_label_store = null
	_session_id = ""
	_pending = false
	_blocked = false
	_idle = 0.0
	_age = 0.0
	_saved_revision = -1
	_active_revision = -1
	_last_errors = PackedStringArray()
	_last_saved = ""
	_suspended = false
	set_process(false)

func has_unsaved_changes() -> bool:
	return _store != null and _store.current_revision() > _saved_revision

func is_saving() -> bool: return _job != null and _job.is_running()
func can_replace_context() -> bool: return not is_saving() and not has_unsaved_changes() and not _blocked
func saved_revision() -> int: return _saved_revision

func status() -> Dictionary:
	var state := "failed" if _blocked else ("saving" if is_saving() else ("unsaved" if has_unsaved_changes() else "saved"))
	return {"state":state,"session_id":_session_id,"revision":_store.current_revision() if _store != null else -1,"saved_revision":_saved_revision,"last_saved":_last_saved,"errors":_last_errors}

## Request is nonblocking. A busy writer coalesces to the latest Store revision.
func request_save() -> void:
	if _store == null: return
	_blocked = false
	_last_errors = PackedStringArray()
	_idle = 0.0
	_age = 0.0
	if not has_unsaved_changes():
		_emit_state()
		return
	if is_saving():
		_pending = _store.current_revision() > _active_revision
		_emit_state()
		return
	_pending = false
	var snapshot: Dictionary = _store.freeze_snapshot()
	_active_revision = snapshot.revision
	var work := _worker if _worker.is_valid() else Callable(_repository,"save_snapshot")
	var errors: PackedStringArray = _job.start(work,[snapshot,_label_store.save_options()])
	if not errors.is_empty(): _report_failure(_active_revision,errors)
	_emit_state()

## Wait for a particular content revision without requiring later edits to stop.
func save_through(revision: int) -> PackedStringArray:
	var identity := _session_id
	request_save()
	while _saved_revision < revision:
		if identity != _session_id: return PackedStringArray(["Session changed while awaiting save"])
		if _blocked: return _last_errors
		await get_tree().process_frame
	return PackedStringArray()

func flush_before_context_change() -> PackedStringArray:
	if _store == null: return PackedStringArray()
	return await save_through(_store.current_revision())

func retry_unsaved() -> PackedStringArray:
	return await flush_before_context_change()

## Discard decisions must first settle any write that has already started.
func settle_running() -> void:
	_pending = false
	set_process(false)
	while is_saving(): await get_tree().process_frame

func suspend_autosave(value: bool) -> void:
	_suspended = value
	set_process(not value and not _blocked and has_unsaved_changes())

func _process(delta: float) -> void:
	if _suspended or _blocked or not has_unsaved_changes():
		set_process(false)
		return
	_idle += delta
	_age += delta
	if _idle >= SAVE_DELAY_SECONDS or _age >= MAX_REQUEST_SECONDS: request_save()

func _on_records_replaced(_frames: PackedInt64Array) -> void: _on_changed()

func _on_changed() -> void:
	_idle = 0.0
	if not _blocked and not _suspended: set_process(true)
	_emit_state()

func _on_finished(result: Dictionary) -> void:
	# Results acknowledge only the submitted immutable session and revision.
	if not result.has("session_id") or not result.has("revision"):
		_report_failure(_active_revision,PackedStringArray(result.get("errors",["Save worker returned an invalid result"])))
		return
	if result.get("session_id") != _session_id or int(result.get("revision",-1)) != _active_revision: return
	if not result.get("success",false):
		_report_failure(_active_revision,PackedStringArray(result.get("errors",["Save failed"])))
		return
	_saved_revision = _active_revision
	_label_store.accept_saved(result)
	_last_saved = Time.get_datetime_string_from_system()
	_blocked = false
	saved.emit(_session_id,_saved_revision)
	_emit_state()
	if _pending and has_unsaved_changes() and not _suspended:
		_pending = false
		call_deferred("request_save")
	elif has_unsaved_changes() and not _suspended:
		set_process(true)

func _report_failure(revision: int, errors: PackedStringArray) -> void:
	_blocked = true
	_pending = false
	_last_errors = errors
	set_process(false)
	if _pause_callback.is_valid(): _pause_callback.call()
	var message := "Save failed: " + "; ".join(errors)
	if _status_callback.is_valid(): _status_callback.call(message)
	persistence_failed.emit(message)
	failed.emit(_session_id,revision,errors)
	_emit_state()

func _emit_state() -> void: state_changed.emit(status())
