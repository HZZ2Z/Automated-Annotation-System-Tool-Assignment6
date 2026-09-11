extends SceneTree
const SESSION = preload("res://client/workspace/workspace_session.gd")
const REPOSITORY = preload("res://client/workspace/session_repository.gd")
const LABEL = preload("res://client/workspace/media_label_store.gd")
var errors: Array[String] = []

class SlowWriter extends RefCounted:
	var repository = preload("res://client/workspace/session_repository.gd").new()
	func write(snapshot: Dictionary, options: Dictionary, token: Variant) -> Dictionary:
		OS.delay_msec(100)
		return repository.save_snapshot(snapshot, options, token)

func check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

func _initialize() -> void: call_deferred("run")

func fixture(name: String, revision: int, persisted: bool = false) -> Dictionary:
	var options = {"path":"/tmp/part4-wait-races-%s-%d-%d/clip.json" % [name,OS.get_process_id(),Time.get_ticks_usec()],"media_id":"clip","media_type":"image_sequence","source":"clip","source_relative_path":"clip","frame_entries":[{"frame":0,"frame_id":16}],"baseline_kind":"empty"}
	var repository = REPOSITORY.new()
	var opened = repository.open_session(options)
	check(opened.success, "fixture opens")
	var label = LABEL.new()
	label.adopt_session(opened)
	var store = opened.store
	for i in range(revision):
		var record = store.get_corrected_record(16)
		record.regions = [{"id":"r","class":"c%d" % i,"kind":"instrument","box":[1,2,3,4]}]
		store.replace_corrected_record(16,record)
	if persisted:
		label.bind_store(store)
		var saved = repository.save_snapshot(store.freeze_snapshot(),label.save_options())
		check(saved.success,"fixture persisted")
		label.accept_saved(saved)
	return {"store":store,"label":label,"options":options}

func wait_save(session, revision: int, result: Array) -> void:
	result.append(await session.save_through(revision))

func await_result(result: Array, timeout: float) -> void:
	var deadline = Time.get_ticks_msec() + int(timeout * 1000)
	while result.is_empty() and Time.get_ticks_msec() < deadline: await process_frame

func edit_to(session, store, revision: int) -> void:
	while store.current_revision() < revision:
		var record = store.get_corrected_record(16)
		record.regions[0]["class"] = "edit%d" % store.current_revision()
		store.replace_corrected_record(16,record)

func run() -> void:
	await identity_race()
	await explicit_suspended_race()
	await settle_suppresses_automatic()
	for error in errors: print("FAIL: " + error)
	if errors.is_empty(): print("PASS Part 4 save waiter identity, suspended explicit queue and automatic drain races")
	quit(0 if errors.is_empty() else 1)

func identity_race() -> void:
	var a = fixture("identity-a",5)
	var b = fixture("identity-b",6,true)
	var session = SESSION.new()
	root.add_child(session)
	var writer = SlowWriter.new()
	session.set_save_worker(Callable(writer,"write"))
	session.bind(a.store,a.label,Callable(),Callable())
	var a_identity = session.status().session_id
	var switched: Array = []
	session.saved.connect(func(_identity: String, _revision: int):
		if switched.is_empty():
			switched.append(true)
			session.bind(b.store,b.label,Callable(),Callable()))
	var result: Array = []
	wait_save(session,5,result)
	await await_result(result,1.0)
	check(not switched.is_empty() and session.status().session_id != a_identity and session.saved_revision() == 6,"session B is already saved beyond session A target before waiter resumes")
	check(result.size() == 1 and not result[0].is_empty() and result[0][0].contains("Session changed"),"old waiter rejects replacement identity even when new saved revision exceeds target")
	session.suspend_autosave(true)
	await session.settle_running()
	session.unbind()
	session.queue_free()
	await process_frame

func explicit_suspended_race() -> void:
	var a = fixture("suspended",3)
	var session = SESSION.new()
	root.add_child(session)
	var writer = SlowWriter.new()
	session.set_save_worker(Callable(writer,"write"))
	session.bind(a.store,a.label,Callable(),Callable())
	session.suspend_autosave(true)
	session.request_save()
	check(session.is_saving(),"revision 3 writer is active")
	edit_to(session,a.store,5)
	var result: Array = []
	wait_save(session,5,result)
	await await_result(result,0.8)
	check(result.size() == 1 and result[0].is_empty() and session.saved_revision() == 5,"explicit revision 5 request drains after revision 3 while autosave remains suspended")
	if result.is_empty():
		# Release the known pre-fix waiter without leaking its coroutine or worker.
		session.request_save()
		await await_result(result,1.0)
	session.suspend_autosave(true)
	await session.settle_running()
	session.unbind()
	session.queue_free()
	await process_frame

func settle_suppresses_automatic() -> void:
	var a = fixture("automatic",3)
	var session = SESSION.new()
	root.add_child(session)
	var writer = SlowWriter.new()
	session.set_save_worker(Callable(writer,"write"))
	session.bind(a.store,a.label,Callable(),Callable())
	session.request_save()
	edit_to(session,a.store,5)
	session._process(0.31)
	session.suspend_autosave(true)
	await session.settle_running()
	await create_timer(0.2).timeout
	check(not session.is_saving() and session.saved_revision() == 3 and session.has_unsaved_changes(),"settling for discard suppresses automatic queued revisions")
	session.unbind()
	session.queue_free()
	await process_frame
