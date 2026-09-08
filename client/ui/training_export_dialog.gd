## Export preview and execution use one frozen, saved revision.
extends Node

const JOB := preload("res://client/services/background_job.gd")
const PACKAGE := preload("res://client/feedback/training_package.gd")

var _host: Variant
var _job: Variant
var _dialog: Window
var _kind: OptionButton
var _directory: LineEdit
var _browse: FileDialog
var _summary: Label
var _publish: Button
var _cancel: Button
var _result: Label
var _open_directory: Button
var _open_report: Button
var _snapshot: Dictionary = {}
var _generation := 0
var _preparing := false
var _exporting := false
var _output := ""
var _package = PACKAGE.new()
var last_result: Dictionary = {}

func setup(host: Variant) -> void:
	_host = host
	_job = JOB.new()
	add_child(_job)
	_job.progress.connect(_on_progress)
	_dialog = Window.new()
	_dialog.visible = false
	_dialog.title = "导出标注与训练交接包"
	_dialog.exclusive = true
	_dialog.transient = true
	_dialog.min_size = Vector2i(650,420)
	_dialog.close_requested.connect(cancel)
	add_child(_dialog)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","top","right","bottom"]: margin.add_theme_constant_override("margin_"+side,18)
	_dialog.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",12)
	margin.add_child(column)
	_kind = OptionButton.new()
	_kind.add_item("训练交接包：仅已验证帧")
	_kind.add_item("全帧评审快照：包含未验证状态")
	_kind.item_selected.connect(func(_index: int): _refresh_preview())
	column.add_child(_kind)
	var row := HBoxContainer.new()
	column.add_child(row)
	_directory = LineEdit.new()
	_directory.text = ProjectSettings.globalize_path("res://output")
	_directory.placeholder_text = "目标目录"
	_directory.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_directory)
	var browse_button := Button.new()
	browse_button.text = "选择目录…"
	row.add_child(browse_button)
	_browse = FileDialog.new()
	_browse.access = FileDialog.ACCESS_FILESYSTEM
	_browse.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_browse.dir_selected.connect(func(path: String): _directory.text = path)
	_dialog.add_child(_browse)
	browse_button.pressed.connect(func(): _browse.popup_centered_ratio(0.7))
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_summary)
	_result = Label.new()
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_result)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	_publish = Button.new()
	_publish.text = "生成文件包"
	_publish.pressed.connect(publish)
	actions.add_child(_publish)
	_cancel = Button.new()
	_cancel.text = "取消"
	_cancel.pressed.connect(cancel)
	actions.add_child(_cancel)
	_open_directory = Button.new()
	_open_directory.text = "打开目录"
	_open_directory.pressed.connect(func(): OS.shell_open(_output))
	actions.add_child(_open_directory)
	_open_report = Button.new()
	_open_report.text = "打开差异报告"
	_open_report.pressed.connect(func(): OS.shell_open(_output.path_join("reports/diff.csv")))
	actions.add_child(_open_report)
	_result_buttons(false)

func open() -> void:
	if is_busy() or _host._source == null: return
	if not _host._prepare_edit_navigation(): return
	_host.pause()
	_generation += 1
	var generation := _generation
	var store = _host._store
	_preparing = true
	_snapshot = {}
	_result.text = ""
	_result_buttons(false)
	_publish.disabled = true
	_kind.disabled = true
	_summary.text = "正在保存当前版本并准备覆盖范围…"
	_dialog.popup_centered(Vector2i(720,450))
	# The modal preparation stage blocks UI edits. Guard programmatic edits too.
	var errors: PackedStringArray = await _host._workspace_session.flush_before_context_change()
	if generation != _generation: return
	if not errors.is_empty() or store != _host._store:
		_preparing = false
		_summary.text = "无法导出：" + "; ".join(errors)
		return
	_snapshot = store.freeze_snapshot()
	if _snapshot.revision > _host._workspace_session.saved_revision():
		_preparing = false
		_summary.text = "内容在准备期间发生变化，请重新打开导出。"
		return
	_preparing = false
	_kind.disabled = false
	await _refresh_preview()

func _refresh_preview() -> void:
	if _snapshot.is_empty() or _job.is_running(): return
	_preparing = true
	_publish.disabled = true
	_kind.disabled = true
	var generation := _generation
	var errors: PackedStringArray = _job.start(Callable(_package,"preview"),[_snapshot,{"kind":_package_kind()}])
	if not errors.is_empty():
		_summary.text = "; ".join(errors)
		_preparing = false
		_kind.disabled = false
		return
	var result: Dictionary = await _job.finished
	if generation != _generation: return
	_preparing = false
	_kind.disabled = false
	if not result.get("success",false):
		_summary.text = "; ".join(result.get("errors",["无法生成预览"]))
		return
	var counts: Dictionary = result.summary
	_summary.text = "媒体 %s · 轮次 %s · 版本 %d\n总帧数 %d · 包含 %d · 排除 %d\n变化帧 %d · 变化对象 %d\n新增 %d · 删除 %d · 类别变化 %d · 几何变化 %d · 属性变化 %d" % [_snapshot.media_id,_snapshot.round_id,_snapshot.revision,counts.total_frames,counts.included_frames,counts.excluded_frames,counts.changed_frames,counts.changed_regions,counts.added,counts.deleted,counts.label_changed,counts.geometry_changed,counts.attributes_changed]
	if _kind.selected == 1: _summary.text += "\n全帧快照保留审核状态；未验证帧不属于已审核训练真值。"
	_publish.disabled = false

func publish() -> void:
	if is_busy() or _snapshot.is_empty(): return
	if _directory.text.strip_edges().is_empty():
		_result.text = "请选择目标目录。"
		return
	if _host._feedback_plugin == null or not _host._feedback_plugin.has_method("export_package"):
		_result.text = "当前 Feedback 插件不支持 training_update_v2。"
		return
	_exporting = true
	_publish.disabled = true
	_kind.disabled = true
	var generation := _generation
	var errors: PackedStringArray = _job.start(Callable(_host._feedback_plugin,"export_package"),[_snapshot,{"kind":_package_kind(),"output_parent":_directory.text.strip_edges()}])
	if not errors.is_empty():
		_exporting = false
		_result.text = "; ".join(errors)
		return
	# A frozen revision is now in the worker. The user can continue editing.
	_dialog.hide()
	_host._export_button.text = "取消导出"
	_host._set_status("正在后台生成 %s 的交接包；可以继续编辑。" % _snapshot.media_id)
	var result: Dictionary = await _job.finished
	_exporting = false
	_host._export_button.text = "Export"
	last_result = result
	if generation != _generation:
		if result.get("success",false):
			_host._set_status("文件包已发布，结果保留在："+String(result.output_path))
		else:
			_host._set_status("导出已取消。")
		return
	_kind.disabled = false
	_publish.disabled = false
	_dialog.popup_centered(Vector2i(720,450))
	if not result.get("success",false):
		_result.text = "; ".join(result.get("errors",["导出失败"]))
		return
	_output = result.output_path
	_result.text = "文件包已生成并通过校验。覆盖 %d 帧，版本 %d。\n%s\n文件交接完成不表示训练已开始。" % [result.summary.included_frames,result.revision,_output]
	_result_buttons(true)
	# Export must not mark current edits saved or reviews verified.

func cancel() -> void:
	_generation += 1
	_job.cancel()
	if _exporting: _host._set_status("正在取消导出，等待当前后台步骤结束…")
	_preparing = false
	_dialog.hide()

func cancel_and_drain() -> void:
	cancel()
	while _job.is_running(): await get_tree().process_frame
	_exporting = false

func is_busy() -> bool: return _preparing or _exporting or (_job != null and _job.is_running())
func _package_kind() -> String: return "training_update_v2" if _kind.selected == 0 else "review_export_v1"

func _result_buttons(value: bool) -> void:
	_open_directory.visible = value
	_open_report.visible = value

func _on_progress(value: Dictionary) -> void:
	_result.text = String(value.get("message",value.get("stage","正在处理…")))
	if _exporting: _host._set_status("导出 %s：%s" % [_snapshot.media_id,_result.text])
