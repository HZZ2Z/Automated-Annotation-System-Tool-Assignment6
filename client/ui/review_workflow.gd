## Part 4 UI orchestration. Disk work is owned by detached worker services.
extends Node

signal leave_decided(choice: String)

const JOB := preload("res://client/services/background_job.gd")
const LOADER := preload("res://client/workspace/session_loader.gd")

var _host: Variant
var _save_button: Button
var _status: Label
var _round_button: Button
var _open_job: Variant
var _loader = LOADER.new()
var _leave_dialog: ConfirmationDialog
var _busy_dialog: AcceptDialog
var _discard_session := ""
var _leaving := false
var _opening := false
var _base_canvas_size := Vector2i.ZERO
var exports: Variant

func setup(host: Variant) -> void:
	_host = host
	var toolbar: HBoxContainer = host.get_node("MainVBox/TopToolbar")
	_save_button = toolbar.get_node("Save")
	_save_button.tooltip_text = "Save committed annotations (Ctrl+S)"
	_save_button.pressed.connect(save_now)
	_status = Label.new()
	_status.text = "未保存"
	_status.name = "SaveStatus"
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(_status)
	_round_button = Button.new()
	_round_button.name = "ModelRound"
	_round_button.text = "模型轮次"
	_round_button.clip_text = true
	_round_button.custom_minimum_size.x = 210
	toolbar.add_child(_round_button)
	_open_job = JOB.new()
	add_child(_open_job)
	_leave_dialog = ConfirmationDialog.new()
	_leave_dialog.title = "尚有未保存的修改"
	_leave_dialog.dialog_text = "保存已提交的修改后继续，或放弃尚未保存的修改。草稿不会自动提交。"
	_leave_dialog.get_ok_button().text = "保存并继续"
	_leave_dialog.get_cancel_button().text = "取消"
	_leave_dialog.add_button("放弃尚未保存的修改",false,"discard")
	_leave_dialog.confirmed.connect(func(): leave_decided.emit("save"))
	_leave_dialog.canceled.connect(func(): leave_decided.emit("cancel"))
	_leave_dialog.custom_action.connect(func(action: StringName): _leave_dialog.hide(); leave_decided.emit(String(action)))
	add_child(_leave_dialog)
	_busy_dialog = AcceptDialog.new()
	_busy_dialog.title = "正在准备会话"
	_busy_dialog.dialog_text = "后台读取与校验中…"
	_busy_dialog.get_ok_button().text = "取消"
	_busy_dialog.confirmed.connect(func(): _open_job.cancel())
	_busy_dialog.canceled.connect(func(): _open_job.cancel())
	add_child(_busy_dialog)
	_host._workspace_session.state_changed.connect(_on_save_state)
	exports = preload("res://client/ui/training_export_dialog.gd").new()
	add_child(exports)
	exports.setup(_host)
	get_tree().auto_accept_quit = false
	_host.get_window().close_requested.connect(request_close)
	_base_canvas_size = _host.get_window().content_scale_size
	_host.get_node("MainVBox").minimum_size_changed.connect(_fit_canvas)
	_fit_canvas.call_deferred()
	refresh()

## Keep every existing panel and transport control inside the logical canvas.
func _fit_canvas() -> void:
	var minimum: Vector2 = _host.get_node("MainVBox").get_combined_minimum_size()
	_host.get_window().content_scale_size = Vector2i(
		maxi(_base_canvas_size.x,ceili(minimum.x)),
		maxi(_base_canvas_size.y,ceili(minimum.y)))

func refresh() -> void:
	_save_button.disabled = _host._source == null or _opening or _leaving
	_round_button.disabled = _host._source == null or _opening or _leaving
	if _host._source != null:
		var snapshot: Dictionary = _host._store.freeze_snapshot()
		_round_button.text = "轮次：" + String(snapshot.get("round_id","initial"))
		if snapshot.get("baseline_kind") == "unknown": _round_button.text += " · 基线未绑定"
		_round_button.tooltip_text = "基线未绑定" if snapshot.get("baseline_kind") == "unknown" else "导入模型新轮次"

func save_now() -> void:
	if _host._source != null: _host._workspace_session.request_save()

func _on_save_state(state: Dictionary) -> void:
	var labels := {"unsaved":"未保存","saving":"保存中…","saved":"已保存","failed":"保存失败 · 点击 Save 重试"}
	_status.text = labels.get(state.state,"未保存")
	if not state.last_saved.is_empty(): _status.text += " " + String(state.last_saved).get_slice("T",1)
	_status.tooltip_text = "; ".join(state.errors)

func open_session(kind: String, options: Dictionary) -> Dictionary:
	if _opening: return {"success":false,"errors":["A session is already opening"]}
	_opening = true
	_host.pause()
	refresh()
	var errors: PackedStringArray = _open_job.start(Callable(_loader,"open_" + kind),[options])
	if not errors.is_empty():
		_opening = false
		refresh()
		return {"success":false,"errors":errors}
	_busy_dialog.popup_centered(Vector2i(460,140))
	var result: Dictionary = await _open_job.finished
	_busy_dialog.hide()
	_opening = false
	refresh()
	if not result.has("success"): return {"success":false,"errors":["Session worker returned an invalid result"]}
	return result

func has_discard_authorization() -> bool:
	return not _discard_session.is_empty() and _discard_session == _host._workspace_session.status().session_id

func finish_transition() -> void:
	_discard_session = ""
	_host._workspace_session.suspend_autosave(false)
	refresh()

func confirm_leave() -> bool:
	if _leaving or _opening: return false
	_leaving = true
	await exports.cancel_and_drain()
	_host.pause()
	var session = _host._workspace_session
	session.suspend_autosave(true)
	refresh()
	await session.settle_running()
	if not session.has_unsaved_changes():
		_leaving = false
		refresh()
		return true
	_leave_dialog.popup_centered(Vector2i(610,180))
	var choice: String = await leave_decided
	_leave_dialog.hide()
	var allowed := false
	if choice == "save":
		var errors: PackedStringArray = await session.flush_before_context_change()
		allowed = errors.is_empty()
		if not allowed: _host._show_errors("保存失败，当前会话已保留",errors)
	elif choice == "discard":
		_discard_session = session.status().session_id
		allowed = true
	_leaving = false
	if not allowed: session.suspend_autosave(false)
	refresh()
	return allowed

func request_close() -> void:
	if _opening:
		_open_job.cancel()
		while _open_job.is_running(): await get_tree().process_frame
	if await confirm_leave(): get_tree().quit()

func is_busy() -> bool: return _opening or _leaving
