## Source 负责读图；此服务只管理独立图像快照、后台进程和候选协议。
extends RefCounted

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
const VALIDATOR := preload("res://client/domain/model_output_validator.gd")
const POLYGONS := preload("res://client/domain/polygon_ops.gd")
const METRIC_ID := "poly-flow-mask-v1"
const MAX_FRAMES := 30
var python_path := "res://.venv/bin/python"
var cli_path := "res://python/propagate_polygons.py"
var job_root := "user://polygon-propagation-jobs"
var timeout_ms := 180000
var result: Dictionary = {}
var running := false
var _source: Variant
var _store: Variant
var _entries: Array = []
var _regions: Array = []
var _frames: Array = []
var _checked: Array[int] = []
var _size := Vector2i.ZERO
var _key := -1
var _left := -1
var _right := -1
var _left_stop := ""
var _right_stop := ""
var _direction := -1
var _threshold := 0.65
var _pid := -1
var _job_dir := ""
var _job_parent := ""
var _started := 0
var _message := ""
var _retired: Array = []

func begin(source: Variant, store: Variant, entries: Array, key: int, threshold: float = 0.65) -> PackedStringArray:
	cancel()
	if source == null or store == null or key < 0 or key >= entries.size() or not is_finite(threshold) or threshold <= 0.0 or threshold > 1.0:
		return PackedStringArray(["Select a source frame with polygon annotations"])
	var record: Dictionary = store.get_corrected_record(int(entries[key].frame_id))
	for region: Dictionary in record.get("regions", []):
		if region.has("polygon"):
			var payload := region.duplicate(true)
			payload.erase("filled")
			_regions.append(payload)
	if _regions.is_empty():
		return PackedStringArray(["The reference frame has no polygon; draw or correct a polygon first"])
	if not FileAccess.file_exists(ProjectSettings.globalize_path(python_path)) or not FileAccess.file_exists(ProjectSettings.globalize_path(cli_path)):
		return PackedStringArray(["Poly worker or project Python is missing; see README environment setup"])
	_job_parent = ProjectSettings.globalize_path(job_root).simplify_path().trim_suffix("/")
	if DirAccess.make_dir_recursive_absolute(_job_parent) != OK:
		return PackedStringArray(["Could not create Poly snapshot directory"])
	_job_dir = _job_parent.path_join("%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if DirAccess.make_dir_absolute(_job_dir) != OK:
		_job_dir = ""
		return PackedStringArray(["Could not create Poly job"])
	_source = source
	_store = store
	_entries = entries.duplicate(true)
	_key = key
	_left = key - 1
	_right = key + 1
	_threshold = threshold
	_started = Time.get_ticks_msec()
	_message = "正在准备参考帧"
	running = true
	return PackedStringArray()

func step() -> void:
	_reap()
	if not running:
		return
	if Time.get_ticks_msec() - _started > timeout_ms:
		_fail("Poly analysis timed out; shorten the range or image size")
		return
	if _pid > 0:
		var progress: Variant = _read_json("progress.json")
		if progress is Dictionary and _integer(progress.get("completed")) and _integer(progress.get("total")):
			_message = "正在分析相邻帧（%d / %d）" % [int(progress.completed), int(progress.total)]
		if OS.is_process_running(_pid):
			return
		var exit_code := OS.get_process_exit_code(_pid)
		_pid = -1
		var payload: Variant = _read_json("result.json")
		if exit_code != 0 or not payload is Dictionary or payload.get("success") != true:
			_fail(str(payload.get("error", "Poly worker failed without a valid result")) if payload is Dictionary else "Poly worker failed without a valid result")
			return
		var errors := validate_source()
		if errors.is_empty():
			errors = _accept(payload)
		if not errors.is_empty():
			_fail(errors[0])
			return
		running = false
		_cleanup(_job_dir, _job_parent)
		_job_dir = ""
		return
	if _frames.is_empty():
		_capture(_key)
		return
	if _frames.size() >= MAX_FRAMES:
		if _left_stop.is_empty():
			_left_stop = "30-frame cap (truncated)"
		if _right_stop.is_empty():
			_right_stop = "30-frame cap (truncated)"
	if not _left_stop.is_empty() and not _right_stop.is_empty():
		_launch()
		return
	if (_direction < 0 and not _left_stop.is_empty()) or (_direction > 0 and not _right_stop.is_empty()):
		_direction *= -1
	var index := _left if _direction < 0 else _right
	var reason := ""
	if index < 0 or index >= _entries.size():
		reason = "source boundary"
	elif int(_entries[index].frame_id) - int(_entries[index - _direction].frame_id) != _direction:
		reason = "missing original frame ID"
	elif _store.is_verified(int(_entries[index].frame_id)):
		reason = "verified frame protected"
	else:
		reason = _capture(index)
	if not reason.is_empty():
		if _direction < 0:
			_left_stop = reason
		else:
			_right_stop = reason
	elif _direction < 0:
		_left -= 1
	else:
		_right += 1
	_direction *= -1

func progress_text() -> String:
	return _message

func validate_source() -> PackedStringArray:
	if _source == null:
		return PackedStringArray(["Source is no longer available; analyze again"])
	for index: int in _checked:
		var actual: Dictionary = _source.get_frame_entry(index)
		actual["frame_id"] = int(actual.get("frame_id", actual.get("frame", -1)))
		if actual != _entries[index]:
			return PackedStringArray(["Source frame mapping changed; analyze again"])
	return PackedStringArray()

func cancel() -> void:
	running = false
	_stop_worker()
	_reap()
	result = {}
	_source = null
	_store = null
	_entries.clear()
	_regions.clear()
	_frames.clear()
	_checked.clear()
	_size = Vector2i.ZERO
	_left_stop = ""
	_right_stop = ""
	_direction = -1
	_message = ""

func _capture(index: int) -> String:
	_checked.append(index)
	var errors := validate_source()
	if not errors.is_empty():
		_fail(errors[0])
		return "source changed"
	var texture: Variant = _source.load_texture(index)
	var image: Image = texture.get_image() if texture is Texture2D else null
	if image == null or image.is_empty():
		_fail("Frame %d could not be loaded; Poly analysis cancelled" % int(_entries[index].frame_id))
		return "image unavailable"
	if _size == Vector2i.ZERO:
		_size = image.get_size()
	elif image.get_size() != _size:
		return "image dimensions changed"
	var path := _job_dir.path_join("frame-%d.png" % index)
	if image.save_png(path) != OK:
		_fail("Could not write Poly image snapshot")
		return "snapshot failed"
	_frames.append({"index": index, "frame_id": int(_entries[index].frame_id), "image_path": path})
	_message = "已准备 %d / %d 帧" % [_frames.size(), MAX_FRAMES]
	return ""

func _launch() -> void:
	_frames.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.index) < int(b.index))
	var file := FileAccess.open(_job_dir.path_join("request.json"), FileAccess.WRITE)
	if file == null:
		_fail("Could not write Poly request")
		return
	file.store_string(JSON.stringify({"schema_version": 1, "key_index": _key, "threshold": _threshold, "frames": _frames, "regions": _regions}))
	file.close()
	_pid = OS.create_process(ProjectSettings.globalize_path(python_path), PackedStringArray([
		ProjectSettings.globalize_path(cli_path), "--request", _job_dir.path_join("request.json"),
		"--result", _job_dir.path_join("result.json"), "--cancel-file", _job_dir.path_join("cancel.request"),
		"--progress-file", _job_dir.path_join("progress.json")]), false)
	if _pid <= 0:
		_fail("Could not start Poly worker")
	else:
		_message = "正在估计目标运动"

func _accept(payload: Dictionary) -> PackedStringArray:
	var invalid := PackedStringArray(["Poly worker returned an invalid or stale candidate"])
	var fields := ["schema_version", "success", "cancelled", "metric_id", "threshold", "key_index", "start_index", "end_index", "left_stop", "right_stop", "proposals"]
	if payload.size() != fields.size():
		return invalid
	for field: String in fields:
		if not payload.has(field):
			return invalid
	if payload.schema_version != 1 or payload.success != true or payload.cancelled != false or payload.metric_id != METRIC_ID or payload.threshold != _threshold or payload.key_index != _key:
		return invalid
	if not _integer(payload.start_index) or not _integer(payload.end_index) or not payload.proposals is Array or not payload.left_stop is String or not payload.right_stop is String:
		return invalid
	var first := int(payload.start_index)
	var last := int(payload.end_index)
	if first < int(_frames[0].index) or last > int(_frames[-1].index) or first > _key or last < _key or payload.proposals.size() != last - first:
		return invalid
	var proposals := {}
	var quality := {}
	var seen := {}
	var expected := {}
	for region: Dictionary in _regions:
		expected[region.id] = region
	for proposal: Variant in payload.proposals:
		if not proposal is Dictionary or proposal.size() != 4 or not _integer(proposal.get("index")) or not _integer(proposal.get("frame_id")) or not proposal.get("regions") is Array or not proposal.get("quality") is Dictionary:
			return invalid
		var index := int(proposal.index)
		if index < first or index > last or index == _key or seen.has(index) or int(proposal.frame_id) != int(_entries[index].frame_id) or proposal.regions.size() != expected.size():
			return invalid
		seen[index] = true
		var ids := {}
		var record := {"schema_version": 1, "source": "candidate", "frame": int(proposal.frame_id), "regions": proposal.regions}
		if not VALIDATOR.new().validate_record(record).is_empty():
			return invalid
		for region: Dictionary in proposal.regions:
			if not expected.has(region.id) or ids.has(region.id) or not region.has("polygon") or region.polygon.size() > 2048 or not POLYGONS.validate_simple_polygon(region.polygon):
				return invalid
			ids[region.id] = true
			var original: Dictionary = expected[region.id].duplicate(true)
			var actual := region.duplicate(true)
			if original.has("box") != actual.has("box"):
				return invalid
			original.erase("polygon")
			original.erase("box")
			actual.erase("polygon")
			actual.erase("box")
			if original != actual:
				return invalid
			for point: Array in region.polygon:
				if float(point[0]) > _size.x - 1 or float(point[1]) > _size.y - 1:
					return invalid
		proposals[int(proposal.frame_id)] = proposal.regions.duplicate(true)
		quality[int(proposal.frame_id)] = proposal.quality.duplicate(true)
	result = {"strategy": "polygon_flow", "key_index": _key, "start_index": first, "end_index": last,
		"metric_id": METRIC_ID, "threshold": _threshold, "max_frames": MAX_FRAMES,
		"left_stop": _left_stop if payload.left_stop == "source boundary" else payload.left_stop,
		"right_stop": _right_stop if payload.right_stop == "source boundary" else payload.right_stop,
		"target_regions": proposals, "quality": quality, "errors": PackedStringArray()}
	return PackedStringArray()

func _integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) == floorf(float(value))

func _read_json(name: String) -> Variant:
	var path := _job_dir.path_join(name)
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	return EXACT_JSON.parse_string(file.get_as_text()) if file != null else null

func _fail(message: String) -> void:
	running = false
	_stop_worker()
	result = {"errors": PackedStringArray([message])}
	_message = message

func _stop_worker() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		var file := FileAccess.open(_job_dir.path_join("cancel.request"), FileAccess.WRITE)
		if file != null:
			file.store_string("cancel\n")
			file.close()
		# 仅终止本服务创建的子进程；不影响其他任务或原始文件。
		if OS.kill(_pid) == OK:
			# Godot 在 Linux 已等待并回收子进程，不能再次查询该 PID。
			_cleanup(_job_dir, _job_parent)
		else:
			_retired.append({"pid": _pid, "path": _job_dir, "parent": _job_parent})
	else:
		_cleanup(_job_dir, _job_parent)
	_pid = -1
	_job_dir = ""

func _reap() -> void:
	for index in range(_retired.size() - 1, -1, -1):
		var job: Dictionary = _retired[index]
		if not OS.is_process_running(int(job.pid)):
			_cleanup(job.path, job.parent)
			_retired.remove_at(index)

func _cleanup(path: String, parent: String) -> void:
	if path.is_empty() or path.get_base_dir() != parent:
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	DirAccess.remove_absolute(path)
