extends SceneTree
const PACKAGE := preload("res://client/feedback/training_package.gd")
var failures: Array[String] = []
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if "--capture" in OS.get_cmdline_user_args(): root.size = Vector2i(1440,900)
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/part4-round-ui-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	if not main.has_method("stage_review_replacement"):
		printerr("FAIL: missing safe round UI staging")
		quit(1); return
	var open_errors = await main.open_source("res://sample/assignment_v1")
	check(open_errors.is_empty(),"open persistent source: " + str(open_errors))
	if not open_errors.is_empty():
		await finish_failed(main); return
	main._history.execute(preload("res://client/domain/commands/review_frames_command.gd").new([12],true),main._store)
	await main._flush_workspace_changes()
	main.seek(12)
	var old_store = main._store
	var old_history = main._history
	var old_frame: int = main.get_current_frame()
	var path: String = main._workspace_label_store.label_path()
	var old_bytes := FileAccess.get_file_as_bytes(path)
	var snapshot: Dictionary = main._store.freeze_snapshot()
	var parent: Dictionary = await main.export_package(main.review_session_root)
	check(parent.success,"parent export: " + str(parent.get("errors",[])))
	if not parent.success:
		await finish_failed(main); return
	var input: String = main.review_session_root.path_join("round.json")
	var annotations: String = main.review_session_root.path_join("model_output_v1.jsonl")
	var records: Array = snapshot.baseline_records.duplicate(true)
	records[12].regions[0].class = "new-round-class"
	PACKAGE.write_text(annotations,PACKAGE.jsonl(records))
	var manifest := {"schema_version":1,"package_type":"model_round_v1","annotation_schema_version":1,"round_id":"round2","model_revision":"m2","parent_package_id":parent.package_id,"taxonomy_version":snapshot.taxonomy_version,"media":{},"source_frame_entries":snapshot.frame_entries,"annotations":{"path":"model_output_v1.jsonl","bytes":FileAccess.get_file_as_bytes(annotations).size(),"sha256":FileAccess.get_sha256(annotations)}}
	for field: String in ["media_id","media_type","source","source_relative_path","source_sha256"]: manifest.media[field] = snapshot[field]
	PACKAGE.write_text(input,JSON.stringify(manifest,"",true,true))
	var flow = main._review_workflow.rounds
	flow.open()
	flow._input.text = input
	await flow.prepare()
	check(not flow._prepared.is_empty() and not flow._commit.disabled,"UI preview validates candidate: " + flow._details.text)
	if flow._prepared.is_empty():
		await finish_failed(main); return
	if "--capture" in OS.get_cmdline_user_args():
		await process_frame
		await RenderingServer.frame_post_draw
		var capture := ProjectSettings.globalize_path("res://output/part4-ui-round-%d.png" % Time.get_ticks_usec())
		flow._dialog.get_texture().get_image().save_png(capture)
		print("UI_CAPTURE ",capture)
	check(main._store == old_store and main._history == old_history and FileAccess.get_file_as_bytes(path)==old_bytes,"preview retains active memory and disk")
	PACKAGE.write_text(annotations,PACKAGE.jsonl(records)+"\n")
	await flow.commit()
	check(not flow.last_result.get("success",false),"changed candidate fails at commit")
	check(main._store == old_store and main.get_current_frame()==old_frame and main._history == old_history and FileAccess.get_file_as_bytes(path)==old_bytes,"failed import preserves old UI and disk")
	PACKAGE.write_text(annotations,PACKAGE.jsonl(records))
	await flow.prepare()
	await flow.commit()
	check(flow.last_result.get("success",false),"valid UI round switch commits: " + str(flow.last_result))
	if not flow.last_result.get("success",false):
		await finish_failed(main); return
	check(main._store != old_store and main._store.freeze_snapshot().round_id == "round2","new independent Store activated")
	check(main._store.get_corrected_record(12).regions[0].class == "new-round-class","new model predictions become current correction initial value")
	check(main._store.snapshot_review_state().is_empty() and main._store.snapshot_batch_operations().is_empty() and not main._history.can_undo(),"new round resets review/batch/history")
	check(FileAccess.get_file_as_bytes(flow.last_result.archive_path)==old_bytes,"UI import exact archive")
	check(not main._workspace_session.has_unsaved_changes(),"adopted round is saved")
	flow.cancel()
	main._workspace_session.suspend_autosave(true)
	await main._workspace_session.settle_running()
	main.queue_free()
	await process_frame
	if failures.is_empty(): print("PASS Part4 model round UI preview/failure/commit/archive")
	else: printerr("FAIL ",failures)
	quit(0 if failures.is_empty() else 1)
func check(value: bool,message: String) -> void:
	if not value: failures.append(message)

func finish_failed(main) -> void:
	await main._review_workflow.rounds.cancel_and_drain()
	await main._workspace_session.settle_running()
	main.queue_free()
	await process_frame
	printerr("FAIL ",failures)
	quit(1)
