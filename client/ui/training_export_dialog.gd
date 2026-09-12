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
var _coco_options: VBoxContainer
var _task: OptionButton
var _frame_subset: LineEdit
var _refresh_coco: Button
var _segmentation_attestation: CheckBox
var _box_fallback: CheckBox
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
var _coco_summary: Dictionary = {}
var _kind_values: Array[String] = []
var _output := ""
var _last_published_kind := ""
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
	_dialog.min_size = Vector2i(760, 570)
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

	_coco_options = VBoxContainer.new()
	_coco_options.add_theme_constant_override("separation", 6)
	column.add_child(_coco_options)
	var task_row := HBoxContainer.new()
	_coco_options.add_child(task_row)
	var task_label := Label.new()
	task_label.text = "训练任务"
	task_row.add_child(task_label)
	_task = OptionButton.new()
	_task.add_item("目标检测（bbox，可保留可信 mask）")
	_task.add_item("实例分割（每个目标都必须有当前 mask）")
	_task.item_selected.connect(_on_task_selected)
	_task.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	task_row.add_child(_task)
	var scope_row := HBoxContainer.new()
	_coco_options.add_child(scope_row)
	_frame_subset = LineEdit.new()
	_frame_subset.placeholder_text = "可选帧范围：留空=全部 Source 帧；或输入 25, 50"
	_frame_subset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_frame_subset.text_submitted.connect(func(_value: String): _prepare_coco_preview())
	scope_row.add_child(_frame_subset)
	_refresh_coco = Button.new()
	_refresh_coco.text = "更新预览"
	_refresh_coco.pressed.connect(_prepare_coco_preview)
	scope_row.add_child(_refresh_coco)
	_segmentation_attestation = CheckBox.new()
	_segmentation_attestation.text = "我已按掩码而不只是框，复核本次实例分割范围"
	_coco_options.add_child(_segmentation_attestation)
	_box_fallback = CheckBox.new()
	_box_fallback.text = "检测任务允许省略无效原始掩码，只保留合法框并记录警告"
	_coco_options.add_child(_box_fallback)
	_coco_options.visible = false

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
	_open_report.pressed.connect(func(): OS.shell_open(_report_path()))
	actions.add_child(_open_report)
	_result_buttons(false)
	_update_publish_gate()

func open() -> void:
	if is_busy(): return
	_generation += 1
	var generation := _generation
	_configure_kind_options()
	_reset_page()
	_load_remembered_parent()
	_summary.text = "正在保存当前内容…"
	_dialog.popup_centered(Vector2i(800, 620))
	if _package_kind() == "training_coco_v1":
		await _prepare_coco_preview()
		return
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
	_coco_summary = {}
	_output = ""
	_last_published_kind = ""
	_result.text = ""
	_technical_details.text = ""
	_recovery.visible = false
	_attestation.button_pressed = false
	_kind.select(0)
	_kind.disabled = false
	_advanced_toggle.set_pressed_no_signal(false)
	_advanced.visible = false
	_task.select(0)
	_frame_subset.text = ""
	_segmentation_attestation.button_pressed = false
	_box_fallback.button_pressed = false
	_apply_kind_presentation()
	_set_coco_controls_enabled(true)
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


func _show_coco_summary() -> void:
	if _coco_summary.is_empty():
		return
	var coverage: Dictionary = _coco_summary.get("coverage", {})
	var summary: Dictionary = _coco_summary.get("summary", {})
	var task_label := "目标检测" if _task_value() == "detection" else "实例分割"
	var included_ids: Array = coverage.get("included_frame_ids", [])
	var verified := {}
	for frame_id: Variant in coverage.get("verified_frame_ids", []):
		verified[int(frame_id)] = true
	var included_verified := 0
	for frame_id: Variant in included_ids:
		if verified.has(int(frame_id)):
			included_verified += 1
	var included_count := int(coverage.get("included_frames", summary.get("included_frames", 0)))
	var unverified_count := maxi(0, included_count - included_verified)
	_summary.text = "COCO 训练包（%s）：Source 共 %d 帧，本次纳入 %d 帧；其中当前内容已审核 %d 帧，沿用旧版或未审核 %d 帧，零目标帧 %d 帧。\n" % [
		task_label,
		int(coverage.get("total_frames", summary.get("total_frames", 0))),
		included_count,
		included_verified,
		unverified_count,
		int(coverage.get("negative_frames", summary.get("negative_frames", 0))),
	]
	if String(coverage.get("policy", "")) == "all_source_frames":
		_summary.text += "所有 Source 帧都进入包；已保留每帧的审核和标注来源状态。"
	else:
		_summary.text += "未选中的帧不会进入包；已保留每帧的审核和标注来源状态。"
	var dataset: Dictionary = _coco_summary.get("dataset", {})
	var warning_codes := PackedStringArray()
	for warning: Variant in _coco_summary.get("warnings", []):
		if warning is Dictionary:
			warning_codes.append(String(warning.get("code", "")))
	_technical_details.text = "kind=training_coco_v1 · task=%s · split=%s · revision=%d · package=%s" % [
		_task_value(), String(dataset.get("source_split", "")),
		int(_coco_summary.get("saved_revision", -1)),
		String(_coco_summary.get("package_id", "")).left(12),
	]
	if not warning_codes.is_empty():
		_technical_details.text += "\n警告：" + ", ".join(warning_codes)


func _configure_kind_options() -> void:
	_kind.clear()
	_kind_values.clear()
	if controller.supports_coco_export():
		_kind.add_item("COCO 训练包（training_coco_v1，推荐）")
		_kind_values.append("training_coco_v1")
	_kind.add_item("训练更新包（training_update_v2，旧协议）")
	_kind_values.append("training_update_v2")
	_kind.add_item("全帧评审快照（包含未 verified 状态）")
	_kind_values.append("review_export_v1")


func _apply_kind_presentation() -> void:
	var kind := _package_kind()
	_coco_options.visible = kind == "training_coco_v1"
	_attestation.visible = kind != "review_export_v1"
	match kind:
		"training_coco_v1":
			_attestation.text = "我确认训练包包含全部 Source 帧；无标注帧在 COCO 中是零目标图像"
			_publish.text = "生成 COCO 训练包"
		"training_update_v2":
			_attestation.text = "我已检查这些标注，可用于训练"
			_publish.text = "确认并生成训练包"
		_:
			_publish.text = "生成评审快照"
	_sync_coco_task_controls()


func _sync_coco_task_controls() -> void:
	var segmentation := _task_value() == "instance_segmentation"
	_segmentation_attestation.visible = _coco_options.visible and segmentation
	_box_fallback.visible = _coco_options.visible and not segmentation


func _on_task_selected(_index: int) -> void:
	_sync_coco_task_controls()
	_preview_generation = -1
	_preview_kind = ""
	_coco_summary = {}
	_summary.text = "训练任务已切换，正在自动重新检查…"
	_result.text = ""
	_technical_details.text = ""
	_update_publish_gate()
	call_deferred("_prepare_coco_preview")

func _show_prepare_failure(result: Dictionary) -> void:
	_preview_generation = -1
	_preview_kind = ""
	_attestation.button_pressed = false
	_recovery.visible = false
	_summary.text = "检查未通过，本次不会生成训练包。"
	var code := String(result.get("error_code", ""))
	_technical_details.text = "; ".join(PackedStringArray(result.get("errors", [])))
	match code:
		"baseline_input_required":
			_result.text = "需要原始标注文件才能比较修正"
			_recovery.visible = true
		"stale_context": _result.text = "当前内容已变化，请关闭后重新导出。"
		"save_failed": _result.text = "当前内容未能保存，请检查保存位置后重试。"
		"baseline_binding_failed": _result.text = "原始标注未能导入，当前内容已保留。"
		"no_verified_frames": _result.text = "当前没有内容摘要仍有效的已审核帧。"
		"segmentation_required": _result.text = _segmentation_required_message(result)
		"unknown_category": _result.text = _unknown_category_message(result)
		"incomplete_frame_annotation": _result.text = "来源导入曾跳过对象或选中帧不完整，不能当作完整真值。"
		"package_invalid": _result.text = "导出数据格式校验失败：" + _first_export_error(result)
		"source_metadata_required": _result.text = "原图或 COCO 元数据不完整：" + _first_export_error(result)
		"image_missing": _result.text = "纳入范围内有原图缺失：" + _first_export_error(result)
		"image_corrupt": _result.text = "纳入范围内有原图无法读取：" + _first_export_error(result)
		"invalid_geometry": _result.text = "选中帧包含无效标注几何：" + _first_export_error(result)
		_: _result.text = "无法准备导出：" + _first_export_error(result)
	_update_publish_gate()


func _first_export_error(result: Dictionary) -> String:
	var errors: PackedStringArray = PackedStringArray(result.get("errors", []))
	if errors.is_empty():
		return "没有收到可识别的错误信息，请重新打开 Source 后重试。"
	var message := errors[0]
	var separator := message.find(": ")
	return message.substr(separator + 2) if separator >= 0 else message


func _unknown_category_message(result: Dictionary) -> String:
	var labels := PackedStringArray()
	var frames := {}
	var allowed := ""
	for value: Variant in result.get("issues", []):
		if not value is Dictionary or String(value.get("code", "")) != "UNKNOWN_CATEGORY":
			continue
		var message := String(value.get("message", ""))
		var prefix := "Unknown category: "
		var label := message.substr(prefix.length()).get_slice(".", 0).strip_edges() \
			if message.begins_with(prefix) else ""
		if not label.is_empty() and label not in labels:
			labels.append(label)
		var allowed_prefix := "Allowed source categories: "
		var allowed_at := message.find(allowed_prefix)
		if allowed.is_empty() and allowed_at >= 0:
			allowed = message.substr(allowed_at + allowed_prefix.length()).replace(", ", "、")
		if value.has("frame_id"):
			frames[int(value.frame_id)] = true
	var names := "、".join(labels) if not labels.is_empty() else "未知类别"
	var suffix := "（涉及 %d 帧）" % frames.size() if not frames.is_empty() else ""
	var allowed_suffix := " 可用类别：%s。" % allowed if not allowed.is_empty() else ""
	return "类别“%s”不在当前 Source 的 COCO 类别表中%s；请改为原始类别后更新预览。%s" % [names, suffix, allowed_suffix]


func _segmentation_required_message(result: Dictionary) -> String:
	var frames := {}
	for value: Variant in result.get("issues", []):
		if value is Dictionary and String(value.get("code", "")) == "SEGMENTATION_REQUIRED" \
				and value.has("frame_id"):
			frames[int(value.frame_id)] = true
	var frame_ids: Array = frames.keys()
	frame_ids.sort()
	var location := ""
	if not frame_ids.is_empty():
		location = "（%d 帧，首个原始帧号 %d）" % [frame_ids.size(), int(frame_ids[0])]
	return "实例分割范围内有目标缺少当前有效 mask%s；请补齐 mask、排除这些帧，或改选目标检测。" % location

func _set_advanced_visible(value: bool) -> void:
	_advanced.visible = value
	if not value and _kind.selected != 0:
		_kind.select(0)
		_apply_kind_presentation()
		if _package_kind() == "training_coco_v1":
			_prepare_coco_preview()
		elif not _training_summary.is_empty():
			_preview_kind = "training_update_v2"
			_preview_generation = controller.generation()
			_show_training_summary()
			_update_publish_gate()
		else:
			_prepare_training_again()

func _on_kind_selected(index: int) -> void:
	if not _dialog.visible or is_busy(): return
	if index < 0 or index >= _kind_values.size():
		return
	_apply_kind_presentation()
	match _package_kind():
		"training_coco_v1":
			await _prepare_coco_preview()
		"training_update_v2":
			if not _training_summary.is_empty():
				_preview_generation = controller.generation()
				_preview_kind = "training_update_v2"
				_show_training_summary()
				_update_publish_gate()
			else:
				await _prepare_training_again()
		_:
			await _prepare_review_preview()


func _prepare_coco_preview() -> void:
	if is_busy() or _package_kind() != "training_coco_v1":
		return
	_coco_summary = {}
	_result.text = ""
	_technical_details.text = ""
	var parsed := _parse_frame_subset()
	if not parsed.get("success", false):
		_show_prepare_failure({
			"error_code": "package_invalid",
			"errors": parsed.get("errors", []),
		})
		return
	_publish.disabled = true
	_preview_generation = -1
	_preview_kind = ""
	_set_coco_controls_enabled(false)
	var generation := _generation
	_summary.text = "正在保存当前内容并核对原图与 COCO 元数据…"
	var selected: Variant = parsed.get("frames")
	var prepared: Dictionary = await controller.prepare_coco(
		_task_value(),
		selected,
		_segmentation_attestation.button_pressed,
		_box_fallback.button_pressed,
	)
	if generation != _generation or prepared.get("cancelled", false):
		return
	_set_coco_controls_enabled(true)
	if not prepared.get("success", false):
		_coco_summary = {}
		_show_prepare_failure(prepared)
		return
	if not controller.can_present(prepared):
		_dialog.hide()
		return
	_coco_summary = prepared.duplicate(true)
	_preview_generation = int(prepared.generation)
	_preview_kind = "training_coco_v1"
	_show_coco_summary()
	_result.text = "检查完成，可以生成训练包。"
	_update_publish_gate()


func _parse_frame_subset() -> Dictionary:
	var text := _frame_subset.text.strip_edges().replace("，", ",")
	if text.is_empty():
		return {"success": true, "frames": null}
	var frames: Array[int] = []
	var seen := {}
	for token: String in text.replace(",", " ").split(" ", false):
		if not token.is_valid_int() or int(token) < 0 or seen.has(int(token)):
			return {
				"success": false,
				"errors": ["帧范围必须是不重复的非负整数，用逗号或空格分隔。"],
			}
		seen[int(token)] = true
		frames.append(int(token))
	return {"success": true, "frames": frames}


func _set_coco_controls_enabled(enabled: bool) -> void:
	_task.disabled = not enabled
	_frame_subset.editable = enabled
	_refresh_coco.disabled = not enabled
	_segmentation_attestation.disabled = not enabled
	_box_fallback.disabled = not enabled
	_kind.disabled = not enabled


func _task_value() -> String:
	return "instance_segmentation" if _task != null and _task.selected == 1 else "detection"

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
	_select_kind("review_export_v1")
	_apply_kind_presentation()
	_attestation.visible = false
	_publish.text = "生成评审快照"
	await _prepare_review_preview(true)

func publish() -> void:
	if is_busy() or _snapshot.is_empty(): return
	if _preview_generation != controller.generation() or _preview_kind != _package_kind():
		_publish.disabled = true
		_result.text = "当前内容已变化，请关闭后重新导出。"
		return
	var kind := _package_kind()
	if kind in ["training_update_v2", "training_coco_v1"] and not _attestation.button_pressed:
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
	if kind == "training_coco_v1":
		result = await controller.publish_coco(_directory.text, _attestation.button_pressed)
	elif kind == "training_update_v2":
		result = await controller.confirm_and_publish(_directory.text, _attestation.button_pressed)
	else:
		result = await controller.publish(_directory.text, "review_export_v1")
	if not controller.belongs_to_current_session(result): return
	if generation != _generation or not controller.can_present(result):
		if not _host._review_workflow.is_busy():
			_host._set_status("导出文件已保存在：" + String(result.output_path) if result.get("success", false) else "导出已取消。")
		return
	_kind.disabled = false
	_dialog.popup_centered(Vector2i(800, 620))
	if not result.get("success", false):
		_show_publish_failure(result)
		return
	_output = String(result.output_path)
	_last_published_kind = kind
	_remember_output_parent(_directory.text)
	if kind == "training_coco_v1":
		_result.text = "COCO 训练包已生成并通过独立检查。\n%s\n包内含预览所列的全部或所选 Source 帧；每帧保留审核状态和标注来源。" % _output
		if result.get("reused", false):
			_result.text += "\n已复用通过完整校验的现有包；本次请求修订 %d，包内记录修订 %d。" % [
				int(result.get("saved_revision", -1)),
				int(result.get("package_saved_revision", -1)),
			]
	elif kind == "training_update_v2":
		_result.text = "训练包已生成并通过检查。\n%s\n文件准备完成不表示训练已开始。" % _output
	else: _result.text = "评审快照已生成并通过检查。\n%s" % _output
	_host._set_status("评审快照已生成。" if kind == "review_export_v1" else "训练包已生成。")
	_result_buttons(true)
	_update_publish_gate()

func _show_publish_failure(result: Dictionary) -> void:
	var code := String(result.get("error_code", ""))
	_technical_details.text = "; ".join(PackedStringArray(result.get("errors", [])))
	match code:
		"stale_context": _result.text = "当前内容已变化，未生成旧版本文件；请重新导出。"
		"save_failed": _result.text = "审核结果未能保存，当前内容已保留；请检查保存位置后重试。"
		"source_changed": _result.text = "原图或原始 COCO 在预览后已变化，未混合发布。"
		"destination_conflict": _result.text = "目标位置已有不同内容或正被另一导出使用，未覆盖。"
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
func _package_kind() -> String:
	if _kind == null or _kind.selected < 0 or _kind.selected >= _kind_values.size():
		return ""
	return _kind_values[_kind.selected]


func _select_kind(value: String) -> bool:
	var index := _kind_values.find(value)
	if index < 0:
		return false
	_kind.select(index)
	return true

func _update_publish_gate() -> void:
	if _publish == null: return
	var prepared: bool = _preview_generation >= 0 and _preview_generation == controller.generation() and _preview_kind == _package_kind()
	var requires_scope := _package_kind() in ["training_update_v2", "training_coco_v1"]
	_publish.disabled = is_busy() or not prepared or (requires_scope and not _attestation.button_pressed)

func _result_buttons(value: bool) -> void:
	_open_directory.visible = value
	_open_report.visible = value


func _report_path() -> String:
	if _output.is_empty():
		return ""
	return _output.path_join(
		"reports/diff.json" if _last_published_kind == "training_coco_v1" else "reports/diff.csv")

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
