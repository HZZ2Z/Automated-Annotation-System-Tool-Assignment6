class_name WorkspaceSession
extends Node


signal persistence_failed(message: String)

const SAVE_DELAY_SECONDS := 0.3
const MAX_MESSAGE_LENGTH := 180


var _store: Variant
var _label_store: Variant
var _pause_callback := Callable()
var _status_callback := Callable()
var _remaining_seconds := 0.0
var _blocked := false


func bind(
	store: Variant,
	label_store: Variant,
	pause_callback: Callable,
	status_callback: Callable
) -> void:
	unbind()
	_store = store
	_label_store = label_store
	_pause_callback = pause_callback
	_status_callback = status_callback
	_blocked = false
	_remaining_seconds = 0.0
	if (
		_store is Object
		and _store.has_signal("corrected_records_replaced")
	):
		_store.corrected_records_replaced.connect(_on_records_replaced)
	set_process(false)


func unbind() -> void:
	if (
		_store is Object
		and _store.has_signal("corrected_records_replaced")
		and _store.corrected_records_replaced.is_connected(_on_records_replaced)
	):
		_store.corrected_records_replaced.disconnect(_on_records_replaced)
	_store = null
	_label_store = null
	_pause_callback = Callable()
	_status_callback = Callable()
	_remaining_seconds = 0.0
	_blocked = false
	set_process(false)


func can_replace_context() -> bool:
	return (
		not _blocked
		and (
			_label_store == null
			or not _label_store.has_method("has_pending_changes")
			or not _label_store.has_pending_changes()
		)
	)


func flush_before_context_change() -> PackedStringArray:
	return _flush_pending()


func retry_unsaved() -> PackedStringArray:
	return _flush_pending()


func _process(delta: float) -> void:
	if _label_store == null or not _label_store.has_pending_changes():
		set_process(false)
		return
	_remaining_seconds -= delta
	if _remaining_seconds <= 0.0:
		_flush_pending()


func _on_records_replaced(frames: PackedInt64Array) -> void:
	if _store == null or _label_store == null:
		return
	for frame_id: int in frames:
		var record: Dictionary = _store.get_corrected_record(frame_id)
		var errors: PackedStringArray = _label_store.replace_record(frame_id, record)
		if not errors.is_empty():
			_report_failure(frame_id, errors[0])
			return
	_remaining_seconds = SAVE_DELAY_SECONDS
	set_process(true)


func _flush_pending() -> PackedStringArray:
	if _label_store == null or not _label_store.has_pending_changes():
		_blocked = false
		set_process(false)
		return PackedStringArray()
	var dirty_frames: PackedInt64Array = _label_store.dirty_frame_ids()
	var errors: PackedStringArray = _label_store.flush()
	if errors.is_empty():
		_blocked = false
		_remaining_seconds = 0.0
		set_process(false)
		return errors
	var frame_id := int(dirty_frames[0]) if not dirty_frames.is_empty() else -1
	_report_failure(frame_id, errors[0])
	return errors


func _report_failure(frame_id: int, detail: String) -> void:
	_blocked = true
	set_process(false)
	if _pause_callback.is_valid():
		_pause_callback.call()
	var path := ""
	if _label_store != null and _label_store.has_method("label_path"):
		path = _label_store.label_path()
	var message := "Auto-save failed"
	if frame_id >= 0:
		message += " at frame %d" % frame_id
	if not path.is_empty():
		message += " (%s)" % path
	if not detail.is_empty():
		message += ": %s" % detail
	message = _bounded(message)
	if _status_callback.is_valid():
		_status_callback.call(message)
	persistence_failed.emit(message)


func _bounded(message: String) -> String:
	var clean := message.replace("\n", " ").replace("\r", " ").strip_edges()
	return clean if clean.length() <= MAX_MESSAGE_LENGTH else clean.left(177) + "..."
