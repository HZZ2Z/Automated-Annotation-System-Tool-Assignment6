extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const PROBE := "import hashlib,json,sys; print(json.dumps({'torch': True, 'sam2': True, 'cuda': False, 'model_version': '1.1.0', 'checkpoint_sha256': hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest(), 'session_id': sys.argv[2]}))"
const ENV := ["PROJECT6_MODEL_PYTHON", "PROJECT6_SAM2_CONFIG", "PROJECT6_SAM2_CHECKPOINT", "PROJECT6_SAM2_DEVICE", "SAM_VIDEO_FAKE_MODE"]
var support = SUPPORT.new()
var service_script: Script
var fixture := ""
var serial := 0

class Source extends RefCounted:
	var entries: Array = [{"frame_id": 11825, "time_s": 7.0 / 30.0}, {"frame_id": 11850, "time_s": 0.5}, {"frame_id": 11875}]
	var changed_image := false
	var loads := 0
	func get_frame_entry(index: int) -> Dictionary:
		return entries[index].duplicate(true)
	func load_texture(index: int) -> ImageTexture:
		return ImageTexture.create_from_image(load_image_snapshot_uncached(index))
	func load_image_snapshot_uncached(index: int) -> Image:
		loads += 1
		var image := Image.create(80, 60, false, Image.FORMAT_RGB8)
		image.fill(Color.RED if changed_image else Color(float(index) / 4.0, 0.2, 0.3))
		return image

class CachedOnlySource extends RefCounted:
	var backing := Source.new()
	func get_frame_entry(index: int) -> Dictionary: return backing.get_frame_entry(index)
	func load_texture(index: int) -> ImageTexture: return backing.load_texture(index)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not FileAccess.file_exists("res://client/services/sam_video_service.gd"):
		printerr("FAIL sam video service: production service missing (expected RED)")
		quit(1)
		return
	service_script = load("res://client/services/sam_video_service.gd")
	if service_script == null or not service_script.can_instantiate():
		printerr("FAIL sam video service cannot instantiate")
		quit(1)
		return
	var saved := {}
	for key in ENV:
		saved[key] = OS.get_environment(key)
	fixture = "/tmp/project6-sam-video-test-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_absolute(fixture)
	_write(fixture.path_join("config.yaml"), "fake config")
	_write(fixture.path_join("checkpoint.pt"), "fake checkpoint")
	await _preflight_cases()
	await _default_probe_version()
	await _happy_path()
	await _faults()
	await _stale()
	await _cancel_restart()
	await _completion_races()
	await _cap_and_residency()
	await _input_contracts()
	await _availability_during_batch()
	await _termination_failure()
	await _fresh_source_boundary()
	await _candidate_classification()
	await _links_and_owned_cleanup()
	for key in ENV:
		if saved[key].is_empty(): OS.unset_environment(key)
		else: OS.set_environment(key, saved[key])
	_remove_tree(fixture)
	if support.failures.is_empty():
		print("PASS sam video service lifecycle and fault matrix")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)

func _environment(mode := "ok") -> void:
	OS.set_environment("PROJECT6_MODEL_PYTHON", "/usr/bin/python3")
	OS.set_environment("PROJECT6_SAM2_CONFIG", fixture.path_join("config.yaml"))
	OS.set_environment("PROJECT6_SAM2_CHECKPOINT", fixture.path_join("checkpoint.pt"))
	OS.set_environment("PROJECT6_SAM2_DEVICE", "cpu")
	OS.set_environment("SAM_VIDEO_FAKE_MODE", mode)

func _ready(mode := "ok"):
	_environment(mode)
	var service = service_script.new()
	serial += 1
	service.job_root = fixture.path_join("jobs-%d" % serial)
	service.worker_path = "res://tests/fixtures/fake_sam_video_worker.py"
	service.preflight_probe_code = PROBE
	service.preflight()
	await _pump(service, func(): return not service._state.get("busy", false))
	support.expect(service._state.get("ok", false), "fixture external probe establishes readiness: " + str(service._state))
	return service

func _context() -> Dictionary:
	return {"session_id": "test-session", "request_nonce": "test-request", "key_playback_index": 0, "key_frame_id": 11825, "key_time_s": 7.0 / 30.0, "store_revision": 4, "review_sha256": "a".repeat(64), "key_record_sha256": "b".repeat(64), "region_id": "region-7", "propagation_count": 2, "requested_device": "cpu"}

func _mask() -> Dictionary:
	var bits := PackedByteArray()
	bits.resize(12)
	bits.fill(1)
	return {"roi": Rect2i(10, 12, 4, 3), "mask": bits}

func _pump(service, predicate: Callable, limit := 4000) -> void:
	var deadline := Time.get_ticks_msec() + limit
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		service.step()
		await create_timer(0.005).timeout
	support.expect(predicate.call(), "service reaches bounded expected state: " + service.progress_text())

func _preflight_cases() -> void:
	for key in ENV.slice(0, 4):
		_environment()
		var service = service_script.new()
		if key == "PROJECT6_SAM2_DEVICE": OS.set_environment(key, "metal")
		else: OS.unset_environment(key)
		var state: Dictionary = service.preflight()
		support.expect(not state.ok and not state.busy and not state.errors.is_empty(), "missing config or bad device rejects: " + key)
		service.shutdown()
	for mode in ["torch", "sam2", "cuda", "timeout"]:
		_environment()
		var service = service_script.new()
		service.preflight_probe_code = PROBE.replace("'%s': True" % mode, "'%s': False" % mode)
		if mode == "cuda": OS.set_environment("PROJECT6_SAM2_DEVICE", "cuda")
		if mode == "timeout":
			service.preflight_probe_code = "import time; time.sleep(30)"
			service.preflight_timeout_ms = 40
		service.preflight()
		await _pump(service, func(): return not service._state.get("busy", false))
		support.expect(not service._state.ok and not service._state.errors.is_empty(), "preflight rejects unavailable dependency: " + mode)
		service.shutdown()

	for bad_version in ["", "/home/wang/model", "x".repeat(65), "1.1.0\n"]:
		_environment()
		var service = service_script.new()
		service.preflight_probe_code = PROBE.replace("'1.1.0'", JSON.stringify(bad_version))
		service.preflight()
		await _pump(service, func(): return not service._state.get("busy", false))
		support.expect(not service._state.ok and not service._state.errors.is_empty(), "preflight refuses invalid reported model version " + JSON.stringify(bad_version))
		service.shutdown()

func _default_probe_version() -> void:
	_environment()
	var packages := fixture.path_join("probe-packages")
	DirAccess.make_dir_recursive_absolute(packages.path_join("sam_2-7.6.5.dist-info"))
	_write(packages.path_join("torch.py"), "class cuda:\n @staticmethod\n def is_available(): return False\n")
	_write(packages.path_join("sam2.py"), "__version__ = '9.9.9'\n")
	_write(packages.path_join("sam_2-7.6.5.dist-info/METADATA"), "Metadata-Version: 2.1\nName: SAM-2\nVersion: 7.6.5\n")
	var previous_path := OS.get_environment("PYTHONPATH")
	OS.set_environment("PYTHONPATH",packages)
	var service = service_script.new()
	service.job_root = fixture.path_join("default-probe-jobs")
	service.worker_path = "res://tests/fixtures/fake_sam_video_worker.py"
	# 使用生产预检脚本和真实 Python 包元数据读取，仅模型安装内容是受控外部夹具。
	service.preflight()
	await _pump(service,func(): return not service._state.get("busy",false))
	support.expect(service._state.get("ok",false),"default external preflight reads installed package metadata")
	if service._state.get("ok",false):
		support.expect_equal(service.begin(_context(),Source.new(),Source.new().entries,_mask()),PackedStringArray(),"default probe runtime starts a batch")
		await _pump(service,func(): return not service.is_running())
		support.expect_equal(service.get_result().get("runtime",{}).get("model_version"),"7.6.5","default probe reports installed package version rather than module fallback or hardcoded model label")
	service.shutdown()
	if previous_path.is_empty(): OS.unset_environment("PYTHONPATH")
	else: OS.set_environment("PYTHONPATH",previous_path)

func _happy_path() -> void:
	var service = await _ready()
	var source := Source.new()
	var ctx := _context()
	var deliveries := []
	service.batch_ready.connect(func(value): deliveries.append(value))
	support.expect(service.begin(ctx, source, source.entries, _mask()).is_empty(), "valid sparse Source begins without Store capability")
	var job: String = service._job_dir
	await _pump(service, func(): return not service.is_running())
	var result: Dictionary = service.get_result()
	support.expect(result.get("errors", ["missing"]).is_empty(), "happy result has no failures: " + str(result))
	support.expect_equal(deliveries.size(), 1, "only one completed batch is published")
	support.expect_equal(result.get("provider_id"), "sam_video", "provider identity retained")
	var proposals: Array = result.get("proposals", [])
	support.expect_equal(proposals.size(), 2, "key excluded and both targets retained")
	if proposals.size() == 2:
		support.expect_equal([proposals[0].playback_index, proposals[0].frame_id, proposals[0].time_s, proposals[0].region_id, proposals[0].object_id], [1, 11850, 0.5, "region-7", 1], "proposal retains exact identities")
		support.expect(not proposals[1].has("time_s"), "absent target time remains absent")
		support.expect_equal(proposals[1].frame_id, 11875, "sparse frame id is never treated as local order")
		proposals[0].mask.path = "tampered"
		support.expect(service.get_result().proposals[0].mask.path != "tampered", "nested results are deep copies")
		var polygon: Variant = proposals[0].get("polygon")
		support.expect(polygon is PackedVector2Array and polygon.size() >= 3, "service publishes the already validated transient polygon")
		if polygon is PackedVector2Array and not polygon.is_empty():
			polygon[0] = Vector2(-100, -100)
			support.expect(service.get_result().proposals[0].polygon[0] != Vector2(-100, -100), "transient polygon is a defensive copy")
	support.expect(not JSON.stringify(result.get("runtime", {})).contains(job), "runtime contains no service-owned job path")
	support.expect_equal(result.get("runtime", {}).get("model_version"), "1.1.0", "runtime exposes the externally reported SAM model version")
	support.expect_equal(DirAccess.get_files_at(job.path_join("inputs")).size(), 3, "exactly one key and two lossless inputs")
	var decoded := Image.new()
	decoded.load(job.path_join(service._key_descriptor.path))
	support.expect_equal(decoded.get_size(), Vector2i(80, 60), "key ROI expanded to full resolution")
	support.expect_equal(decoded.get_pixel(10, 12), Color.WHITE, "key foreground preserved")
	support.expect_equal(decoded.get_pixel(9, 12), Color.BLACK, "key background preserved")
	support.expect(service.validate_source().is_empty(), "frozen sources revalidate after completion")
	service.shutdown()
	support.expect(not DirAccess.dir_exists_absolute(job), "shutdown removes owned job")
	var too_many = await _ready()
	ctx.propagation_count = 31
	support.expect(not too_many.begin(ctx, source, source.entries, _mask()).is_empty(), "31 targets rejected before any Source load")
	too_many.shutdown()

func _faults() -> void:
	for mode in ["duplicate", "extra", "malformed", "overlong", "protocol", "request_id", "context", "hello_pid", "hello_session", "traversal", "hash", "size", "roi", "binary", "linked_output", "linked_inputs", "replace_reset", "crash", "eof", "hang_hello", "hang_open_batch", "hang_propagate", "wrong_frame", "extra_mask", "bool_identity", "context_time", "context_time_presence"]:
		var service = await _ready(mode)
		service.load_timeout_ms = 200
		service.open_timeout_ms = 200
		service.propagate_timeout_ms = 200
		var source := Source.new()
		support.expect(service.begin(_context(), source, source.entries, _mask()).is_empty(), "fault fixture begins: " + mode)
		var job: String = service._job_dir
		await _pump(service, func(): return not service.is_running())
		var result: Dictionary = service.get_result()
		support.expect(not result.get("errors", []).is_empty(), "whole batch invalidated: " + mode + " " + str(result))
		support.expect(result.get("proposals", []).is_empty(), "no valid prefix escapes protocol/file/process error: " + mode)
		service.shutdown()
		support.expect(not DirAccess.dir_exists_absolute(job), "failed worker job cleaned: " + mode)
	for mode in ["topology", "hole", "empty", "full"]:
		var topology = await _ready(mode)
		var source := Source.new()
		topology.begin(_context(), source, source.entries, _mask())
		await _pump(topology, func(): return not topology.is_running())
		var result: Dictionary = topology.get_result()
		support.expect(result.get("errors", ["missing"]).is_empty(), "model geometry rejection is a bounded stop: " + mode)
		support.expect_equal(result.get("proposals", []).size(), 1, "geometry rejection retains valid prefix: " + mode)
		support.expect(not str(result.get("stop", "")).is_empty(), "geometry stop reason is visible: " + mode)
		topology.shutdown()

func _candidate_classification() -> void:
	var service = await _ready()
	if not service.has_method("_candidate_refusal_category"):
		support.expect(false, "candidate refusal classification uses explicit outcomes, not English reason prefixes")
		service.shutdown()
		return
	var source := Source.new()
	service.begin(_context(), source, source.entries, _mask())
	await _pump(service, func(): return not service.is_running())
	var candidate_script = load("res://client/domain/model_assist_candidate.gd")
	for mode in ["empty", "full", "hole", "multi_component", "binary", "roi", "hash", "size", "unknown"]:
		var image := Image.create(80, 60, false, Image.FORMAT_RGB8)
		image.fill(Color.WHITE if mode == "full" else Color.BLACK)
		if mode not in ["empty", "full"]:
			for y in range(10, 20):
				for x in range(10, 20): image.set_pixel(x, y, Color.WHITE)
		if mode == "hole": image.set_pixel(15, 15, Color.BLACK)
		if mode == "multi_component": image.set_pixel(30, 30, Color.WHITE)
		if mode == "binary": image.set_pixel(15, 15, Color(0.5, 0.5, 0.5))
		var relative := "outputs/classify-%s.png" % mode
		var path: String = service._job_dir.path_join(relative)
		support.expect_equal(image.save_png(path), OK, "classification fixture writes real PNG: " + mode)
		var descriptor := {"path": relative, "roi": [0, 0, 80, 60], "score": 0.8, "sha256": FileAccess.get_sha256(path)}
		if mode == "roi": descriptor.roi = [-1, 0, 80, 60]
		if mode == "hash": descriptor.sha256 = "0".repeat(64)
		if mode == "size": descriptor.roi = [0, 0, 79, 60]
		var validation: Dictionary = candidate_script.validate_file(service._job_dir, descriptor, Vector2i(80, 60))
		support.expect_equal(validation.ok, mode == "unknown", "real validator establishes classification fixture: " + mode)
		var expected := &"geometry" if mode in ["empty", "full", "hole", "multi_component"] else &"integrity"
		support.expect_equal(service._candidate_refusal_category(descriptor), expected, "explicit candidate refusal category: " + mode)
	service.shutdown()

func _stale() -> void:
	for field in ["session_id", "store_revision", "review_sha256", "key_record_sha256", "region_id", "entry", "image"]:
		var service = await _ready("delay")
		var source := Source.new()
		var ctx := _context()
		service.begin(ctx, source, source.entries, _mask())
		await _pump(service, func(): return service.progress_text() == "propagate" or not service.is_running())
		if field == "entry": source.entries[1].frame_id = 999
		elif field == "image": source.changed_image = true
		elif field == "store_revision": ctx[field] += 1
		else: ctx[field] = "changed"
		await _pump(service, func(): return not service.is_running())
		support.expect(not service.get_result().get("errors", []).is_empty(), "stale identity invalidates batch: " + field)
		support.expect(service.get_result().get("proposals", []).is_empty(), "stale identity publishes no masks: " + field)
		service.shutdown()

func _cancel_restart() -> void:
	var service = await _ready("delay")
	var source := Source.new()
	var ready := []
	service.batch_ready.connect(func(value): ready.append(value))
	service.begin(_context(), source, source.entries, _mask())
	await _pump(service, func(): return service.progress_text() == "propagate" or not service.is_running())
	var job: String = service._job_dir
	service.cancel()
	await create_timer(0.2).timeout
	service.step()
	support.expect(ready.is_empty() and service.get_result().is_empty(), "cancel retires generation before any late publication")
	support.expect(not DirAccess.dir_exists_absolute(job), "cancel reaps worker before removing job")
	OS.set_environment("SAM_VIDEO_FAKE_MODE", "crash")
	service.begin(_context(), source, source.entries, _mask())
	await _pump(service, func(): return not service.is_running())
	support.expect(not service.get_result().get("errors", []).is_empty(), "fatal failure observed before retry")
	OS.set_environment("SAM_VIDEO_FAKE_MODE", "ok")
	support.expect(service.begin(_context(), source, source.entries, _mask()).is_empty(), "same service can restart after fatal failure")
	await _pump(service, func(): return not service.is_running())
	support.expect_equal(service.get_result().get("proposals", []).size(), 2, "retry uses new independent worker")
	service.shutdown()

func _completion_races() -> void:
	# Removing the generation/context recheck after state_changed would allow a
	# callback's cancellation or annotation change to publish a stale batch.
	for action in ["cancel", "context", "failure_cancel", "worker_exit", "read_only"]:
		var service = await _ready("wrong_frame" if action == "failure_cancel" else "ok")
		var source := Source.new()
		var ctx := _context()
		var delivered := []
		var observed_results := []
		var observed_running := []
		service.batch_ready.connect(func(result): delivered.append(result))
		var on_state := func(state):
			if state.status == "failed" and action == "failure_cancel": service.cancel()
			if state.status == "ready":
				if action == "cancel": service.cancel()
				elif action == "context": ctx.store_revision += 1
				elif action == "worker_exit":
					var pid: int = service._pid
					support.expect_equal(OS.kill(pid), OK, "worker termination at the final publication boundary succeeds")
					var deadline := Time.get_ticks_msec() + 250
					while DirAccess.dir_exists_absolute("/proc/%d" % pid) and Time.get_ticks_msec() < deadline: OS.delay_msec(5)
					support.expect(not DirAccess.dir_exists_absolute("/proc/%d" % pid), "worker has exited before the ready callback returns")
				if action in ["context", "worker_exit", "read_only"]:
					observed_results.append(service.get_result())
					observed_running.append(service.is_running())
		service.state_changed.connect(on_state)
		service.begin(ctx, source, source.entries, _mask())
		await _pump(service, func(): return not service.is_running())
		if action in ["cancel", "failure_cancel"]:
			support.expect(delivered.is_empty(), "completion callback cancellation publishes nothing")
		elif action == "read_only":
			support.expect_equal(service.get_result().get("proposals", []).size(), 2, "validated success becomes public only after the completion barrier")
		else:
			support.expect(not service.get_result().get("errors", []).is_empty(), "completion callback context/process change invalidates result: " + action)
			support.expect(service.get_result().get("proposals", []).is_empty(), "completion callback cannot expose stale proposals")
		if action in ["context", "worker_exit", "read_only"]:
			support.expect(observed_results.size() == 1 and observed_results[0].is_empty(), "callback-local get_result cannot observe staged proposals: " + action)
			support.expect_equal(observed_running, [true], "batch remains running until completion validation finishes: " + action)
		service.state_changed.disconnect(on_state)
		service.shutdown()

func _cap_and_residency() -> void:
	var service = await _ready()
	var source := Source.new()
	for index in range(3, 32): source.entries.append({"frame_id": 11825 + 25 * index})
	var ctx := _context()
	ctx.propagation_count = 30
	support.expect(service.begin(ctx, source, source.entries, _mask()).is_empty(), "30 targets fit the cap")
	var pid: int = service._pid
	var job: String = service._job_dir
	await _pump(service, func(): return not service.is_running(), 6000)
	support.expect_equal(service.get_result().get("proposals", []).size(), 30, "all 30 bounded targets accepted")
	support.expect_equal(DirAccess.get_files_at(job.path_join("inputs")).size(), 31, "one key plus 30 inputs is the physical cap")
	ctx = _context()
	ctx.request_nonce = "second-request"
	support.expect(service.begin(ctx, source, source.entries, _mask()).is_empty(), "reset batch permits a fresh request")
	await _pump(service, func(): return not service.is_running())
	support.expect_equal(service._pid, pid, "successful reset retains independent resident worker")
	support.expect_equal(service.get_result().get("proposals", []).size(), 2, "fresh resident request returns only new targets")
	support.expect_equal(DirAccess.get_files_at(job.path_join("inputs")).size(), 3, "new batch replaces old input set")
	ctx.propagation_count = 31
	var loads: int = source.loads
	support.expect(not service.begin(ctx, source, source.entries, _mask()).is_empty(), "31 targets refused despite available Source entries")
	support.expect_equal(source.loads, loads, "oversized request rejected before reading images")
	support.expect(service.get_result().is_empty(), "a rejected new request cannot expose the previous batch result")
	service.shutdown()

func _links_and_owned_cleanup() -> void:
	var service = await _ready()
	var outside := fixture.path_join("outside")
	DirAccess.make_dir_absolute(outside)
	_write(outside.path_join("keep.txt"), "preserve")
	var link := fixture.path_join("linked-root")
	OS.execute("/usr/bin/ln", PackedStringArray(["-s", outside, link]))
	service.job_root = link
	var source := Source.new()
	support.expect(not service.begin(_context(), source, source.entries, _mask()).is_empty(), "linked job root rejected")
	service.shutdown()
	support.expect(FileAccess.file_exists(outside.path_join("keep.txt")), "linked root target untouched")
	service = await _ready("delay")
	service.begin(_context(), source, source.entries, _mask())
	var sibling: String = service._job_parent.path_join("sam-video-unowned")
	DirAccess.make_dir_absolute(sibling)
	_write(sibling.path_join("keep.txt"), "preserve")
	var captured_pid: int = service._pid
	support.expect(service._kill_owned_process(captured_pid + 1, service._worker_nonce) != OK, "wrong PID is never killed")
	support.expect(service._kill_owned_process(captured_pid, "wrong-nonce") != OK, "wrong session nonce is never killed")
	service.cancel()
	support.expect(FileAccess.file_exists(sibling.path_join("keep.txt")), "cleanup only touches exact owned job")
	service.shutdown()

func _input_contracts() -> void:
	var decoded_service = await _ready()
	var decoded_source := Source.new()
	for entry in decoded_source.entries: entry.frame_id = float(entry.frame_id)
	var decoded_errors: PackedStringArray = decoded_service.begin(_context(), decoded_source, decoded_source.entries, _mask())
	support.expect(decoded_errors.is_empty(), "Source JSON numeric frame IDs normalize to exact protocol integers")
	if decoded_errors.is_empty():
		await _pump(decoded_service, func(): return not decoded_service.is_running())
		support.expect_equal(decoded_service.get_result().get("proposals", []).size(), 2, "decoded Source frames retain sparse identities")
	decoded_service.shutdown()
	for geometry in [{"box": [10, 12, 4, 3]}, {"polygon": [[10, 12], [14, 12], [14, 15], [10, 15]]}]:
		var service = await _ready()
		var source := Source.new()
		var errors: PackedStringArray = service.begin(_context(), source, source.entries, geometry)
		support.expect(errors.is_empty(), "V1 Box/Poly can be rasterized by the service: " + str(errors))
		if errors.is_empty():
			await _pump(service, func(): return not service.is_running())
			support.expect_equal(service.get_result().get("proposals", []).size(), 2, "rasterized anchor reaches candidate pipeline")
		service.shutdown()
	for geometry in [{"box": [-1, 12, 4, 3]}, {"polygon": [[-1, 12], [14, 12], [14, 15], [-1, 15]]}, {"polygon": [[10, 12], [14, 15], [10, 15], [14, 12]]}]:
		var service = await _ready()
		var source := Source.new()
		support.expect(not service.begin(_context(), source, source.entries, geometry).is_empty(), "out-of-bounds or self-intersecting anchor is refused")
		service.shutdown()
	var service = await _ready()
	var source := Source.new()
	var ctx := _context()
	ctx.store_revision = 9007199254740993
	support.expect(not service.begin(ctx, source, source.entries, _mask()).is_empty(), "unrepresentable JSON integer is rejected before launch")
	service.shutdown()

func _availability_during_batch() -> void:
	var service = await _ready("delay")
	var availability_events := []
	service.state_changed.connect(func(state): availability_events.append(state))
	service.preflight()
	support.expect(availability_events.is_empty(), "cached ready availability does not emit a recursive state update")
	var source := Source.new()
	service.begin(_context(), source, source.entries, _mask())
	await _pump(service, func(): return service.progress_text() == "propagate" or not service.is_running())
	var state: Dictionary = service.preflight()
	support.expect(state.get("ok", false) and state.get("busy", false) and state.get("status") == "propagate", "availability inspection preserves a running batch")
	await _pump(service, func(): return not service.is_running())
	support.expect_equal(service.get_result().get("proposals", []).size(), 2, "availability inspection does not clear the frozen runtime")
	service.shutdown()

func _termination_failure() -> void:
	var service = await _ready("hang_propagate")
	service.cancel_grace_ms = 20
	service.shutdown_grace_ms = 20
	var source := Source.new()
	service.begin(_context(), source, source.entries, _mask())
	await _pump(service, func(): return service.progress_text() == "propagate" or not service.is_running())
	var job: String = service._job_dir
	var nonce: String = service._process_nonce
	service._process_nonce = "retired-nonce"
	service.cancel()
	support.expect(DirAccess.dir_exists_absolute(job), "failed termination retains files until its worker is stopped")
	support.expect(not service.begin(_context(), source, source.entries, _mask()).is_empty(), "failed termination cannot reuse files under a running worker")
	service._process_nonce = nonce
	service.shutdown()
	support.expect(not DirAccess.dir_exists_absolute(job), "owned retry terminates and then removes exact job")

func _fresh_source_boundary() -> void:
	var unsupported = await _ready()
	var cached_only := CachedOnlySource.new()
	support.expect(not unsupported.begin(_context(), cached_only, cached_only.backing.entries, _mask()).is_empty(), "SAM refuses a Source without an explicit uncached snapshot capability")
	support.expect_equal(cached_only.backing.loads, 0, "unsupported Source is refused before any cached image read")
	unsupported.shutdown()
	for phase in ["capture", "inflight"]:
		var service = await _ready("delay")
		var source = preload("res://client/plugins/source/numeric_image_sequence_source/plugin.gd").new()
		var media := fixture.path_join("cached-sequence-" + phase)
		DirAccess.make_dir_absolute(media)
		for frame in [11825, 11850, 11875]: _save_source_png(media.path_join("%06d.png" % frame), Color.RED)
		support.expect(source.open(media).is_empty(), "real numeric Source opens cached replacement fixture")
		var entries: Array = []
		for index in range(3):
			entries.append(source.get_frame_entry(index))
			support.expect(source.load_texture(index) != null, "real Source cache is primed before SAM")
		var ctx := _context()
		ctx.key_time_s = 11825.0
		if phase == "capture": _replace_source_png(media.path_join("011825.png"), Color.GREEN)
		var errors: PackedStringArray = service.begin(ctx, source, entries, _mask())
		support.expect(errors.is_empty(), "fresh-capable real Source starts the batch: " + str(errors))
		if errors.is_empty():
			if phase == "capture":
				var image := Image.load_from_file(service._job_dir.path_join(service._frames[0].path))
				support.expect_equal(image.get_pixel(0, 0), Color.GREEN, "SAM capture reads replacement pixels despite a primed playback cache")
			else:
				await _pump(service, func(): return service.progress_text() == "propagate" or not service.is_running())
				_replace_source_png(media.path_join("011850.png"), Color.BLUE)
				support.expect_equal(source.load_texture(1).get_image().get_pixel(0, 0), Color.RED, "replacement fixture retains real stale playback cache")
			await _pump(service, func(): return not service.is_running())
			if phase == "inflight":
				support.expect(not service.get_result().get("errors", []).is_empty(), "replaced cached Source image invalidates the whole SAM batch")
				support.expect(service.get_result().get("proposals", []).is_empty(), "cached Source replacement publishes no proposals")
		service.shutdown()
		source.close()

func _save_source_png(path: String, color: Color) -> void:
	var image := Image.create(80, 60, false, Image.FORMAT_RGB8)
	image.fill(color)
	support.expect_equal(image.save_png(path), OK, "real Source fixture image is written")

func _replace_source_png(path: String, color: Color) -> void:
	var replacement := path + ".replacement.png"
	_save_source_png(replacement, color)
	support.expect_equal(DirAccess.rename_absolute(replacement, path), OK, "Source file is atomically replaced")

func _write(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()

func _remove_tree(path: String) -> void:
	var parent := DirAccess.open(path.get_base_dir())
	if parent != null and parent.is_link(path.get_file()):
		DirAccess.remove_absolute(path)
		return
	for name in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(name))
	for name in DirAccess.get_directories_at(path): _remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)
