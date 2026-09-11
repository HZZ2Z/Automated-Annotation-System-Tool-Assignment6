extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const CONTROLLER := preload("res://client/services/batch_controller.gd")
const REVIEW := preload("res://client/domain/commands/review_frames_command.gd")
var s = SUPPORT.new()

class Source extends RefCounted:
	var entries: Array = []
	func get_frame_entry(index: int) -> Dictionary: return entries[index].duplicate(true)
	func load_image_snapshot_uncached(_index: int) -> Image: return Image.create(80, 60, false, Image.FORMAT_RGB8)
	func load_texture(index: int) -> ImageTexture: return ImageTexture.create_from_image(load_image_snapshot_uncached(index))
	func get_manifest() -> Dictionary: return {"frame_step": 1}

# 唯一替身是外部推理服务；Controller、Provider、Store 和历史均真实执行。
class Inference extends RefCounted:
	var running := false
	var context: Dictionary = {}
	var entries: Array = []
	var source: Variant
	var stop_at := -1
	var stop_reason := "Candidate topology refusal"
	var append_after_stop := false
	var fault := ""
	var bad_identity := false
	var bad_region := false
	var on_step: Callable
	func preflight() -> Dictionary: return {"ok": true, "busy": false, "message": "", "device": "cpu"}
	func begin(value: Dictionary, src, all_entries: Array, _mask: Dictionary) -> PackedStringArray:
		context = value.duplicate(true)
		entries = all_entries.duplicate(true)
		source = src
		running = true
		return PackedStringArray()
	func step() -> void:
		running = false
		if on_step.is_valid(): on_step.call()
	func cancel() -> void: running = false
	func is_running() -> bool: return running
	func progress_text() -> String: return "inference"
	func validate_source() -> PackedStringArray:
		return PackedStringArray() if entries == source.entries else PackedStringArray(["Source changed"])
	func get_result() -> Dictionary:
		var proposals: Array = []
		var bound := context.duplicate(true)
		bound.targets = []
		for offset in range(context.propagation_count):
			var index: int = context.key_playback_index + offset + 1
			var entry: Dictionary = entries[index]
			var target := {"playback_index": index, "frame_id": entry.frame_id, "entry_sha256": "a".repeat(64), "image_sha256": "b".repeat(64), "time_s": entry.time_s}
			bound.targets.append(target)
			if stop_at >= 0 and offset >= stop_at and not append_after_stop: continue
			proposals.append({"playback_index": index, "frame_id": entry.frame_id + (1 if bad_identity else 0), "object_id": 1,
				"region_id": "wrong-region" if bad_region else context.region_id, "time_s": entry.time_s, "polygon": PackedVector2Array([Vector2(10, 12), Vector2(14, 12), Vector2(14, 15), Vector2(10, 15)]),
				"mask": {"path": "outputs/%d.png" % index, "roi": [10, 12, 4, 3], "score": 0.9, "sha256": "c".repeat(64)}})
		return {"errors": [] if fault.is_empty() else [fault], "provider_id": "sam_video", "context": bound,
			"proposals": proposals, "stop": stop_reason if stop_at >= 0 else "", "risks": [], "runtime": {"device": "cpu", "checkpoint_sha256": "d".repeat(64), "badge": "CPU"}}

func _initialize() -> void: call_deferred("run")

func run() -> void:
	if not CONTROLLER.new().has_method("start_sam_video_analysis"):
		s.expect(false, "Controller must expose single-region SAM analysis")
	else:
		_test_rejections()
		_test_ranges_and_preview()
		_test_invalidation()
		_test_stops()
		_test_completion_signal()
		_test_existing_history()
		await _test_real_service()
	if s.failures.is_empty():
		print("PASS SAM video batch controller and read-only region preview")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _fixture(count := 32, polygon := false) -> Dictionary:
	var source := Source.new()
	var records: Array = []
	for index in range(count):
		var frame := 11825 + index * 25
		source.entries.append({"frame_id": frame, "time_s": index * 0.8})
		var selected := {"id": "r", "class": "key" if index == 0 else "target", "kind": "instrument", "track_id": "T%d" % index, "conf": 0.73, "box": [10, 12, 4, 3]}
		if polygon:
			selected.erase("box")
			selected["polygon"] = [[10,12],[14,12],[14,15],[10,15]]
		var regions: Array = [{"id":"before", "class":"other", "kind":"anatomy", "box":[20,20,4,4]}, selected, {"id":"after", "class":"other2", "kind":"anatomy", "box":[30,30,4,4]}]
		if index == 2: regions.remove_at(1)
		records.append({"schema_version": 1, "source": "test", "frame": frame, "time_s": index * 0.8, "regions": regions})
	var store = STORE.new()
	s.expect_equal(store.load_model_records(records), PackedStringArray(), "real Store fixture is valid")
	for frame in [11825, 11850]:
		if not store.get_corrected_record(frame).is_empty():
			var record: Dictionary = store.get_corrected_record(frame)
			record.regions[1]["filled"] = frame == 11825
			s.expect_equal(store.replace_corrected_record(frame, record), PackedStringArray(), "real Store filled state is valid")
	var history = HISTORY.new()
	var controller = CONTROLLER.new()
	controller.configure(source, store, history, source.entries)
	var live := {"key_index": 0, "region_id": "r", "edit_pending": false}
	controller.configure_sam_context(func(): return live.duplicate(true))
	var inference := Inference.new()
	controller._providers[&"sam_video"].service = inference
	return {"controller": controller, "source": source, "store": store, "history": history, "live": live, "inference": inference}

func _test_rejections() -> void:
	for args in [["",1,true],["deleted",1,true],["r",0,true],["r",31,true],["r",1,false]]:
		var f := _fixture()
		s.expect(not f.controller.start_sam_video_analysis(0,args[0],args[1],args[2]).is_empty(), "invalid request rejects %s" % str(args))
	for mode in ["draft", "selection", "frame", "no_probe", "duplicate", "geometry", "verified"]:
		var f := _fixture()
		if mode == "draft": f.live.edit_pending = true
		if mode == "selection": f.live.region_id = "before"
		if mode == "frame": f.live.key_index = 1
		if mode == "no_probe": f.controller.configure_sam_context(Callable())
		if mode in ["duplicate", "geometry"]:
			var record: Dictionary = f.store.get_corrected_record(11825)
			if mode == "duplicate": record.regions.append(record.regions[1].duplicate(true))
			else: record.regions[1].erase("box")
			# Corrupted live snapshot injection tests defensive checks beyond Store's ingress validation.
			f.store._corrected_records[11825] = record
		if mode == "verified": REVIEW.new([11850], true).apply(f.store)
		var before: Dictionary = f.store.freeze_snapshot()
		s.expect(not f.controller.start_sam_video_analysis(0,"r",1,true).is_empty(), "reject " + mode)
		_unchanged(f, before, "reject " + mode)

func _test_ranges_and_preview() -> void:
	for polygon in [false, true]:
		for count in [1, 5, 30]:
			var f := _fixture(32, polygon)
			var before: Dictionary = f.store.freeze_snapshot()
			s.expect_equal(f.controller.start_sam_video_analysis(0,"r",count,true), PackedStringArray(), "valid Box/Poly count starts")
			s.expect(f.controller.get_plan().is_empty(), "no publication while running")
			if f.controller.has_method("step_provider_availability"):
				f.controller.step_provider_availability(&"sam_video")
				s.expect(f.controller.is_analyzing() and f.controller.get_plan().is_empty(), "availability polling never advances active inference")
			f.controller.step_analysis()
			var plan: Dictionary = f.controller.get_plan()
			s.expect(not _has_object(plan), "published SAM plan contains no live Store, Source or history capability")
			s.expect_equal(plan.get("generated_count"), count, "requested next Source entries generated")
			s.expect_equal(plan.get("end_index"), count, "forward Source order despite sparse IDs")
			s.expect(not plan.get("risks", []).is_empty(), "sparse gaps produce risk hints")
			s.expect(not plan.get("target_regions", {}).has(11825), "keyframe excluded")
			var preview: Dictionary = f.controller.preview(0, count, "overwrite")
			s.expect_equal(preview.get("errors"), PackedStringArray(), "SAM scoped preview succeeds")
			var target: Dictionary = preview.get("after", {}).get(11850, {})
			if not target.is_empty():
				s.expect_equal(target.regions[0], before.records[1].regions[0], "preceding region exact")
				s.expect_equal(target.regions[2], before.records[1].regions[2], "following region exact")
				s.expect_equal(target.regions[1]["class"], "target", "target class preserved")
				s.expect_equal(target.regions[1].track_id, "T1", "target track preserved")
				s.expect_equal(target.regions[1].conf, 0.73, "confidence preserved")
				s.expect_equal(target.regions[1].filled, false, "target filled display state preserved")
				s.expect(not target.regions[1].has("box") and target.regions[1].has("polygon"), "geometry becomes only Poly")
			if count >= 5:
				var appended: Dictionary = preview.get("after", {}).get(11875, {})
				s.expect_equal(appended.get("regions", []).slice(0,2), before.records[2].regions, "absent selected ID preserves all existing order")
				if appended.get("regions", []).size() == 3:
					s.expect_equal(appended.regions[2].track_id, "T0", "append copies key shell")
					s.expect_equal(appended.regions[2].filled, true, "append copies key filled display state")
			_unchanged(f, before, "preview")
			f.controller.cancel()
			_unchanged(f, before, "cancel")
	for mode in ["end", "verified"]:
		var f := _fixture(4)
		if mode == "verified": REVIEW.new([11875], true).apply(f.store)
		f.controller.start_sam_video_analysis(0,"r",5,true)
		f.controller.step_analysis()
		var plan: Dictionary = f.controller.get_plan()
		s.expect_equal(plan.get("generated_count"), 3 if mode == "end" else 1, "shortened " + mode)
		s.expect_equal(plan.get("requested_count"), 5, "original requested count retained")
		s.expect_equal(plan.get("stop", {}).get("kind"), "source_end" if mode == "end" else "verified_target", "structured range stop")

func _test_invalidation() -> void:
	for phase in ["running", "published", "previewed"]:
		for mode in ["source", "revision", "review", "session", "key", "selection", "frame", "draft"]:
			var f := _fixture()
			f.controller.start_sam_video_analysis(0,"r",2,true)
			if phase != "running": f.controller.step_analysis()
			if phase == "previewed": f.controller.preview(0,2,"merge")
			if mode == "source": f.source.entries[1].frame_id += 1
			if mode == "revision": f.store._revision += 1
			if mode == "review": REVIEW.new([11850],true).apply(f.store)
			if mode == "session": f.store._session["session_id"] = "replaced"
			if mode == "key":
				var record: Dictionary = f.store.get_corrected_record(11825)
				record.regions[1]["class"] = "edited"
				f.store.replace_corrected_record(11825, record)
			if mode == "selection": f.live.region_id = "before"
			if mode == "frame": f.live.key_index = 1
			if mode == "draft": f.live.edit_pending = true
			var before: Dictionary = f.store.freeze_snapshot()
			if phase == "running": f.controller.step_analysis()
			elif phase == "published": f.controller.preview(0,2,"merge")
			else: s.expect(not f.controller.apply_preview().is_empty(), "stale apply refuses")
			s.expect(f.controller.get_plan().is_empty(), "%s invalidates %s" % [mode, phase])
			_unchanged(f, before, "stale " + mode)

func _test_stops() -> void:
	for stop_at in [0,1]:
		var f := _fixture()
		f.inference.stop_at = stop_at
		var before: Dictionary = f.store.freeze_snapshot()
		f.controller.start_sam_video_analysis(0,"r",3,true)
		f.controller.step_analysis()
		var plan: Dictionary = f.controller.get_plan()
		s.expect_equal(plan.get("generated_count"), stop_at, "valid topology prefix retained")
		s.expect_equal(plan.get("stop", {}).get("kind"), "model_topology", "topology structured stop")
		s.expect_equal(plan.get("stop", {}).get("frame_id"), 11850 + stop_at * 25, "stop names first refused target")
		f.controller.preview(0,stop_at,"merge")
		_unchanged(f, before, "topology prefix")
	# 这些已分类模型拒绝来自推理边界；掩码几何验证由真实 Service 的独立测试负责。
	for reason in ["empty mask", "full mask", "multiple components", "hole", "degenerate", "self-intersecting", ">2048 vertices", "non-lossless round-trip"]:
		var f := _fixture()
		f.inference.stop_at = 1
		f.inference.stop_reason = reason
		var before: Dictionary = f.store.freeze_snapshot()
		f.controller.start_sam_video_analysis(0,"r",3,true)
		f.controller.step_analysis()
		var plan: Dictionary = f.controller.get_plan()
		s.expect_equal(plan.get("generated_count"), 1, "classified refusal retains valid prefix: " + reason)
		s.expect_equal(plan.get("target_regions", {}).keys(), [11850], "refused and later targets excluded: " + reason)
		s.expect_equal(plan.get("stop", {}).get("kind"), "model_topology", "classified refusal remains model stop: " + reason)
		s.expect(not f.controller.preview(0,2,"merge").get("errors", []).is_empty(), "preview cannot extend after refused target: " + reason)
		_unchanged(f, before, "classified refusal " + reason)
	var post_stop := _fixture()
	post_stop.inference.stop_at = 1
	post_stop.inference.append_after_stop = true
	post_stop.controller.start_sam_video_analysis(0,"r",3,true)
	post_stop.controller.step_analysis()
	s.expect(post_stop.controller.get_plan().is_empty(), "inconsistent service result cannot include post-stop targets")
	for mode in ["protocol", "context", "system", "identity", "region"]:
		var f := _fixture()
		if mode == "identity": f.inference.bad_identity = true
		elif mode == "region": f.inference.bad_region = true
		else: f.inference.fault = mode
		var before: Dictionary = f.store.freeze_snapshot()
		f.controller.start_sam_video_analysis(0,"r",3,true)
		f.controller.step_analysis()
		s.expect(f.controller.get_plan().is_empty(), "entire plan discarded on " + mode)
		s.expect(not f.controller.last_error.is_empty(), "fault surfaced without fallback")
		_unchanged(f, before, "model failure")

func _unchanged(f: Dictionary, before: Dictionary, label: String) -> void:
	s.expect_equal(f.store.freeze_snapshot(), before, label + " preserves complete Store snapshot")
	s.expect_equal(f.history.get_undo_count(), 0, label + " preserves history")

func _has_object(value: Variant) -> bool:
	if value is Object: return true
	if value is Dictionary:
		for item in value.values():
			if _has_object(item): return true
	if value is Array:
		for item in value:
			if _has_object(item): return true
	return false

func _test_completion_signal() -> void:
	var f := _fixture()
	f.inference.on_step = func(): REVIEW.new([11850], true).apply(f.store)
	f.controller.start_sam_video_analysis(0,"r",3,true)
	f.controller.step_analysis()
	f.inference.on_step = Callable()
	s.expect(f.controller.get_plan().is_empty(), "review signal during service completion cancels publication")
	s.expect(not f.controller.is_analyzing(), "completion cancellation leaves controller idle")
	s.expect_equal(f.history.get_undo_count(), 0, "completion cancellation creates no history")

func _test_existing_history() -> void:
	var f := _fixture()
	s.expect_equal(f.history.execute(REVIEW.new([11825], true), f.store), PackedStringArray(), "prior key review command is valid")
	var before: Dictionary = f.store.freeze_snapshot()
	s.expect_equal(f.controller.start_sam_video_analysis(0,"r",3,true), PackedStringArray(), "previously verified key remains a legal anchor")
	f.controller.step_analysis()
	f.controller.preview(0,3,"overwrite")
	s.expect_equal(f.store.freeze_snapshot(), before, "preview preserves existing key review and whole Store")
	s.expect_equal(f.history.get_undo_count(), 1, "preview preserves nonempty history")
	f.controller.cancel()
	s.expect_equal(f.history.get_undo_count(), 1, "cancel preserves nonempty history")
	s.expect_equal(f.store.freeze_snapshot(), before, "cancel preserves existing key review and whole Store")

func _test_real_service() -> void:
	if not CONTROLLER.new().has_method("provider_availability") or not CONTROLLER.new().has_method("step_provider_availability"):
		s.expect(false, "cold SAM preflight must advance to ready through public Controller availability API")
		return
	var env_names := ["PROJECT6_MODEL_PYTHON", "PROJECT6_SAM2_CONFIG", "PROJECT6_SAM2_CHECKPOINT", "PROJECT6_SAM2_DEVICE", "SAM_VIDEO_FAKE_MODE"]
	var saved := {}
	for key in env_names: saved[key] = OS.get_environment(key)
	var path := "/tmp/sam-video-controller-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_absolute(path)
	for name in ["config.yaml", "checkpoint.pt"]:
		var file := FileAccess.open(path.path_join(name), FileAccess.WRITE)
		file.store_string("fixture")
		file.close()
	OS.set_environment("PROJECT6_MODEL_PYTHON", "/usr/bin/python3")
	OS.set_environment("PROJECT6_SAM2_CONFIG", path.path_join("config.yaml"))
	OS.set_environment("PROJECT6_SAM2_CHECKPOINT", path.path_join("checkpoint.pt"))
	OS.set_environment("PROJECT6_SAM2_DEVICE", "cpu")
	for mode in ["ok", "topology", "hole", "empty", "full", "binary", "protocol", "context", "hash", "wrong_frame"]:
		OS.set_environment("SAM_VIDEO_FAKE_MODE", mode)
		var f := _fixture(4)
		var service = load("res://client/services/sam_video_service.gd").new()
		service.job_root = path.path_join("jobs-" + mode)
		service.worker_path = "res://tests/fixtures/fake_sam_video_worker.py"
		var probe_count_path := path.path_join("probe-" + mode + ".txt")
		service.preflight_probe_code = "import hashlib,json,sys; open(%s, 'a').write('probe\\n'); print(json.dumps({'torch': True, 'sam2': True, 'cuda': False, 'model_version': '1.1.0', 'checkpoint_sha256': hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest(), 'session_id': sys.argv[2]}))" % JSON.stringify(probe_count_path)
		# 唯一配置替换发生在外部预检/推理边界；之后只使用公开 Controller 生命周期。
		f.controller._providers[&"sam_video"].service = service
		var before: Dictionary = f.store.freeze_snapshot()
		s.expect_equal(f.controller.start_analysis(0, 0.1), PackedStringArray(), "legacy scanner starts before cold availability check")
		var state: Dictionary = f.controller.provider_availability(&"sam_video")
		s.expect(not state.get("available", true) and state.get("details", {}).get("busy", false), "cold query exposes checking state " + mode)
		s.expect(f.controller.is_analyzing(), "availability does not replace running copy analysis")
		state = f.controller.provider_availability(&"sam_video")
		s.expect(not state.get("available", true) and state.get("details", {}).get("busy", false), "repeat query retains the same pending preflight")
		f.controller.step_provider_availability(&"sam_video")
		s.expect(f.controller.is_analyzing() and f.controller.get_plan().is_empty(), "availability stepping does not advance the legacy scanner")
		while f.controller.is_analyzing(): f.controller.step_analysis()
		var copy_plan: Dictionary = f.controller.get_plan()
		s.expect(not copy_plan.is_empty(), "legacy copy plan remains usable")
		var deadline := Time.get_ticks_msec() + 5000
		while not state.get("available", false) and Time.get_ticks_msec() < deadline:
			state = f.controller.step_provider_availability(&"sam_video")
			await create_timer(0.005).timeout
		s.expect(state.get("available", false) and state.get("details", {}).get("status") == "ready", "public cold preflight reaches ready " + mode)
		s.expect_equal(FileAccess.get_file_as_string(probe_count_path), "probe\n", "polling launches one external preflight " + mode)
		s.expect_equal(f.controller.get_plan(), copy_plan, "availability polling preserves the existing copy plan")
		s.expect(f.controller.last_error.is_empty(), "availability never runs uninitialized SAM context validation")
		_unchanged(f, before, "cold preflight")
		s.expect_equal(f.controller.start_sam_video_analysis(0,"r",3,true), PackedStringArray(), "real service starts " + mode)
		deadline = Time.get_ticks_msec() + 5000
		while f.controller.is_analyzing() and Time.get_ticks_msec() < deadline:
			f.controller.step_analysis()
			await create_timer(0.005).timeout
		s.expect(not f.controller.is_analyzing(), "real service completes " + mode)
		var plan: Dictionary = f.controller.get_plan()
		if mode in ["ok", "topology", "hole", "empty", "full"]:
			s.expect_equal(plan.get("generated_count"), 3 if mode == "ok" else 1, "real masks enforce prefix " + mode)
			if mode != "ok": s.expect_equal(plan.get("stop", {}).get("kind"), "model_topology", "real mask stop classified " + mode)
			if not plan.is_empty():
				var preview: Dictionary = f.controller.preview(0, plan.end_index, "merge")
				s.expect_equal(preview.get("errors"), PackedStringArray(), "real service polygons preview " + mode)
				for record: Dictionary in preview.get("after", {}).values():
					s.expect_equal(f.store._validator.validate_record(STORE._model_output_projection(record)), PackedStringArray(), "preview produces valid V1 records")
		else:
			s.expect(plan.is_empty(), "real protocol/integrity fault rejects entire plan " + mode)
			s.expect(not f.controller.last_error.is_empty(), "real fault is actionable " + mode)
		_unchanged(f, before, "real service " + mode)
		f.controller.cancel()
		service.shutdown()
	for key in env_names:
		if saved[key].is_empty(): OS.unset_environment(key)
		else: OS.set_environment(key, saved[key])
	# Service cleans only its owned jobs; retain this bounded fixture root as test evidence.
