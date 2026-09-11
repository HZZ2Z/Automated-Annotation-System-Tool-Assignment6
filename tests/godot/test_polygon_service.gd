extends "res://tests/godot/test_polygon_batch.gd"

const SERVICE := preload("res://client/services/polygon_propagation_service.gd")

func run() -> void:
	var s = SUPPORT.new()
	await _boundaries(s)
	await _process_lifecycle(s)
	await _stale_snapshot_identities(s)
	await _strict_result_protocol(s)
	if s.failures.is_empty():
		print("PASS polygon service boundaries and lifecycle")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _new_service():
	var service = SERVICE.new()
	service.job_root = "/tmp/poly-service-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	return service

func _finish_service(service) -> void:
	var started := Time.get_ticks_msec()
	while service.running and Time.get_ticks_msec() - started < 30000:
		service.step()
		await create_timer(0.01).timeout

func _boundaries(s) -> void:
	for scenario: String in ["gap", "verified", "dimensions", "unreadable", "stale_source"]:
		var f := _fixture()
		var service = _new_service()
		if scenario == "gap":
			f.source.entries[3].frame_id = 5
			f.source.entries[3].frame = 5
		elif scenario == "verified":
			load("res://client/domain/commands/review_frames_command.gd").new([3], true).apply(f.store)
		elif scenario == "dimensions":
			f.source.images[0] = Image.create(80, 60, false, Image.FORMAT_RGB8)
		elif scenario == "unreadable":
			f.source.failed_index = 5
		s.expect_equal(service.begin(f.source, f.store, f.source.entries, 2), PackedStringArray(), scenario + " starts")
		service.step()
		if scenario == "stale_source":
			f.source.entries[2].time_s = 8.0
		await _finish_service(service)
		var result: Dictionary = service.result
		s.expect(not service.running, scenario + " completes")
		if scenario in ["unreadable", "stale_source"]:
			s.expect(not result.get("errors", []).is_empty() and not result.has("target_regions"), scenario + " invalidates entire candidate")
		else:
			s.expect_equal(result.get("errors"), PackedStringArray(), scenario + " truncates with a valid plan")
			if scenario == "dimensions":
				s.expect_equal(result.get("start_index"), 1, "dimension change stops only left side")
				s.expect_equal(result.get("left_stop"), "image dimensions changed", "dimension reason retained")
			else:
				s.expect_equal(result.get("end_index"), 2, scenario + " excludes the blocked target")
				s.expect_equal(result.get("right_stop"), "missing original frame ID" if scenario == "gap" else "verified frame protected", scenario + " reason retained")
		service.cancel()
	var f := _fixture()
	for index in range(6, 60):
		f.source.entries.append({"frame":index, "frame_id":index, "time_s":index * 0.04})
		f.source.images.append(f.source.images[2])
		var record: Dictionary = f.records[2].duplicate(true)
		record.frame = index
		record.time_s = index * 0.04
		f.records.append(record)
	f.store.load_model_records(f.records)
	var service = _new_service()
	service.begin(f.source, f.store, f.source.entries, 30)
	await _finish_service(service)
	s.expect_equal(service.result.get("end_index",-1) - service.result.get("start_index",-1) + 1, 30, "bounded sampling includes at most 30 frames")
	s.expect_equal(service.result.get("left_stop"), "30-frame cap (truncated)", "cap is reported")
	service.cancel()

func _process_lifecycle(s) -> void:
	var f := _fixture()
	var service = _new_service()
	service.begin(f.source, f.store, f.source.entries, 2)
	var turns := 0
	while service._pid < 0 and service.running and turns < 50:
		service.step()
		turns += 1
	var pid: int = service._pid
	var job: String = service._job_dir
	s.expect(pid > 0, "real worker launched without blocking")
	var request: Variant = service._read_json("request.json")
	s.expect(request is Dictionary and request.get("schema_version") == 3, "worker request uses sampling-aware schema v3")
	s.expect_equal(request.get("frame_step"), 1, "worker receives the default sampling step")
	s.expect_equal(request.get("similarity_threshold"), 0.1, "worker receives the relaxed default similarity threshold")
	if request is Dictionary:
		for frame: Variant in request.get("frames", []):
			s.expect(frame is Dictionary and frame.size() == 7, "each worker frame has only v2 snapshot fields")
			if frame is Dictionary:
				for field: String in ["index", "frame_id", "image_path", "image_sha256", "entry_digest", "record_digest", "verified"]:
					s.expect(frame.has(field), "worker frame includes %s" % field)
	var sentinel := FileAccess.open(service.job_root.path_join("keep.txt"), FileAccess.WRITE)
	sentinel.store_string("unrelated local data")
	sentinel.close()
	service.cancel()
	await create_timer(0.05).timeout
	service.step()
	if OS.get_name() == "Linux":
		s.expect(not DirAccess.dir_exists_absolute("/proc/%d" % pid), "cancel stops only its own running worker")
	s.expect(not service.running and service.result.is_empty(), "cancel discards any result")
	s.expect(not DirAccess.dir_exists_absolute(job), "cancel reaps its own snapshot directory")
	s.expect(FileAccess.file_exists(service.job_root.path_join("keep.txt")), "cleanup preserves unrelated data")
	service.begin(f.source, f.store, f.source.entries, 2)
	service.timeout_ms = -1
	service.step()
	s.expect(not service.running and not service.result.get("errors", []).is_empty(), "timeout fails without a partial candidate")
	service.cancel()
	# 真实进程返回错误协议：边界层应拒绝，而不是把空输出当作完成。
	var bad_cli: String = service.job_root.path_join("bad_worker.py")
	var script := FileAccess.open(bad_cli, FileAccess.WRITE)
	script.store_string("import json,sys\nfrom pathlib import Path\np=Path(sys.argv[sys.argv.index('--result')+1])\np.write_text(json.dumps({'success':True,'proposals':[]}))\n")
	script.close()
	service.cli_path = bad_cli
	service.timeout_ms = 30000
	service.begin(f.source, f.store, f.source.entries, 2)
	await _finish_service(service)
	s.expect(not service.result.get("errors", []).is_empty() and not service.result.has("target_regions"), "malformed worker success is rejected atomically")
	service.cancel()

func _launch(service, fixture) -> void:
	service.begin(fixture.source, fixture.store, fixture.source.entries, 2, 0.123)
	var turns := 0
	while service._pid < 0 and service.running and turns < 80:
		service.step()
		turns += 1

func _wait_worker_process(service) -> void:
	var started := Time.get_ticks_msec()
	while service._pid > 0 and OS.is_process_running(service._pid) and Time.get_ticks_msec() - started < 30000:
		await create_timer(0.01).timeout

func _stale_snapshot_identities(s) -> void:
	for scenario: String in ["entry", "record", "review", "image", "png"]:
		var f := _fixture()
		var service = _new_service()
		await _launch(service, f)
		s.expect(service._pid > 0, scenario + " launched from frozen inputs")
		if scenario == "entry":
			f.source.entries[2].time_s = 99.0
		elif scenario == "record":
			var record: Dictionary = f.store.get_corrected_record(2)
			record.regions[0].polygon[0][0] += 1
			f.store.replace_corrected_record(2, record)
		elif scenario == "review":
			load("res://client/domain/commands/review_frames_command.gd").new([2], true).apply(f.store)
		elif scenario == "image":
			f.source.images[2].set_pixel(0, 0, Color.WHITE)
		else:
			await _wait_worker_process(service)
			var path: String = service._snapshots[2].image_path
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string("tampered snapshot")
			file.close()
		await _finish_service(service)
		s.expect(not service.result.get("errors", []).is_empty() and not service.result.has("target_regions"), scenario + " mutation invalidates the whole candidate")
		service.cancel()

func _strict_result_protocol(s) -> void:
	var f := _fixture()
	var service = _new_service()
	await _launch(service, f)
	await _wait_worker_process(service)
	var payload: Variant = service._read_json("result.json")
	s.expect(payload is Dictionary and payload.get("success") == true, "strict protocol fixture produced a real worker result")
	if payload is Dictionary and not payload.get("proposals", []).is_empty():
		var extra: Dictionary = payload.duplicate(true)
		extra["unexpected"] = true
		s.expect(not service._accept(extra).is_empty(), "extra result fields are rejected")
		var nonfinite: Dictionary = payload.duplicate(true)
		var proposal: Dictionary = nonfinite.proposals[0]
		var region_id: String = proposal.regions[0].id
		proposal.quality[region_id].edge.hausdorff = NAN
		s.expect(not service._accept(nonfinite).is_empty(), "non-finite edge diagnostics are rejected")
		var oversized: Dictionary = payload.duplicate(true)
		oversized.proposals[0].quality[region_id].edge.reason = "x".repeat(161)
		s.expect(not service._accept(oversized).is_empty(), "unbounded edge reasons are rejected")
	service.cancel()
