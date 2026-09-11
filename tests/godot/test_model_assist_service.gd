extends SceneTree

const SERVICE := preload("res://client/services/model_assist_service.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")
const ENV_KEYS := [
	"PROJECT6_MODEL_PYTHON",
	"PROJECT6_SAM2_CONFIG",
	"PROJECT6_SAM2_CHECKPOINT",
	"PROJECT6_SAM2_DEVICE",
	"MODEL_ASSIST_FAKE_MODE",
	"MODEL_ASSIST_FAKE_START_LOG",
	"MODEL_ASSIST_FAKE_REQUEST_LOG",
	"MODEL_ASSIST_FAKE_HANG_MARKER",
]
const VALID_PROBE := "import hashlib,json,sys; print(json.dumps({'torch': True, 'sam2': True, 'cuda': False, 'checkpoint_sha256': hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest(), 'session_id': sys.argv[2]}))"
var _saved_environment := {}
var _root := ""
var _config := ""
var _checkpoint := ""
var _python := ""
var _timer_tree: SceneTree


func _initialize() -> void:
	_timer_tree = self
	call_deferred("_run")


func _run() -> void:
	var support = SUPPORT.new()
	await run(support, self)
	if support.failures.is_empty():
		print("PASS model assist service lifecycle")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)


func run(support, tree: SceneTree) -> void:
	_timer_tree = tree
	_save_environment()
	_make_fixture()
	await _test_preflight_messages_and_device_badges(support)
	await _test_atomic_image_and_initial_mask_snapshots(support)
	await _test_persistent_worker_sequence_cache_and_cleanup(support)
	await _test_latest_token_cancel_and_deadlines(support)
	await _test_cancel_restart_image_races_and_candidate_cleanup(support)
	await _test_session_bound_termination_failure(support)
	await _test_crash_malformed_and_oversized_responses(support)
	_restore_environment()
	_remove_tree(_root)


func _test_preflight_messages_and_device_badges(support) -> void:
	_clear_runtime_environment()
	var service = SERVICE.new()
	support.expect_equal((await _preflight_result(service)).get("message"), "模型辅助不可用：未配置外部 Python。", "missing interpreter has the exact actionable message")
	OS.set_environment("PROJECT6_MODEL_PYTHON", _root.path_join("missing-python"))
	support.expect_equal((await _preflight_result(service)).get("message"), "模型辅助不可用：外部 Python 无法执行。", "invalid interpreter has the exact actionable message")
	OS.set_environment("PROJECT6_MODEL_PYTHON", _python)
	support.expect_equal((await _preflight_result(service)).get("message"), "模型辅助不可用：未配置可读的 SAM2 config。", "missing config has the exact actionable message")
	OS.set_environment("PROJECT6_SAM2_CONFIG", _config)
	support.expect_equal((await _preflight_result(service)).get("message"), "模型辅助不可用：未配置可读的 SAM2 checkpoint。", "missing checkpoint has the exact actionable message")
	OS.set_environment("PROJECT6_SAM2_CHECKPOINT", _checkpoint)
	OS.set_environment("PROJECT6_SAM2_DEVICE", "metal")
	support.expect_equal((await _preflight_result(service)).get("message"), "模型辅助不可用：PROJECT6_SAM2_DEVICE 必须是 auto、cpu 或 cuda。", "invalid device is never guessed")
	OS.set_environment("PROJECT6_SAM2_DEVICE", "cpu")
	service.preflight_probe_code = VALID_PROBE.replace("'torch': True", "'torch': False")
	support.expect_equal((await _preflight_result(service)).get("message"), "模型辅助不可用：解释器中未安装 torch。", "missing torch is distinguished")
	service.preflight_probe_code = VALID_PROBE.replace("'sam2': True", "'sam2': False")
	support.expect_equal((await _preflight_result(service)).get("message"), "模型辅助不可用：解释器中未安装 sam2。", "missing sam2 is distinguished")
	OS.set_environment("PROJECT6_SAM2_DEVICE", "cuda")
	service.preflight_probe_code = VALID_PROBE
	support.expect_equal((await _preflight_result(service)).get("message"), "模型辅助不可用：已指定 CUDA，但当前解释器无法使用 CUDA。", "explicit CUDA never falls back")
	OS.set_environment("PROJECT6_SAM2_DEVICE", "cpu")
	var started_at := Time.get_ticks_msec()
	var checking: Dictionary = service.preflight()
	support.expect(Time.get_ticks_msec() - started_at < 200 and checking.get("status") == "checking", "package imports and checkpoint hashing never block the UI thread")
	var cpu: Dictionary = await _await_preflight(service)
	support.expect(cpu.get("ok", false), "valid CPU runtime passes preflight")
	support.expect_equal(cpu.get("badge"), "SAM2 已就绪 · CPU（较慢）", "CPU mode keeps a persistent slow badge")
	support.expect_equal(cpu.get("checkpoint_sha256"), FileAccess.get_sha256(_checkpoint), "preflight freezes the checkpoint digest")
	OS.set_environment("PROJECT6_SAM2_DEVICE", "auto")
	service.preflight_probe_code = VALID_PROBE.replace("'cuda': False", "'cuda': True")
	service.preflight()
	var automatic: Dictionary = await _await_preflight(service)
	support.expect_equal(automatic.get("device"), "cuda", "auto chooses CUDA only when the configured interpreter reports it")
	support.expect_equal(automatic.get("badge"), "SAM2 已就绪 · CUDA", "CUDA badge reports the actual device")
	service.shutdown()

	_configure_valid_environment("ok")
	service = SERVICE.new()
	service.preflight_probe_code = "import time; time.sleep(3600)"
	service.preflight_timeout_ms = 50
	var before := Time.get_ticks_msec()
	checking = service.preflight()
	support.expect(Time.get_ticks_msec() - before < 200 and checking.get("status") == "checking", "a hanging import probe returns control immediately")
	var probe_pid: int = service.get("_preflight_pid")
	await _pump_until(service, func(): return service._state.get("status") != "checking", 1000)
	support.expect_equal(service._state.get("message"), "模型辅助不可用：外部 Python 预检超时。", "hanging preflight has a bounded explicit deadline")
	support.expect(probe_pid <= 0 or not DirAccess.dir_exists_absolute("/proc/%d" % probe_pid), "preflight timeout reaps only its spawned probe")
	service.shutdown()


func _test_atomic_image_and_initial_mask_snapshots(support) -> void:
	_configure_valid_environment("ok")
	var case_root := _case_root("snapshots")
	var service = await _service(case_root)
	var state_copy: Dictionary = service.preflight()
	state_copy.badge = "tampered"
	support.expect_equal(service._state.get("badge"), "SAM2 已就绪 · CPU（较慢）", "preflight returns a defensive state snapshot")
	var image := _image()
	var digest := _image_digest(image)
	var bits := PackedByteArray()
	bits.resize(12)
	bits.fill(1)
	var initial := {"roi": Rect2i(10, 12, 4, 3), "mask": bits}
	var token: int = service.set_image(_context(digest, 0), image, initial)
	support.expect(token > 0, "valid ROI initial mask starts image caching")
	var descriptor: Variant = service._current_initial_mask
	support.expect(descriptor is Dictionary, "initial ROI mask becomes a full-image file descriptor")
	if descriptor is Dictionary:
		var mask_path: String = service._job_dir.path_join(descriptor.path)
		support.expect_equal([descriptor.width, descriptor.height], [80, 60], "initial mask descriptor uses current image dimensions")
		support.expect_equal(FileAccess.get_sha256(mask_path), descriptor.sha256, "initial mask descriptor freezes exact PNG bytes")
		var decoded := Image.new()
		support.expect_equal(decoded.load(mask_path), OK, "initial mask snapshot is readable PNG")
		support.expect_equal(decoded.get_size(), Vector2i(80, 60), "initial ROI mask expands to the full image")
		decoded.convert(Image.FORMAT_L8)
		support.expect_equal(decoded.get_pixel(10, 12), Color.WHITE, "initial mask retains selected ROI pixels")
		support.expect_equal(decoded.get_pixel(9, 12), Color.BLACK, "initial mask keeps pixels outside the ROI clear")
	for file_name: String in DirAccess.get_files_at(service._job_dir):
		support.expect(".tmp-" not in file_name, "atomic snapshot publication leaves no temporary file")
	bits.fill(0)
	if descriptor is Dictionary:
		support.expect_equal(FileAccess.get_sha256(service._job_dir.path_join(descriptor.path)), descriptor.sha256, "caller mask mutation cannot alter the frozen snapshot")
	service.shutdown()

	var rejected = await _service(_case_root("snapshot-rejection"))
	var wrong := _context("0".repeat(64), 0)
	support.expect_equal(rejected.set_image(wrong, image), -1, "mismatched image digest is rejected before launch")
	support.expect(rejected._job_dir.is_empty() and rejected._pid < 0, "rejected image context leaves no job or process")
	rejected.shutdown()


func _test_persistent_worker_sequence_cache_and_cleanup(support) -> void:
	_configure_valid_environment("ok")
	var case_root := _case_root("persistent")
	var service = await _service(case_root)
	var delivered: Array = []
	service.prediction_ready.connect(func(token: int, result: Dictionary): delivered.append([token, result]))
	var context := _context(_image_digest(_image()), 0)
	var first_image_token: int = service.set_image(context, _image())
	support.expect(first_image_token > 0, "set_image returns a request token")
	await _pump_until(service, func(): return service._image_ready, 3000)
	support.expect(service._image_ready, "hello and set_image complete through nonblocking pipes: state=%s stderr=%s" % [str(service._state), service._stderr_text])
	support.expect(service.get("_worker_confirmed") == true, "hello binds the launched PID to a service session")
	support.expect(not str(service.get("_worker_session_id")).is_empty(), "worker launch uses a non-empty session nonce")
	var pid: int = service._pid
	var cached_token: int = service.set_image(context, _image())
	support.expect_equal(cached_token, first_image_token, "same image digest reuses the current embedding request")
	var predict_token: int = service.predict(_context(context.image_sha256, 1), _prompts(12.0))
	await _pump_until(service, func(): return not delivered.is_empty(), 3000)
	support.expect_equal(service._pid, pid, "set_image and predict share one persistent worker")
	support.expect_equal(delivered.size(), 1, "one current prediction is delivered: state=%s stderr=%s" % [str(service._state), service._stderr_text])
	if not delivered.is_empty():
		support.expect_equal(delivered[0][0], predict_token, "prediction signal retains its local token")
		support.expect(delivered[0][1].get("ok", false), "valid worker response is delivered as success")
		support.expect_equal(delivered[0][1].get("data", {}).get("candidates", []).size(), 1, "candidate descriptors remain bounded protocol data")
	var requests := _request_log(case_root)
	support.expect_equal(_ops(requests), ["hello", "set_image", "predict"], "cache avoids a duplicate set_image request")
	support.expect_equal(_ids(requests), ["1", "2", "3"], "worker request IDs are strictly sequential")
	support.expect_equal(_line_count(case_root.path_join("starts.log")), 1, "worker starts exactly once")
	var job: String = service._job_dir
	service.shutdown()


func _test_cancel_restart_image_races_and_candidate_cleanup(support) -> void:
	_configure_valid_environment("ok")
	var cleanup_root := _case_root("candidate-cleanup")
	var service = await _service(cleanup_root)
	var delivered: Array = []
	service.prediction_ready.connect(func(token: int, result: Dictionary): delivered.append([token, result]))
	var image_a := _image()
	var digest_a := _image_digest(image_a)
	service.set_image(_context(digest_a, 0), image_a)
	await _pump_until(service, func(): return service._image_ready, 3000)
	var first: int = service.predict(_context(digest_a, 1), _prompts(12.0))
	await _pump_until(service, func(): return delivered.size() == 1, 3000)
	var first_path: String = service._job_dir.path_join(delivered[0][1].data.candidates[0].path)
	support.expect(FileAccess.file_exists(first_path), "current candidate remains available for synchronous validation")
	service.predict(_context(digest_a, 2), _prompts(15.0))
	support.expect(not FileAccess.file_exists(first_path), "a new revision removes the previous candidate output")
	await _pump_until(service, func(): return delivered.size() == 2, 3000)
	var second_token: int = delivered[-1][0]
	var second_path: String = service._job_dir.path_join(delivered[-1][1].data.candidates[0].path)
	service.cancel(second_token)
	support.expect(not FileAccess.file_exists(second_path), "cancel also removes an already-delivered candidate")
	service.shutdown()

	_configure_valid_environment("delay_second_image")
	var race_root := _case_root("image-race")
	service = await _service(race_root)
	image_a = _image_color(Color(0.1, 0.2, 0.3))
	var image_b := _image_color(Color(0.4, 0.2, 0.1))
	digest_a = _image_digest(image_a)
	var digest_b := _image_digest(image_b)
	service.set_image(_context(digest_a, 0), image_a)
	var image_b_token: int = service.set_image(_context(digest_b, 0), image_b)
	await _pump_for(service, 250)
	support.expect(not service._image_ready, "an older set_image response cannot announce the newer image as ready")
	await _pump_until(service, func(): return service._image_ready, 3000)
	support.expect(service._image_ready and service._current_image_token == image_b_token, "only the current image token completes caching")
	service.shutdown()

	_configure_valid_environment("hang_second_image")
	var hang_image_root := _case_root("image-timeout")
	service = await _service(hang_image_root)
	var now := [1000]
	service.clock = func(): return now[0]
	service.set_image(_context(digest_a, 0), image_a)
	service.set_image(_context(digest_b, 0), image_b)
	await _pump_for(service, 150)
	now[0] = 181001
	service.step()
	support.expect_equal(service._state.get("message"), "模型加载超时（180 秒），当前标注未修改。", "hung current set_image retains the 180-second deadline after hello")
	service.shutdown()

	_configure_valid_environment("hang_once")
	var retry_root := _case_root("cancel-retry")
	OS.set_environment("MODEL_ASSIST_FAKE_HANG_MARKER", retry_root.path_join("hung.marker"))
	service = await _service(retry_root)
	service.cancel_grace_ms = 50
	delivered.clear()
	service.prediction_ready.connect(func(token: int, result: Dictionary): delivered.append([token, result]))
	service.set_image(_context(digest_a, 0), image_a)
	await _pump_until(service, func(): return service._image_ready, 3000)
	var hung: int = service.predict(_context(digest_a, 1), _prompts(12.0))
	await _pump_until(service, func(): return _request_log(retry_root).any(func(item): return item.op == "predict"), 1000)
	service.cancel(hung)
	var retried: int = service.predict(_context(digest_a, 2), _prompts(18.0))
	await _pump_until(service, func(): return not delivered.is_empty(), 3000)
	support.expect_equal(delivered.size(), 1, "cancel plus immediate retry cannot remain queued behind a hung prediction")
	if not delivered.is_empty():
		support.expect_equal(delivered[0][0], retried, "restarted worker delivers only the retry token")
	support.expect_equal(_line_count(retry_root.path_join("starts.log")), 2, "hung cancellation recreates exactly one owned worker")
	service.shutdown()


func _test_session_bound_termination_failure(support) -> void:
	_configure_valid_environment("ok")
	var case_root := _case_root("termination-proof")
	var service = await _service(case_root)
	var image := _image()
	var digest := _image_digest(image)
	service.set_image(_context(digest, 0), image)
	await _pump_until(service, func(): return service._image_ready, 3000)
	var job: String = service._job_dir
	var pid: int = service._pid
	service.shutdown_grace_ms = 0
	service.process_running = func(candidate: int): return candidate == pid
	service.kill_process = func(_candidate: int): return ERR_CANT_OPEN
	service.shutdown()
	support.expect_equal(service._pid, pid, "failed termination retains the owned PID for recovery")
	support.expect_equal(service._job_dir, job, "unconfirmed termination quarantines rather than deletes the job")
	support.expect(DirAccess.dir_exists_absolute(job), "unconfirmed live worker keeps its snapshots intact")
	support.expect("worker 无法确认退出" in str(service._state.get("message", "")), "termination failure is explicit")
	service.process_running = Callable()
	service.kill_process = Callable()
	service.shutdown_grace_ms = 50
	service.shutdown()
	support.expect(not DirAccess.dir_exists_absolute(job), "a later confirmed shutdown reaps the quarantined job")
	support.expect(pid <= 0 or not FileAccess.file_exists("/proc/%d/stat" % pid), "shutdown reaps the exact worker PID")
	support.expect(not DirAccess.dir_exists_absolute(job), "shutdown removes only its exact job directory")
	support.expect(FileAccess.file_exists(case_root.path_join("jobs/sibling/keep.txt")), "cleanup preserves a sibling sentinel directory")


func _test_latest_token_cancel_and_deadlines(support) -> void:
	_configure_valid_environment("out_of_order")
	var order_root := _case_root("latest")
	var service = await _service(order_root)
	var delivered: Array = []
	service.prediction_ready.connect(func(token: int, result: Dictionary): delivered.append([token, result]))
	var image := _image()
	var digest := _image_digest(image)
	service.set_image(_context(digest, 0), image)
	await _pump_until(service, func(): return service._image_ready, 3000)
	var older: int = service.predict(_context(digest, 1), _prompts(11.0))
	var latest: int = service.predict(_context(digest, 2), _prompts(18.0))
	await _pump_until(service, func(): return not service._pending.has(str(latest)), 3000)
	support.expect(older != latest and older > 0, "each prediction gets a distinct token")
	support.expect_equal(delivered.size(), 1, "out-of-order responses deliver only the latest token")
	if not delivered.is_empty():
		support.expect_equal(delivered[0][0], latest, "late older response cannot replace current preview")
	service.shutdown()

	_configure_valid_environment("delay")
	var cancel_root := _case_root("cancel")
	service = await _service(cancel_root)
	delivered.clear()
	service.prediction_ready.connect(func(token: int, result: Dictionary): delivered.append([token, result]))
	service.set_image(_context(digest, 0), image)
	await _pump_until(service, func(): return service._image_ready, 3000)
	var cancelled: int = service.predict(_context(digest, 1), _prompts(12.0))
	service.cancel(cancelled)
	await _pump_for(service, 1200)
	support.expect(delivered.is_empty(), "cancel invalidates the token before any late callback")
	support.expect(service._pid > 0 and OS.is_process_running(service._pid), "request cancel keeps the reusable worker alive")
	service.shutdown()

	_configure_valid_environment("delay_hello")
	var load_root := _case_root("load-timeout")
	service = await _service(load_root)
	var now := [1000]
	service.clock = func(): return now[0]
	service.set_image(_context(digest, 0), image)
	support.expect_equal(service._load_deadline_ms, 181000, "model load receives an injected 180-second deadline")
	now[0] = 181001
	service.step()
	support.expect_equal(service._state.get("message"), "模型加载超时（180 秒），当前标注未修改。", "load timeout is explicit and non-mutating")
	service.shutdown()

	_configure_valid_environment("delay")
	var predict_root := _case_root("predict-timeout")
	service = await _service(predict_root)
	now[0] = 5000
	service.clock = func(): return now[0]
	service.set_image(_context(digest, 0), image)
	await _pump_until(service, func(): return service._image_ready, 3000)
	var pending: int = service.predict(_context(digest, 1), _prompts(12.0))
	support.expect_equal(service._pending[str(pending)].deadline_ms, 65000, "prediction receives an injected 60-second deadline")
	now[0] = 65001
	service.step()
	support.expect_equal(service._state.get("message"), "模型推理超时（60 秒），当前标注未修改。", "prediction timeout fails without a partial result")
	service.shutdown()


func _test_crash_malformed_and_oversized_responses(support) -> void:
	for scenario: String in ["crash", "malformed", "duplicate", "oversize"]:
		_configure_valid_environment(scenario)
		var case_root := _case_root(scenario)
		var service = await _service(case_root)
		var delivered: Array = []
		service.prediction_ready.connect(func(token: int, result: Dictionary): delivered.append([token, result]))
		var image := _image()
		var digest := _image_digest(image)
		service.set_image(_context(digest, 0), image)
		await _pump_until(service, func(): return service._image_ready, 3000)
		var job: String = service._job_dir
		service.predict(_context(digest, 1), _prompts(12.0))
		await _pump_until(service, func(): return service._state.get("status") == "failed", 3000)
		support.expect_equal(delivered.size(), 0, "%s never delivers an untrusted candidate" % scenario)
		var message := str(service._state.get("message", ""))
		if scenario == "crash":
			support.expect("worker 已异常退出" in message and "23" in message, "crash reports the worker exit code")
		elif scenario in ["malformed", "duplicate"]:
			support.expect_equal(message, "模型辅助协议错误：worker 返回了畸形响应。", "malformed JSON has an exact protocol error")
		else:
			support.expect_equal(message, "模型辅助协议错误：worker 响应超过 1 MiB。", "oversized line is rejected before parsing")
		support.expect(not DirAccess.dir_exists_absolute(job), "%s failure cleans its exact job" % scenario)
		support.expect(FileAccess.file_exists(case_root.path_join("jobs/sibling/keep.txt")), "%s cleanup preserves sibling state" % scenario)
		service.shutdown()


func _service(case_root: String):
	var service = SERVICE.new()
	service.job_root = case_root.path_join("jobs")
	service.worker_path = ProjectSettings.globalize_path("res://tests/fixtures/fake_model_assist_worker.py")
	service.preflight_probe_code = VALID_PROBE
	OS.set_environment("MODEL_ASSIST_FAKE_START_LOG", case_root.path_join("starts.log"))
	OS.set_environment("MODEL_ASSIST_FAKE_REQUEST_LOG", case_root.path_join("requests.log"))
	service.preflight()
	await _await_preflight(service)
	return service


func _preflight_result(service) -> Dictionary:
	var result: Dictionary = service.preflight()
	if result.get("status") == "checking":
		return await _await_preflight(service)
	return result


func _await_preflight(service) -> Dictionary:
	await _pump_until(service, func(): return service._state.get("status") != "checking", 3000)
	return service._state.duplicate(true)


func _configure_valid_environment(mode: String) -> void:
	OS.set_environment("PROJECT6_MODEL_PYTHON", _python)
	OS.set_environment("PROJECT6_SAM2_CONFIG", _config)
	OS.set_environment("PROJECT6_SAM2_CHECKPOINT", _checkpoint)
	OS.set_environment("PROJECT6_SAM2_DEVICE", "cpu")
	OS.set_environment("MODEL_ASSIST_FAKE_MODE", mode)


func _context(image_sha256: String, revision: int) -> Dictionary:
	return {
		"session_id": "service-test",
		"frame_id": 17,
		"playback_index": 3,
		"image_sha256": image_sha256,
		"record_sha256": "b".repeat(64),
		"selected_region_id": "",
		"prompt_revision": revision,
	}


func _prompts(x: float) -> Dictionary:
	return {"points": [[x, 14.0]], "labels": [1], "box": null}


func _image() -> Image:
	return _image_color(Color(0.1, 0.2, 0.3))


func _image_color(color: Color) -> Image:
	var image := Image.create(80, 60, false, Image.FORMAT_RGB8)
	image.fill(color)
	return image


func _image_digest(image: Image) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(image.save_png_to_buffer())
	return context.finish().hex_encode()


func _pump_until(service, predicate: Callable, timeout_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		service.step()
		await _timer_tree.create_timer(0.005).timeout
	service.step()


func _pump_for(service, duration_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + duration_ms
	while Time.get_ticks_msec() < deadline:
		service.step()
		await _timer_tree.create_timer(0.005).timeout


func _case_root(label: String) -> String:
	var path := _root.path_join(label)
	DirAccess.make_dir_recursive_absolute(path.path_join("jobs/sibling"))
	var sentinel := FileAccess.open(path.path_join("jobs/sibling/keep.txt"), FileAccess.WRITE)
	sentinel.store_string("keep")
	sentinel.close()
	return path


func _request_log(case_root: String) -> Array:
	var result: Array = []
	var path := case_root.path_join("requests.log")
	if not FileAccess.file_exists(path):
		return result
	for line: String in FileAccess.get_file_as_string(path).split("\n", false):
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			result.append(parsed)
	return result


func _ops(requests: Array) -> Array:
	return requests.map(func(item): return item.op)


func _ids(requests: Array) -> Array:
	return requests.map(func(item): return item.request_id)


func _line_count(path: String) -> int:
	return FileAccess.get_file_as_string(path).split("\n", false).size() if FileAccess.file_exists(path) else 0


func _make_fixture() -> void:
	_root = "/tmp/model-assist-service-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(_root)
	_config = _root.path_join("sam2.yaml")
	_checkpoint = _root.path_join("sam2.pt")
	_python = ProjectSettings.globalize_path("res://.venv/bin/python")
	var config_file := FileAccess.open(_config, FileAccess.WRITE)
	config_file.store_string("model: fake\n")
	config_file.close()
	var checkpoint_file := FileAccess.open(_checkpoint, FileAccess.WRITE)
	checkpoint_file.store_string("fake checkpoint")
	checkpoint_file.close()


func _save_environment() -> void:
	for key: String in ENV_KEYS:
		_saved_environment[key] = {"set": OS.has_environment(key), "value": OS.get_environment(key)}


func _restore_environment() -> void:
	for key: String in ENV_KEYS:
		if _saved_environment[key].set:
			OS.set_environment(key, _saved_environment[key].value)
		else:
			OS.unset_environment(key)


func _clear_runtime_environment() -> void:
	for key: String in ENV_KEYS:
		OS.unset_environment(key)


func _remove_tree(path: String) -> void:
	if path.is_empty() or not path.begins_with("/tmp/model-assist-service-") or not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for directory_name: String in directory.get_directories():
		var child := path.path_join(directory_name)
		if directory.is_link(directory_name):
			DirAccess.remove_absolute(child)
		else:
			_remove_tree(child)
	DirAccess.remove_absolute(path)
