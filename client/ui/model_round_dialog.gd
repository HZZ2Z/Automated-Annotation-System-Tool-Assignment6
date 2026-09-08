## Main-thread round preview and staged activation; transaction IO stays in worker.
extends Node
const JOB := preload("res://client/services/background_job.gd")
const ROUNDS := preload("res://client/workspace/model_round_controller.gd")
var _host: Variant
var _job: Variant
var _service = ROUNDS.new()
var _dialog: Window
var _mode: OptionButton
var _input: LineEdit
var _parent: LineEdit
var _details: Label
var _validate: Button
var _commit: Button
var _cancel: Button
var _prepared: Dictionary = {}
var _context: Dictionary = {}
var _working := false
var _committing := false
var _generation := 0
var _origin_store: Variant
var _origin_revision := -1
var last_result: Dictionary = {}

func setup(host: Variant) -> void:
	_host = host
	_job = JOB.new()
	add_child(_job)
	_dialog = Window.new()
	_dialog.visible = false
	_dialog.title = "模型轮次与原始基线"
	_dialog.exclusive = true
	_dialog.transient = true
	_dialog.min_size = Vector2i(660,400)
	_dialog.close_requested.connect(cancel)
	add_child(_dialog)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left","right","top","bottom"]: margin.add_theme_constant_override("margin_"+side,18)
	_dialog.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",12)
	margin.add_child(column)
	_mode = OptionButton.new()
	_mode.add_item("导入模型新轮次")
	_mode.add_item("为旧标签绑定原始模型输出")
	column.add_child(_mode)
	_input = _path_row(column,"新轮次清单 JSON / 原始模型 JSONL",false)
	_parent = _path_row(column,"对应的训练交接包目录",true)
	_details = Label.new()
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_details)
	var row := HBoxContainer.new()
	column.add_child(row)
	_validate = Button.new()
	_validate.text = "校验并预览"
	_validate.pressed.connect(prepare)
	row.add_child(_validate)
	_commit = Button.new()
	_commit.text = "确认导入"
	_commit.pressed.connect(commit)
	row.add_child(_commit)
	_cancel = Button.new()
	_cancel.text = "取消"
	_cancel.pressed.connect(cancel)
	row.add_child(_cancel)
	_mode.item_selected.connect(func(_index: int): _invalidate())
	_input.text_changed.connect(func(_text: String): _invalidate())
	_parent.text_changed.connect(func(_text: String): _invalidate())

func _path_row(column: VBoxContainer,placeholder: String,directory: bool) -> LineEdit:
	var row := HBoxContainer.new()
	column.add_child(row)
	var input := LineEdit.new()
	input.placeholder_text = placeholder
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(input)
	var button := Button.new()
	button.text = "选择…"
	row.add_child(button)
	var picker := FileDialog.new()
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR if directory else FileDialog.FILE_MODE_OPEN_FILE
	if not directory: picker.filters = PackedStringArray(["*.json, *.jsonl ; JSON / JSONL"])
	_dialog.add_child(picker)
	picker.dir_selected.connect(func(path: String): input.text = path; _invalidate())
	picker.file_selected.connect(func(path: String): input.text = path; _invalidate())
	button.pressed.connect(func(): if not _working: picker.popup_centered_ratio(0.7))
	return input

func open() -> void:
	if _working or _host._source == null or _host._review_workflow.is_busy(): return
	if _host._is_class_dialog_active(): return
	if _host._edit_plugin != null and _host._edit_plugin.get_edit_state().get("draft_active",false):
		_host._set_status("请先完成或取消当前草稿，再导入模型轮次。")
		return
	_host._review_workflow.exports.cancel()
	_host.pause()
	_generation += 1
	_input.text = ""
	var previous: Dictionary = _host._review_workflow.exports.last_result
	_parent.text = previous.get("output_path","") if previous.get("success",false) else ""
	var snapshot: Dictionary = _host._store.freeze_snapshot()
	_mode.set_item_disabled(1,snapshot.baseline_kind != "unknown")
	_mode.select(1 if snapshot.baseline_kind == "unknown" else 0)
	last_result = {}
	_invalidate()
	_dialog.popup_centered(Vector2i(740,440))

func _invalidate() -> void:
	_prepared = {}
	_commit.disabled = true
	_parent.get_parent().visible = _mode.selected == 0
	_details.text = "新轮次会保留旧轮次文件，修正初值来自新模型，验证、批量状态和撤销历史重新开始。" if _mode.selected == 0 else "请选择本媒体完整的原始模型输出。现有人工修正和验证状态将保留；绑定成功后可生成正式差异包。"

func prepare() -> void:
	if _working or _input.text.strip_edges().is_empty(): return
	_working = true
	_generation += 1
	var generation := _generation
	_origin_store = _host._store
	var session = _host._workspace_session
	session.suspend_autosave(true)
	_set_working(true)
	_details.text = "正在保存当前版本，随后校验输入…"
	var errors: PackedStringArray = await session.flush_before_context_change()
	if generation != _generation:
		_end_work()
		return
	if not errors.is_empty() or _origin_store != _host._store:
		_end_work()
		_details.text = "无法准备："+"; ".join(errors)
		return
	_context = {"snapshot":_origin_store.freeze_snapshot(),"save_options":_host._workspace_label_store.save_options(),"parent_package_path":_parent.text.strip_edges()}
	_origin_revision = _context.snapshot.revision
	var method := "prepare_round" if _mode.selected == 0 else "prepare_baseline_binding"
	errors = _job.start(Callable(_service,method),[_context,_input.text.strip_edges()])
	if not errors.is_empty():
		_end_work()
		_details.text = "; ".join(errors)
		return
	var result: Dictionary = await _job.finished
	_end_work()
	if generation != _generation: return
	if not result.get("success",false):
		_details.text = "; ".join(result.get("errors",["无法校验输入"]))
		return
	_prepared = result
	var target: Dictionary = result.snapshot
	_details.text = "校验通过：%s\n轮次 %s → %s · 模型 %s\n完整覆盖 %d 帧。\n%s" % [target.media_id,_context.snapshot.round_id,target.round_id,target.model_revision,target.frame_entries.size(),"旧轮次将归档。新轮次的验证、批量状态和撤销历史将重置。" if _mode.selected == 0 else "原始基线将绑定；现有明确标注与验证记录保留。"]
	_commit.disabled = false

func commit() -> void:
	if _working or _prepared.is_empty(): return
	if _host._store != _origin_store or _origin_store.current_revision() != _origin_revision:
		_invalidate()
		_details.text = "当前内容已变化，请重新校验。"
		return
	# Candidate activation errors are discovered while the old UI and bytes live.
	var staged: Dictionary = _host.stage_review_replacement(_prepared.store)
	if not staged.success:
		_details.text = "; ".join(staged.errors)
		return
	if staged.store.current_revision() != _prepared.snapshot.revision:
		_host.discard_review_replacement(staged)
		_details.text = "编辑插件改变了候选内容，导入已停止。"
		return
	_working = true
	_committing = true
	var generation := _generation
	_set_working(true)
	_host._workspace_session.suspend_autosave(true)
	_details.text = "正在重新校验并保存轮次…"
	var worker_input := _prepared.duplicate()
	worker_input.erase("store")
	var method := "commit_round" if _mode.selected == 0 else "commit_baseline_binding"
	var errors: PackedStringArray = _job.start(Callable(_service,method),[_context,worker_input])
	if not errors.is_empty():
		_host.discard_review_replacement(staged)
		_end_work()
		_details.text = "; ".join(errors)
		return
	var result: Dictionary = await _job.finished
	last_result = result
	if result.get("success",false):
		# Successful publication is authoritative even if cancellation arrived late.
		_host.adopt_review_replacement(result,staged)
		_details.text = "已导入轮次 %s。\n%s" % [result.snapshot.round_id,"旧轮次："+result.archive_path if not result.archive_path.is_empty() else "原始基线已绑定。"]
		_host._set_status("当前模型轮次："+String(result.snapshot.round_id))
	else:
		_host.discard_review_replacement(staged)
		_details.text = "导入失败，当前会话已保留："+"; ".join(result.get("errors",[]))
	_prepared = {}
	_end_work()
	_commit.disabled = true
	if generation != _generation: _dialog.hide()

func cancel() -> void:
	_generation += 1
	_job.cancel()
	_prepared = {}
	if not _committing: _dialog.hide()

func cancel_and_drain() -> void:
	cancel()
	while _working or _job.is_running(): await get_tree().process_frame
	_dialog.hide()

func _set_working(value: bool) -> void:
	_validate.disabled = value
	_commit.disabled = true
	_mode.disabled = value
	_input.editable = not value
	_parent.editable = not value
	_host._review_workflow.refresh()

func _end_work() -> void:
	_working = false
	_committing = false
	_host._workspace_session.suspend_autosave(false)
	_set_working(false)

func is_busy() -> bool: return _working or (_job != null and _job.is_running())
