## 批量页面协调器：界面意图接入现有播放、历史与持久会话。
extends Node

const CONTROLLER := preload("res://client/services/batch_controller.gd")
const REVIEW := preload("res://client/domain/commands/review_frames_command.gd")
const RANGE_MODEL := preload("res://client/ui/batch_range_model.gd")
var controller = CONTROLLER.new()
var _host: Variant
var _store: Variant
var _panel: VBoxContainer
var _scroll: ScrollContainer
var _info: Label
var _summary: Label
var _current: Label
var _first_entry: OptionButton
var _last_entry: OptionButton
var _range_controls: HBoxContainer
var _range_model = RANGE_MODEL.new()
var _threshold: SpinBox
var _mode: OptionButton
var _algorithm: OptionButton
var _algorithm_hint: Label
var _show_preview: CheckButton
var _auto: CheckButton
var _apply: Button
var _verify_range: Button
var _analyze: Button
var _guarded_buttons: Array[Button] = []
var _range := Vector2i(-1, -1)
var _preview := false
var _setting := false
var _content: VBoxContainer
var _advanced: VBoxContainer
var _details: Label
var _key_label: Label
var _mode_hint: Label
var _preview_note: Label
var _verify_current: Button
var _retry: Button
var _edges: HBoxContainer
var _cancel: Button
var _annotation_tab: Button
var _batch_tab: Button
var _next_contiguous: Button

func setup(host: Variant, sidebar: VBoxContainer) -> void:
	_host = host
	# 批量页优先使用无衬线中文字体，缺失时由系统回退。
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Noto Sans CJK SC", "Microsoft YaHei", "PingFang SC", "sans-serif"])
	var page_theme := Theme.new()
	page_theme.default_font = font
	page_theme.default_font_size = 14
	var tabs := HBoxContainer.new()
	tabs.theme = page_theme
	sidebar.add_child(tabs)
	sidebar.move_child(tabs, 0)
	_annotation_tab = Button.new()
	_annotation_tab.text = "标注"
	_batch_tab = Button.new()
	_batch_tab.text = "批量"
	for tab: Button in [_annotation_tab, _batch_tab]:
		tab.toggle_mode = true
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.custom_minimum_size.y = 34
		tabs.add_child(tab)
	_scroll = ScrollContainer.new()
	_scroll.theme = page_theme
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sidebar.add_child(_scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for edge: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 8)
	_scroll.add_child(margin)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	_content.add_theme_font_size_override("font_size", 14)
	margin.add_child(_content)
	_panel = _content
	_current = _label("请先打开工作区")
	_info = _label("")
	_info.visible = false
	_preview_note = _label("预览中 · 尚未应用")
	_preview_note.add_theme_color_override("font_color", Color("#8fc8f5"))
	_preview_note.visible = false
	_section("1  选择参考帧")
	_key_label = _label("在播放器中选一帧，先修正它的标注。")
	_algorithm = OptionButton.new()
	_algorithm.add_item("固定坐标复制")
	_algorithm.add_item("Poly 光流 + 边缘精修")
	_algorithm.select(1)
	_panel.add_child(_algorithm)
	_algorithm.item_selected.connect(_select_algorithm)
	var threshold_row := HBoxContainer.new()
	_panel.add_child(threshold_row)
	var caption := Label.new()
	caption.text = "相似帧差异阈值"
	threshold_row.add_child(caption)
	_threshold = _spin(threshold_row, 0.001, 1.0, 0.02, 0.001)
	_threshold.tooltip_text = "只控制相邻/关键帧相似度；越小越保守。光流质量门固定，每批最多 30 帧。"
	_threshold.value_changed.connect(func(_value: float): cancel())
	_analyze = _button("分析 Poly 光流与边缘", analyze)
	_section("2  应用标注")
	_range_controls = HBoxContainer.new()
	_panel.add_child(_range_controls)
	_first_entry = OptionButton.new()
	_first_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_first_entry.tooltip_text = "起始候选帧，只能缩短候选范围"
	_range_controls.add_child(_first_entry)
	var through := Label.new()
	through.text = "至"
	_range_controls.add_child(through)
	_last_entry = OptionButton.new()
	_last_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_last_entry.tooltip_text = "结束候选帧，范围必须包含参考帧"
	_range_controls.add_child(_last_entry)
	_range_controls.visible = false
	_first_entry.item_selected.connect(func(_option: int): _update_preview())
	_last_entry.item_selected.connect(func(_option: int): _update_preview())
	_edges = HBoxContainer.new()
	_panel.add_child(_edges)
	for pair: Array in [["首帧", "first"], ["末帧", "last"]]:
		var button := Button.new()
		button.text = pair[0]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_boundary.bind(pair[1]))
		_edges.add_child(button)
	_mode = OptionButton.new()
	_mode.add_item("覆盖目标标注")
	_mode.add_item("合并，保留其他标注")
	_mode.select(1)
	_panel.add_child(_mode)
	_mode.item_selected.connect(_select_mode)
	_mode_hint = _label("更新同 ID 的 Poly，保留目标帧独有区域。")
	_mode_hint.add_theme_color_override("font_color", Color("#b4bac5"))
	_summary = _label("尚未选择范围")
	_next_contiguous = _button("跳到下一段连续帧", _jump_to_next_contiguous, false)
	_next_contiguous.visible = false
	_show_preview = CheckButton.new()
	_show_preview.text = "预览传播结果"
	_panel.add_child(_show_preview)
	_show_preview.toggled.connect(_toggle_preview)
	var action_row := HBoxContainer.new()
	_panel.add_child(action_row)
	_apply = _button("应用到所选帧", apply)
	_apply.reparent(action_row)
	_apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply.custom_minimum_size.y = 36
	var primary := StyleBoxFlat.new()
	primary.bg_color = Color("#365b77")
	primary.set_corner_radius_all(4)
	_apply.add_theme_stylebox_override("normal", primary)
	_cancel = _button("取消本批", cancel, false)
	_cancel.reparent(action_row)
	_cancel.flat = true
	_section("3  检查并确认")
	var review_row := HBoxContainer.new()
	_panel.add_child(review_row)
	_verify_current = Button.new()
	_verify_current.text = "确认本帧"
	_verify_current.pressed.connect(_toggle_current_verification)
	_verify_range = Button.new()
	_verify_range.text = "确认本段"
	_verify_range.pressed.connect(verify_range)
	for button: Button in [_verify_current, _verify_range]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		review_row.add_child(button)
		_guarded_buttons.append(button)
	_button("下一待检查帧", next_unverified)
	_retry = _button("重试保存", retry_save, false)
	_retry.visible = false
	_panel = _content
	var disclosure := _button("高级设置", Callable(), false)
	disclosure.toggle_mode = true
	disclosure.flat = true
	_advanced = VBoxContainer.new()
	_advanced.add_theme_constant_override("separation", 8)
	_content.add_child(_advanced)
	_panel = _advanced
	_auto = CheckButton.new()
	_auto.text = "确认后自动前进"
	_auto.button_pressed = true
	_panel.add_child(_auto)
	_algorithm_hint = _label("只传播参考帧的 Poly；先验相似、再做光流和有界边缘精修，结果需人工检查。")
	_details = _label("分析后可在此查看范围停止原因。")
	_label("时间轴：斜线为待检查，勾号为已确认。\n蓝色为候选段，金色为已应用批次。")
	_advanced.visible = false
	disclosure.toggled.connect(func(expanded: bool): _advanced.visible = expanded)
	_annotation_tab.pressed.connect(func(): _show_tab(false))
	_batch_tab.pressed.connect(func(): _show_tab(true))
	_show_tab(false)
	refresh_current()

func _section(title: String) -> void:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#27292d")
	style.set_corner_radius_all(5)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 9
	style.content_margin_bottom = 9
	card.add_theme_stylebox_override("panel", style)
	_content.add_child(card)
	_panel = VBoxContainer.new()
	_panel.add_theme_constant_override("separation", 7)
	card.add_child(_panel)
	var heading := _label(title)
	heading.add_theme_color_override("font_color", Color("#c1cbd8"))

func _toggle_current_verification() -> void:
	if _store != null and _store.is_verified(_host._current_record_frame()):
		unverify_current()
	else:
		verify_current()

func _show_tab(batch: bool) -> void:
	if batch and (_host._is_class_dialog_active() or not _host._prepare_edit_navigation()):
		_scroll.visible = false
		_annotation_tab.set_pressed_no_signal(true)
		_batch_tab.set_pressed_no_signal(false)
		_host._annotation_sidebar.visible = true
		_host._tool_panel.visible = true
		_host._tool_panel.get_parent().get_node("Separator").visible = true
		_host._set_status("请先应用或取消当前编辑，再进入批量标注。")
		return
	_scroll.visible = batch
	_annotation_tab.set_pressed_no_signal(not batch)
	_batch_tab.set_pressed_no_signal(batch)
	_host._annotation_sidebar.visible = not batch
	_host._tool_panel.visible = not batch
	_host._tool_panel.get_parent().get_node("Separator").visible = not batch
	if not batch:
		_show_preview.button_pressed = false
	else:
		_host.pause()
	refresh_current()

func available() -> bool:
	return _host != null and _store != null and _host._source != null and _host._workspace_label_store != null

func bind_source() -> void:
	clear()
	_store = _host._store
	controller.configure(_host._source, _store, _host._history, _host._frame_entries)
	_store.corrected_records_replaced.connect(_changed)
	_store.review_state_changed.connect(_changed)
	refresh_current()
	_refresh_timeline()

func clear() -> void:
	if _store != null:
		if _store.corrected_records_replaced.is_connected(_changed):
			_store.corrected_records_replaced.disconnect(_changed)
		if _store.review_state_changed.is_connected(_changed):
			_store.review_state_changed.disconnect(_changed)
	_store = null
	if _key_label != null:
		_key_label.text = "在播放器中选一帧，先修正它的标注。"
		_summary.text = "尚未选择范围"
		_info.visible = false
	controller.configure(null, null, null, [])
	_range = Vector2i(-1, -1)
	_preview = false
	_reset_range_controls()
	if _show_preview != null:
		_show_preview.set_pressed_no_signal(false)
	set_process(false)

func analyze() -> void:
	if not _ready_for_action():
		return
	cancel()
	var errors: PackedStringArray = controller.start_polygon_analysis(_host.get_current_frame(), _threshold.value) if _algorithm.selected == 1 else controller.start_analysis(_host.get_current_frame(), _threshold.value)
	if not errors.is_empty():
		_status(errors[0])
		return
	_info.text = controller.progress_text()
	_info.visible = true
	set_process(true)
	refresh_current()

func _process(_delta: float) -> void:
	controller.step_analysis()
	if controller.is_analyzing():
		_info.text = controller.progress_text()
		return
	set_process(false)
	var plan: Dictionary = controller.get_plan()
	if plan.is_empty():
		_status(controller.last_error)
		refresh_current()
		return
	_range = Vector2i(plan.start_index, plan.end_index)
	_setting = true
	var range_errors := _range_model.configure(_host._frame_entries, int(plan.start_index), int(plan.key_index), int(plan.end_index))
	if not range_errors.is_empty():
		_setting = false
		_status(range_errors[0])
		return
	_first_entry.clear()
	_last_entry.clear()
	var first_selected := -1
	for index in range(int(plan.start_index), int(plan.key_index) + 1):
		if index == int(plan.start_index):
			first_selected = _first_entry.item_count
		_add_range_option(_first_entry, index)
	var last_selected := -1
	for index in range(int(plan.key_index), int(plan.end_index) + 1):
		if index == int(plan.end_index):
			last_selected = _last_entry.item_count
		_add_range_option(_last_entry, index)
	_first_entry.select(first_selected)
	_last_entry.select(last_selected)
	_range_controls.visible = _range_model.indices().size() > 1
	_next_contiguous.visible = _algorithm.selected == 1 and _range_model.indices().size() == 1
	var next_run := controller.find_next_contiguous_run(int(plan.end_index))
	_next_contiguous.disabled = next_run.x < 0
	_next_contiguous.tooltip_text = "没有可跳转的连续段" if next_run.x < 0 else "跳到连续原始帧段的起点"
	_setting = false
	_info.visible = false
	_key_label.text = "参考帧 %d · %d 个区域" % [plan.keyframe, _host._store.get_corrected_record(plan.keyframe).regions.size()]
	_details.text = _advanced_diagnostics(plan)
	_update_preview()
	refresh_current()

func _update_preview() -> void:
	if _setting or _store == null:
		return
	_mode_hint.text = ("只保留传播得到的参考 Poly。" if _mode.selected == 0 else "更新同 ID 的 Poly，保留目标帧独有区域。") if _algorithm.selected == 1 else ("替换目标帧的全部标注。" if _mode.selected == 0 else "同 ID 更新，保留目标帧独有区域。")
	var plan: Dictionary = controller.get_plan()
	if plan.is_empty():
		return
	var first := _selected_range_index(_first_entry)
	var last := _selected_range_index(_last_entry)
	if first < 0 or last < 0:
		_apply.disabled = true
		return
	var preview: Dictionary = controller.preview(first, last, "overwrite" if _mode.selected == 0 else "merge")
	if not preview.get("errors", []).is_empty():
		_apply.disabled = true
		return
	_range = Vector2i(first, last)
	var counts := _edge_frame_counts(plan, first, last)
	_summary.text = "候选 %d 帧 · 将修改 %d 帧 · 边缘精修 %d 帧，光流回退 %d 帧\n相似度停止：%s；光流停止：%s" % [
		maxi(0, preview.covered_count - 1), preview.changed_count, counts.x, counts.y,
		_stop_category(plan, true), _stop_category(plan, false)]
	if preview.changed_count == 0:
		var empty_text := _no_poly_candidate_summary(plan) if _algorithm.selected == 1 and preview.covered_count == 1 else "标注已一致，无需应用。"
		_summary.text = "%s\n候选 0 帧 · 边缘精修 %d 帧，光流回退 %d 帧\n相似度停止：%s；光流停止：%s" % [
			empty_text, counts.x, counts.y, _stop_category(plan, true), _stop_category(plan, false)]
	_summary.tooltip_text = "新增 %d 个区域，替换 %d 个，删除 %d 个" % [preview.added, preview.replaced, preview.removed]
	_apply.text = "应用到 %d 帧" % preview.changed_count
	if _host._store.get_corrected_record(plan.keyframe).regions.is_empty() and _mode.selected == 0:
		_apply.text = "清空 %d 帧的全部标注" % preview.changed_count
	_apply.disabled = preview.changed_count == 0
	_verify_range.text = "确认本段（%d 帧）" % preview.covered_count
	_verify_range.disabled = not available()
	_host._timeline.set_candidate(_range.x, _range.y, int(controller.get_plan().key_index))
	_render_preview()

func apply() -> void:
	if not _ready_for_action():
		return
	var first := _range.x
	var errors: PackedStringArray = controller.apply_preview()
	if not errors.is_empty():
		_status(errors[0])
		return
	_show_preview.set_pressed_no_signal(false)
	_preview = false
	_host._refresh_after_edit(false)
	if await _save():
		_summary.text = "已应用并保存，请检查后确认。"
		_status("已保存，目标帧仍待检查。")
		_host.seek(first)
	refresh_current()

func verify_current() -> void:
	await _verify(Vector2i(_host.get_current_frame(), _host.get_current_frame()), true)

func verify_range() -> void:
	await _verify(_range, true)

func unverify_current() -> void:
	await _verify(Vector2i(_host.get_current_frame(), _host.get_current_frame()), false)

func _verify(selected: Vector2i, verified: bool) -> void:
	if _preview:
		_status("请先应用或关闭预览，再确认标注。")
		return
	if not _ready_for_action() or selected.x < 0 or selected.y < selected.x:
		return
	var ids := PackedInt64Array()
	for i in range(selected.x, selected.y + 1):
		ids.append(int(_host._frame_entries[i].frame_id))
	var errors: PackedStringArray = _host._history.execute(REVIEW.new(ids, verified), _store)
	if not errors.is_empty():
		_status(errors[0])
		return
	_host._refresh_after_edit(false)
	if await _save():
		_status("确认已保存。" if verified else "已取消确认，重新标为待检查。")
		if verified and _auto.button_pressed:
			_next_after(selected.y)
	refresh_current()

func next_unverified() -> void:
	if _ready_for_action() and await _save():
		_next_after(_host.get_current_frame())

func _next_after(index: int) -> void:
	var count: int = _host._frame_entries.size()
	for offset in range(1, count + 1):
		var candidate := (index + offset) % count
		if not _store.is_verified(int(_host._frame_entries[candidate].frame_id)):
			if not _host.seek(candidate):
				_status("下一待检查帧加载失败，已停止。")
			elif candidate <= index:
				_status("已回到最早的待检查帧。")
			return
	_status("全部 %d 帧已确认。" % count)

func retry_save() -> void:
	if available() and await _save():
		_retry.visible = false
		_status("已保存。")

func _save() -> bool:
	var expected_store = _store
	var expected_revision: int = _store.current_revision()
	var expected_frame: int = _host.get_current_frame()
	var errors: PackedStringArray = await _host._flush_workspace_changes()
	if _store != expected_store or _store.current_revision() != expected_revision or _host.get_current_frame() != expected_frame:
		return false
	if not errors.is_empty():
		_retry.visible = true
		_details.text = errors[0]
		_status("保存失败，已停止前进。请重试保存。")
		return false
	_retry.visible = false
	return true

func _ready_for_action() -> bool:
	if not available():
		_status("请打开上一级工作区文件夹，再选择视频。")
		return false
	if _host._is_class_dialog_active() or not _host._prepare_edit_navigation():
		_status("请先完成当前编辑和类别选择。")
		return false
	_host.pause()
	return true

func _boundary(which: String) -> void:
	if _range.x < 0 or not _ready_for_action():
		return
	var index := _range.x
	if which == "last":
		index = _range.y
	elif which != "first":
		return
	_host.seek(index)

func cancel() -> void:
	controller.cancel()
	set_process(false)
	_preview = false
	_show_preview.set_pressed_no_signal(false)
	_range = Vector2i(-1, -1)
	_reset_range_controls()
	_host._timeline.set_candidate(-1, -1, -1)
	_summary.text = "尚未选择范围"
	_key_label.text = "在播放器中选一帧，先修正它的标注。"
	_info.visible = false
	refresh_current()

func is_previewing() -> bool:
	return _preview

func _toggle_preview(enabled: bool) -> void:
	if enabled and not _ready_for_action():
		_show_preview.set_pressed_no_signal(false)
		return
	_preview = enabled and not controller.get_plan().is_empty()
	if not _preview:
		_host._refresh_current_annotations()
	refresh_current()

func _render_preview() -> void:
	if not _preview:
		return
	var proposed: Dictionary = controller.proposed_record(_host._current_record_frame())
	if proposed.is_empty():
		proposed = _host._store.get_corrected_record(_host._current_record_frame())
	_host._viewport.set_record(proposed)
	_host._set_status("预览中，尚未应用。关闭预览后可编辑。")

func refresh_current() -> void:
	if _host == null or _current == null:
		return
	var active := available()
	var enabled: bool = active and not controller.is_analyzing() and not _host._is_class_dialog_active()
	_mode.disabled = not enabled
	_threshold.editable = enabled
	_threshold.get_parent().visible = true
	_algorithm.disabled = not active
	for button: Button in _guarded_buttons:
		button.disabled = not enabled
	_apply.disabled = not enabled or not controller.can_apply()
	_verify_range.disabled = not enabled or _range.x < 0 or _preview
	_verify_current.disabled = not enabled or _preview
	_first_entry.disabled = not enabled or controller.get_plan().is_empty() or _range_model.indices().size() <= 1
	_last_entry.disabled = _first_entry.disabled
	_show_preview.disabled = not enabled or controller.get_plan().is_empty()
	_preview_note.visible = _preview
	_cancel.visible = controller.is_analyzing() or not controller.get_plan().is_empty()
	for button: Button in _edges.get_children():
		button.disabled = not enabled or _range.x < 0
	if not active:
		_info.text = "请打开工作区文件夹，再选择视频。"
		_info.visible = true
		_current.text = "批量标注"
	else:
		var id: int = _host._current_record_frame()
		_current.text = "当前帧 %d · %s" % [id, "已确认" if _store.is_verified(id) else "待检查"]
		_verify_current.text = "取消本帧确认" if _store.is_verified(id) else "确认本帧"
	_render_preview()

func _changed(_frames: Variant = null) -> void:
	_preview = false
	_show_preview.set_pressed_no_signal(false)
	_host._timeline.set_candidate(-1, -1, -1)
	_summary.text = "标注已变化，应用前请重新查找。"
	_refresh_timeline()
	refresh_current()

func _refresh_timeline() -> void:
	if _store == null:
		return
	var mapping := {}
	for i in range(_host._frame_entries.size()):
		var id := int(_host._frame_entries[i].frame_id)
		mapping[id] = i
		_host._timeline.set_verified(i, _store.is_verified(id))
	var ranges: Array = []
	for marker: Dictionary in _store.snapshot_batch_operations():
		if mapping.has(int(marker.get("start_frame", -1))) and mapping.has(int(marker.get("end_frame", -1))):
			ranges.append({"start_frame": mapping[int(marker.start_frame)], "end_frame": mapping[int(marker.end_frame)]})
	_host._timeline.set_batch_ranges(ranges)

func _status(message: String) -> void:
	var text := message
	# 底层错误保留在详情中；主流程使用简短、可行动的中文提示。
	var contains_chinese := false
	for i in range(message.length()):
		if message.unicode_at(i) >= 0x4e00 and message.unicode_at(i) <= 0x9fff:
			contains_chinese = true
			break
	if not contains_chinese:
		_details.text = message
		text = {
			"Preview expired; analyze again": "候选范围已失效，请重新查找。",
			"Annotations already match; no batch was created": "标注已一致，无需应用。",
			"review: no changed review state": "这些帧已处于所选确认状态。",
			"Target changed; analyze again": "目标标注已变化，请重新查找。",
			"Keyframe image could not be loaded": "参考帧加载失败，请重新选择。",
			"The reference frame has no polygon; draw or correct a polygon first": "参考帧没有 Poly，请先绘制或修正轮廓。",
			"Source frame mapping changed; analyze again": "帧来源已变化，请重新分析。",
			"Keyframe changed; analyze again": "参考帧已变化，请重新分析。",
		}.get(message, "操作未完成，请重试；详细原因见高级设置。")
	_info.text = text
	_info.visible = text.contains("失败") or text.contains("请") or text.contains("失效")
	_host._set_status(text)

func _label(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(label)
	return label

func _button(value: String, callback: Callable, guarded: bool = true) -> Button:
	var button := Button.new()
	button.text = value
	if callback.is_valid():
		button.pressed.connect(callback)
	_panel.add_child(button)
	if guarded:
		_guarded_buttons.append(button)
	return button

func _spin(parent: Node, minimum: float, maximum: float, value: float, increment: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = increment
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(spin)
	return spin

func _frame_id(index: int) -> int:
	return int(_host._frame_entries[index].frame_id)

func _add_range_option(selector: OptionButton, index: int) -> void:
	var option := _range_model.option_for_index(index)
	selector.add_item(str(_range_model.frame_ids()[option]))
	selector.set_item_metadata(selector.item_count - 1, option)

func _selected_range_index(selector: OptionButton) -> int:
	if selector.selected < 0:
		return -1
	var option: Variant = selector.get_item_metadata(selector.selected)
	return _range_model.index_at(int(option)) if typeof(option) == TYPE_INT else -1

func _reset_range_controls() -> void:
	_range_model.configure([], 0, 0, -1)
	if _first_entry != null:
		_first_entry.clear()
	if _last_entry != null:
		_last_entry.clear()
	if _range_controls != null:
		_range_controls.visible = false
	if _next_contiguous != null:
		_next_contiguous.visible = false
		_next_contiguous.disabled = true

func _no_poly_candidate_summary(plan: Dictionary) -> String:
	if str(plan.get("right_stop", "")) != "missing original frame ID":
		return "没有可传播的可靠相邻帧。"
	var next_index := int(plan.end_index) + 1
	if next_index < 0 or next_index >= _host._frame_entries.size():
		return "没有可传播的可靠相邻帧。"
	var end_id := int(_host._frame_entries[int(plan.end_index)].frame_id)
	var next_id := int(_host._frame_entries[next_index].frame_id)
	return "Poly 无法跨越缺失原始帧 %d–%d；下一个可接受帧为 %d。" % [end_id + 1, next_id - 1, next_id]

func _jump_to_next_contiguous() -> void:
	if not _ready_for_action():
		return
	var plan := controller.get_plan()
	if plan.is_empty():
		return
	var run := controller.find_next_contiguous_run(int(plan.end_index))
	if run.x < 0:
		_summary.text = "没有可跳转的连续原始帧段。"
		_next_contiguous.disabled = true
		return
	cancel()
	if _host.seek(run.x):
		_summary.text = "已跳到下一段连续帧；请修正或选择参考帧后重新分析。"
		_status("已跳到下一段连续帧；请修正或选择参考帧后重新分析。")
	else:
		_status("下一段连续帧加载失败，已停止。")
	refresh_current()

func _select_algorithm(index: int) -> void:
	cancel()
	if index == 1:
		_mode.select(1)
	_analyze.text = "分析 Poly 光流与边缘" if index == 1 else "以当前帧查找相似段"
	_algorithm_hint.text = "只传播参考帧的 Poly；先验相似、再做光流和有界边缘精修，结果需人工检查。" if index == 1 else "固定坐标复制，不跟随物体运动。"
	_mode_hint.text = "更新同 ID 的 Poly，保留目标帧独有区域。" if index == 1 else "同 ID 更新，保留目标帧独有区域。"
	refresh_current()

func _select_mode(_index: int) -> void:
	cancel()
	_mode_hint.text = ("只保留传播得到的参考 Poly。" if _mode.selected == 0 else "更新同 ID 的 Poly，保留目标帧独有区域。") if _algorithm.selected == 1 else ("替换目标帧的全部标注。" if _mode.selected == 0 else "同 ID 更新，保留目标帧独有区域。")
	refresh_current()

func _edge_frame_counts(plan: Dictionary, first: int, last: int) -> Vector2i:
	var refined := {}
	var fallback := {}
	for index in range(first, last + 1):
		if index == int(plan.get("key_index", -1)):
			continue
		var frame_id := _frame_id(index)
		var frame_quality: Variant = plan.get("quality", {}).get(frame_id)
		if not frame_quality is Dictionary:
			continue
		for quality: Variant in frame_quality.values():
			var edge: Variant = quality.get("edge") if quality is Dictionary else null
			if edge is Dictionary and edge.get("attempted") == true:
				if edge.get("accepted") == true:
					refined[frame_id] = true
				else:
					fallback[frame_id] = true
	return Vector2i(refined.size(), fallback.size())

func _stop_category(plan: Dictionary, similarity: bool) -> String:
	var reasons: Array[String] = []
	for side: String in ["left_stop", "right_stop"]:
		var reason := str(plan.get(side, ""))
		var is_similarity := "similarity" in reason.to_lower()
		var is_flow := reason.begins_with("frame ") and not is_similarity
		if (similarity and is_similarity) or (not similarity and is_flow):
			reasons.append(_stop_reason(reason))
	return "无" if reasons.is_empty() else "；".join(reasons)

func _advanced_diagnostics(plan: Dictionary) -> String:
	var lines: Array[String] = ["左侧：%s" % _stop_reason(str(plan.left_stop)),
		"右侧：%s" % _stop_reason(str(plan.right_stop))]
	var frame_ids: Array = plan.get("quality", {}).keys()
	frame_ids.sort()
	for frame_id: Variant in frame_ids:
		var frame_quality: Variant = plan.quality[frame_id]
		if not frame_quality is Dictionary:
			continue
		var region_ids: Array = frame_quality.keys()
		region_ids.sort()
		for region_id: Variant in region_ids:
			var quality: Variant = frame_quality[region_id]
			var edge: Variant = quality.get("edge") if quality is Dictionary else null
			if not edge is Dictionary:
				continue
			lines.append("帧 %s · %s：MAD %.6f / %.6f，光流 %.3f，边缘 %.3f → %.3f（%s）" % [
				str(frame_id), str(region_id), float(quality.adjacent_mad),
				float(quality.keyframe_mad), float(quality.score),
				float(edge.raw_edge_score), float(edge.refined_edge_score),
				"接受" if edge.accepted else "回退：%s" % str(edge.reason)])
	return "\n".join(lines)

func _exit_tree() -> void:
	controller.cancel()

func _stop_reason(reason: String) -> String:
	if ": similarity adjacent " in reason:
		return reason.replace(": similarity adjacent ", "：相邻差异 ").replace(" / keyframe ", "，关键帧差异 ").replace(" >= threshold ", "，达到阈值 ")
	if reason.begins_with("difference "):
		var pieces := reason.trim_prefix("difference ").split(" / keyframe ")
		return "差异 %s，参考帧差异 %s" % [pieces[0], pieces[1]] if pieces.size() == 2 else "图像差异超过阈值"
	return {"source boundary": "已到视频边界", "30-frame cap (truncated)": "达到 30 帧上限",
		"missing original frame ID": "原始帧号不连续", "verified frame protected": "遇到已确认帧",
		"image dimensions changed": "图像尺寸变化"}.get(reason, reason)
