## SAM 视频批次独立持有进程、快照和代次；只返回候选，永不取得 Store 写权限。
class_name SamVideoService
extends RefCounted

signal state_changed(snapshot: Dictionary)
signal batch_ready(result: Dictionary)

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
const CANDIDATE := preload("res://client/domain/model_assist_candidate.gd")
const MASK_OPS := preload("res://client/domain/mask_region_ops.gd")
const POLYGONS := preload("res://client/domain/polygon_ops.gd")
const PROTOCOL := "sam-video-v1"
const MAX_LINE_BYTES := 1048576
const MAX_IMAGE_PIXELS := 32 * 1024 * 1024
const CONTEXT_FIELDS := ["session_id", "request_nonce", "key_playback_index", "key_frame_id", "store_revision", "review_sha256", "key_record_sha256", "region_id", "propagation_count", "requested_device"]
const RESPONSE_FIELDS := ["protocol", "request_id", "ok", "context", "data", "errors"]
const RAW_MASK_FIELDS := ["local_index", "playback_index", "frame_id", "object_id", "path", "roi", "score", "sha256"]
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

var job_root := "user://sam-video-jobs"
var worker_path := "res://python/sam_video_worker.py"
var preflight_timeout_ms := 30000
var load_timeout_ms := 180000
var open_timeout_ms := 60000
var propagate_timeout_ms := 180000
var cancel_grace_ms := 200
var shutdown_grace_ms := 200
var clock: Callable
var _runtime: Dictionary = {}
var _state: Dictionary = {"ok": false, "status": "unavailable", "message": "", "badge": "", "device": "", "busy": false, "errors": [], "checkpoint_sha256": ""}
var _preflight_pipe: Dictionary = {}
var _preflight_stdio: FileAccess
var _preflight_stderr: FileAccess
var _preflight_pid := -1
var _preflight_session_id := ""
var _preflight_inputs: Dictionary = {}
var _preflight_buffer := PackedByteArray()
var _preflight_stderr_text := ""
var _preflight_deadline_ms := -1
var _stdio: FileAccess
var _stderr: FileAccess
var _pid := -1
var _worker_nonce := ""
var _process_nonce := ""
var _worker_session_id := ""
var _worker_confirmed := false
var _termination_blocked := false
var _job_parent := ""
var _job_dir := ""
var _owned_job := ""
var _job_serial := 0
var _worker_launch_count := 0
var _request_serial := 0
var _generation := 0
var _pending: Dictionary = {}
var _buffer := PackedByteArray()
var _stderr_text := ""
var _running := false
var _phase := ""
var _source: Variant
var _live_context: Dictionary = {}
var _input_context: Dictionary = {}
var _context: Dictionary = {}
var _entries: Array = []
var _frames: Array = []
var _snapshots: Array = []
var _key_descriptor: Dictionary = {}
var _size := Vector2i.ZERO
var _result: Dictionary = {}
var _staged_result: Dictionary = {}
var _output_digests: Dictionary = {}

func begin(context: Dictionary, source: Variant, entries: Array, key_mask: Dictionary) -> PackedStringArray:
	if _running:
		cancel()
	_result.clear()
	if _termination_blocked:
		return PackedStringArray(["Previous SAM video worker termination is unconfirmed; retry shutdown first"])
	if _runtime.is_empty() or _preflight_pid > 0:
		return PackedStringArray(["SAM video preflight must finish successfully before analysis"])
	if source == null or not source.has_method("get_frame_entry") or not source.has_method("load_image_snapshot_uncached"):
		return PackedStringArray(["SAM video requires a Source with uncached image snapshot integrity support"])
	for key in CONTEXT_FIELDS:
		if not context.has(key): return PackedStringArray(["SAM video context is missing " + key])
	for key in ["session_id", "request_nonce", "region_id"]:
		if not _valid_text(context[key]): return PackedStringArray(["SAM video context has invalid " + key])
	for key in ["key_playback_index", "key_frame_id", "store_revision", "propagation_count"]:
		if not context[key] is int or not _integer(context[key]) or context[key] < 0: return PackedStringArray(["SAM video context has invalid " + key])
	if not _digest_valid(context.review_sha256) or not _digest_valid(context.key_record_sha256):
		return PackedStringArray(["SAM video context digests are invalid"])
	if context.requested_device != _runtime.requested_device:
		return PackedStringArray(["SAM video requested device changed; repeat preflight"])
	var key_index: int = context.key_playback_index
	var count: int = context.propagation_count
	if count < 1 or count > 30 or key_index + count >= entries.size():
		return PackedStringArray(["SAM video requires one key and 1–30 subsequent Source entries"])
	if context.has("key_time_s") and not _finite_number(context.key_time_s):
		return PackedStringArray(["SAM video key time must be finite"])
	# 所有调用方上下文和条目先冻结，首次 Source 读图发生在此之后。
	_live_context = context
	_input_context = context.duplicate(true)
	_entries = entries.duplicate(true)
	_context = {}
	for key in CONTEXT_FIELDS: _context[key] = context[key]
	if context.has("key_time_s"): _context.key_time_s = context.key_time_s
	_context.targets = []
	_source = source
	_result.clear()
	_staged_result.clear()
	_output_digests.clear()
	_frames.clear()
	_snapshots.clear()
	_key_descriptor.clear()
	_size = Vector2i.ZERO
	_generation += 1
	if _pid > 0 and (_worker_session_id != context.session_id or not _worker_confirmed):
		if not _terminate_worker(): return PackedStringArray(["Previous SAM video worker could not be stopped"])
		_cleanup_job()
	if not _prepare_job(): return PackedStringArray(["SAM video job directory is invalid or linked"])
	# reset_batch 已确认后才可复用常驻模型的独立 job；旧候选随新批次失效。
	for name in DirAccess.get_files_at(_job_dir):
		if name != ".owner": DirAccess.remove_absolute(_job_dir.path_join(name))
	for name in DirAccess.get_directories_at(_job_dir): _remove_owned_tree(_job_dir.path_join(name))
	if DirAccess.make_dir_absolute(_job_dir.path_join("inputs")) != OK:
		return _begin_failure("Could not create frozen input directory")
	for local in range(count + 1):
		var error := _capture(key_index + local, local)
		if not error.is_empty(): return _begin_failure(error)
	if _context.has("key_time_s") != _entries[key_index].has("time_s") or (_context.has("key_time_s") and _context.key_time_s != _entries[key_index].time_s):
		return _begin_failure("Key Source timestamp changed")
	if _frames[0].frame_id != _context.key_frame_id: return _begin_failure("Key Source frame ID changed")
	var mask_error := _snapshot_mask(key_mask)
	if not mask_error.is_empty(): return _begin_failure(mask_error)
	var stale := validate_source()
	if not stale.is_empty(): return _begin_failure(stale[0])
	_running = true
	if _pid > 0:
		_send("open_batch", {"frames": _frames}, open_timeout_ms)
	else:
		_launch()
	return PackedStringArray() if _running else PackedStringArray(_result.get("errors", ["SAM video launch failed"]))

func step() -> void:
	if _preflight_pid > 0: _step_preflight()
	if not _running: return
	var stale := validate_source()
	if not stale.is_empty():
		_fail(stale[0])
		return
	if not _pending.is_empty() and _now_msec() > int(_pending.deadline):
		_fail("SAM video %s timed out" % _pending.op)
		return
	_read_worker()
	if _running and not _worker_is_alive():
		_fail("SAM video worker exited before completing the batch")

func is_running() -> bool:
	return _running

func progress_text() -> String:
	return _phase

func get_result() -> Dictionary:
	return {} if _running else _result.duplicate(true)

func validate_source() -> PackedStringArray:
	if _source == null or _live_context != _input_context:
		return PackedStringArray(["SAM video context changed; analyze again"])
	if _job_dir.is_empty() or _job_dir != _owned_job or not _no_links(_job_dir) or not _owner_matches():
		return PackedStringArray(["SAM video job ownership changed"])
	for snapshot: Dictionary in _snapshots:
		var entry: Variant = _source.get_frame_entry(snapshot.index)
		if not entry is Dictionary or _entry_digest(entry) != snapshot.entry_sha256:
			return PackedStringArray(["Source frame mapping changed; analyze again"])
		var image := _load_image(snapshot.index)
		if image == null or image.get_size() != _size or _sha256(image.save_png_to_buffer()) != snapshot.image_sha256:
			return PackedStringArray(["Source image changed; analyze again"])
		if not _file_matches(snapshot.path, snapshot.image_sha256):
			return PackedStringArray(["Frozen SAM video input changed"])
	if not _key_descriptor.is_empty() and not _file_matches(_key_descriptor.path, _key_descriptor.sha256):
		return PackedStringArray(["Frozen SAM video key mask changed"])
	for path in _output_digests:
		if not _file_matches(path, _output_digests[path]):
			return PackedStringArray(["SAM video output file changed during validation"])
	if _live_context != _input_context:
		return PackedStringArray(["SAM video context changed while loading Source"])
	return PackedStringArray()

func cancel() -> void:
	# 先退役本地代次，再发送 cancel；所有迟到回复均无发布权限。
	_generation += 1
	_running = false
	_result.clear()
	_staged_result.clear()
	if _pid > 0 and _pending.get("op") == "propagate":
		_write_control("cancel", {"target_request_id": _pending.id})
	_pending.clear()
	if _terminate_worker(): _cleanup_job()
	_phase = "SAM video worker termination failed; retry shutdown" if _termination_blocked else "cancelled"
	_source = null
	_set_status("failed" if _termination_blocked else "cancelled", false, [_phase] if _termination_blocked else [])

func shutdown() -> void:
	cancel()
	_stop_preflight()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and (_preflight_pid > 0 or _pid > 0 or not _job_dir.is_empty()): shutdown()

func _capture(index: int, local: int) -> String:
	if not _entries[index] is Dictionary: return "Source entry is invalid"
	var entry: Variant = _source.get_frame_entry(index)
	if not entry is Dictionary or _entry_digest(entry) != _entry_digest(_entries[index]): return "Source entry changed before capture"
	var frame_id: Variant = entry.get("frame_id", entry.get("frame"))
	if not _integer(frame_id) or frame_id < 0: return "Source frame ID must be an exactly representable non-negative integer"
	frame_id = int(frame_id)
	if entry.has("time_s") and not _finite_number(entry.time_s): return "Source time must be finite"
	var image := _load_image(index)
	if image == null: return "Source image could not be loaded"
	if image.get_height() <= 0 or image.get_width() > MAX_IMAGE_PIXELS / image.get_height(): return "Source image exceeds bounded mask size"
	if _size == Vector2i.ZERO: _size = image.get_size()
	if image.get_size() != _size: return "Source image dimensions differ across the batch"
	var payload := image.save_png_to_buffer()
	var digest := _sha256(payload)
	var name := "inputs/%06d-%s.png" % [local, digest]
	if not _write_atomic(name, payload): return "Could not publish frozen PNG input"
	_frames.append({"path": name, "sha256": digest, "width": _size.x, "height": _size.y, "playback_index": index, "frame_id": frame_id})
	var entry_digest := _entry_digest(entry)
	_snapshots.append({"index": index, "path": name, "image_sha256": digest, "entry_sha256": entry_digest})
	if local > 0:
		var target := {"playback_index": index, "frame_id": frame_id, "entry_sha256": entry_digest, "image_sha256": digest}
		if entry.has("time_s"): target.time_s = entry.time_s
		_context.targets.append(target)
	return ""

func _load_image(index: int) -> Image:
	var image: Variant = _source.load_image_snapshot_uncached(index)
	return image if image is Image and not image.is_empty() else null

func _snapshot_mask(value: Dictionary) -> String:
	var raster := value.duplicate(true)
	var polygon: Variant = null
	if value.has("polygon"):
		polygon = value.polygon
	elif value.has("box"):
		polygon = POLYGONS.box_to_polygon(value.box)
	if polygon != null:
		if not (polygon is Array or polygon is PackedVector2Array) or polygon.size() > 2048 or not POLYGONS.validate_simple_polygon(polygon) or not POLYGONS.points_fit_image(polygon, Vector2(_size)):
			return "Key geometry must be one simple ring inside the image"
		raster = MASK_OPS.rasterize_polygon_mask(polygon, _size)
		if not raster.get("ok", false): return "Key geometry could not be rasterized"
	if not raster.get("roi") is Rect2i or not raster.get("mask") is PackedByteArray: return "Key mask requires a binary ROI, Box or Poly"
	var roi: Rect2i = raster.roi
	var bits: PackedByteArray = raster.mask
	if roi.size.x <= 0 or roi.size.y <= 0 or roi.intersection(Rect2i(Vector2i.ZERO, _size)) != roi or bits.size() != roi.size.x * roi.size.y: return "Key mask ROI is invalid"
	var full := PackedByteArray()
	full.resize(_size.x * _size.y)
	var selected := 0
	for y in range(roi.size.y):
		for x in range(roi.size.x):
			var pixel: int = bits[y * roi.size.x + x]
			if pixel not in [0, 1, 255]: return "Key mask must be binary"
			if pixel != 0: selected += 1
			full[(roi.position.y + y) * _size.x + roi.position.x + x] = 255 if pixel != 0 else 0
	if selected == 0 or selected == full.size(): return "Key mask cannot be empty or cover the full image"
	var image := Image.create_from_data(_size.x, _size.y, false, Image.FORMAT_L8, full)
	var payload := image.save_png_to_buffer()
	var digest := _sha256(payload)
	var name := "key-%s.png" % digest
	if not _write_atomic(name, payload): return "Could not publish key mask"
	_key_descriptor = {"path": name, "sha256": digest, "roi": [0, 0, _size.x, _size.y]}
	return ""

func _launch() -> void:
	_worker_session_id = _context.session_id
	_process_nonce = _worker_nonce
	_worker_launch_count += 1
	var pipe := OS.execute_with_pipe(_runtime.python_path, PackedStringArray([ProjectSettings.globalize_path(worker_path), "--job-dir", _job_dir, "--config", _runtime.config_path, "--checkpoint", _runtime.checkpoint_path, "--device", _runtime.requested_device, "--session-id", _worker_session_id]), false)
	if not pipe.get("stdio") is FileAccess or not pipe.get("stderr") is FileAccess or not pipe.get("pid") is int:
		_fail("SAM video worker could not launch")
		return
	_stdio = pipe.stdio
	_stderr = pipe.stderr
	_pid = pipe.pid
	_buffer.clear()
	_stderr_text = ""
	_worker_confirmed = false
	_send("hello", {}, load_timeout_ms)

func _send(op: String, data: Dictionary, timeout: int) -> void:
	_request_serial += 1
	var id := "%s-%d-%d" % [_worker_nonce, _generation, _request_serial]
	_pending = {"id": id, "op": op, "generation": _generation, "deadline": _now_msec() + timeout}
	_phase = op
	var raw := (JSON.stringify({"protocol": PROTOCOL, "request_id": id, "op": op, "context": _context, "data": data}, "", false, true) + "\n").to_utf8_buffer()
	if raw.size() > MAX_LINE_BYTES or _stdio == null:
		_fail("SAM video request exceeds protocol boundary")
		return
	_stdio.store_buffer(raw)
	if _stdio.get_error() != OK:
		_fail("SAM video worker pipe write failed")
		return
	_set_status(op, true)

func _read_worker() -> void:
	if _stdio == null: return
	if _stderr != null:
		var errors := _stderr.get_buffer(4096)
		_stderr_text = (_stderr_text + errors.get_string_from_utf8()).right(4096)
	for _turn in range(32):
		if _stdio == null or not _running: return
		var chunk := _stdio.get_buffer(65536)
		var error := _stdio.get_error()
		_buffer.append_array(chunk)
		var newline := _buffer.find(10)
		if _buffer.size() > MAX_LINE_BYTES or (newline >= 0 and newline + 1 != _buffer.size()):
			_fail("SAM video returned an oversized or unsolicited response")
			return
		if newline >= 0:
			var line := _buffer.slice(0, newline)
			_buffer.clear()
			if line.find(13) >= 0 or line.get_string_from_utf8().to_utf8_buffer() != line:
				_fail("SAM video response must be one UTF-8 JSONL line")
				return
			_consume(line.get_string_from_utf8())
			return
		# Godot's nonblocking pipe may report ERR_FILE_CANT_READ for an empty
		# short read; process liveness and the deadline distinguish EOF/hangs.
		if chunk.size() < 65536 and _worker_is_alive(): return
		if error == ERR_FILE_EOF:
			_fail("SAM video worker closed stdout before completion")
			return
		if error not in [OK, ERR_BUSY]:
			_fail("SAM video worker pipe read failed (%d): %s" % [error, _stderr_text])
			return
		if error == ERR_BUSY or chunk.size() < 65536: return

func _consume(line: String) -> void:
	if _json_has_duplicate_keys(line):
		_fail("SAM video response contains duplicate or malformed JSON")
		return
	var response: Variant = EXACT_JSON.parse_string(line)
	if not response is Dictionary or not _keys_equal(response, RESPONSE_FIELDS):
		_fail("SAM video response envelope is invalid")
		return
	if _pending.is_empty() or response.protocol != PROTOCOL or response.request_id != _pending.id or not _json_equal(response.context, _context) or _pending.generation != _generation:
		_fail("SAM video response has stale protocol, request ID or context")
		return
	if not response.ok is bool or not response.data is Dictionary or not response.errors is Array:
		_fail("SAM video response has invalid field types")
		return
	for error in response.errors:
		if not _valid_text(error, 512):
			_fail("SAM video response has invalid errors")
			return
	if response.ok != response.errors.is_empty() or (not response.ok and not response.data.is_empty()):
		_fail("SAM video response has inconsistent status")
		return
	if not response.ok:
		_fail("SAM video worker: " + str(response.errors[0]))
		return
	var data: Dictionary = response.data
	var op: String = _pending.op
	_pending.clear()
	match op:
		"hello":
			if not _keys_equal(data, ["backend", "persistent", "device", "checkpoint_sha256", "session_id", "pid"]) or data.backend != "sam2-video-predictor" or not data.persistent is bool or data.persistent != true or not _integer(data.pid) or data.pid != _pid or data.session_id != _worker_session_id or data.device != _runtime.device or data.checkpoint_sha256 != _runtime.checkpoint_sha256:
				_fail("SAM video hello did not bind process, session or runtime")
				return
			_worker_confirmed = true
			_send("open_batch", {"frames": _frames}, open_timeout_ms)
		"open_batch":
			if not _keys_equal(data, ["batch_serial", "frame_count"]) or not _integer(data.batch_serial) or data.batch_serial <= 0 or not _integer(data.frame_count) or data.frame_count != _frames.size():
				_fail("SAM video open_batch returned invalid frame ownership")
				return
			_send("add_mask", {"mask": _key_descriptor, "object_id": 1}, open_timeout_ms)
		"add_mask":
			if not _keys_equal(data, ["local_index", "object_id"]) or not _integer(data.local_index) or data.local_index != 0 or not _integer(data.object_id) or data.object_id != 1:
				_fail("SAM video add_mask returned invalid key identity")
				return
			_send("propagate", {"count": _context.propagation_count, "object_id": 1}, propagate_timeout_ms)
		"propagate":
			var error := _accept_masks(data)
			if not error.is_empty():
				_fail(error)
				return
			_send("reset_batch", {}, open_timeout_ms)
		"reset_batch":
			if not _keys_equal(data, ["reset"]) or not data.reset is bool or not data.reset:
				_fail("SAM video reset_batch was not acknowledged")
				return
			var stale := validate_source()
			if not stale.is_empty():
				_fail(stale[0])
				return
			if not _worker_is_alive():
				_fail("SAM video worker exited before publication")
				return
			_phase = "ready"
			var completed_generation := _generation
			# 完成提示回调仍处于发布屏障内：get_result() 不可见候选，
			# is_running() 仍为真；回调可能取消、修改上下文或终止进程。
			_set_status("ready", false)
			if completed_generation != _generation: return
			stale = validate_source()
			if not stale.is_empty():
				_fail(stale[0])
				return
			if not _worker_is_alive():
				_fail("SAM video worker exited before publication")
				return
			_result = _staged_result.duplicate(true)
			_staged_result.clear()
			_running = false
			batch_ready.emit(_result.duplicate(true))
		_:
			_fail("SAM video returned an unexpected operation")

func _accept_masks(data: Dictionary) -> String:
	if not _keys_equal(data, ["masks"]) or not data.masks is Array or data.masks.size() != _context.propagation_count:
		return "SAM video mask count is invalid"
	var proposals: Array = []
	var stop := ""
	var paths := {}
	# 协议或文件错误即整批拒绝，即使此前已有合法前缀；拓扑错误仅截断模型建议。
	for index in range(data.masks.size()):
		var raw: Variant = data.masks[index]
		var target: Dictionary = _context.targets[index]
		if not raw is Dictionary or not _keys_equal(raw, RAW_MASK_FIELDS): return "SAM video mask fields are invalid"
		for key in ["local_index", "playback_index", "frame_id", "object_id"]:
			if not _integer(raw[key]): return "SAM video mask identity must be integer"
			raw[key] = int(raw[key])
		if raw.local_index != index + 1 or raw.playback_index != target.playback_index or raw.frame_id != target.frame_id or raw.object_id != 1:
			return "SAM video mask frame identity is invalid"
		if not raw.roi is Array or raw.roi.size() != 4: return "SAM video mask ROI is invalid"
		var roi: Array = []
		for coordinate in raw.roi:
			if not _integer(coordinate): return "SAM video mask ROI must be integer"
			roi.append(int(coordinate))
		var descriptor := {"path": raw.path, "roi": roi, "score": raw.score, "sha256": raw.sha256}
		if not raw.path is String or not raw.path.begins_with("outputs/") or paths.has(raw.path): return "SAM video output path is invalid or repeated"
		paths[raw.path] = true
		if not _file_matches(raw.path, raw.sha256): return "SAM video output path or hash changed"
		var validation := CANDIDATE.validate_file(_job_dir, descriptor, _size)
		if not validation.ok:
			var reason: String = validation.reason
			if _candidate_refusal_category(descriptor) != &"geometry": return reason
			if stop.is_empty(): stop = "Frame %d: %s" % [target.frame_id, reason]
		_output_digests[raw.path] = raw.sha256
		if stop.is_empty():
			var proposal := {"playback_index": target.playback_index, "frame_id": target.frame_id, "object_id": 1, "region_id": _context.region_id, "mask": descriptor.duplicate(true), "polygon": validation.polygon.duplicate()}
			if target.has("time_s"): proposal.time_s = target.time_s
			proposals.append(proposal)
	var stale := validate_source()
	if not stale.is_empty(): return stale[0]
	_staged_result = {"errors": [], "context": _context.duplicate(true), "proposals": proposals, "stop": stop, "risks": [] if stop.is_empty() else [stop], "runtime": _public_runtime(), "provider_id": "sam_video"}
	return ""

func _candidate_refusal_category(descriptor: Dictionary) -> StringName:
	# 错误文案仅用于显示；只对白名单几何结果保留前缀，其余未知拒绝均视作完整性错误。
	if not _keys_equal(descriptor, CANDIDATE.DESCRIPTOR_FIELDS): return &"integrity"
	var score: Variant = descriptor.score
	if not (score is int or score is float) or not is_finite(float(score)): return &"integrity"
	var roi_result := CANDIDATE._roi(descriptor.roi, _size)
	var path_result := CANDIDATE._candidate_path(_job_dir, descriptor.path)
	if not roi_result.get("ok", false) or not path_result.get("ok", false): return &"integrity"
	if not _file_matches(descriptor.path, descriptor.sha256): return &"integrity"
	var path: String = path_result.path
	var bytes := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	if bytes.is_empty() or image.load_png_from_buffer(bytes) != OK or image.is_empty(): return &"integrity"
	if image.get_format() not in [Image.FORMAT_L8, Image.FORMAT_R8, Image.FORMAT_RGB8, Image.FORMAT_RGBA8]: return &"integrity"
	var roi: Rect2i = roi_result.roi
	if image.get_size() != roi.size: return &"integrity"
	var binary := CANDIDATE._binary_mask(image)
	if not binary.get("ok", false): return &"integrity"
	var category := _mask_refusal_category(roi, binary.mask)
	# 几何分类同样受字节与路径完整性保护，文件替换不能降级为普通模型停止。
	if FileAccess.get_file_as_bytes(path) != bytes or not _file_matches(descriptor.path, descriptor.sha256): return &"integrity"
	return category

func _mask_refusal_category(roi: Rect2i, mask: PackedByteArray) -> StringName:
	var selected := 0
	for value: int in mask:
		if value != 0: selected += 1
	if selected == 0 or (roi == Rect2i(Vector2i.ZERO, _size) and selected == _size.x * _size.y): return &"geometry"
	var state := {"roi": roi, "mask": mask}
	var candidate := MASK_OPS.to_v1_candidate(state)
	if not candidate.get("ok", false):
		return &"geometry" if candidate.get("status", &"") in [MASK_OPS.STATUS_EMPTY, MASK_OPS.STATUS_HOLE, MASK_OPS.STATUS_MULTI_COMPONENT, &"non_simple_topology", &"too_complex"] else &"integrity"
	var polygon: PackedVector2Array = candidate.polygon
	if polygon.size() > CANDIDATE.MAX_VERTICES or not POLYGONS.validate_simple_polygon(polygon) or not POLYGONS.points_fit_image(polygon, Vector2(_size)): return &"geometry"
	var raster := MASK_OPS.rasterize_polygon_mask(polygon, _size)
	if not raster.get("ok", false) or MASK_OPS.mask_iou(state, raster) < CANDIDATE.MIN_RASTER_IOU: return &"geometry"
	return &"integrity"

func _begin_failure(message: String) -> PackedStringArray:
	_fail(message)
	return PackedStringArray([message])

func _fail(message: String) -> void:
	_generation += 1
	_running = false
	_pending.clear()
	_staged_result.clear()
	_result = {"errors": [message], "context": _context.duplicate(true), "proposals": [], "stop": "", "risks": [], "runtime": _public_runtime(), "provider_id": "sam_video"}
	if _terminate_worker(): _cleanup_job()
	_phase = message
	var failed_generation := _generation
	_set_status("failed", false, [message])
	if failed_generation != _generation: return
	batch_ready.emit(_result.duplicate(true))

func _public_runtime() -> Dictionary:
	return {"device": _runtime.get("device", ""), "checkpoint_sha256": _runtime.get("checkpoint_sha256", ""), "model_version": _runtime.get("model_version", ""), "badge": _runtime.get("badge", "")}

func _set_status(status: String, busy: bool, errors: Array = []) -> void:
	_set_state({"ok": errors.is_empty() and not _runtime.is_empty(), "status": status, "message": _phase, "badge": _runtime.get("badge", ""), "device": _runtime.get("device", ""), "busy": busy, "errors": errors, "checkpoint_sha256": _runtime.get("checkpoint_sha256", "")})

func _write_control(op: String, data: Dictionary) -> void:
	if _stdio == null or _context.is_empty(): return
	_request_serial += 1
	_stdio.store_buffer((JSON.stringify({"protocol": PROTOCOL, "request_id": "control-%s-%d" % [_worker_nonce, _request_serial], "op": op, "context": _context, "data": data}, "", false, true) + "\n").to_utf8_buffer())

func _terminate_worker() -> bool:
	if _worker_is_alive():
		_write_control("shutdown", {})
		var deadline := Time.get_ticks_msec() + mini(cancel_grace_ms, shutdown_grace_ms)
		while _worker_is_alive() and Time.get_ticks_msec() < deadline: OS.delay_msec(5)
		if _worker_is_alive():
			if _kill_owned_process(_pid, _worker_nonce) != OK:
				_termination_blocked = true
				return false
			deadline = Time.get_ticks_msec() + 250
			while DirAccess.dir_exists_absolute("/proc/%d" % _pid) and Time.get_ticks_msec() < deadline: OS.delay_msec(5)
			if DirAccess.dir_exists_absolute("/proc/%d" % _pid):
				_termination_blocked = true
				return false
	if _stdio != null: _stdio.close()
	if _stderr != null: _stderr.close()
	_stdio = null
	_stderr = null
	_pid = -1
	_process_nonce = ""
	_worker_confirmed = false
	_worker_session_id = ""
	_termination_blocked = false
	_buffer.clear()
	return true

func _worker_is_alive() -> bool:
	if _pid <= 0: return false
	# OS.kill() can already reap a child; avoid polling a retired Godot PID.
	if OS.get_name() == "Linux" and not DirAccess.dir_exists_absolute("/proc/%d" % _pid): return false
	return OS.is_process_running(_pid)

func _kill_owned_process(process_id: int, nonce: String) -> Error:
	if process_id <= 0 or process_id != _pid or nonce.is_empty() or nonce != _worker_nonce or nonce != _process_nonce:
		return ERR_INVALID_PARAMETER
	return OS.kill(process_id)

func _prepare_job() -> bool:
	if not _job_dir.is_empty(): return _job_dir == _owned_job and _owner_matches() and _no_links(_job_dir)
	_job_parent = ProjectSettings.globalize_path(job_root).simplify_path().trim_suffix("/")
	if _job_parent.is_empty() or _job_parent == "/" or not _no_links(_job_parent): return false
	if DirAccess.make_dir_recursive_absolute(_job_parent) != OK or not _no_links(_job_parent): return false
	_worker_nonce = Crypto.new().generate_random_bytes(32).hex_encode()
	if _worker_nonce.is_empty(): return false
	_job_serial += 1
	var path := _job_parent.path_join("sam-video-%s-%d" % [_worker_nonce, _job_serial])
	if DirAccess.make_dir_absolute(path) != OK: return false
	_job_dir = path
	_owned_job = path
	var marker := FileAccess.open(path.path_join(".owner"), FileAccess.WRITE)
	if marker == null: return false
	marker.store_string(_worker_nonce)
	marker.close()
	return true

func _owner_matches() -> bool:
	var marker := _job_dir.path_join(".owner")
	return not _is_link(marker) and FileAccess.file_exists(marker) and FileAccess.get_file_as_string(marker) == _worker_nonce

func _write_atomic(name: String, payload: PackedByteArray) -> bool:
	if payload.is_empty() or not _relative_path(name) or not _no_links(_job_dir) or not _owner_matches(): return false
	var path := _job_dir.path_join(name)
	if not _no_links(path) or FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path): return false
	var temporary := path + ".tmp-" + _worker_nonce
	if FileAccess.file_exists(temporary) or _is_link(temporary): return false
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return false
	file.store_buffer(payload)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or FileAccess.get_sha256(temporary) != _sha256(payload) or not _no_links(path) or FileAccess.file_exists(path):
		DirAccess.remove_absolute(temporary)
		return false
	return DirAccess.rename_absolute(temporary, path) == OK

func _file_matches(relative: Variant, digest: Variant) -> bool:
	if not relative is String or not _relative_path(relative) or not _digest_valid(digest): return false
	var path := _job_dir.path_join(relative)
	return _no_links(path) and FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path) and FileAccess.get_sha256(path) == digest

func _relative_path(path: String) -> bool:
	return not path.is_empty() and not path.is_absolute_path() and path == path.simplify_path() and "\\" not in path and path.get_extension().to_lower() == "png"

func _no_links(path: String) -> bool:
	var current := path.simplify_path().trim_suffix("/")
	while not current.is_empty() and current != "/":
		if _is_link(current): return false
		current = current.get_base_dir()
	return true

func _cleanup_job() -> void:
	if _pid > 0 or _job_dir.is_empty(): return
	if _job_dir == _owned_job and _job_dir.get_base_dir() == _job_parent and _job_dir.get_file().begins_with("sam-video-" + _worker_nonce + "-") and _no_links(_job_parent):
		if _is_link(_job_dir): DirAccess.remove_absolute(_job_dir)
		elif _owner_matches(): _remove_owned_tree(_job_dir)
	_job_dir = ""
	_owned_job = ""

func _entry_digest(entry: Dictionary) -> String:
	var normalized := entry.duplicate(true)
	normalized["frame_id"] = normalized.get("frame_id", normalized.get("frame", -1))
	if _integer(normalized.frame_id): normalized["frame_id"] = int(normalized.frame_id)
	return _sha256(JSON.stringify(normalized, "", true, true).to_utf8_buffer())

func _valid_text(value: Variant, maximum := 256) -> bool:
	if not value is String or value.is_empty() or value.length() > maximum: return false
	for character in value:
		if character.unicode_at(0) < 32 or character.unicode_at(0) == 127: return false
	return true

func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and absf(float(value)) <= 9007199254740991.0

func _json_equal(actual: Variant, expected: Variant) -> bool:
	# ExactJson decodes JSON numbers to float; compare numbers exactly after
	# excluding bool, and recurse so Dictionary equality cannot hide int/float.
	if expected is Dictionary:
		if not actual is Dictionary or actual.size() != expected.size(): return false
		for key in expected:
			if not actual.has(str(key)) or not _json_equal(actual[str(key)], expected[key]): return false
		return true
	if expected is Array:
		if not actual is Array or actual.size() != expected.size(): return false
		for index in range(expected.size()):
			if not _json_equal(actual[index], expected[index]): return false
		return true
	if expected is int or expected is float:
		return _finite_number(actual) and actual == expected
	return typeof(actual) == typeof(expected) and actual == expected


var preflight_probe_code := (
	"import hashlib,importlib.metadata,json,sys\n"
	+ "result = {'torch': False, 'sam2': False, 'cuda': False, 'model_version': ''}\n"
	+ "try:\n import torch\n result['torch'] = True\n result['cuda'] = bool(torch.cuda.is_available())\n"
	+ "except Exception:\n pass\n"
	+ "try:\n import sam2\n result['sam2'] = True\n try:\n  result['model_version'] = importlib.metadata.version('SAM-2')\n except importlib.metadata.PackageNotFoundError:\n  result['model_version'] = str(getattr(sam2, '__version__', ''))\n"
	+ "except Exception:\n pass\n"
	+ "digest = hashlib.sha256()\n"
	+ "with open(sys.argv[1], 'rb') as handle:\n"
	+ " while True:\n  chunk = handle.read(1048576)\n  if not chunk: break\n  digest.update(chunk)\n"
	+ "result['checkpoint_sha256'] = digest.hexdigest()\n"
	+ "result['session_id'] = sys.argv[2]\n"
	+ "print(json.dumps(result, separators=(',', ':')))"
)


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
	if not _runtime.is_empty() and _runtime.get("inputs") == inputs:
		if not _running and _state.get("status") != "ready" and not _termination_blocked:
			_set_status("ready", false)
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
		or not _keys_equal(probe, ["checkpoint_sha256", "cuda", "sam2", "session_id", "torch", "model_version"])
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
	var version_pattern := RegEx.new()
	version_pattern.compile("^[A-Za-z0-9][A-Za-z0-9._+\\-]{0,63}\\z")
	if not probe.model_version is String or version_pattern.search(probe.model_version) == null:
		_preflight_failure("SAM runtime did not report a valid installed model version")
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
		"model_version": probe.model_version,
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


func _digest_valid(value: Variant) -> bool:
	if not value is String or value.length() != 64 or value != value.to_lower():
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _sha256(payload: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(payload)
	return hashing.finish().hex_encode()


func _now_msec() -> int:
	return int(clock.call()) if clock.is_valid() else Time.get_ticks_msec()


func _new_session_id(label: String) -> String:
	var entropy := Crypto.new().generate_random_bytes(32)
	if not entropy.is_empty():
		return entropy.hex_encode()
	return _sha256(("%s:%d:%d:%d" % [label, OS.get_process_id(), Time.get_ticks_usec(), _worker_launch_count]).to_utf8_buffer())


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
	directory.include_hidden = true
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for directory_name: String in directory.get_directories():
		var child := path.path_join(directory_name)
		if directory.is_link(directory_name):
			DirAccess.remove_absolute(child)
		else:
			_remove_owned_tree(child)
	DirAccess.remove_absolute(path)


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
