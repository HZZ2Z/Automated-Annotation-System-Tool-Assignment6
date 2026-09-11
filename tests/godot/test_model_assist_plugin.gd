extends SceneTree

const PLUGIN := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const TRANSFORM := preload("res://client/services/viewport_transform.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")


class FakeModelAssistService extends RefCounted:
	signal state_changed(snapshot: Dictionary)
	signal prediction_ready(token: int, result: Dictionary)

	var job_dir := ""
	var preflight_calls := 0
	var set_images: Array[Dictionary] = []
	var predictions: Array[Dictionary] = []
	var cancelled: Array[int] = []
	var shutdown_calls := 0
	var _token := 100

	func _init(path: String) -> void:
		job_dir = path
		DirAccess.make_dir_recursive_absolute(job_dir.path_join("candidates"))

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
		pass

	func shutdown() -> void:
		shutdown_calls += 1

	func candidate_job_dir() -> String:
		return job_dir

	func deliver(token: int, descriptors: Array, ok := true, errors: Array = []) -> void:
		var context := {}
		for request: Dictionary in predictions:
			if request.token == token:
				context = request.context.duplicate(true)
				break
		var data := {"image_sha256": context.get("image_sha256", ""), "candidates": descriptors.duplicate(true)} if ok else {}
		prediction_ready.emit(token, {"ok": ok, "context": context, "data": data, "errors": errors.duplicate(true)})

	func fail_service(message: String) -> void:
		state_changed.emit({"status": "failed", "message": message, "badge": "SAM2 failed", "device": "cpu", "busy": false, "errors": [message]})


class ViewportProbe extends RefCounted:
	signal edit_cancel_requested

	var image: Image
	var transform = TRANSFORM.new()
	var overlays: Array[Dictionary] = []
	var records: Array[Dictionary] = []
	var selected_ids: Array[String] = []

	func _init(next_image: Image) -> void:
		image = next_image
		transform.configure(Vector2(image.get_size()), Rect2(0, 0, 400, 320))

	func set_record(record: Dictionary) -> void:
		records.append(record.duplicate(true))

	func set_selected_region_id(region_id: String) -> void:
		selected_ids.append(region_id)

	func get_image_transform():
		return transform

	func get_current_image() -> Image:
		return image.duplicate()

	func set_edit_overlay(state: Dictionary) -> void:
		overlays.append(state.duplicate(true))

	func clear_edit_overlay() -> void:
		overlays.append({})


func _initialize() -> void:
	var support = SUPPORT.new()
	run_suite(support)
	if support.failures.is_empty():
		print("PASS model assist edit plugin")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)


static func run_suite(support) -> void:
	_test_descriptor_preflight_and_prompt_routing(support)
	_test_stale_and_cancel_are_atomic(support)
	_test_service_fatal_becomes_retryable(support)
	_test_creation_class_assignment_and_history(support)
	_test_box_correction_metadata_stale_gate_and_history(support)


static func _test_descriptor_preflight_and_prompt_routing(support) -> void:
	var fixture := _fixture("prompts", "")
	var plugin = fixture.plugin
	var service: FakeModelAssistService = fixture.service
	var ids: Array = plugin.get_tool_descriptors().map(func(item): return item.id)
	support.expect_equal(ids, [&"box", &"subtract", &"lasso", &"fill", &"paint", &"eraser", &"select", &"match_region", &"model_assist"], "Match and model assist are appended without renumbering the existing seven tools")
	var descriptor: Dictionary = plugin.get_tool_descriptors()[-1]
	support.expect_equal(descriptor.get("node_name"), "ModelAssist", "model assist has a stable ToolPanel node")
	support.expect(ResourceLoader.load(descriptor.get("icon_path", "")) is Texture2D, "model assist descriptor uses a loadable local icon")
	support.expect_equal(service.preflight_calls, 1, "plugin activation runs one external-runtime preflight")
	support.expect(service.set_images.is_empty() and service.predictions.is_empty(), "activation never starts image inference")
	support.expect(plugin.handle_key(_key(KEY_M)), "plain M selects model assist through the edit input route")
	support.expect_equal(plugin.get_active_tool(), &"model_assist", "M activates the ninth tool")

	_click(plugin, Vector2(12, 14))
	support.expect_equal(fixture.selected[0], "", "empty-space model prompt never changes selection")
	support.expect_equal(service.set_images.size(), 1, "first prompt freezes one image snapshot")
	support.expect_equal(service.predictions.size(), 1, "first prompt starts one prediction")
	support.expect_equal(service.predictions[-1].prompts.labels, [1], "ordinary click is a positive point")
	_click(plugin, Vector2(22, 24), true)
	support.expect_equal(service.predictions[-1].prompts.labels, [1, 0], "Shift+click appends a negative point")
	support.expect(service.cancelled.has(service.predictions[-2].token), "new prompt invalidates the previous token before requesting")

	_ctrl_drag(plugin, Vector2(30, 28), Vector2(8, 6))
	support.expect_equal(service.predictions[-1].prompts.box, [8.0, 6.0, 30.0, 28.0], "Ctrl-drag adds one normalized xyxy box")
	_ctrl_drag(plugin, Vector2(5, 7), Vector2(25, 29))
	support.expect_equal(service.predictions[-1].prompts.box, [5.0, 7.0, 25.0, 29.0], "a later Ctrl-drag replaces rather than appends the prompt box")
	var before_backspace: int = service.predictions[-1].context.prompt_revision
	support.expect(plugin.handle_key(_key(KEY_BACKSPACE)), "Backspace is owned by model prompt history")
	support.expect(service.predictions[-1].context.prompt_revision > before_backspace, "Backspace starts a fresh non-stale revision")
	support.expect_equal(service.predictions[-1].prompts.box, [8.0, 6.0, 30.0, 28.0], "Backspace restores the replaced prompt box")
	_cleanup_fixture(fixture)


static func _test_stale_and_cancel_are_atomic(support) -> void:
	var fixture := _fixture("stale-cancel", "")
	var plugin = fixture.plugin
	var service: FakeModelAssistService = fixture.service
	plugin.set_active_tool(&"model_assist")
	var before: Dictionary = fixture.store.get_corrected_record(17)
	_click(plugin, Vector2(12, 14))
	var stale_token: int = service.predictions[-1].token
	_click(plugin, Vector2(18, 20))
	var current_token: int = service.predictions[-1].token
	service.deliver(stale_token, [_candidate_descriptor(service, "stale.png", 0)])
	support.expect_equal(plugin.get_edit_state().phase, &"requesting", "late older response cannot leave the current requesting state")
	support.expect_equal(fixture.store.get_corrected_record(17), before, "stale response never mutates Store")
	support.expect(plugin.handle_key(_key(KEY_ESCAPE)), "Escape cancels a model draft")
	support.expect(service.cancelled.has(current_token), "Escape invalidates the current service token")
	service.deliver(current_token, [_candidate_descriptor(service, "late.png", 1)])
	support.expect_equal(plugin.get_edit_state().phase, &"ready", "late callback after Escape cannot restore preview")
	support.expect_equal(fixture.store.get_corrected_record(17), before, "cancelled callback preserves Store byte-for-byte")
	support.expect_equal(fixture.history.get_undo_count(), 0, "stale and Cancel paths never enter history")
	_cleanup_fixture(fixture)


static func _test_service_fatal_becomes_retryable(support) -> void:
	var fixture := _fixture("fatal-retry", "")
	var plugin = fixture.plugin
	var service: FakeModelAssistService = fixture.service
	plugin.set_active_tool(&"model_assist")
	_click(plugin, Vector2(12, 14))
	var failed_token: int = service.predictions[-1].token
	support.expect_equal(plugin.get_edit_state().phase, &"requesting", "fatal fixture starts from an active prediction")
	service.fail_service("worker crashed during predict")
	var state: Dictionary = plugin.get_edit_state()
	support.expect_equal(state.phase, &"failed", "terminal service failure leaves requesting state")
	support.expect("worker crashed during predict" in state.message, "terminal service reason remains visible")
	var action_ids: Array = state.session_panel.actions.map(func(action): return action.id)
	support.expect_equal(action_ids, [&"model_retry", &"model_cancel"], "failed prediction offers Retry and Cancel")
	support.expect_equal(fixture.history.get_undo_count(), 0, "service failure never mutates history")
	support.expect_equal(plugin.invoke(&"model_retry"), PackedStringArray(), "Retry preserves prompts and starts a fresh request")
	support.expect_equal(plugin.get_edit_state().phase, &"requesting", "Retry returns to requesting")
	support.expect(service.predictions[-1].token != failed_token, "Retry uses a fresh service token")
	_cleanup_fixture(fixture)


static func _test_creation_class_assignment_and_history(support) -> void:
	var fixture := _fixture("creation", "")
	var plugin = fixture.plugin
	var service: FakeModelAssistService = fixture.service
	plugin.set_active_tool(&"model_assist")
	var before: Dictionary = fixture.store.get_corrected_record(17)
	_click(plugin, Vector2(12, 14))
	var token: int = service.predictions[-1].token
	var invalid := _candidate_descriptor(service, "hole.png", 0, true)
	var safe_one := _candidate_descriptor(service, "safe-one.png", 0)
	var safe_two := _candidate_descriptor(service, "safe-two.png", 2)
	service.deliver(token, [invalid, safe_one, safe_two])
	support.expect_equal(plugin.get_edit_state().phase, &"invalid", "unsafe first candidate is explained without repair")
	support.expect(not plugin.invoke(&"model_apply").is_empty(), "invalid candidate cannot be applied through a forged action")
	support.expect_equal(fixture.store.get_corrected_record(17), before, "invalid Apply preserves Store")
	support.expect_equal(plugin.invoke(&"model_next_candidate"), PackedStringArray(), "generic next action selects another candidate")
	support.expect_equal(plugin.get_edit_state().phase, &"candidate", "next safe candidate becomes applicable")
	var selected_polygon: PackedVector2Array = fixture.viewport.overlays[-1].candidate_polygon.duplicate()
	support.expect(plugin.handle_key(_key(KEY_TAB)), "Tab cycles safe/unsafe candidates inside the tool")
	support.expect(fixture.viewport.overlays[-1].candidate_polygon != selected_polygon, "Tab changes the visible candidate")
	support.expect_equal(plugin.invoke(&"model_previous_candidate"), PackedStringArray(), "previous action restores the prior candidate")
	support.expect_equal(plugin.invoke(&"model_apply"), PackedStringArray(), "creation Apply enters existing class assignment")
	support.expect_equal(fixture.store.get_corrected_record(17), before, "class-pending model candidate remains uncommitted")
	support.expect_equal(fixture.class_requests.size(), 1, "creation requests class assignment exactly once")
	var request: Dictionary = fixture.class_requests[0]
	support.expect_equal(request.get("tool_id"), &"model_assist", "class request preserves the creating tool")
	var errors: PackedStringArray = plugin.invoke(&"confirm_pending_region", {"candidate_token": request.candidate_token, "class": "new-tool", "kind": "instrument"})
	support.expect_equal(errors, PackedStringArray(), "class confirmation commits the model candidate")
	var after: Dictionary = fixture.store.get_corrected_record(17)
	support.expect_equal(after.regions.size(), before.regions.size() + 1, "creation adds exactly one region")
	support.expect_equal(after.regions[-1].get("class"), "new-tool", "creation uses the existing class dialog result")
	support.expect_equal(fixture.history.get_undo_count(), 1, "creation produces exactly one AddPolygonCommand")
	support.expect(fixture.history.undo(fixture.store), "model creation undo succeeds")
	support.expect_equal(fixture.store.get_corrected_record(17), before, "creation undo restores the exact record")
	support.expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "model creation redo succeeds")
	support.expect_equal(fixture.store.get_corrected_record(17), after, "creation redo restores the exact committed record")
	_cleanup_fixture(fixture)


static func _test_box_correction_metadata_stale_gate_and_history(support) -> void:
	var fixture := _fixture("correction", "r-box")
	var plugin = fixture.plugin
	var service: FakeModelAssistService = fixture.service
	plugin.set_active_tool(&"model_assist")
	var before: Dictionary = fixture.store.get_corrected_record(17)
	_click(plugin, Vector2(13, 15))
	support.expect(not service.set_images[-1].initial_mask.is_empty(), "selected Box is rasterized once as the correction initial mask")
	var token: int = service.predictions[-1].token
	service.deliver(token, [_candidate_descriptor(service, "correction.png", 1)])
	support.expect_equal(fixture.viewport.overlays[-1].get("suppress_region_id"), "r-box", "correction preview suppresses only its frozen region")
	support.expect_equal(plugin.invoke(&"model_apply"), PackedStringArray(), "current safe correction applies atomically")
	var after: Dictionary = fixture.store.get_corrected_record(17)
	var old_region := _find_region(before, "r-box")
	var changed := _find_region(after, "r-box")
	support.expect(changed.has("polygon") and not changed.has("box"), "Box correction converts geometry to Poly")
	for field: String in ["id", "class", "kind", "track_id", "conf"]:
		support.expect_equal(changed.get(field), old_region.get(field), "correction preserves region metadata field %s" % field)
	support.expect_equal(fixture.history.get_undo_count(), 1, "correction creates exactly one ReplaceRegionGeometryCommand")
	support.expect(fixture.history.undo(fixture.store), "correction undo succeeds")
	support.expect_equal(fixture.store.get_corrected_record(17), before, "correction undo restores exact Box record")
	support.expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "correction redo succeeds")
	support.expect_equal(fixture.store.get_corrected_record(17), after, "correction redo restores exact Poly record")
	_cleanup_fixture(fixture)

	fixture = _fixture("correction-stale", "r-box")
	plugin = fixture.plugin
	service = fixture.service
	plugin.set_active_tool(&"model_assist")
	_click(plugin, Vector2(13, 15))
	token = service.predictions[-1].token
	service.deliver(token, [_candidate_descriptor(service, "stale-correction.png", 1)])
	var externally_changed: Dictionary = fixture.store.get_corrected_record(17)
	_find_region(externally_changed, "r-box").class = "changed-outside"
	fixture.store.replace_corrected_record(17, externally_changed)
	var history_before: int = fixture.history.get_undo_count()
	support.expect(not plugin.invoke(&"model_apply").is_empty(), "record drift refuses the frozen correction")
	support.expect_equal(fixture.store.get_corrected_record(17), externally_changed, "stale correction never overwrites newer Store data")
	support.expect_equal(fixture.history.get_undo_count(), history_before, "stale correction never enters history")
	_cleanup_fixture(fixture)


static func _fixture(label: String, selected_id: String) -> Dictionary:
	var root := "/tmp/model-assist-plugin-%s-%d-%d" % [label, OS.get_process_id(), Time.get_ticks_usec()]
	var service := FakeModelAssistService.new(root)
	var store = STORE.new()
	store.load_model_records([_record()])
	var history = HISTORY.new()
	var image := Image.create(100, 80, false, Image.FORMAT_RGB8)
	image.fill(Color(0.1, 0.2, 0.3))
	var viewport := ViewportProbe.new(image)
	var selected := [selected_id]
	var class_requests: Array[Dictionary] = []
	var statuses: Array[String] = []
	var states: Array[Dictionary] = []
	var plugin = PLUGIN.new()
	plugin.model_assist_service_factory = func(): return service
	var errors: PackedStringArray = plugin.activate({
		"store": store,
		"history": history,
		"viewport": viewport,
		"get_current_frame": func(): return 17,
		"get_playback_index": func(): return 3,
		"get_selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"get_current_image": func(): return image.duplicate(),
		"status": func(message: String): statuses.append(message),
		"edit_state_changed": func(state: Dictionary): states.append(state.duplicate(true)),
		"request_class_assignment": func(request: Dictionary): class_requests.append(request.duplicate(true)),
		"taxonomy": {"classes": [{"id": "unknown", "kind": "region"}]},
	})
	return {"root": root, "service": service, "store": store, "history": history, "image": image, "viewport": viewport, "selected": selected, "class_requests": class_requests, "statuses": statuses, "states": states, "plugin": plugin, "activation_errors": errors}


static func _record() -> Dictionary:
	return {"schema_version": 1, "source": "frame.png", "frame": 17, "regions": [
		{"id": "r-box", "class": "grasper", "kind": "instrument", "box": [4.0, 5.0, 20.0, 12.0], "track_id": "T1", "conf": 0.82},
		{"id": "r-poly", "class": "hook", "kind": "instrument", "polygon": [[40.0, 15.0], [60.0, 15.0], [58.0, 32.0], [41.0, 30.0]], "track_id": null, "conf": 0.7},
	]}


static func _candidate_descriptor(service: FakeModelAssistService, name: String, offset: int, hole := false) -> Dictionary:
	var image := Image.create(20, 18, false, Image.FORMAT_L8)
	image.fill(Color.BLACK)
	for y in range(2, 15):
		for x in range(2 + offset, 7 + offset):
			image.set_pixel(x, y, Color.WHITE)
	for y in range(10, 15):
		for x in range(7 + offset, 17):
			image.set_pixel(x, y, Color.WHITE)
	if hole:
		for y in range(11, 13):
			for x in range(4 + offset, 6 + offset):
				image.set_pixel(x, y, Color.BLACK)
	var relative := "candidates/" + name
	var path := service.job_dir.path_join(relative)
	image.save_png(path)
	return {"path": relative, "roi": [10, 12, 20, 18], "sha256": FileAccess.get_sha256(path), "score": 0.9 - offset * 0.01}


static func _click(plugin, point: Vector2, shift := false) -> void:
	plugin.handle_pointer(_mouse(true, shift, false), point)
	plugin.handle_pointer(_mouse(false, shift, false), point)


static func _ctrl_drag(plugin, start: Vector2, finish: Vector2) -> void:
	plugin.handle_pointer(_mouse(true, false, true), start)
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.ctrl_pressed = true
	plugin.handle_pointer(motion, finish)
	plugin.handle_pointer(_mouse(false, false, true), finish)


static func _mouse(pressed: bool, shift: bool, ctrl: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	return event


static func _key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	return event


static func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	for region: Variant in record.get("regions", []):
		if region is Dictionary and region.get("id") == region_id:
			return region
	return {}


static func _cleanup_fixture(fixture: Dictionary) -> void:
	fixture.plugin.deactivate()
	_remove_tree(fixture.root)


static func _remove_tree(path: String) -> void:
	if not path.begins_with("/tmp/model-assist-plugin-") or not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for directory_name: String in directory.get_directories():
		_remove_tree(path.path_join(directory_name))
	DirAccess.remove_absolute(path)
