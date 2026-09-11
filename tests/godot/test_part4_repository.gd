extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not FileAccess.file_exists("res://client/workspace/session_repository.gd"):
		print("FAIL: session repository is missing")
		quit(1)
		return
	var repository = load("res://client/workspace/session_repository.gd").new()
	var store_script = load("res://client/domain/annotation_store.gd")
	var codec = load("res://client/workspace/review_session_codec.gd").new()
	var root_path := "/tmp/part4-repository-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var path := root_path.path_join("label/clip.json")
	var records: Array = [{"schema_version":1,"source":"clip","frame":16,"time_s":0.0,"regions":[]}, {"schema_version":1,"source":"clip","frame":23,"time_s":0.1,"regions":[]}]
	var options := {"path":path,"media_id":"clip","media_type":"image_sequence","source":"clip","source_relative_path":"clip","source_sha256":null,"round_id":"initial","model_revision":"fixture","taxonomy_version":"v1","baseline_kind":"model","seed_records":records,"frame_entries":[{"frame":0,"frame_id":16,"time_s":0.0,"image_path":"16.png"},{"frame":1,"frame_id":23,"time_s":0.1,"image_path":"23.png"}]}
	var opened: Dictionary = repository.open_session(options)
	if not _expect(opened.get("success", false), str(opened)): return
	var store = store_script.new()
	if not _expect(repository.restore_store(store, opened.snapshot).is_empty(), "restore new session"): return
	var baseline: Variant = store.freeze_snapshot().baseline_digest
	var record: Dictionary = store.get_corrected_record(16)
	record.regions = [{"id":"r","class":"grasper","kind":"instrument","box":[1,2,3,4],"conf":1,"track_id":null}]
	store.replace_corrected_record(16, record)
	var saved: Dictionary = repository.save_snapshot(store.freeze_snapshot(), {"path":path,"expected_sha256":""})
	if not _expect(saved.get("success", false), str(saved)): return
	var reopened: Dictionary = repository.open_session(options)
	if not _expect(reopened.get("success", false) and reopened.snapshot.baseline_digest == baseline and reopened.snapshot.records[0].regions.size() == 1, "baseline must remain immutable on reopen: " + str(reopened)): return
	var payload: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not _expect(payload.schema_version == 3 and payload.frames["16"].source == "human_corrected", "V3 source projection"): return
	var wrong := options.duplicate(true)
	wrong.frame_entries[1].time_s = 0.2
	if not _expect(not repository.open_session(wrong).success, "changed source mapping must fail"): return
	var legacy := {"schema_version":1,"media_id":"clip","media_type":"image_sequence","source_relative_path":"clip","source_sha256":null,"frame_digits":6,"frames":{"16":record.duplicate(true)}}
	legacy.frames["16"].erase("time_s")
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(legacy,"",true,true))
	file.close()
	var legacy_bytes := FileAccess.get_file_as_bytes(path)
	var migrated: Dictionary = repository.open_session(options)
	if not _expect(migrated.get("success", false) and migrated.snapshot.baseline_kind == "unknown" and migrated.snapshot.baseline_records.is_empty(), "legacy cannot manufacture model baseline: " + str(migrated)): return
	if not _expect(not migrated.snapshot.records[0].has("time_s"), "legacy optional time remains absent despite timed source"): return
	var result: Dictionary = repository.save_snapshot(migrated.snapshot,{"path":path,"expected_sha256":migrated.disk_sha256,"backup_existing":true})
	if not _expect(result.get("success", false) and FileAccess.get_file_as_bytes(result.backup_path) == legacy_bytes, "migration preserves exact legacy backup"): return
	print("PASS Part 4 session repository")
	quit(0)

func _expect(condition: bool, message: String) -> bool:
	if not condition:
		print("FAIL: " + message)
		quit(1)
	return condition
