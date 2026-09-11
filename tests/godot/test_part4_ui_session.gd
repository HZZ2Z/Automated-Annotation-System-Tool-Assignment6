extends SceneTree

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/part4-ui-session-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var errors: PackedStringArray = await main.open_source("res://sample/assignment_v1")
	if not _expect(errors.is_empty(),"open direct source: " + str(errors)): return
	var store = main._store
	var baseline: Variant = store.freeze_snapshot().baseline_digest
	var before: Dictionary = store.get_corrected_record(12)
	var after := before.duplicate(true)
	after.regions[0].class = "part4-changed"
	var command = load("res://client/domain/commands/replace_frame_command.gd").new(12,before,after)
	if not _expect(main._history.execute(command,store).is_empty(),"edit through command history"): return
	if not _expect(not main.get_node("MainVBox/TopToolbar/Save").disabled,"Save is enabled for direct sources"): return
	main.get_node("MainVBox/TopToolbar/Save").pressed.emit()
	errors = await main._flush_workspace_changes()
	if not _expect(errors.is_empty() and not main._workspace_session.has_unsaved_changes(),"button saves committed revision: " + str(errors)): return
	errors = await main.open_source("res://sample/assignment_v1")
	if not _expect(errors.is_empty(),"reopen: " + str(errors)): return
	if not _expect(main._store.freeze_snapshot().baseline_digest == baseline and main._store.get_corrected_record(12).regions[0].class == "part4-changed","reopen separates model baseline and correction"): return
	if not _expect(main._batch_workflow.available(),"direct source now persists review and supports batch"): return
	await main._flush_workspace_changes()
	main.queue_free()
	await process_frame
	print("PASS Part 4 direct Source UI persistence")
	quit(0)

func _expect(condition: bool,message: String) -> bool:
	if not condition:
		print("FAIL: " + message)
		quit(1)
	return condition
