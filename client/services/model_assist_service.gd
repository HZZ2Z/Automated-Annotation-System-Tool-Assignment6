## 单帧模型辅助边界：只管理外部运行时、冻结快照、严格协议与生命周期，不读写 Store。
class_name ModelAssistService
extends RefCounted

signal state_changed(snapshot: Dictionary)
signal prediction_ready(token: int, result: Dictionary)

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
const PROTOCOL := "model-assist-v1"
const MAX_LINE_BYTES := 1024 * 1024
const MAX_POINTS := 64
const MAX_CANDIDATES := 3
const MAX_IMAGE_PIXELS := 32 * 1024 * 1024
const CONTEXT_FIELDS := [
	"frame_id",
	"image_sha256",
	"playback_index",
	"prompt_revision",
	"record_sha256",
	"selected_region_id",
	"session_id",
]
const RESPONSE_FIELDS := ["context", "data", "errors", "ok", "protocol", "request_id"]
const CANDIDATE_FIELDS := ["path", "roi", "score", "sha256"]
const MISSING_PYTHON := "模型辅助不可用：未配置外部 Python。"
const BAD_PYTHON := "模型辅助不可用：外部 Python 无法执行。"
const MISSING_CONFIG := "模型辅助不可用：未配置可读的 SAM2 config。"
const MISSING_CHECKPOINT := "模型辅助不可用：未配置可读的 SAM2 checkpoint。"
const BAD_DEVICE := "模型辅助不可用：PROJECT6_SAM2_DEVICE 必须是 auto、cpu 或 cuda。"
const MISSING_TORCH := "模型辅助不可用：解释器中未安装 torch。"
const MISSING_SAM2 := "模型辅助不可用：解释器中未安装 sam2。"
const CUDA_UNAVAILABLE := "模型辅助不可用：已指定 CUDA，但当前解释器无法使用 CUDA。"
const PREFLIGHT_TIMEOUT := "模型辅助不可用：外部 Python 预检超时。"
const CPU_BADGE := "SAM2 已就绪 · CPU（较慢）"
const CUDA_BADGE := "SAM2 已就绪 · CUDA"

var job_root := "user://model-assist-jobs"
var worker_path := "res://python/model_assist_worker.py"
var preflight_timeout_ms := 30000
var load_timeout_ms := 180000
var predict_timeout_ms := 60000
var cancel_grace_ms := 500
var shutdown_grace_ms := 500
var clock: Callable
var process_running: Callable
var kill_process: Callable
# 只替换可测的探针文本；实际解释器和运行时路径始终来自环境变量。
var preflight_probe_code := (
	"import hashlib,json,sys\n"
	+ "result = {'torch': False, 'sam2': False, 'cuda': False}\n"
	+ "try:\n import torch\n result['torch'] = True\n result['cuda'] = bool(torch.cuda.is_available())\n"
	+ "except Exception:\n pass\n"
	+ "try:\n import sam2\n result['sam2'] = True\n"
	+ "except Exception:\n pass\n"
	+ "digest = hashlib.sha256()\n"
	+ "with open(sys.argv[1], 'rb') as handle:\n"
	+ " while True:\n  chunk = handle.read(1048576)\n  if not chunk: break\n  digest.update(chunk)\n"
	+ "result['checkpoint_sha256'] = digest.hexdigest()\n"
	+ "result['session_id'] = sys.argv[2]\n"
	+ "print(json.dumps(result, separators=(',', ':')))"
)

var _runtime: Dictionary = {}
var _state: Dictionary = {
	"status": "unavailable",
	"message": "",
	"badge": "",
	"device": "",
	"busy": false,
	"errors": [],
}
var _preflight_pipe: Dictionary = {}
var _preflight_stdio: FileAccess
var _preflight_stderr: FileAccess
var _preflight_pid := -1
var _preflight_session_id := ""
var _preflight_inputs: Dictionary = {}
var _preflight_buffer := PackedByteArray()
var _preflight_stderr_text := ""
var _preflight_deadline_ms := -1
var _pipe: Dictionary = {}
var _stdio: FileAccess
var _stderr: FileAccess
var _pid := -1
var _worker_launch_count := 0
var _worker_session_id := ""
var _worker_confirmed := false
var _job_parent := ""
var _job_dir := ""
var _job_serial := 0
var _request_serial := 0
var _pending: Dictionary = {}
var _retired_ids: Dictionary = {}
var _read_buffer := PackedByteArray()
var _stderr_text := ""
var _hello_ready := false
var _image_ready := false
var _current_context: Dictionary = {}
var _current_image: Dictionary = {}
var _current_initial_mask: Variant = null
var _current_image_token := -1
var _latest_predict_token := -1
var _load_deadline_ms := -1
var _candidate_paths: Dictionary = {}
var _shutting_down := false


func preflight() -> Dictionary:
	var python_path := OS.get_environment("PROJECT6_MODEL_PYTHON")
	if python_path.is_empty():
		return _preflight_failure(MISSING_PYTHON)
	if not _regular_readable_file(python_path, true):
		return _preflight_failure(BAD_PYTHON)
	var config_path := OS.get_environment("PROJECT6_SAM2_CONFIG")
	if not _regular_readable_file(config_path):
		return _preflight_failure(MISSING_CONFIG)
	var checkpoint_path := OS.get_environment("PROJECT6_SAM2_CHECKPOINT")
	if not _regular_readable_file(checkpoint_path):
		return _preflight_failure(MISSING_CHECKPOINT)
	var requested_device := OS.get_environment("PROJECT6_SAM2_DEVICE").to_lower()
	if requested_device.is_empty():
		requested_device = "auto"
	if requested_device not in ["auto", "cpu", "cuda"]:
		return _preflight_failure(BAD_DEVICE)
	var inputs := {
		"python_path": python_path,
		"config_path": config_path,
		"checkpoint_path": checkpoint_path,
		"requested_device": requested_device,
	}
	if _preflight_pid > 0 and _preflight_inputs == inputs:
		return _state.duplicate(true)
	if _preflight_pid > 0 and not _stop_preflight():
		return _preflight_failure(BAD_PYTHON)
	if not _runtime.is_empty() and _runtime.get("inputs") == inputs and _state.get("status") == "ready":
		return _state.duplicate(true)
	if not _runtime.is_empty() and _runtime.get("inputs") != inputs and (_pid > 0 or not _job_dir.is_empty()):
		shutdown()
		if _pid > 0 or not _job_dir.is_empty():
			return _state.duplicate(true)
	_runtime.clear()
	_preflight_session_id = _new_session_id("preflight")
	_preflight_inputs = inputs.duplicate(true)
	_preflight_pipe = OS.execute_with_pipe(
		python_path,
		PackedStringArray(["-c", preflight_probe_code, checkpoint_path, _preflight_session_id]),
		false,
	)
	if (
		_preflight_pipe.is_empty()
		or not _preflight_pipe.get("stdio") is FileAccess
		or not _preflight_pipe.get("stderr") is FileAccess
		or not _preflight_pipe.get("pid") is int
	):
		_clear_preflight_state()
		return _preflight_failure(BAD_PYTHON)
	_preflight_stdio = _preflight_pipe.stdio
	_preflight_stderr = _preflight_pipe.stderr
	_preflight_pid = int(_preflight_pipe.pid)
	if _preflight_pid <= 0:
		_close_preflight_pipes()
		_clear_preflight_state()
		return _preflight_failure(BAD_PYTHON)
	_preflight_buffer.clear()
	_preflight_stderr_text = ""
	_preflight_deadline_ms = _now_msec() + preflight_timeout_ms
	var checking := {
		"ok": false,
		"status": "checking",
		"message": "正在检查 SAM2 外部运行时…",
		"badge": "",
		"device": "",
		"busy": true,
		"errors": [],
		"checkpoint_sha256": "",
	}
	_set_state(checking)
	return checking.duplicate(true)


func set_image(context: Dictionary, image: Image, initial_mask: Dictionary = {}) -> int:
	if _runtime.is_empty() and not preflight().get("ok", false):
		return -1
	var normalized_context := _validate_context(context)
	if normalized_context.is_empty() or image == null or image.is_empty() or image.get_width() > MAX_IMAGE_PIXELS / image.get_height():
		_fail_input("模型辅助无法冻结当前图像与上下文。")
		return -1
	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		_fail_input("模型辅助无法写入当前图像快照。")
		return -1
	var digest := _sha256(png_bytes)
	if normalized_context.image_sha256 != digest:
		_fail_input("模型辅助拒绝了与冻结图像不一致的摘要。")
		return -1
	if not _prepare_job():
		_fail_input("模型辅助无法创建独立任务目录。")
		return -1
	var image_name := "image-%s.png" % digest
	if not _write_atomic_bytes(image_name, png_bytes):
		_fatal("模型辅助无法写入当前图像快照。", "shutdown")
		return -1
	var mask_result := _snapshot_initial_mask(initial_mask, image.get_size())
	if not mask_result.get("ok", false):
		_fatal(str(mask_result.get("message", "初始 mask 无效。")), "shutdown")
		return -1
	var descriptor := {
		"path": image_name,
		"sha256": digest,
		"width": image.get_width(),
		"height": image.get_height(),
	}
	var identity_changed := not _current_context.is_empty() and not _same_image_identity(normalized_context, _current_context)
	var cached: bool = (
		not _current_image.is_empty()
		and _current_image.sha256 == digest
		and _current_initial_mask == mask_result.get("descriptor")
		and _pid > 0
		and _process_is_running(_pid)
	)
	_current_context = normalized_context.duplicate(true)
	_current_initial_mask = _duplicate_variant(mask_result.get("descriptor"))
	if cached:
		if identity_changed:
			_invalidate_predictions()
		return _current_image_token
	_invalidate_predictions()
	_retire_current_image_request()
	_current_image = descriptor.duplicate(true)
	_image_ready = false
	if not _ensure_worker():
		return -1
	_load_deadline_ms = _now_msec() + load_timeout_ms
	_current_image_token = _send_request("set_image", normalized_context, {"image": descriptor}, _load_deadline_ms)
	if _current_image_token < 0:
		return -1
	_set_busy_state("loading", "正在缓存当前图像…")
	return _current_image_token


func predict(context: Dictionary, prompts: Dictionary) -> int:
	var normalized_context := _validate_context(context)
	var normalized_prompts := _validate_prompts(prompts)
	if normalized_context.is_empty() or normalized_prompts.is_empty() or _current_image.is_empty():
		_fail_input("模型辅助请求的上下文或提示无效。")
		return -1
	if not _same_image_identity(normalized_context, _current_context):
		_fail_input("图像或标注已变化，旧候选已取消。")
		return -1
	if _pid <= 0 or not _process_is_running(_pid):
		_fatal("模型辅助 worker 未运行。", "")
		return -1
	if _has_retired_inflight_predict() and not _restart_worker_for_current_image(normalized_context):
		return -1
	if _latest_predict_token > 0 and _pending.has(str(_latest_predict_token)):
		var superseded := _latest_predict_token
		cancel(superseded)
		if not _restart_worker_for_current_image(normalized_context):
			return -1
	_cleanup_candidate_outputs()
	var data := normalized_prompts.duplicate(true)
	data["initial_mask"] = _duplicate_variant(_current_initial_mask)
	var deadline := _now_msec() + predict_timeout_ms if _image_ready else -1
	var token := _send_request("predict", normalized_context, data, deadline)
	if token < 0:
		return -1
	_latest_predict_token = token
	_set_busy_state("requesting", "正在生成候选…")
	return token


func cancel(token: int) -> void:
	var key := str(token)
	_cleanup_candidate_token(key)
	if token <= 0 or not _pending.has(key):
		return
	var record: Dictionary = _pending[key]
	if record.op != "predict":
		return
	record.retired = true
	record.cancel_deadline_ms = _now_msec() + cancel_grace_ms
	_pending[key] = record
	_remember_retired(key)
	if token == _latest_predict_token:
		_latest_predict_token = -1
	if _pid > 0 and _process_is_running(_pid):
		_send_request("cancel", {}, {"target_request_id": key}, _now_msec() + predict_timeout_ms)
	if _image_ready:
		_set_state(_ready_state())
	else:
		_set_busy_state("loading", "正在缓存当前图像…")


func candidate_job_dir() -> String:
	return _job_dir


func step() -> void:
	_step_preflight()
	if _pid <= 0:
		return
	if not _read_pipes():
		return
	if _pid <= 0:
		return
	var now := _now_msec()
	if not _hello_ready and _load_deadline_ms >= 0 and now > _load_deadline_ms:
		_fatal("模型加载超时（180 秒），当前标注未修改。", "cancel")
		return
	for request_id: Variant in _pending.keys():
		var record: Dictionary = _pending[request_id]
		if record.op == "set_image" and str(request_id) == str(_current_image_token) and int(record.deadline_ms) >= 0 and now > int(record.deadline_ms):
			_fatal("模型加载超时（180 秒），当前标注未修改。", "cancel")
			return
		if record.op == "predict" and record.retired and int(record.get("cancel_deadline_ms", -1)) >= 0 and now > int(record.cancel_deadline_ms):
			_finish_cancelled_worker()
			return
		if record.op == "predict" and int(record.deadline_ms) >= 0 and now > int(record.deadline_ms):
			_fatal("模型推理超时（60 秒），当前标注未修改。", "cancel", str(request_id))
			return
	if _pid > 0 and not _process_is_running(_pid):
		var exit_code := OS.get_process_exit_code(_pid)
		if _shutting_down:
			_pid = -1
		else:
			_fatal("模型辅助 worker 已异常退出（exit %d）。" % exit_code, "")


func shutdown() -> void:
	if _shutting_down:
		return
	_shutting_down = true
	if not _stop_preflight():
		_shutting_down = false
		_preflight_failure(BAD_PYTHON)
		return
	_invalidate_predictions()
	var terminated := true
	if _pid > 0 and _process_is_running(_pid):
		_send_control("shutdown", {})
		terminated = _wait_or_kill(_pid)
	if not terminated:
		_shutting_down = false
		_set_termination_failure()
		return
	_close_pipes()
	_pid = -1
	_worker_session_id = ""
	_worker_confirmed = false
	_pending.clear()
	_cleanup_job()
	_clear_image_state()
	_shutting_down = false
	_set_state({
		"status": "stopped",
		"message": "",
		"badge": "",
		"device": "",
		"busy": false,
		"errors": [],
	})


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and (_preflight_pid > 0 or _pid > 0 or not _job_dir.is_empty()):
		shutdown()


func _step_preflight() -> void:
	if _preflight_pid <= 0:
		return
	if _preflight_stdio != null:
		for _read_turn in range(32):
			var chunk := _preflight_stdio.get_buffer(65536)
			var read_error := _preflight_stdio.get_error()
			if not chunk.is_empty():
				_preflight_buffer.append_array(chunk)
			if _preflight_buffer.size() > MAX_LINE_BYTES:
				_stop_preflight()
				_preflight_failure(BAD_PYTHON)
				return
			if read_error == ERR_BUSY or chunk.size() < 65536:
				break
			if read_error not in [OK, ERR_FILE_EOF]:
				_stop_preflight()
				_preflight_failure(BAD_PYTHON)
				return
	if _preflight_stderr != null:
		var error_chunk := _preflight_stderr.get_buffer(4096)
		if _preflight_stderr.get_error() in [OK, ERR_BUSY, ERR_FILE_EOF] and not error_chunk.is_empty():
			_preflight_stderr_text = (_preflight_stderr_text + error_chunk.get_string_from_utf8()).right(4096)
	if _now_msec() > _preflight_deadline_ms:
		_stop_preflight()
		_preflight_failure(PREFLIGHT_TIMEOUT)
		return
	if OS.is_process_running(_preflight_pid):
		return
	var exit_code := OS.get_process_exit_code(_preflight_pid)
	var raw := _preflight_buffer.duplicate()
	var inputs := _preflight_inputs.duplicate(true)
	var session_id := _preflight_session_id
	_close_preflight_pipes()
	_clear_preflight_state()
	if exit_code != 0:
		_preflight_failure(BAD_PYTHON)
		return
	var newline := raw.find(10)
	if newline < 0 or newline != raw.size() - 1:
		_preflight_failure(BAD_PYTHON)
		return
	var text := raw.slice(0, newline).get_string_from_utf8()
	_complete_preflight(text, inputs, session_id)


func _complete_preflight(text: String, inputs: Dictionary, session_id: String) -> void:
	if text.is_empty() or _json_has_duplicate_keys(text):
		_preflight_failure(BAD_PYTHON)
		return
	var probe: Variant = EXACT_JSON.parse_string(text)
	if (
		not probe is Dictionary
		or not _keys_equal(probe, ["checkpoint_sha256", "cuda", "sam2", "session_id", "torch"])
		or not probe.get("torch") is bool
		or not probe.get("sam2") is bool
		or not probe.get("cuda") is bool
		or probe.get("session_id") != session_id
		or not _digest_valid(probe.get("checkpoint_sha256"))
	):
		_preflight_failure(BAD_PYTHON)
		return
	if not probe.torch:
		_preflight_failure(MISSING_TORCH)
		return
	if not probe.sam2:
		_preflight_failure(MISSING_SAM2)
		return
	var requested_device: String = inputs.requested_device
	if requested_device == "cuda" and not probe.cuda:
		_preflight_failure(CUDA_UNAVAILABLE)
		return
	var actual_device := "cuda" if requested_device == "cuda" or (requested_device == "auto" and probe.cuda) else "cpu"
	var badge := CUDA_BADGE if actual_device == "cuda" else CPU_BADGE
	_runtime = {
		"python_path": inputs.python_path,
		"config_path": inputs.config_path,
		"checkpoint_path": inputs.checkpoint_path,
		"checkpoint_sha256": probe.checkpoint_sha256,
		"requested_device": requested_device,
		"device": actual_device,
		"badge": badge,
		"inputs": inputs.duplicate(true),
	}
	_set_state({
		"ok": true,
		"status": "ready",
		"message": badge,
		"badge": badge,
		"device": actual_device,
		"busy": false,
		"errors": [],
		"checkpoint_sha256": probe.checkpoint_sha256,
	})


func _stop_preflight() -> bool:
	if _preflight_pid <= 0:
		_close_preflight_pipes()
		_clear_preflight_state()
		return true
	var process_id := _preflight_pid
	if OS.is_process_running(process_id):
		if OS.kill(process_id) != OK:
			return false
		var deadline := Time.get_ticks_msec() + 250
		while DirAccess.dir_exists_absolute("/proc/%d" % process_id) and Time.get_ticks_msec() < deadline:
			OS.delay_msec(5)
		if DirAccess.dir_exists_absolute("/proc/%d" % process_id):
			return false
	_close_preflight_pipes()
	_clear_preflight_state()
	return true


func _close_preflight_pipes() -> void:
	if _preflight_stdio != null:
		_preflight_stdio.close()
	if _preflight_stderr != null:
		_preflight_stderr.close()
	_preflight_stdio = null
	_preflight_stderr = null
	_preflight_pipe.clear()


func _clear_preflight_state() -> void:
	_preflight_pid = -1
	_preflight_session_id = ""
	_preflight_inputs.clear()
	_preflight_buffer.clear()
	_preflight_stderr_text = ""
	_preflight_deadline_ms = -1


func _ensure_worker() -> bool:
	if _pid > 0 and _process_is_running(_pid):
		return true
	var python_path := str(_runtime.get("python_path", ""))
	var script_path := ProjectSettings.globalize_path(worker_path)
	if not _regular_readable_file(script_path):
		_fatal("模型辅助启动失败：worker 脚本不存在或不可读。", "")
		return false
	_worker_session_id = _new_worker_session_id()
	_worker_confirmed = false
	var arguments := PackedStringArray([
		script_path,
		"--job-dir", _job_dir,
		"--config", str(_runtime.config_path),
		"--checkpoint", str(_runtime.checkpoint_path),
		"--device", str(_runtime.device),
		"--session-id", _worker_session_id,
	])
	_pipe = OS.execute_with_pipe(python_path, arguments, false)
	if _pipe.is_empty() or not _pipe.get("stdio") is FileAccess or not _pipe.get("stderr") is FileAccess or not _pipe.get("pid") is int:
		_pipe.clear()
		_fatal("模型辅助启动失败：无法创建外部 worker。", "")
		return false
	_stdio = _pipe.stdio
	_stderr = _pipe.stderr
	_pid = int(_pipe.pid)
	if _pid <= 0:
		_close_pipes()
		_fatal("模型辅助启动失败：无法创建外部 worker。", "")
		return false
	_worker_launch_count += 1
	_read_buffer.clear()
	_stderr_text = ""
	_hello_ready = false
	_load_deadline_ms = _now_msec() + load_timeout_ms
	var hello := _send_request("hello", {}, {}, _load_deadline_ms)
	if hello < 0:
		return false
	_set_busy_state("loading", "正在加载 SAM2…")
	return true


func _restart_worker_for_current_image(context: Dictionary) -> bool:
	if _current_image.is_empty() or _job_dir.is_empty() or _pid <= 0:
		return false
	if _process_is_running(_pid) and not _wait_or_kill(_pid):
		_set_termination_failure()
		return false
	_close_pipes()
	_pid = -1
	_worker_session_id = ""
	_worker_confirmed = false
	_pending.clear()
	_cleanup_candidate_outputs()
	_cleanup_candidate_directory()
	_hello_ready = false
	_image_ready = false
	_current_image_token = -1
	_latest_predict_token = -1
	_current_context = context.duplicate(true)
	if not _ensure_worker():
		return false
	_load_deadline_ms = _now_msec() + load_timeout_ms
	_current_image_token = _send_request(
		"set_image",
		_current_context,
		{"image": _current_image.duplicate(true)},
		_load_deadline_ms,
	)
	if _current_image_token < 0:
		return false
	_set_busy_state("loading", "正在重建当前图像缓存…")
	return true


func _send_request(op: String, context: Dictionary, data: Dictionary, deadline_ms: int) -> int:
	_request_serial += 1
	var request_id := str(_request_serial)
	var request := {
		"protocol": PROTOCOL,
		"request_id": request_id,
		"op": op,
		"context": context.duplicate(true),
		"data": data.duplicate(true),
	}
	var raw := (JSON.stringify(request, "", false, true) + "\n").to_utf8_buffer()
	if raw.size() > MAX_LINE_BYTES or not _write_pipe(raw):
		_fatal("模型辅助协议写入失败。", "")
		return -1
	_pending[request_id] = {
		"op": op,
		"context": context.duplicate(true),
		"data": data.duplicate(true),
		"deadline_ms": deadline_ms,
		"cancel_deadline_ms": -1,
		"retired": false,
	}
	return _request_serial


func _send_control(op: String, data: Dictionary) -> void:
	if _stdio == null:
		return
	_request_serial += 1
	var request := {
		"protocol": PROTOCOL,
		"request_id": str(_request_serial),
		"op": op,
		"context": {},
		"data": data.duplicate(true),
	}
	_write_pipe((JSON.stringify(request, "", false, true) + "\n").to_utf8_buffer())


func _write_pipe(raw: PackedByteArray) -> bool:
	if _stdio == null:
		return false
	_stdio.store_buffer(raw)
	_stdio.flush()
	return _stdio.get_error() == OK


func _read_pipes() -> bool:
	if _stdio != null:
		# Pipe FileAccess has no length/available query. In nonblocking mode a read
		# returns immediately; ERR_BUSY means there are currently no more bytes.
		for _read_turn in range(32):
			var chunk := _stdio.get_buffer(65536)
			var read_error := _stdio.get_error()
			if not chunk.is_empty():
				_read_buffer.append_array(chunk)
			if read_error == ERR_BUSY or chunk.size() < 65536:
				break
			if read_error != OK:
				if read_error == ERR_FILE_EOF and not _process_is_running(_pid):
					break
				_fatal("模型辅助协议读取失败。", "shutdown")
				return false
		while true:
			var newline := _read_buffer.find(10)
			if newline < 0:
				break
			if newline + 1 > MAX_LINE_BYTES:
				_fatal("模型辅助协议错误：worker 响应超过 1 MiB。", "shutdown")
				return false
			var line := _read_buffer.slice(0, newline).get_string_from_utf8()
			_read_buffer = _read_buffer.slice(newline + 1)
			if not _consume_response(line):
				return false
		if _read_buffer.size() >= MAX_LINE_BYTES:
			_fatal("模型辅助协议错误：worker 响应超过 1 MiB。", "shutdown")
			return false
	if _stderr != null:
		var error_chunk := _stderr.get_buffer(4096)
		if _stderr.get_error() in [OK, ERR_BUSY, ERR_FILE_EOF] and not error_chunk.is_empty():
			_stderr_text = (_stderr_text + error_chunk.get_string_from_utf8()).right(4096)
	return true


func _consume_response(line: String) -> bool:
	if line.is_empty() or _json_has_duplicate_keys(line):
		_fatal("模型辅助协议错误：worker 返回了畸形响应。", "shutdown")
		return false
	var response: Variant = EXACT_JSON.parse_string(line)
	if not response is Dictionary or not _validate_response_envelope(response):
		_fatal("模型辅助协议错误：worker 返回了畸形响应。", "shutdown")
		return false
	var request_id: String = response.request_id
	if not _pending.has(request_id):
		if _retired_ids.has(request_id):
			return true
		_fatal("模型辅助协议错误：worker 返回了未知请求。", "shutdown")
		return false
	var record: Dictionary = _pending[request_id]
	if not _response_context_matches(response.context, record.context):
		_fatal("模型辅助协议错误：worker 响应与冻结上下文不一致。", "shutdown")
		return false
	if record.retired:
		if record.op == "predict" and response.ok:
			_remove_response_candidates(response.data)
		_pending.erase(request_id)
		_remember_retired(request_id)
		return true
	if not response.ok:
		_pending.erase(request_id)
		return _consume_worker_error(int(request_id), record, response)
	var data: Dictionary = response.data
	match str(record.op):
		"hello":
			if not _validate_hello(data):
				return _malformed_response()
			_hello_ready = true
			_worker_confirmed = true
			_pending.erase(request_id)
			if _image_ready:
				_set_state(_ready_state())
		"set_image":
			if not _validate_set_image(data, record):
				return _malformed_response()
			if request_id != str(_current_image_token) or record.data.image != _current_image:
				_pending.erase(request_id)
				_remember_retired(request_id)
				return true
			_image_ready = true
			_pending.erase(request_id)
			for pending_id: Variant in _pending:
				if _pending[pending_id].op == "predict" and int(_pending[pending_id].deadline_ms) < 0:
					_pending[pending_id].deadline_ms = _now_msec() + predict_timeout_ms
			if _latest_predict_token > 0:
				_set_busy_state("requesting", "正在生成候选…")
			else:
				_set_state(_ready_state())
		"predict":
			if not _validate_predict(data):
				return _malformed_response()
			_pending.erase(request_id)
			var token := int(record.get("delivery_token", int(request_id)))
			if token == _latest_predict_token:
				_latest_predict_token = -1
				_store_candidate_paths(str(token), data.candidates)
				_set_state(_ready_state())
				prediction_ready.emit(token, {
					"ok": true,
					"context": response.context.duplicate(true),
					"data": data.duplicate(true),
					"errors": [],
				})
		"cancel":
			if not _validate_cancel(data, record):
				return _malformed_response()
			_pending.erase(request_id)
		"shutdown":
			if not data.is_empty():
				return _malformed_response()
			_pending.erase(request_id)
	return true


func _consume_worker_error(token: int, record: Dictionary, response: Dictionary) -> bool:
	var message := str(response.errors[0]) if not response.errors.is_empty() else "worker 返回了未知错误。"
	if record.op == "predict":
		if token == _latest_predict_token:
			_latest_predict_token = -1
			_set_state({
				"status": "failed",
				"message": "推理失败，当前标注未修改；可重试或按 Escape 取消。",
				"badge": str(_runtime.get("badge", "")),
				"device": str(_runtime.get("device", "")),
				"busy": false,
				"errors": [message],
			})
			prediction_ready.emit(token, {
				"ok": false,
				"context": response.context.duplicate(true),
				"data": {},
				"errors": response.errors.duplicate(true),
			})
		return true
	_fatal("模型辅助 worker 初始化失败：%s" % message, "shutdown")
	return false


func _validate_response_envelope(response: Dictionary) -> bool:
	if not _keys_equal(response, RESPONSE_FIELDS):
		return false
	if response.get("protocol") != PROTOCOL or not response.get("request_id") is String or response.request_id.is_empty() or response.request_id.length() > 128:
		return false
	if not response.get("ok") is bool or not response.get("context") is Dictionary or not response.get("data") is Dictionary or not response.get("errors") is Array:
		return false
	for error: Variant in response.errors:
		if not error is String or error.is_empty() or error.length() > 512:
			return false
	if response.ok != response.errors.is_empty():
		return false
	if not response.ok and not response.data.is_empty():
		return false
	return true


func _validate_hello(data: Dictionary) -> bool:
	if not _keys_equal(data, ["backend", "checkpoint_sha256", "device", "persistent", "pid", "session_id"]):
		return false
	return (
		data.get("backend") is String
		and not data.backend.is_empty()
		and data.get("persistent") == true
		and data.get("device") == _runtime.get("device")
		and data.get("checkpoint_sha256") == _runtime.get("checkpoint_sha256")
		and data.get("session_id") == _worker_session_id
		and _logical_integer(data.get("pid"))
		and int(data.pid) == _pid
	)


func _validate_set_image(data: Dictionary, record: Dictionary) -> bool:
	if not _keys_equal(data, ["cached", "height", "image_sha256", "width"]):
		return false
	var expected: Dictionary = record.data.image
	return (
		data.get("cached") is bool
		and _logical_integer(data.get("width"))
		and _logical_integer(data.get("height"))
		and int(data.width) == int(expected.width)
		and int(data.height) == int(expected.height)
		and data.get("image_sha256") == expected.sha256
	)


func _validate_predict(data: Dictionary) -> bool:
	if not _keys_equal(data, ["candidates", "image_sha256"]):
		return false
	if data.get("image_sha256") != _current_image.get("sha256") or not data.get("candidates") is Array or data.candidates.size() > MAX_CANDIDATES:
		return false
	for candidate: Variant in data.candidates:
		if not candidate is Dictionary or not _keys_equal(candidate, CANDIDATE_FIELDS):
			return false
		if not candidate.path is String or candidate.path.is_empty() or candidate.path.is_absolute_path() or candidate.path.get_extension().to_lower() != "png":
			return false
		if not _digest_valid(candidate.sha256) or not candidate.roi is Array or candidate.roi.size() != 4:
			return false
		for coordinate: Variant in candidate.roi:
			if not _logical_integer(coordinate):
				return false
		if not _finite_number(candidate.score):
			return false
	return true


func _validate_cancel(data: Dictionary, record: Dictionary) -> bool:
	return (
		_keys_equal(data, ["cancelled", "target_request_id"])
		and data.get("cancelled") == true
		and data.get("target_request_id") == record.data.get("target_request_id")
	)


func _malformed_response() -> bool:
	_fatal("模型辅助协议错误：worker 返回了畸形响应。", "shutdown")
	return false


func _validate_context(value: Dictionary) -> Dictionary:
	if not _keys_equal(value, CONTEXT_FIELDS):
		return {}
	if not value.session_id is String or value.session_id.is_empty() or value.session_id.length() > 256:
		return {}
	if not _logical_integer(value.frame_id) or int(value.frame_id) < 0:
		return {}
	if not _logical_integer(value.playback_index) or int(value.playback_index) < 0:
		return {}
	if not _logical_integer(value.prompt_revision) or int(value.prompt_revision) < 0:
		return {}
	if not _digest_valid(value.image_sha256) or not _digest_valid(value.record_sha256):
		return {}
	if not value.selected_region_id is String or value.selected_region_id.length() > 256:
		return {}
	return {
		"session_id": value.session_id,
		"frame_id": int(value.frame_id),
		"playback_index": int(value.playback_index),
		"image_sha256": value.image_sha256,
		"record_sha256": value.record_sha256,
		"selected_region_id": value.selected_region_id,
		"prompt_revision": int(value.prompt_revision),
	}


func _validate_prompts(value: Dictionary) -> Dictionary:
	if not _keys_equal(value, ["box", "labels", "points"]):
		return {}
	if not value.points is Array or not value.labels is Array or value.points.size() != value.labels.size() or value.points.size() > MAX_POINTS:
		return {}
	var points: Array = []
	var labels: Array = []
	for index in range(value.points.size()):
		var point: Variant = value.points[index]
		if not point is Array or point.size() != 2 or not _finite_number(point[0]) or not _finite_number(point[1]):
			return {}
		var label: Variant = value.labels[index]
		if not _logical_integer(label) or int(label) not in [0, 1]:
			return {}
		points.append([float(point[0]), float(point[1])])
		labels.append(int(label))
	var box: Variant = value.box
	if box != null:
		if not box is Array or box.size() != 4:
			return {}
		for coordinate: Variant in box:
			if not _finite_number(coordinate):
				return {}
		if float(box[0]) >= float(box[2]) or float(box[1]) >= float(box[3]):
			return {}
		box = [float(box[0]), float(box[1]), float(box[2]), float(box[3])]
	if points.is_empty() and box == null:
		return {}
	return {"points": points, "labels": labels, "box": box}


func _snapshot_initial_mask(value: Dictionary, image_size: Vector2i) -> Dictionary:
	if value.is_empty():
		return {"ok": true, "descriptor": null}
	if not _keys_equal(value, ["mask", "roi"]) or not value.roi is Rect2i or not value.mask is PackedByteArray:
		return {"ok": false, "message": "初始 mask 格式无效。"}
	var roi: Rect2i = value.roi
	if roi.size.x <= 0 or roi.size.y <= 0 or roi.position.x < 0 or roi.position.y < 0 or roi.intersection(Rect2i(Vector2i.ZERO, image_size)) != roi:
		return {"ok": false, "message": "初始 mask 越出当前图像。"}
	if roi.size.x > 32 * 1024 * 1024 / roi.size.y or value.mask.size() != roi.size.x * roi.size.y:
		return {"ok": false, "message": "初始 mask 尺寸无效。"}
	var full := PackedByteArray()
	full.resize(image_size.x * image_size.y)
	for y in range(roi.size.y):
		for x in range(roi.size.x):
			var source_value: int = value.mask[y * roi.size.x + x]
			if source_value not in [0, 1, 255]:
				return {"ok": false, "message": "初始 mask 必须是二值数据。"}
			full[(roi.position.y + y) * image_size.x + roi.position.x + x] = 255 if source_value != 0 else 0
	var image := Image.create_from_data(image_size.x, image_size.y, false, Image.FORMAT_L8, full)
	var payload := image.save_png_to_buffer()
	if payload.is_empty():
		return {"ok": false, "message": "初始 mask 无法写入快照。"}
	var digest := _sha256(payload)
	var name := "initial-mask-%s.png" % digest
	if not _write_atomic_bytes(name, payload):
		return {"ok": false, "message": "初始 mask 无法写入快照。"}
	return {
		"ok": true,
		"descriptor": {"path": name, "sha256": digest, "width": image_size.x, "height": image_size.y},
	}


func _prepare_job() -> bool:
	if not _job_dir.is_empty():
		return true
	_job_parent = ProjectSettings.globalize_path(job_root).simplify_path().trim_suffix("/")
	if _job_parent.is_empty() or _job_parent == "/" or _is_link(_job_parent):
		return false
	if DirAccess.make_dir_recursive_absolute(_job_parent) != OK or _is_link(_job_parent):
		return false
	_job_serial += 1
	_job_dir = _job_parent.path_join("model-assist-%d-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec(), _job_serial])
	if FileAccess.file_exists(_job_dir) or DirAccess.dir_exists_absolute(_job_dir):
		_job_dir = ""
		return false
	if DirAccess.make_dir_absolute(_job_dir) != OK:
		_job_dir = ""
		return false
	return not _is_link(_job_dir)


func _write_atomic_bytes(name: String, payload: PackedByteArray) -> bool:
	if _job_dir.is_empty() or name.get_file() != name or name.is_empty():
		return false
	var destination := _job_dir.path_join(name)
	if FileAccess.file_exists(destination):
		return not _is_link(destination) and FileAccess.get_sha256(destination) == _sha256(payload)
	var temporary := _job_dir.path_join(".%s.tmp-%d-%d" % [name, OS.get_process_id(), Time.get_ticks_usec()])
	if FileAccess.file_exists(temporary) or DirAccess.dir_exists_absolute(temporary):
		return false
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(payload)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or FileAccess.get_sha256(temporary) != _sha256(payload):
		DirAccess.remove_absolute(temporary)
		return false
	if FileAccess.file_exists(destination) or _is_link(destination):
		DirAccess.remove_absolute(temporary)
		return false
	if DirAccess.rename_absolute(temporary, destination) != OK:
		DirAccess.remove_absolute(temporary)
		return false
	return true


func _preflight_failure(message: String) -> Dictionary:
	if _preflight_pid > 0:
		_stop_preflight()
	if _pid > 0 or not _job_dir.is_empty():
		shutdown()
	_runtime.clear()
	var result := {
		"ok": false,
		"status": "unavailable",
		"message": message,
		"badge": "",
		"device": "",
		"busy": false,
		"errors": [message],
		"checkpoint_sha256": "",
	}
	_set_state(result)
	return result.duplicate(true)


func _fail_input(message: String) -> void:
	_set_state({
		"status": "failed",
		"message": message,
		"badge": str(_runtime.get("badge", "")),
		"device": str(_runtime.get("device", "")),
		"busy": false,
		"errors": [message],
	})


func _fatal(message: String, graceful_op: String, target_request_id: String = "") -> void:
	if _shutting_down:
		return
	_shutting_down = true
	_invalidate_predictions()
	var terminated := true
	if _pid > 0 and _process_is_running(_pid):
		if graceful_op == "cancel" and not target_request_id.is_empty():
			_send_control("cancel", {"target_request_id": target_request_id})
		else:
			_send_control("shutdown", {})
		terminated = _wait_or_kill(_pid)
	if not terminated:
		_shutting_down = false
		_set_termination_failure()
		return
	_close_pipes()
	_pid = -1
	_worker_session_id = ""
	_worker_confirmed = false
	_pending.clear()
	_cleanup_job()
	_clear_image_state()
	_shutting_down = false
	_set_state({
		"status": "failed",
		"message": message,
		"badge": str(_runtime.get("badge", "")),
		"device": str(_runtime.get("device", "")),
		"busy": false,
		"errors": [message],
	})


func _wait_or_kill(process_id: int) -> bool:
	if process_id <= 0 or process_id != _pid or _worker_session_id.is_empty():
		return false
	var deadline := Time.get_ticks_msec() + maxi(shutdown_grace_ms, 0)
	while _process_is_running(process_id) and Time.get_ticks_msec() < deadline:
		OS.delay_msec(5)
	if not _process_is_running(process_id):
		return true
	if _kill_owned_process(process_id) != OK:
		return false
	var kill_deadline := Time.get_ticks_msec() + 250
	while _pid_present_after_kill(process_id) and Time.get_ticks_msec() < kill_deadline:
		OS.delay_msec(5)
	return not _pid_present_after_kill(process_id)


func _set_termination_failure() -> void:
	_set_state({
		"status": "failed",
		"message": "模型辅助 worker 无法确认退出；已保留任务目录。",
		"badge": str(_runtime.get("badge", "")),
		"device": str(_runtime.get("device", "")),
		"busy": false,
		"errors": ["模型辅助 worker 无法确认退出；已保留任务目录。"],
	})


func _close_pipes() -> void:
	if _stdio != null:
		_stdio.close()
	if _stderr != null:
		_stderr.close()
	_stdio = null
	_stderr = null
	_pipe.clear()
	_read_buffer.clear()


func _retire_current_image_request() -> void:
	if _current_image_token <= 0:
		return
	var key := str(_current_image_token)
	if _pending.has(key) and _pending[key].op == "set_image":
		_pending[key].retired = true
		_remember_retired(key)


func _has_retired_inflight_predict() -> bool:
	for request_id: Variant in _pending:
		var record: Dictionary = _pending[request_id]
		if record.op == "predict" and record.retired:
			return true
	return false


func _finish_cancelled_worker() -> void:
	if _current_image.is_empty() or _current_context.is_empty():
		_fatal("模型辅助取消超时，当前标注未修改。", "cancel")
		return
	_restart_worker_for_current_image(_current_context)


func _store_candidate_paths(token: String, candidates: Array) -> void:
	_cleanup_candidate_token(token)
	var paths: Array[String] = []
	for candidate: Variant in candidates:
		if candidate is Dictionary:
			var path := _safe_candidate_output_path(str(candidate.get("path", "")))
			if not path.is_empty() and path not in paths:
				paths.append(path)
	_candidate_paths[token] = paths


func _remove_response_candidates(data: Dictionary) -> void:
	var candidates: Variant = data.get("candidates", [])
	if not candidates is Array:
		return
	for candidate: Variant in candidates:
		if candidate is Dictionary:
			_remove_candidate_path(_safe_candidate_output_path(str(candidate.get("path", ""))))


func _cleanup_candidate_token(token: String) -> void:
	if not _candidate_paths.has(token):
		return
	var paths: Variant = _candidate_paths[token]
	if paths is Array:
		for path: Variant in paths:
			_remove_candidate_path(str(path))
	_candidate_paths.erase(token)


func _cleanup_candidate_outputs() -> void:
	for token: Variant in _candidate_paths.keys():
		_cleanup_candidate_token(str(token))


func _cleanup_candidate_directory() -> void:
	if _job_dir.is_empty():
		return
	var directory := _job_dir.path_join("candidates").simplify_path()
	if directory.get_base_dir() != _job_dir.simplify_path():
		return
	_remove_owned_tree(directory)


func _safe_candidate_output_path(relative: String) -> String:
	if _job_dir.is_empty() or relative.is_empty() or relative.is_absolute_path():
		return ""
	var candidate_root := _job_dir.path_join("candidates").simplify_path()
	var absolute := _job_dir.path_join(relative).simplify_path()
	if absolute.get_base_dir() != candidate_root or absolute.get_extension().to_lower() != "png":
		return ""
	return absolute


func _remove_candidate_path(path: String) -> void:
	if path.is_empty() or not FileAccess.file_exists(path) or _is_link(path):
		return
	DirAccess.remove_absolute(path)


func _process_is_running(process_id: int) -> bool:
	if process_running.is_valid():
		return bool(process_running.call(process_id))
	return OS.is_process_running(process_id)


func _kill_owned_process(process_id: int) -> Error:
	if process_id <= 0 or process_id != _pid or _worker_session_id.is_empty():
		return ERR_INVALID_PARAMETER
	if kill_process.is_valid():
		return int(kill_process.call(process_id)) as Error
	return OS.kill(process_id)


func _pid_present_after_kill(process_id: int) -> bool:
	# OS.is_process_running() logs an engine error after Godot has already reaped
	# a child. Linux /proc gives the post-kill existence check without that noise.
	return DirAccess.dir_exists_absolute("/proc/%d" % process_id)


func _new_worker_session_id() -> String:
	return _new_session_id("worker")


func _new_session_id(label: String) -> String:
	var entropy := Crypto.new().generate_random_bytes(32)
	if not entropy.is_empty():
		return entropy.hex_encode()
	return _sha256(("%s:%d:%d:%d" % [label, OS.get_process_id(), Time.get_ticks_usec(), _worker_launch_count]).to_utf8_buffer())


func _cleanup_job() -> void:
	if _job_dir.is_empty():
		return
	var owned := _job_dir.simplify_path()
	var parent := _job_parent.simplify_path()
	if parent.is_empty() or parent == "/" or owned.get_base_dir() != parent or not owned.get_file().begins_with("model-assist-"):
		_job_dir = ""
		return
	_remove_owned_tree(owned)
	_job_dir = ""


func _remove_owned_tree(path: String) -> void:
	var parent := DirAccess.open(path.get_base_dir())
	if parent != null and parent.is_link(path.get_file()):
		DirAccess.remove_absolute(path)
		return
	if not DirAccess.dir_exists_absolute(path):
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for directory_name: String in directory.get_directories():
		var child := path.path_join(directory_name)
		if directory.is_link(directory_name):
			DirAccess.remove_absolute(child)
		else:
			_remove_owned_tree(child)
	DirAccess.remove_absolute(path)


func _clear_image_state() -> void:
	_hello_ready = false
	_image_ready = false
	_current_context.clear()
	_current_image.clear()
	_current_initial_mask = null
	_current_image_token = -1
	_latest_predict_token = -1
	_load_deadline_ms = -1


func _invalidate_predictions() -> void:
	_cleanup_candidate_outputs()
	if _latest_predict_token > 0:
		var key := str(_latest_predict_token)
		if _pending.has(key):
			_pending[key].retired = true
		_remember_retired(key)
	_latest_predict_token = -1


func _remember_retired(request_id: String) -> void:
	_retired_ids[request_id] = true
	while _retired_ids.size() > 256:
		_retired_ids.erase(_retired_ids.keys()[0])


func _same_image_identity(left: Dictionary, right: Dictionary) -> bool:
	for field: String in ["session_id", "frame_id", "playback_index", "image_sha256", "record_sha256", "selected_region_id"]:
		if left.get(field) != right.get(field):
			return false
	return true


func _response_context_matches(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.is_empty() or expected.is_empty():
		return actual.is_empty() and expected.is_empty()
	if not _keys_equal(actual, CONTEXT_FIELDS):
		return false
	for field: String in ["frame_id", "playback_index", "prompt_revision"]:
		if not _logical_integer(actual.get(field)) or int(actual[field]) != int(expected.get(field, -1)):
			return false
	for field: String in ["session_id", "image_sha256", "record_sha256", "selected_region_id"]:
		if actual.get(field) != expected.get(field):
			return false
	return true


func _ready_state() -> Dictionary:
	return {
		"status": "ready",
		"message": str(_runtime.get("badge", "")),
		"badge": str(_runtime.get("badge", "")),
		"device": str(_runtime.get("device", "")),
		"busy": false,
		"errors": [],
	}


func _set_busy_state(status: String, message: String) -> void:
	_set_state({
		"status": status,
		"message": message,
		"badge": str(_runtime.get("badge", "")),
		"device": str(_runtime.get("device", "")),
		"busy": true,
		"errors": [],
	})


func _set_state(value: Dictionary) -> void:
	_state = value.duplicate(true)
	state_changed.emit(_state.duplicate(true))


func _regular_readable_file(path: String, executable: bool = false) -> bool:
	# Conda/venv Python executables are normally symlinks; execution itself is the authority check.
	if path.is_empty() or not path.is_absolute_path() or not FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path) or (not executable and _is_link(path)):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	file.close()
	return true


func _is_link(path: String) -> bool:
	if path.is_empty() or path == "/":
		return false
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


func _keys_equal(value: Dictionary, expected: Array) -> bool:
	var actual: Array = value.keys()
	for key: Variant in actual:
		if not key is String:
			return false
	actual.sort()
	var sorted_expected := expected.duplicate()
	sorted_expected.sort()
	return actual == sorted_expected


func _logical_integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value))


func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _digest_valid(value: Variant) -> bool:
	if not value is String or value.length() != 64 or value != value.to_lower():
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


func _sha256(payload: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(payload)
	return hashing.finish().hex_encode()


func _now_msec() -> int:
	return int(clock.call()) if clock.is_valid() else Time.get_ticks_msec()


func _duplicate_variant(value: Variant) -> Variant:
	if value is Dictionary or value is Array:
		return value.duplicate(true)
	if value is PackedByteArray:
		return value.duplicate()
	return value


# ExactJson intentionally accepts duplicate keys for legacy readers; the model
# protocol is stricter, so this lexical pass rejects duplicates at every depth.
func _json_has_duplicate_keys(text: String) -> bool:
	var scan := {"position": 0, "duplicate": false, "invalid": false}
	_scan_json_value(text, scan, 0)
	return scan.duplicate or scan.invalid


func _scan_json_value(text: String, scan: Dictionary, depth: int) -> void:
	_scan_space(text, scan)
	if depth > 256 or scan.position >= text.length():
		scan.invalid = true
		return
	var character := text[scan.position]
	if character == "{":
		_scan_json_object(text, scan, depth + 1)
	elif character == "[":
		_scan_json_array(text, scan, depth + 1)
	elif character == '"':
		_scan_json_string(text, scan)
	else:
		while scan.position < text.length() and text[scan.position] not in [",", "]", "}", " ", "\t", "\r", "\n"]:
			scan.position += 1


func _scan_json_object(text: String, scan: Dictionary, depth: int) -> void:
	scan.position += 1
	_scan_space(text, scan)
	if scan.position < text.length() and text[scan.position] == "}":
		scan.position += 1
		return
	var keys := {}
	while scan.position < text.length():
		_scan_space(text, scan)
		if scan.position >= text.length() or text[scan.position] != '"':
			scan.invalid = true
			return
		var key := _scan_json_string(text, scan)
		if keys.has(key):
			scan.duplicate = true
			return
		keys[key] = true
		_scan_space(text, scan)
		if scan.position >= text.length() or text[scan.position] != ":":
			scan.invalid = true
			return
		scan.position += 1
		_scan_json_value(text, scan, depth)
		_scan_space(text, scan)
		if scan.position < text.length() and text[scan.position] == "}":
			scan.position += 1
			return
		if scan.position >= text.length() or text[scan.position] != ",":
			scan.invalid = true
			return
		scan.position += 1
	scan.invalid = true


func _scan_json_array(text: String, scan: Dictionary, depth: int) -> void:
	scan.position += 1
	_scan_space(text, scan)
	if scan.position < text.length() and text[scan.position] == "]":
		scan.position += 1
		return
	while scan.position < text.length():
		_scan_json_value(text, scan, depth)
		_scan_space(text, scan)
		if scan.position < text.length() and text[scan.position] == "]":
			scan.position += 1
			return
		if scan.position >= text.length() or text[scan.position] != ",":
			scan.invalid = true
			return
		scan.position += 1
	scan.invalid = true


func _scan_json_string(text: String, scan: Dictionary) -> String:
	var start: int = scan.position
	scan.position += 1
	while scan.position < text.length():
		if text[scan.position] == "\\":
			scan.position += 2
			continue
		if text[scan.position] == '"':
			scan.position += 1
			var parsed: Variant = JSON.parse_string(text.substr(start, scan.position - start))
			if not parsed is String:
				scan.invalid = true
				return ""
			return parsed
		scan.position += 1
	scan.invalid = true
	return ""


func _scan_space(text: String, scan: Dictionary) -> void:
	while scan.position < text.length() and text[scan.position] in [" ", "\t", "\r", "\n"]:
		scan.position += 1
