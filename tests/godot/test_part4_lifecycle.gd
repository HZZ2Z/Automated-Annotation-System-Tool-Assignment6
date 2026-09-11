extends SceneTree

class Writer extends RefCounted:
	var fail := false
	var delay := 0
	func write(snapshot: Dictionary,options: Dictionary,token: Variant) -> Dictionary:
		if delay: OS.delay_msec(delay)
		if fail: return {"success":false,"errors":["Injected disk failure"],"session_id":snapshot.session_id,"revision":snapshot.revision}
		return preload("res://client/workspace/session_repository.gd").new().save_snapshot(snapshot,options,token)

var _failures: Array[String] = []
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/part4-lifecycle-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	_expect((await main.open_source("res://sample/assignment_v1")).is_empty(),"source opens")
	var session = main._workspace_session
	var flow = main._review_workflow
	await session.flush_before_context_change()
	var original_store = main._store
	var path: String = main._workspace_label_store.label_path()
	var old_bytes := FileAccess.get_file_as_bytes(path)
	session.suspend_autosave(true)
	_edit(main,12,"cancel-me")
	var chosen: bool = await _choose(flow,"cancel")
	_expect(not chosen and main._store == original_store and session.has_unsaved_changes(),"cancel keeps original store and unsaved correction")
	_expect(FileAccess.get_file_as_bytes(path) == old_bytes,"cancel performs no implicit save")
	session.suspend_autosave(true)
	chosen = await _choose(flow,"discard")
	_expect(chosen and flow.has_discard_authorization(),"discard authorizes only current unsaved session")
	_expect((await main.open_source("res://sample/assignment_v1")).is_empty(),"discard then reopen succeeds")
	_expect(main._store.get_corrected_record(12).regions[0].class != "cancel-me","unsaved correction discarded without overwriting last successful save")
	_expect(not flow.has_discard_authorization(),"discard authorization reset after transition")
	session.suspend_autosave(true)
	_edit(main,12,"save-me")
	chosen = await _choose(flow,"save")
	_expect(chosen and not session.has_unsaved_changes(),"save and continue waits for successful revision")
	flow.finish_transition()
	_expect((await main.open_source("res://sample/assignment_v1")).is_empty(),"saved session reopens")
	_expect(main._store.get_corrected_record(12).regions[0].class == "save-me","saved content restored")
	var writer := Writer.new()
	writer.fail = true
	session.set_save_worker(Callable(writer,"write"))
	session.suspend_autosave(true)
	_edit(main,12,"failed-close")
	old_bytes = FileAccess.get_file_as_bytes(path)
	chosen = await _choose(flow,"save")
	_expect(not chosen and session.has_unsaved_changes(),"failed close-save refuses transition")
	_expect(FileAccess.get_file_as_bytes(path) == old_bytes and main._store.get_corrected_record(12).regions[0].class == "failed-close","failed close-save retains disk and memory")
	writer.fail = false
	await session.flush_before_context_change()
	writer.delay = 400
	session.suspend_autosave(true)
	_edit(main,12,"save-dialog")
	chosen = await _choose(flow,"save",func(): _edit_later(main))
	_expect(chosen and not session.has_unsaved_changes(),"save departure also persists edits arriving during slow write")
	flow.finish_transition()
	await session.flush_before_context_change()
	await main._on_file_selected("/tmp/part4-pending-video.mp4")
	_expect(session._suspended,"video import holds transition while choosing output")
	main._on_video_import_cancel_pressed()
	_expect(not session._suspended and not flow.has_discard_authorization(),"closing unstarted video import restores autosave and clears transition")
	for callback in ["_on_video_import_cancelled","_on_video_import_failed"]:
		session.suspend_autosave(true)
		flow._discard_session = session.status().session_id
		if callback.ends_with("failed"): main.call(callback,"injected import failure")
		else: main.call(callback)
		_expect(not session._suspended and not flow.has_discard_authorization(),callback+" releases transition")
	main._video_import_dialog.hide()
	session.suspend_autosave(true)
	_edit(main,12,"in-flight")
	session.request_save()
	_edit(main,13,"later-unsaved")
	var started := Time.get_ticks_msec()
	chosen = await _choose(flow,"discard")
	_expect(Time.get_ticks_msec()-started >= 350,"discard first drains already-running writer")
	_expect(chosen,"discard allowed after writer settles")
	_expect((await main.open_source("res://sample/assignment_v1")).is_empty(),"discard-later reopen succeeds")
	_expect(main._store.get_corrected_record(12).regions[0].class == "in-flight","discard preserves already successful save")
	_expect(main._store.get_corrected_record(13).regions[0].class != "later-unsaved","discard excludes pending automatic newer revision")
	session.suspend_autosave(true)
	await session.settle_running()
	main.queue_free()
	await process_frame
	if _failures.is_empty(): print("PASS Part4 unsaved lifecycle save/discard/cancel/failure/in-flight")
	else: printerr("FAIL ",_failures)
	quit(0 if _failures.is_empty() else 1)

func _edit_later(main: Variant) -> void:
	await create_timer(0.05).timeout
	_edit(main,14,"arrived-during-close-save")

func _choose(flow: Variant,choice: String,on_saving: Callable = Callable()) -> bool:
	var finished := [false,false]
	var operation := func(): finished[1] = await flow.confirm_leave(); finished[0] = true
	operation.call()
	var submitted := false
	var deadline := Time.get_ticks_msec()+10000
	while not finished[0] and Time.get_ticks_msec()<deadline:
		if flow._leave_dialog.visible and not submitted:
			submitted = true
			match choice:
				"save":
					flow._leave_dialog.confirmed.emit()
					if on_saving.is_valid(): on_saving.call()
				"cancel": flow._leave_dialog.canceled.emit()
				"discard": flow._leave_dialog.custom_action.emit("discard")
		await process_frame
	_expect(finished[0],"lifecycle choice settles within deadline")
	return finished[1]

func _edit(main: Variant,frame: int,value: String) -> void:
	var before: Dictionary = main._store.get_corrected_record(frame)
	var after := before.duplicate(true)
	after.regions[0].class = value
	_expect(main._history.execute(preload("res://client/domain/commands/replace_frame_command.gd").new(frame,before,after),main._store).is_empty(),"committed edit")
func _expect(ok: bool,message: String) -> void:
	if not ok: _failures.append(message)
