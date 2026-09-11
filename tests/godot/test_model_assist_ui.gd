extends SceneTree

const HARNESS := preload("res://tests/godot/edit_test_harness.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")


class FakeMountedModelService extends RefCounted:
	signal state_changed(snapshot: Dictionary)
	signal prediction_ready(token: int, result: Dictionary)

	var root: String
	var preflight_calls := 0
	var step_calls := 0
	var set_images: Array[Dictionary] = []
	var predictions: Array[Dictionary] = []
	var cancelled: Array[int] = []
	var shutdown_calls := 0
	var _token := 400

	func _init(path: String) -> void:
		root = path
		DirAccess.make_dir_recursive_absolute(root.path_join("candidates"))

	func preflight() -> Dictionary:
		preflight_calls += 1
		return {"ok": true, "status": "ready", "message": "SAM2 已就绪 · CPU（较慢）", "badge": "SAM2 已就绪 · CPU（较慢）", "device": "cpu", "busy": false, "errors": [], "checkpoint_sha256": "a".repeat(64)}

	func set_image(context: Dictionary, image: Image, initial_mask: Dictionary = {}) -> int:
		_token += 1
		set_images.append({"token": _token, "context": context.duplicate(true), "image": image.duplicate(), "initial_mask": initial_mask.duplicate(true)})
		return _token

	func predict(context: Dictionary, prompts: Dictionary) -> int:
		_token += 1
		predictions.append({"token": _token, "context": context.duplicate(true), "prompts": prompts.duplicate(true)})
		return _token

	func cancel(token: int) -> void:
		cancelled.append(token)

	func step() -> void:
		step_calls += 1

	func shutdown() -> void:
		shutdown_calls += 1

	func candidate_job_dir() -> String:
		return root

	func deliver(token: int, descriptors: Array, ok := true) -> void:
		var context := {}
		for request: Dictionary in predictions:
			if int(request.token) == token:
				context = request.context.duplicate(true)
				break
		prediction_ready.emit(token, {
			"ok": ok,
			"context": context,
			"data": {"image_sha256": context.get("image_sha256", ""), "candidates": descriptors.duplicate(true)} if ok else {},
			"errors": [] if ok else ["fake mounted failure"],
		})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var support = SUPPORT.new()
	await run_suite(support, self)
	if support.failures.is_empty():
		print("PASS mounted Model Assist UI")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)


static func run_suite(support, tree: SceneTree) -> void:
	var harness = HARNESS.new()
	if not await harness.mount(support, tree):
		if is_instance_valid(harness.main):
			await harness.finish()
		return
	var root := "/tmp/model-assist-mounted-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var service := FakeMountedModelService.new(root)
	var install_errors: PackedStringArray = harness.install_model_assist_service_factory(func(): return service)
	support.expect_equal(install_errors, PackedStringArray(), "mounted Main accepts the injected Model Assist service")
	await tree.process_frame
	await tree.process_frame
	support.expect(service.step_calls > 0, "Main polls the nonblocking Model Assist service while playback is idle")

	await harness.select_region("box-1")
	await harness.focus_viewport()
	await harness.press_key(KEY_M)
	support.expect_equal(harness.edit_plugin.get_active_tool(), &"model_assist", "plain M reaches Model Assist through mounted Main")
	support.expect(service.set_images.is_empty() and service.predictions.is_empty(), "tool selection performs preflight without inference")

	var before := harness.record().duplicate(true)
	await harness.pointer_click_modified(Vector2(30, 30))
	var first_token: int = service.predictions[-1].token
	support.expect_equal(harness.selected_region_id(), "box-1", "a positive prompt does not change the selected correction target")
	var playback_before: int = int(harness.main.get("_current_frame"))
	var batch_workflow: Variant = harness.main.get("_batch_workflow")
	await harness.call("_click_control_node", batch_workflow.get("_batch_tab"))
	support.expect_equal(int(harness.main.get("_current_frame")), playback_before, "batch-tab navigation is refused while a model draft is active")
	support.expect(harness.tool_panel.visible, "refused batch navigation keeps annotation tools visible")
	await harness.click_timeline_frame(1)
	support.expect_equal(int(harness.main.get("_current_frame")), playback_before, "timeline navigation is refused while a model request is active")

	await harness.pointer_click_modified(Vector2(34, 33), true)
	var second_token: int = service.predictions[-1].token
	await harness.pointer_drag_modified([Vector2(18, 17), Vector2(52, 48)], false, true)
	var current_token: int = service.predictions[-1].token
	support.expect_equal(service.predictions[-1].prompts.labels, [1, 0], "mounted click and Shift-click emit positive and negative prompts")
	support.expect_equal(service.predictions[-1].prompts.box, [18.0, 17.0, 52.0, 48.0], "mounted Ctrl-drag emits one xyxy prompt box")
	support.expect(service.cancelled.has(first_token) and service.cancelled.has(second_token), "new mounted prompt revisions cancel older tokens")
	service.deliver(second_token, [_candidate(service, "stale.png", 0)])
	support.expect_equal(harness.edit_plugin.get_edit_state().phase, &"requesting", "out-of-order mounted response stays stale")
	service.deliver(current_token, [_candidate(service, "first.png", 0), _candidate(service, "second.png", 3)])
	await tree.process_frame
	support.expect_equal(harness.edit_plugin.get_edit_state().phase, &"candidate", "current mounted response exposes a checked candidate")
	support.expect_equal(harness.overlay().get("suppress_region_id"), "box-1", "correction preview suppresses only the frozen region")
	await harness.call("_click_control_node", batch_workflow.get("_batch_tab"))
	support.expect(harness.tool_panel.visible, "candidate preview also blocks the batch tab")
	await harness.click_timeline_frame(1)
	support.expect_equal(int(harness.main.get("_current_frame")), playback_before, "candidate preview also blocks frame navigation")
	var first_polygon: PackedVector2Array = harness.overlay().candidate_polygon.duplicate()
	await harness.click_session_action(&"model_next_candidate")
	support.expect(harness.overlay().candidate_polygon != first_polygon, "real session action button cycles the mounted candidate")
	await harness.click_session_action(&"model_apply")
	var corrected := harness.record().duplicate(true)
	support.expect(corrected != before, "real Apply button commits the correction")
	support.expect_equal(harness.last_command_script(), "res://client/domain/commands/replace_region_geometry_command.gd", "mounted correction is one ReplaceRegionGeometryCommand")
	support.expect_equal(str(harness.main.get("_status_bar").text), "Modified", "Main refreshes committed UI state after a generic tool action")
	await harness.focus_viewport()
	await harness.press_key(KEY_Z, false, true)
	support.expect_equal(harness.record(), before, "mounted Ctrl+Z restores the exact pre-correction record")
	await harness.press_key(KEY_Y, false, true)
	support.expect_equal(harness.record(), corrected, "mounted Ctrl+Y restores the exact correction")

	await harness.pointer_click_modified(Vector2(31, 31))
	var tool_switch_token: int = service.predictions[-1].token
	var before_tool_switch := harness.record().duplicate(true)
	await harness.click_tool(&"select")
	support.expect_equal(harness.edit_plugin.get_active_tool(), &"select", "tool switch cancels rather than commits a requesting Model Assist draft")
	service.deliver(tool_switch_token, [_candidate(service, "late-after-tool.png", 2)])
	await tree.process_frame
	support.expect_equal(harness.record(), before_tool_switch, "late response after tool switch cannot change Store")
	await harness.pointer_click_modified(Vector2(150, 110))
	support.expect_equal(harness.selected_region_id(), "", "empty mounted Selection click clears the correction target")
	await harness.click_tool(&"model_assist")
	var before_creation := harness.record().duplicate(true)
	await harness.pointer_click_modified(Vector2(125, 86))
	var creation_token: int = service.predictions[-1].token
	service.deliver(creation_token, [_candidate(service, "creation.png", 1)])
	await tree.process_frame
	await harness.click_session_action(&"model_apply")
	support.expect(harness.class_dialog.visible, "Model Assist creation reuses the mounted class-assignment dialog")
	await harness.confirm_class("model-created", "instrument")
	var after_creation := harness.record().duplicate(true)
	support.expect_equal(after_creation.regions.size(), before_creation.regions.size() + 1, "class confirmation adds exactly one model-created polygon")
	support.expect_equal(after_creation.regions[-1].get("class"), "model-created", "mounted creation preserves the chosen class")

	await harness.pointer_click_modified(Vector2(128, 90))
	var cancelled_token: int = service.predictions[-1].token
	var before_cancel := harness.record().duplicate(true)
	await harness.press_key(KEY_ESCAPE)
	service.deliver(cancelled_token, [_candidate(service, "late-after-cancel.png", 2)])
	await tree.process_frame
	support.expect_equal(harness.record(), before_cancel, "late response after mounted Escape cannot change Store")
	support.expect_equal(harness.edit_plugin.get_edit_state().phase, &"ready", "mounted Escape returns Model Assist to ready")

	var session: Variant = harness.main.get("_workspace_session")
	support.expect_equal(await session.flush_before_context_change(), PackedStringArray(), "model-created Poly saves through the real workspace session")
	support.expect_equal(await harness.main.open_source(harness.source_root), PackedStringArray(), "saved Model Assist annotations reopen through the normal source lifecycle")
	harness.store = harness.main.get("_store")
	harness.history = harness.main.get("_history")
	harness.edit_plugin = harness.main.get("_edit_plugin")
	support.expect_equal(harness.record(), before_cancel, "save and reopen preserve the exact Model Assist correction and creation record")
	support.expect_equal(service.shutdown_calls, 1, "source replacement shuts down exactly the owned Model Assist service")
	await harness.finish()
	_remove_tree(root)


static func _candidate(service: FakeMountedModelService, name: String, offset: int) -> Dictionary:
	var image := Image.create(28, 24, false, Image.FORMAT_L8)
	image.fill(Color.BLACK)
	for y in range(3, 17):
		for x in range(3 + offset, 10 + offset):
			image.set_pixel(x, y, Color.WHITE)
	for y in range(12, 20):
		for x in range(10 + offset, 21):
			image.set_pixel(x, y, Color.WHITE)
	var relative := "candidates/" + name
	var path := service.root.path_join(relative)
	image.save_png(path)
	return {"path": relative, "roi": [20, 20, 28, 24], "sha256": FileAccess.get_sha256(path), "score": 0.9 - offset * 0.01}


static func _remove_tree(path: String) -> void:
	if not path.begins_with("/tmp/model-assist-mounted-") or not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for directory_name: String in directory.get_directories():
		_remove_tree(path.path_join(directory_name))
	DirAccess.remove_absolute(path)
