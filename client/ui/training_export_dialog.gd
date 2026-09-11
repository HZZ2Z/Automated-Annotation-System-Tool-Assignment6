## 对话框只展示控制器状态；保存、快照和后台任务归 TrainingExportController。
extends Node

const CONTROLLER := preload("res://client/services/training_export_controller.gd")

var _host: Variant
var controller: Variant
var _job: Variant:
	get: return controller._job
var _dialog: Window
var _kind: OptionButton
var _directory: LineEdit
var _browse: FileDialog
var _summary: Label
var _attestation: CheckBox
var _publish: Button
var _cancel: Button
var _result: Label
var _open_directory: Button
var _open_report: Button
var _advanced_toggle: CheckButton
var _advanced: VBoxContainer
var _technical_details: Label
var _rounds_button: Button
var _recovery: HBoxContainer
var _choose_baseline: Button
var _review_snapshot: Button
var _snapshot: Dictionary:
	get: return controller.get_snapshot()
var _generation := 0
var _preview_generation := -1
var _preview_kind := ""
var _training_summary: Dictionary = {}
var _output := ""
var last_result: Dictionary:
	get: return controller.last_result

func setup(host: Variant) -> void:
	_host = host
	controller = CONTROLLER.new()
	add_child(controller)
	controller.setup(host)
	controller.progress.connect(_on_progress)
	controller.state_changed.connect(_on_state_changed)
	_dialog = Window.new()
	_dialog.visible = false
	_dialog.title = "导出训练包"
	_dialog.exclusive = true
	_dialog.transient = true
	_dialog.min_size = Vector2i(680, 430)
	_dialog.close_requested.connect(cancel)
	add_child(_dialog)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	_dialog.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var directory_row := HBoxContainer.new()
	column.add_child(directory_row)
	_directory = LineEdit.new()
	_directory.text = ProjectSettings.globalize_path("res://output")
	_directory.placeholder_text = "训练包保存位置"
	_directory.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	directory_row.add_child(_directory)
	var browse_button := Button.new()
	browse_button.text = "选择目录…"
	directory_row.add_child(browse_button)
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
	_attestation = CheckBox.new()
	_attestation.text = "我已检查这些标注，可用于训练"
	_attestation.toggled.connect(func(_pressed: bool): _update_publish_gate())
	column.add_child(_attestation)
	_result = Label.new()
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_result)

	_recovery = HBoxContainer.new()
	column.add_child(_recovery)
	_choose_baseline = Button.new()
	_choose_baseline.text = "选择原始标注"
	_choose_baseline.pressed.connect(_open_baseline_binding)
	_recovery.add_child(_choose_baseline)
	_review_snapshot = Button.new()
	_review_snapshot.text = "导出评审快照"
	_review_snapshot.pressed.connect(_recover_review_snapshot)
	_recovery.add_child(_review_snapshot)
	_recovery.visible = false

	_advanced_toggle = CheckButton.new()
	_advanced_toggle.text = "高级选项"
	_advanced_toggle.toggled.connect(_set_advanced_visible)
	column.add_child(_advanced_toggle)
	_advanced = VBoxContainer.new()
	_advanced.visible = false
	_advanced.add_theme_constant_override("separation", 8)
	column.add_child(_advanced)
	_kind = OptionButton.new()
	_kind.add_item("训练更新包（training_update_v2）")
	_kind.add_item("全帧评审快照（包含未 verified 状态）")
	_kind.item_selected.connect(_on_kind_selected)
	_advanced.add_child(_kind)
	_rounds_button = Button.new()
	_rounds_button.text = "管理模型轮次与原始标注"
	_rounds_button.pressed.connect(_open_rounds)
	_advanced.add_child(_rounds_button)
	_technical_details = Label.new()
	_technical_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_advanced.add_child(_technical_details)

	var actions := HBoxContainer.new()
	column.add_child(actions)
	_publish = Button.new()
	_publish.text = "确认并生成训练包"
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
	_update_publish_gate()

func open() -> void:
	if is_busy(): return
	_generation += 1
	var generation := _generation
	_reset_page()
	_load_remembered_parent()
	_summary.text = "正在保存当前内容…"
	_dialog.popup_centered(Vector2i(720, 470))
	var prepared: Dictionary = await controller.prepare_one_click()
	if generation != _generation or prepared.get("cancelled", false): return
	if not prepared.get("success", false):
		_show_prepare_failure(prepared)
		return
	if not controller.can_present(prepared):
		_dialog.hide()
		return
	_training_summary = prepared.duplicate(true)
	_preview_generation = int(prepared.generation)
	_preview_kind = "training_update_v2"
	_show_training_summary()
	_update_publish_gate()

func _reset_page() -> void:
	_preview_generation = -1
	_preview_kind = ""
	_training_summary = {}
	_output = ""
	_result.text = ""
	_technical_details.text = ""
	_recovery.visible = false
	_attestation.visible = true
	_attestation.button_pressed = false
	_kind.select(0)
	_kind.disabled = false
	_advanced_toggle.set_pressed_no_signal(false)
	_advanced.visible = false
	_publish.text = "确认并生成训练包"
	_result_buttons(false)
	_update_publish_gate()

func _show_training_summary() -> void:
	if _training_summary.is_empty(): return
	_summary.text = "当前共 %d 帧，%d 帧已写入标注。\n本次将导出 %d 帧；未完成草稿和未确认空帧不包含在内。" % [
		int(_training_summary.get("total_frames", 0)), int(_training_summary.get("annotated_frames", 0)),
		int(_training_summary.get("will_export_frames", 0))]
	_technical_details.text = "已确认 %d 帧；其中空帧 %d 帧；待本次确认：%s。" % [
		int(_training_summary.get("already_verified_frames", 0)), int(_training_summary.get("verified_empty_frames", 0)),
		"是" if _training_summary.get("needs_attestation", false) else "否"]

func _show_prepare_failure(result: Dictionary) -> void:
	_preview_generation = -1
	_preview_kind = ""
	_attestation.button_pressed = false
	_recovery.visible = false
	var code := String(result.get("error_code", ""))
	_technical_details.text = "; ".join(PackedStringArray(result.get("errors", [])))
	match code:
		"baseline_input_required":
			_result.text = "需要原始标注文件才能比较修正"
			_recovery.visible = true
		"stale_context": _result.text = "当前内容已变化，请关闭后重新导出。"
		"save_failed": _result.text = "当前内容未能保存，请检查保存位置后重试。"
		"baseline_binding_failed": _result.text = "原始标注未能导入，当前内容已保留。"
		_: _result.text = "暂时无法准备导出，当前内容已保留。"
	_update_publish_gate()

func _set_advanced_visible(value: bool) -> void:
	_advanced.visible = value
	if not value and _kind.selected != 0:
		_kind.select(0)
		_attestation.visible = true
		_publish.text = "确认并生成训练包"
		_preview_kind = "training_update_v2" if not _training_summary.is_empty() else ""
		if not _training_summary.is_empty():
			_preview_generation = controller.generation()
			_show_training_summary()
		_update_publish_gate()

func _on_kind_selected(index: int) -> void:
	if not _dialog.visible or is_busy(): return
	if index == 0:
		_attestation.visible = true
		_publish.text = "确认并生成训练包"
		if not _training_summary.is_empty():
			_preview_generation = controller.generation()
			_preview_kind = "training_update_v2"
			_show_training_summary()
			_update_publish_gate()
		else: await _prepare_training_again()
	else:
		_attestation.visible = false
		_publish.text = "生成评审快照"
		await _prepare_review_preview()

func _prepare_training_again() -> void:
	_publish.disabled = true
	var generation := _generation
	_summary.text = "正在保存当前内容…"
	var prepared: Dictionary = await controller.prepare_one_click()
	if generation != _generation or prepared.get("cancelled", false): return
	if not prepared.get("success", false):
		_show_prepare_failure(prepared)
		return
	_training_summary = prepared.duplicate(true)
	_preview_generation = int(prepared.generation)
	_preview_kind = "training_update_v2"
	_show_training_summary()
	_update_publish_gate()

func _prepare_review_preview(force_prepare: bool = false) -> void:
	_publish.disabled = true
	_kind.disabled = true
	var generation := _generation
	if force_prepare or _snapshot.is_empty():
		var prepared: Dictionary = await controller.prepare()
		if generation != _generation or prepared.get("cancelled", false): return
		if not prepared.get("success", false):
			_kind.disabled = false
			_show_prepare_failure(prepared)
			return
	var result: Dictionary = await controller.preview("review_export_v1")
	if generation != _generation or not controller.can_present(result): return
	_kind.disabled = false
	if not result.get("success", false):
		_show_prepare_failure({"error_code":"preview_failed", "errors":result.get("errors", [])})
		return
	var counts: Dictionary = result.summary
	_summary.text = "评审快照：共 %d 帧，包含 %d 帧，排除 %d 帧。" % [int(counts.get("total_frames", 0)),
		int(counts.get("included_frames", 0)), int(counts.get("excluded_frames", 0))]
	_technical_details.text = "baseline=%s · round=%s · revision=%d · kind=review_export_v1\nJSONL 快照保留 verified 审核状态。" % [
		String(_snapshot.get("baseline_kind", "unknown")), String(_snapshot.get("round_id", "")), int(_snapshot.get("revision", -1))]
	_preview_generation = int(result.generation)
	_preview_kind = "review_export_v1"
	_update_publish_gate()

func _recover_review_snapshot() -> void:
	_recovery.visible = false
	_advanced_toggle.set_pressed_no_signal(true)
	_advanced.visible = true
	_kind.select(1)
	_attestation.visible = false
	_publish.text = "生成评审快照"
	await _prepare_review_preview(true)

func publish() -> void:
	if is_busy() or _snapshot.is_empty(): return
	if _preview_generation != controller.generation() or _preview_kind != _package_kind():
		_publish.disabled = true
		_result.text = "当前内容已变化，请关闭后重新导出。"
		return
	if _package_kind() == "training_update_v2" and not _attestation.button_pressed:
		_update_publish_gate()
		return
	if _directory.text.strip_edges().is_empty():
		_result.text = "请选择保存位置。"
		return
	_publish.disabled = true
	_kind.disabled = true
	var generation := _generation
	var media_id: String = String(_snapshot.get("media_id", ""))
	_dialog.hide()
	_host._set_status("正在后台生成 %s 的导出文件；可以继续编辑。" % media_id)
	var result: Dictionary
	if _package_kind() == "training_update_v2": result = await controller.confirm_and_publish(_directory.text, _attestation.button_pressed)
	else: result = await controller.publish(_directory.text, "review_export_v1")
	if not controller.belongs_to_current_session(result): return
	if generation != _generation or not controller.can_present(result):
		if not _host._review_workflow.is_busy():
			_host._set_status("导出文件已保存在：" + String(result.output_path) if result.get("success", false) else "导出已取消。")
		return
	_kind.disabled = false
	_dialog.popup_centered(Vector2i(720, 470))
	if not result.get("success", false):
		_show_publish_failure(result)
		return
	_output = String(result.output_path)
	_remember_output_parent(_directory.text)
	if _package_kind() == "training_update_v2":
		_result.text = "训练包已生成并通过检查。\n%s\n文件准备完成不表示训练已开始。" % _output
	else: _result.text = "评审快照已生成并通过检查。\n%s" % _output
	_host._set_status("训练包已生成。" if _package_kind() == "training_update_v2" else "评审快照已生成。")
	_result_buttons(true)
	_update_publish_gate()

func _show_publish_failure(result: Dictionary) -> void:
	var code := String(result.get("error_code", ""))
	_technical_details.text = "; ".join(PackedStringArray(result.get("errors", [])))
	match code:
		"stale_context": _result.text = "当前内容已变化，未生成旧版本文件；请重新导出。"
		"save_failed": _result.text = "审核结果未能保存，当前内容已保留；请检查保存位置后重试。"
		_: _result.text = "未能生成文件，当前内容已保留；可修正保存位置后重试。"
	_update_publish_gate()

func _open_baseline_binding() -> void:
	cancel()
	_host._review_workflow.rounds.call_deferred("open_baseline_binding")

func _open_rounds() -> void:
	cancel()
	_host._review_workflow.rounds.call_deferred("open")

func cancel() -> void:
	_generation += 1
	if controller.is_publishing(): _host._set_status("正在取消导出，等待当前后台步骤结束…")
	controller.cancel()
	_dialog.hide()

func cancel_and_drain() -> void:
	_generation += 1
	_dialog.hide()
	await controller.cancel_and_drain()

func is_busy() -> bool: return controller != null and controller.is_busy()
func _package_kind() -> String: return "training_update_v2" if _kind.selected == 0 else "review_export_v1"

func _update_publish_gate() -> void:
	if _publish == null: return
	var prepared: bool = _preview_generation >= 0 and _preview_generation == controller.generation() and _preview_kind == _package_kind()
	_publish.disabled = is_busy() or not prepared or (_package_kind() == "training_update_v2" and not _attestation.button_pressed)

func _result_buttons(value: bool) -> void:
	_open_directory.visible = value
	_open_report.visible = value

func _on_state_changed() -> void:
	_host._export_button.text = "取消导出" if is_busy() else "导出训练包"
	if _preview_generation >= 0 and _preview_generation != controller.generation():
		_generation += 1
		_preview_generation = -1
		_preview_kind = ""
		_update_publish_gate()
		_kind.disabled = true
		_result_buttons(false)
		_dialog.hide()

func _on_progress(value: Dictionary) -> void:
	if _snapshot.is_empty(): return
	var raw := String(value.get("message", value.get("stage", "")))
	var fraction := float(value.get("fraction", 0.0))
	_result.text = "正在准备导出内容…" if fraction <= 0.0 else ("正在写入导出文件…" if fraction < 1.0 else "正在完成检查…")
	if _advanced.visible and not raw.is_empty(): _technical_details.text = raw
	if controller.is_publishing():
		_host._set_status("正在导出 %s：%s" % [String(_snapshot.get("media_id", "")), _result.text])

func _preferences_path() -> String:
	return ProjectSettings.globalize_path(String(_host.review_session_root)).path_join("ui/export_dialog.cfg")

func _load_remembered_parent() -> void:
	var config := ConfigFile.new()
	if config.load(_preferences_path()) != OK: return
	var value := String(config.get_value("export", "last_successful_parent", "")).strip_edges()
	if not value.is_empty(): _directory.text = value

func _remember_output_parent(path: String) -> void:
	var value := ProjectSettings.globalize_path(path.strip_edges()).simplify_path()
	var config_path := _preferences_path()
	if DirAccess.make_dir_recursive_absolute(config_path.get_base_dir()) != OK: return
	var config := ConfigFile.new()
	config.set_value("export", "last_successful_parent", value)
	config.save(config_path)
