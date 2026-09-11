extends SceneTree

class FailingWriter extends RefCounted:
	var fail := true
	var repository = preload("res://client/workspace/session_repository.gd").new()
	func write(snapshot: Dictionary, options: Dictionary, token: Variant) -> Dictionary:
		if fail: return {"success":false,"errors":["Injected write failure"],"session_id":snapshot.session_id,"revision":snapshot.revision}
		return repository.save_snapshot(snapshot,options,token)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var repository = load("res://client/workspace/session_repository.gd").new()
	var options := {"path":"/tmp/part4-save-failures-%d-%d/clip.json" % [OS.get_process_id(),Time.get_ticks_usec()],"media_id":"clip","media_type":"image_sequence","source":"clip","source_relative_path":"clip","frame_entries":[{"frame":0,"frame_id":16}],"baseline_kind":"empty"}
	var opened: Dictionary = repository.open_session(options)
	var label = load("res://client/workspace/media_label_store.gd").new()
	label.adopt_session(opened)
	var store = opened.store
	var session = load("res://client/workspace/workspace_session.gd").new()
	root.add_child(session)
	session.bind(store,label,Callable(),Callable())
	await session.flush_before_context_change()
	var old_bytes := FileAccess.get_file_as_bytes(options.path)
	var writer := FailingWriter.new()
	session.set_save_worker(Callable(writer,"write"))
	var record: Dictionary = store.get_corrected_record(16)
	record.regions = [{"id":"r","class":"a","kind":"instrument","box":[1,2,3,4]}]
	store.replace_corrected_record(16,record)
	var errors: PackedStringArray = await session.flush_before_context_change()
	if not _expect(not errors.is_empty() and session.has_unsaved_changes() and FileAccess.get_file_as_bytes(options.path) == old_bytes,"failed write preserves old disk and unsaved memory"): return
	writer.fail = false
	if not _expect((await session.retry_unsaved()).is_empty(),"explicit retry publishes same authoritative edit"): return
	var latest := FileAccess.get_file_as_bytes(options.path)
	var file := FileAccess.open(options.path,FileAccess.WRITE)
	file.store_buffer(latest + " ".to_utf8_buffer())
	file.close()
	record.regions[0].class = "b"
	store.replace_corrected_record(16,record)
	errors = await session.flush_before_context_change()
	if not _expect(not errors.is_empty() and errors[0].contains("externally") and session.has_unsaved_changes(),"external writer detected; no overwrite"): return
	if not _expect(FileAccess.get_file_as_bytes(options.path) == latest + " ".to_utf8_buffer(),"external bytes retained"): return
	session.suspend_autosave(true)
	await session.settle_running()
	session.unbind()
	session.queue_free()
	await process_frame
	print("PASS Part 4 save failures and external changes")
	quit(0)

func _expect(condition: bool,message: String) -> bool:
	if not condition:
		print("FAIL: " + message)
		quit(1)
	return condition
