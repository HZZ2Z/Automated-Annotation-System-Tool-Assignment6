extends SceneTree

var saves: Array = []
var saved_states: Array = []
class SlowWriter extends RefCounted:
	var slow := true
	var repository = preload("res://client/workspace/session_repository.gd").new()
	func write(snapshot: Dictionary, options: Dictionary, token: Variant) -> Dictionary:
		if slow:
			slow = false
			OS.delay_msec(2000)
		return repository.save_snapshot(snapshot,options,token)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var session = load("res://client/workspace/workspace_session.gd").new()
	root.add_child(session)
	if not session.has_method("request_save"):
		print("FAIL: revision-aware autosave is missing")
		quit(1)
		return
	var repository = load("res://client/workspace/session_repository.gd").new()
	var path := "/tmp/part4-autosave-%d-%d/label/clip.json" % [OS.get_process_id(),Time.get_ticks_usec()]
	var opened: Dictionary = repository.open_session({"path":path,"media_id":"clip","media_type":"image_sequence","source":"clip","source_relative_path":"clip","frame_entries":[{"frame":0,"frame_id":16}],"baseline_kind":"empty"})
	var label = load("res://client/workspace/media_label_store.gd").new()
	label.adopt_session(opened)
	var store = opened.store
	var slow_writer := SlowWriter.new()
	session.set_save_worker(Callable(slow_writer,"write"))
	session.bind(store,label,Callable(),Callable())
	session.saved.connect(func(_id: String, revision: int):
		saves.append(revision)
		saved_states.append({"revision":revision,"unsaved":session.has_unsaved_changes(),"current_revision":store.current_revision()}))
	var edit: Dictionary = store.get_corrected_record(16)
	edit.regions = [{"id":"r","class":"a","kind":"instrument","box":[1,2,3,4],"conf":1,"track_id":null}]
	store.replace_corrected_record(16,edit)
	await create_timer(0.42).timeout
	if not _expect(session.is_saving(),"debounce starts asynchronous save"): return
	edit.regions[0].class = "b"
	store.replace_corrected_record(16,edit)
	var latest: int = store.current_revision()
	var ticks := 0
	while saves.is_empty():
		await create_timer(0.02).timeout
		ticks += 1
		if ticks > 200:
			_expect(false,"save timed out")
			return
	# The queued latest save may finish before this 20 ms polling timer wakes.
	# Inspect the first acknowledgement itself, where the older revision must
	# leave the newer edit unsaved; a later successful save may correctly clear it.
	if not _expect(ticks > 20 and saved_states[0].unsaved and saved_states[0].current_revision == latest and saves[0] < latest,"slow worker keeps UI alive and cannot clear newer edits"): return
	var errors: PackedStringArray = await session.flush_before_context_change()
	if not _expect(errors.is_empty() and not session.has_unsaved_changes() and saves[-1] == latest,"latest pending version saves after active job"): return
	var reopened: Dictionary = repository.open_session({"path":path,"media_id":"clip","media_type":"image_sequence","source":"clip","source_relative_path":"clip","frame_entries":[{"frame":0,"frame_id":16}],"baseline_kind":"empty"})
	if not _expect(reopened.success and reopened.snapshot.records[0].regions[0].class == "b","disk contains newest revision"): return
	session.unbind()
	session.queue_free()
	await process_frame
	print("PASS Part 4 asynchronous autosave (%d responsive ticks)" % ticks)
	quit(0)

func _expect(condition: bool,message: String) -> bool:
	if not condition:
		print("FAIL: " + message)
		quit(1)
	return condition
