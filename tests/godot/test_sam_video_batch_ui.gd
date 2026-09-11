extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")

class Inference extends RefCounted:
	var ready := false
	var unavailable_reason := ""
	var validate_error := ""
	var running := false
	var context: Dictionary = {}
	var entries: Array = []
	var source_ref: Variant
	var captured_target_pngs: Dictionary = {}
	var successful_source_validations := 0
	var stop_at := -1
	var stop_reason := "候选包含多个连通区域，已在此帧停止。"

	func preflight() -> Dictionary:
		if not unavailable_reason.is_empty():
			return {"ok": false, "busy": false, "status": "unavailable",
				"message": unavailable_reason, "badge": "", "device": ""}
		if ready:
			return {"ok": true, "busy": false, "status": "ready", "message": "CPU（较慢）",
				"badge": "CPU（较慢）", "device": "cpu", "model_version": "fixture-1"}
		return {"ok": false, "busy": true, "status": "checking", "message": "正在检查 SAM 2 Video…",
			"badge": "", "device": ""}

	func begin(value: Dictionary, source, all_entries: Array, _region: Dictionary) -> PackedStringArray:
		context = value.duplicate(true)
		entries = all_entries.duplicate(true)
		source_ref = source
		captured_target_pngs.clear()
		for offset in range(int(context.propagation_count)):
			var index := int(context.key_playback_index) + offset + 1
			var image: Variant = source_ref.load_image_snapshot_uncached(index)
			if not image is Image or image.is_empty():
				return PackedStringArray(["source fixture target is unavailable"])
			captured_target_pngs[index] = image.save_png_to_buffer()
		running = true
		return PackedStringArray()

	func step() -> void:
		if running:
			running = false
		else:
			ready = true

	func cancel() -> void: running = false
	func is_running() -> bool: return running
	func progress_text() -> String: return "正在生成 SAM 候选…"
	func validate_source() -> PackedStringArray:
		if not validate_error.is_empty():
			return PackedStringArray([validate_error])
		for index: Variant in captured_target_pngs:
			var image: Variant = source_ref.load_image_snapshot_uncached(int(index))
			if not image is Image or image.is_empty() \
					or image.save_png_to_buffer() != captured_target_pngs[index]:
				return PackedStringArray(["source fixture changed after capture"])
		successful_source_validations += 1
		return PackedStringArray()

	func get_result() -> Dictionary:
		var proposals: Array = []
		var bound := context.duplicate(true)
		bound["targets"] = []
		for offset in range(int(context.propagation_count)):
			var index := int(context.key_playback_index) + offset + 1
			var entry: Dictionary = entries[index]
			bound.targets.append({"playback_index": index, "frame_id": entry.frame_id,
				"entry_sha256": "a".repeat(64), "image_sha256": _sha256(captured_target_pngs[index]),
				"time_s": entry.get("time_s")})
			if stop_at >= 0 and offset >= stop_at:
				continue
			proposals.append({"playback_index": index, "frame_id": entry.frame_id,
				"object_id": 1, "region_id": context.region_id, "time_s": entry.get("time_s"),
				"polygon": PackedVector2Array([Vector2(34, 37), Vector2(82, 37), Vector2(82, 71), Vector2(34, 71)]),
				"mask": {"score": 0.8}})
		return {"errors": [], "context": bound, "proposals": proposals,
			"stop": stop_reason if stop_at >= 0 else "", "runtime": {
				"device": "cpu", "badge": "CPU（较慢）", "model_version": "fixture-1",
				"checkpoint_sha256": "d".repeat(64)}}

	func _sha256(bytes: PackedByteArray) -> String:
		var hashing := HashingContext.new()
		hashing.start(HashingContext.HASH_SHA256)
		hashing.update(bytes)
		return hashing.finish().hex_encode()

class StaleCacheSource extends RefCounted:
	var delegate: Variant
	var target_index: int
	var stale_texture: Texture2D
	var fresh_image: Image
	var return_stale_snapshot_once := false
	var change_after_next_snapshot := false

	func _init(value: Variant, index: int) -> void:
		delegate = value
		target_index = index
		stale_texture = delegate.load_texture(index)
		fresh_image = _copy_image(delegate.load_image_snapshot_uncached(index))
		var pixel := fresh_image.get_pixel(0, 0)
		fresh_image.set_pixel(0, 0, Color(1.0 - pixel.r, 1.0 - pixel.g, 1.0 - pixel.b, pixel.a))

	func get_frame_entry(index: int) -> Dictionary: return delegate.get_frame_entry(index)
	func get_manifest() -> Dictionary: return delegate.get_manifest()
	func load_texture(index: int) -> Texture2D:
		return stale_texture if index == target_index else delegate.load_texture(index)
	func load_image_snapshot_uncached(index: int) -> Image:
		if index != target_index:
			return delegate.load_image_snapshot_uncached(index)
		if return_stale_snapshot_once:
			return_stale_snapshot_once = false
			return _copy_image(stale_texture.get_image())
		var result := _copy_image(fresh_image)
		if change_after_next_snapshot:
			change_after_next_snapshot = false
			var pixel := fresh_image.get_pixel(1, 0)
			fresh_image.set_pixel(1, 0, Color(1.0 - pixel.r, 1.0 - pixel.g, 1.0 - pixel.b, pixel.a))
		return result
	func close() -> void: delegate.close()

	func fresh_bytes() -> PackedByteArray: return fresh_image.get_data()
	func stale_bytes() -> PackedByteArray: return stale_texture.get_image().get_data()

	func _copy_image(image: Image) -> Image:
		return Image.create_from_data(image.get_width(), image.get_height(), image.has_mipmaps(),
			image.get_format(), image.get_data())

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var s = SUPPORT.new()
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/task5-sam-ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var workflow = main.get("_batch_workflow")
	s.expect_equal(await main.open_source("res://sample/assignment_v1"), PackedStringArray(), "mounted source opens")
	var inference := Inference.new()
	workflow.controller._providers[&"sam_video"].service = inference
	workflow._show_tab(true)

	s.expect_equal(workflow._algorithm.selected, 0, "SAM is the default Batch algorithm")
	s.expect_equal(workflow._algorithm.get_item_text(0), "SAM 2 Video", "default algorithm is named")
	s.expect("SAM" in workflow._algorithm_hint.text and not "光流不足" in workflow._algorithm_hint.text,
		"initial algorithm help describes the selected SAM path")
	if workflow._algorithm.item_count >= 3:
		s.expect_equal(workflow._algorithm.get_item_text(1), "Poly 光流 + 边缘精修", "Poly remains explicit")
		s.expect_equal(workflow._algorithm.get_item_text(2), "固定坐标复制", "fixed copy remains explicit")
	else:
		s.expect(false, "SAM, Poly and fixed copy are all present")
	var count: Variant = workflow.get("_propagation_count")
	s.expect(count is SpinBox, "SAM exposes a target-count SpinBox")
	if count is SpinBox:
		s.expect_equal(count.min_value, 1.0, "target count minimum is one")
		s.expect_equal(count.max_value, 30.0, "target count maximum is thirty")
		s.expect_equal(count.step, 1.0, "target count is integral")
	var attestation: Variant = workflow.get("_anchor_attestation")
	s.expect(attestation is CheckButton, "SAM exposes explicit anchor attestation")
	s.expect(workflow._analyze.disabled, "Analyze starts disabled without a selected anchor")
	var runtime_badge: Variant = workflow.get("_runtime_badge")
	var reanchor: Variant = workflow.get("_reanchor")
	var surface_ready: bool = count is SpinBox and attestation is CheckButton \
		and runtime_badge is Label and reanchor is Button and workflow._algorithm.item_count >= 3

	if surface_ready:
		main.call("_set_selected_region", "sample-r01")
		workflow.refresh_current()
		s.expect("grasper" in workflow._key_label.text and "sample-r01" in workflow._key_label.text
			and "Box" in workflow._key_label.text and "0" in workflow._key_label.text,
			"current committed object shows class, ID, geometry and key frame")
		s.expect(workflow._analyze.disabled, "selection alone cannot authorize SAM")
		attestation.button_pressed = true
		s.expect(workflow._analyze.disabled, "cold preflight keeps Analyze disabled")
		workflow._process(0.0)
		workflow.refresh_current()
		s.expect(not workflow._analyze.disabled, "public cold preflight reaches ready")
		s.expect_equal(runtime_badge.text, "CPU（较慢）", "badge comes from actual preflight")

		var before: Dictionary = main._store.freeze_snapshot()
		var frozen_context: Dictionary = main.call("_batch_sam_context")
		inference.stop_at = -1
		count.value = 2
		attestation.button_pressed = true
		workflow.analyze()
		while workflow.controller.is_analyzing():
			workflow._process(0.0)
		workflow._process(0.0)
		s.expect_equal(main._store.freeze_snapshot(), before, "SAM generation and preview do not write Store")
		s.expect("2" in workflow._summary.text,
			"result exposes requested and generated counts")
		var preview_previous: Variant = workflow.get("_sam_preview_previous")
		var preview_next: Variant = workflow.get("_sam_preview_next")
		var preview_label: Variant = workflow.get("_sam_preview_label")
		var preview_ready := preview_previous is Button and preview_next is Button and preview_label is Label
		s.expect(preview_ready, "SAM result exposes an independent previous/next preview cursor")
		if preview_ready:
			s.expect_equal(int(main._viewport.get("_record").frame), 1, "viewport displays the first accepted target")
			s.expect(main._viewport.get("_record").regions[0].has("polygon"), "viewport displays the candidate polygon")
			s.expect_equal(_viewport_bytes(main), _source_bytes(main, 1), "viewport displays the first target texture")
			s.expect("1 / 2" in preview_label.text, "preview cursor labels the first accepted target")
			preview_next.pressed.emit()
			s.expect_equal(int(main._viewport.get("_record").frame), 2, "next preview displays the next accepted target")
			s.expect_equal(_viewport_bytes(main), _source_bytes(main, 2), "next preview displays the next target texture")
			s.expect("2 / 2" in preview_label.text, "preview cursor labels the second accepted target")
			preview_previous.pressed.emit()
			s.expect_equal(int(main._viewport.get("_record").frame), 1, "previous preview returns to the first accepted target")
		s.expect_equal(main.get_current_frame(), 0, "preview cursor never changes Main playback identity")
		s.expect_equal(main.call("_get_selected_region_id"), "sample-r01", "preview cursor preserves the selected anchor")
		s.expect_equal(main.call("_batch_sam_context"), frozen_context, "preview cursor preserves the live SAM context")
		s.expect(not workflow.controller.get_plan().is_empty(), "preview cursor keeps the plan valid")
		s.expect_equal(main._edit_plugin.get_active_tool(), &"select", "preview never enters Edit")
		s.expect_equal(main._store.freeze_snapshot(), before, "overlay remains read-only")
		workflow._show_preview.button_pressed = false
		s.expect_equal(int(main._viewport.get("_record").frame), 0, "closing preview restores the true current frame")
		s.expect_equal(_viewport_bytes(main), _source_bytes(main, 0), "closing preview restores the true current texture")
		workflow._show_preview.button_pressed = true
		s.expect_equal(int(main._viewport.get("_record").frame), 1, "preview can reopen at the first accepted target")
		await workflow.apply()
		s.expect_equal(int(main._viewport.get("_record").frame), 0, "applying restores the true current viewport")
		s.expect_equal(_viewport_bytes(main), _source_bytes(main, 0), "applying restores the true current texture")
		main._run_history_undo()

		workflow.cancel()
		inference.stop_at = 1
		count.value = 3
		attestation.button_pressed = true
		workflow.analyze()
		while workflow.controller.is_analyzing(): workflow._process(0.0)
		workflow._process(0.0)
		s.expect("2" in workflow._summary.text and "多个连通区域" in workflow._summary.text,
			"result exposes the exact stop frame and reason")
		s.expect_equal(workflow._apply.text, "确认并写入 1 帧", "confirm names the atomic write count")
		s.expect(reanchor.visible, "truncated model result offers re-anchor")

		reanchor.pressed.emit()
		await process_frame
		s.expect_equal(main.get_current_frame(), 2, "re-anchor seeks the stored stopped playback index")
		s.expect_equal(main.call("_get_selected_region_id"), "sample-r01", "existing stopped-frame region is restored")
		s.expect_equal(main._edit_plugin.get_active_tool(), &"model_assist", "single-frame Model Assist activates")
		s.expect(not workflow._scroll.visible and workflow.controller.get_plan().is_empty(), "Batch closes and video state is discarded")

	main._workspace_session.suspend_autosave(true)
	await main._workspace_session.settle_running()
	main.queue_free()
	await process_frame
	await _test_stale_cached_target_preview(s)
	await _test_invalidation_and_zero_candidate(s)
	if s.failures.is_empty():
		print("PASS SAM video mounted Batch UI and re-anchor")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _test_stale_cached_target_preview(s) -> void:
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/task5-sam-ui-stale-cache-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	s.expect_equal(await main.open_source("res://sample/assignment_v1"), PackedStringArray(),
		"stale-cache source opens")
	var workflow = main._batch_workflow
	var stale_source := StaleCacheSource.new(main._source, 1)
	s.expect(stale_source.fresh_bytes() != stale_source.stale_bytes(),
		"fixture separates the validated target snapshot from the playback cache")
	main._source = stale_source
	workflow.controller.configure(stale_source, main._store, main._history, main._frame_entries)
	workflow.controller.configure_sam_context(Callable(main, "_batch_sam_context"))
	var inference := Inference.new()
	inference.ready = true
	workflow.controller._providers[&"sam_video"].service = inference
	workflow._show_tab(true)
	main.call("_set_selected_region", "sample-r01")
	workflow._propagation_count.value = 1
	workflow._anchor_attestation.button_pressed = true
	var before: Dictionary = main._store.freeze_snapshot()
	workflow.analyze()
	while workflow.controller.is_analyzing(): workflow._process(0.0)
	workflow._process(0.0)
	s.expect(not workflow.controller.get_plan().is_empty(),
		"frozen uncached target remains valid while the playback cache is stale")
	s.expect_equal(_bytes_sha256(_viewport_bytes(main)), _bytes_sha256(stale_source.fresh_bytes()),
		"SAM preview displays the digest-validated uncached target instead of stale cached bytes")
	s.expect_equal(main.get_current_frame(), 0, "stale-cache preview does not change playback identity")
	s.expect_equal(main._edit_plugin.get_active_tool(), &"select", "stale-cache preview does not enter Edit")
	s.expect_equal(main._store.freeze_snapshot(), before, "stale-cache preview does not write Store")
	var validations_before_aba := inference.successful_source_validations
	stale_source.return_stale_snapshot_once = true
	workflow.call("_show_sam_preview_at_cursor")
	s.expect(inference.successful_source_validations > validations_before_aba,
		"Controller still validates current Source successfully after the one-read ABA snapshot")
	s.expect(workflow.controller.get_plan().is_empty(),
		"one-read ABA snapshot is refused even though subsequent Source validation sees the frozen target")
	s.expect_equal(int(main._viewport.get("_record").frame), 0,
		"ABA digest mismatch restores the true current viewport")
	s.expect_equal(main.get_current_frame(), 0, "ABA digest mismatch does not change playback identity")
	s.expect_equal(main._edit_plugin.get_active_tool(), &"select", "ABA digest mismatch does not enter Edit")
	s.expect_equal(main._store.freeze_snapshot(), before, "ABA digest mismatch does not write Store")
	s.expect("/" not in main._status_bar.text and "res:" not in main._status_bar.text,
		"ABA digest mismatch reports no Source path")
	workflow.cancel()
	main.call("_set_selected_region", "sample-r01")
	workflow._propagation_count.value = 1
	workflow._anchor_attestation.button_pressed = true
	workflow.analyze()
	while workflow.controller.is_analyzing(): workflow._process(0.0)
	workflow._process(0.0)
	stale_source.change_after_next_snapshot = true
	workflow.call("_show_sam_preview_at_cursor")
	s.expect(workflow.controller.get_plan().is_empty(),
		"Source mutation after the preview snapshot invalidates the digest-bound plan")
	s.expect_equal(int(main._viewport.get("_record").frame), 0,
		"digest mismatch restores the true current viewport")
	s.expect_equal(main.get_current_frame(), 0, "digest mismatch does not change playback identity")
	s.expect_equal(main._edit_plugin.get_active_tool(), &"select", "digest mismatch does not enter Edit")
	s.expect_equal(main._store.freeze_snapshot(), before, "digest mismatch does not write Store")
	s.expect("/" not in main._status_bar.text and "res:" not in main._status_bar.text,
		"digest mismatch reports no Source path")
	main._workspace_session.suspend_autosave(true)
	await main._workspace_session.settle_running()
	main.queue_free()
	await process_frame

func _test_invalidation_and_zero_candidate(s) -> void:
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/task5-sam-ui-invalid-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	s.expect_equal(await main.open_source("res://sample/assignment_v1"), PackedStringArray(), "invalidation source opens")
	var workflow = main._batch_workflow
	var inference := Inference.new()
	inference.ready = true
	workflow.controller._providers[&"sam_video"].service = inference
	workflow._show_tab(true)
	_publish_zero_plan(main, workflow, inference)
	s.expect(not workflow.controller.get_plan().is_empty(), "fixture publishes a transient SAM plan")
	workflow._propagation_count.value = 2
	s.expect(not workflow._anchor_attestation.button_pressed and workflow.controller.get_plan().is_empty(),
		"count change clears attestation and transient plan")

	for change in ["region", "frame", "algorithm", "store", "review", "edit", "source"]:
		_publish_zero_plan(main, workflow, inference)
		s.expect(not workflow.controller.get_plan().is_empty() and workflow._reanchor.visible,
			change + " invalidation starts from a real plan and re-anchor action")
		if change == "region": main.call("_set_selected_region", "sample-r02")
		elif change == "frame": main.seek(1)
		elif change == "algorithm":
			workflow._algorithm.select(1)
			workflow._select_algorithm(1)
		elif change == "store": workflow._store.corrected_records_replaced.emit(PackedInt64Array([0]))
		elif change == "review": workflow._store.review_state_changed.emit()
		elif change == "edit": main.call("_on_edit_state_changed", {"phase": &"paint", "navigation_blocked": true, "draft_active": true})
		else:
			inference.validate_error = "source fixture changed"
			workflow.refresh_current()
		s.expect(not workflow._anchor_attestation.button_pressed and workflow.controller.get_plan().is_empty(),
			change + " change clears SAM authorization and transients")
		s.expect(not workflow._reanchor.visible and workflow.get("_reanchor_context").is_empty(),
			change + " change removes the stale re-anchor action")
		s.expect_equal(int(main._viewport.get("_record").frame), main.call("_current_record_frame"),
			change + " invalidation restores the true current viewport record")
		s.expect_equal(_viewport_bytes(main), _source_bytes(main, main.get_current_frame()),
			change + " invalidation restores the true current texture")
		var stayed_at: int = main.get_current_frame()
		workflow.call("_request_reanchor")
		s.expect_equal(main.get_current_frame(), stayed_at, change + " stale re-anchor cannot execute")
		if change == "edit": main.call("_on_edit_state_changed", {"phase": &"idle", "navigation_blocked": false, "draft_active": false})
		if change == "source": inference.validate_error = ""

	workflow._algorithm.select(0)
	workflow._select_algorithm(0)
	main.seek(0)
	main.call("_set_selected_region", "sample-r01")
	var target: Dictionary = main._store.get_corrected_record(1)
	for index in range(target.regions.size() - 1, -1, -1):
		if target.regions[index].id == "sample-r01": target.regions.remove_at(index)
	s.expect_equal(main._store.replace_corrected_record(1, target), PackedStringArray(), "absent-region target remains valid")
	inference.stop_at = 0
	workflow._propagation_count.value = 1
	workflow._anchor_attestation.button_pressed = true
	workflow.analyze()
	while workflow.controller.is_analyzing(): workflow._process(0.0)
	workflow._process(0.0)
	s.expect(workflow._apply.disabled and workflow._reanchor.visible and workflow._cancel.visible,
		"zero candidates cannot confirm and offer cancel/re-anchor only")
	workflow.refresh_current()
	s.expect(workflow._apply.disabled and workflow._show_preview.disabled,
		"zero candidates stay non-previewable and non-confirmable after refresh")
	workflow._reanchor.pressed.emit()
	await process_frame
	s.expect_equal(main.get_current_frame(), 1, "zero-candidate re-anchor reaches exact stopped playback index")
	s.expect_equal(main.call("_get_selected_region_id"), "", "absent stopped-frame region is not invented")
	s.expect_equal(main._edit_plugin.get_active_tool(), &"model_assist", "absent region opens a new single-frame Model Assist prompt")

	workflow._show_tab(true)
	workflow._algorithm.select(0)
	workflow._select_algorithm(0)
	inference.unavailable_reason = "checkpoint fixture missing exactly"
	workflow.refresh_current()
	s.expect_equal(workflow._info.text, "checkpoint fixture missing exactly", "SAM shows the exact unavailable reason")
	s.expect(workflow._analyze.disabled and not workflow._algorithm.disabled,
		"unavailable SAM disables only its Analyze action, not alternative algorithms")
	s.expect(not main._open_button.disabled and not main._export_button.disabled and main._edit_plugin != null,
		"SAM unavailability leaves open, export, save/edit session capabilities intact")
	s.expect(workflow._runtime_badge.text.is_empty(), "unavailable requested device never guesses a CUDA badge")

	_publish_zero_plan(main, workflow, inference)
	workflow.clear()
	s.expect(not workflow._anchor_attestation.button_pressed and workflow.controller.get_plan().is_empty()
		and not workflow._reanchor.visible,
		"workspace clear removes authorization and every transient")
	main._workspace_session.suspend_autosave(true)
	await main._workspace_session.settle_running()
	main.queue_free()
	await process_frame

func _publish_zero_plan(main, workflow, inference: Inference) -> void:
	if main.get_current_frame() != 0: main.seek(0)
	workflow._algorithm.select(0)
	workflow._select_algorithm(0)
	main.call("_set_selected_region", "sample-r01")
	inference.stop_at = 0
	workflow._propagation_count.value = 1
	workflow._anchor_attestation.button_pressed = true
	workflow.analyze()
	while workflow.controller.is_analyzing(): workflow._process(0.0)
	workflow._process(0.0)

func _viewport_bytes(main) -> PackedByteArray:
	var texture: Texture2D = main._viewport.get("_texture")
	return texture.get_image().get_data()

func _source_bytes(main, index: int) -> PackedByteArray:
	var texture: Texture2D = main._source.load_texture(index)
	return texture.get_image().get_data()

func _bytes_sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()
