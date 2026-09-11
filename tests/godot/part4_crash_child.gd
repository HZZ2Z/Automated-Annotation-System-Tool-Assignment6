extends SceneTree
class CrashDocument extends "res://client/workspace/atomic_document.gd":
	var mode := ""
	var checks := 0
	func barrier(stage: String) -> void:
		print("CRASH_BARRIER " + stage)
		while true: OS.delay_msec(20)
	func _write_bytes(path: String,bytes: PackedByteArray,token: Variant) -> String:
		if mode == "writing":
			var file := FileAccess.open(path,FileAccess.WRITE)
			file.store_buffer(bytes.slice(0,bytes.size()/2))
			file.flush()
			barrier(mode)
		return super._write_bytes(path,bytes,token)
	func _check_expected(path: String,expected: String) -> String:
		checks += 1
		if mode == "validated" and checks == 2: barrier(mode)
		return super._check_expected(path,expected)
	func _replace_file(from: String,to: String) -> Error:
		if mode == "before_replace": barrier(mode)
		var error := super._replace_file(from,to)
		if mode == "after_replace": barrier(mode)
		return error
	func validate(payload: Dictionary) -> PackedStringArray:
		return preload("res://client/workspace/review_session_codec.gd").new().decode(payload).errors
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var path := args[0]
	var mode := args[1]
	var repo = preload("res://client/workspace/session_repository.gd").new()
	var options := {"path":path,"session_id":"crash-case","media_id":"clip","media_type":"image","source":"clip","source_relative_path":"image.png","source_sha256":null,"baseline_kind":"model","frame_entries":[{"frame":0,"frame_id":16,"time_s":0.5}],"seed_records":[{"schema_version":1,"source":"clip","frame":16,"time_s":0.5,"regions":[{"id":"r","class":"old","kind":"instrument","box":[1,2,3,4]}]}]}
	var opened: Dictionary = repo.open_session(options)
	if not opened.success: printerr(opened); quit(1); return
	var store = opened.store
	if mode != "seed":
		var record: Dictionary = store.get_corrected_record(16)
		record.regions[0].class = "new"
		store.replace_corrected_record(16,record)
	var document := CrashDocument.new()
	document.mode = mode
	var result: Dictionary = document.write_document(preload("res://client/workspace/review_session_codec.gd").new().encode(store.freeze_snapshot()),{"path":path,"expected_sha256":opened.disk_sha256,"validate":Callable(document,"validate")})
	print(JSON.stringify(result))
	quit(0 if result.success else 1)
