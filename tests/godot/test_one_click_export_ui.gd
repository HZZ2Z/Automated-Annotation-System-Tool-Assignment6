extends SceneTree

var _failures: PackedStringArray = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280, 800)
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/one-click-export-ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var errors: PackedStringArray = await main.open_source("res://sample/assignment_v1")
	_check(errors.is_empty(), "the mounted assignment session opens")
	if not errors.is_empty():
		_finish(main)
		return

	var flow = main._review_workflow.exports
	await flow.open()
	_check(flow._dialog.title == "导出训练包", "the default dialog uses the plain title")
	_check(flow._summary.text.contains("当前共 120 帧，120 帧已写入标注。"), "the summary reports the mounted frame and annotation counts")
	_check(flow._summary.text.contains("本次将导出 120 帧"), "the summary reports the exact training coverage")
	_check(flow._publish.disabled, "the primary action is disabled before attestation")
	_check(flow._attestation.text == "我已检查这些标注，可用于训练", "the attestation is a single plain-language confirmation")
	_check(main._export_button.text == "导出训练包" and not main._review_workflow._round_button.visible,
		"the normal toolbar keeps expert round management behind the dialog disclosure")
	if "--capture" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		var capture := "/tmp/project6-one-click-export-ui-1280x800.png"
		_check(flow._dialog.get_texture().get_image().save_png(capture) == OK, "the mounted 1280x800 dialog capture saves")
		print("UI_CAPTURE " + capture)
	flow._on_progress({"fraction":0.5, "message":"Writing package JSONL"})
	_check(flow._result.text == "正在写入导出文件…" and not "JSONL" in flow._result.text,
		"normal progress copy hides worker terminology")
	flow._attestation.button_pressed = true
	await process_frame
	_check(not flow._publish.disabled, "one attestation enables the primary action")
	_check(flow._publish.text == "确认并生成训练包", "the main action names the user outcome")
	_check(not flow._advanced.visible, "expert controls are collapsed by default")
	_check(flow._kind.get_item_count() == 2 and flow._rounds_button != null, "advanced mode retains snapshot and round entry points")

	var plain_text := _visible_text(flow._dialog)
	for forbidden: String in ["baseline", "JSONL", "verified", "training_update_v2", "基线未绑定"]:
		_check(not forbidden.to_lower() in plain_text.to_lower(), "the default surface hides expert term: " + forbidden)
	_check(flow._dialog.size.x <= 1280 and flow._dialog.size.y <= 800, "the dialog fits a 1280x800 viewport")
	_check(flow._publish.position.y + flow._publish.size.y <= flow._dialog.size.y, "the primary action is not clipped")
	_check(flow._summary.position.y + flow._summary.size.y <= flow._dialog.size.y, "the summary is not clipped")
	flow._advanced_toggle.button_pressed = true
	await process_frame
	_check(flow._advanced.is_visible_in_tree() and flow._rounds_button.is_visible_in_tree(), "advanced disclosure reveals the manual round entry point")
	flow._on_progress({"fraction":0.5, "message":"Writing package JSONL"})
	_check("JSONL" in flow._technical_details.text, "advanced disclosure retains raw progress detail")
	flow._kind.select(1)
	await flow._on_kind_selected(1)
	var expert_text := _visible_text(flow._dialog)
	_check("JSONL" in expert_text and "review_export_v1" in expert_text, "advanced snapshot mode retains full technical context")
	_check(not flow._publish.disabled, "the recoverable review snapshot remains available")
	flow._advanced_toggle.button_pressed = false
	await process_frame
	_check(not flow._advanced.visible and flow._kind.selected == 0, "collapsing advanced options restores the plain training path")
	flow._show_prepare_failure({"error_code":"baseline_input_required", "errors":PackedStringArray(["raw baseline JSONL error"])})
	_check(flow._result.text == "需要原始标注文件才能比较修正", "a missing original source gets recoverable plain-language copy")
	_check(flow._choose_baseline.is_visible_in_tree() and flow._review_snapshot.is_visible_in_tree(), "the missing-original state offers both recovery actions")
	_check(flow._publish.disabled, "the missing-original state cannot publish training data")
	flow._show_prepare_failure({"error_code":"save_failed", "errors":PackedStringArray(["disk details"])})
	_check(flow._publish.disabled and not flow._choose_baseline.is_visible_in_tree() and not flow._review_snapshot.is_visible_in_tree(), "other validation failures never enable publication")

	flow.cancel()
	await flow.cancel_and_drain()
	_finish(main)

func _visible_text(node: Node) -> String:
	var values: PackedStringArray = []
	if node is Window:
		values.append(node.title)
	if node is Control and not node.is_visible_in_tree():
		return ""
	if node is Label or node is Button:
		values.append(node.text)
	if node is LineEdit:
		values.append(node.placeholder_text)
	if node is OptionButton:
		for index: int in range(node.item_count):
			values.append(node.get_item_text(index))
	for child: Node in node.get_children():
		values.append(_visible_text(child))
	return "\n".join(values)

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _finish(main: Node) -> void:
	main.queue_free()
	await process_frame
	if _failures.is_empty():
		print("PASS one-click export plain-language UI")
		quit(0)
	else:
		for failure: String in _failures:
			print("FAIL: " + failure)
		quit(1)
