extends SceneTree

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var repository = load("res://client/workspace/session_repository.gd").new()
	var options := {"path":"/tmp/part4-save-deadline-%d-%d/clip.json" % [OS.get_process_id(),Time.get_ticks_usec()],"media_id":"clip","media_type":"image_sequence","source":"clip","source_relative_path":"clip","frame_entries":[{"frame":0,"frame_id":16}],"baseline_kind":"empty"}
	var opened: Dictionary = repository.open_session(options)
	var label = load("res://client/workspace/media_label_store.gd").new()
	label.adopt_session(opened)
	var store = opened.store
	var session = load("res://client/workspace/workspace_session.gd").new()
	root.add_child(session)
	session.bind(store,label,Callable(),Callable())
	await session.flush_before_context_change()
	var save_times: Array = []
	var started := Time.get_ticks_msec()
	session.saved.connect(func(_id: String, _revision: int): save_times.append(Time.get_ticks_msec()-started))
	var record: Dictionary = store.get_corrected_record(16)
	record.regions = [{"id":"r","class":"a","kind":"instrument","box":[1,2,3,4]}]
	for i in range(48):
		record.regions[0].box[0] = i
		store.replace_corrected_record(16,record)
		await create_timer(0.05).timeout
	if save_times.is_empty() or save_times[0] > 2150:
		print("FAIL: continuous-edit save deadline " + str(save_times))
		quit(1)
		return
	await session.flush_before_context_change()
	session.unbind()
	session.queue_free()
	await process_frame
	print("PASS Part 4 continuous edit deadline: first save %d ms" % save_times[0])
	quit(0)
