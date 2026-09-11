extends SceneTree

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/part4-export-ui-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var errors: PackedStringArray = await main.open_source("res://sample/assignment_v1")
	if not _expect(errors.is_empty(),"direct session opens"): return
	var review = load("res://client/domain/commands/review_frames_command.gd").new([12,13],true)
	main._history.execute(review,main._store)
	var exports = main._review_workflow.exports
	var output_parent: String = main.review_session_root.path_join("packages")
	exports._directory.text = output_parent
	var one_click_revision: int = main._store.current_revision()
	var one_click: Dictionary = await main.prepare_training_export()
	if not _expect(one_click.get("success",false) and one_click.get("total_frames") == 120
			and not one_click.get("auto_baseline_bound",true),
			"Main exposes the one-click summary for a known baseline"): return
	var unattested: Dictionary = await main.confirm_training_export(
		main.review_session_root.path_join("unattested"),false)
	if not _expect(not unattested.get("success",false)
			and unattested.get("error_code") == "attestation_required"
			and main._store.current_revision() == one_click_revision,
			"Main one-click entry refuses an absent attestation without mutation"): return
	await exports.open()
	if not _expect(exports._publish.disabled and exports._summary.text.contains("当前共 120 帧")
			and exports._summary.text.contains("本次将导出 120 帧"),
			"plain one-click counts and attestation gate: " + exports._summary.text): return
	exports._attestation.button_pressed = true
	await process_frame
	if not _expect(not exports._publish.disabled, "attestation enables the one-click action"): return
	var cli_snapshot: String = main.review_session_root.path_join("frozen_for_cli.json")
	if not _expect(DirAccess.copy_absolute(main._workspace_label_store.label_path(),cli_snapshot)==OK,"preserve the same saved snapshot for independent CLI comparison"): return
	print("CLI_SNAPSHOT "+cli_snapshot)
	exports.publish()
	var ticks := 0
	while exports.is_busy() and ticks < 4000:
		await process_frame
		ticks += 1
	if not _expect(exports.last_result.get("success",false),"export succeeds: " + str(exports.last_result)): return
	if not _expect(exports.last_result.revision == main._store.current_revision()
			and not main._workspace_session.has_unsaved_changes(),
			"the attested review revision is saved before publication"): return
	if not _expect(main._store.is_verified(12) and main._store.is_verified(14),
			"one confirmation reviews the written non-empty frames"): return
	if not _expect(FileAccess.file_exists(exports.last_result.output_path.path_join("manifest.json")),
			"the one-click path publishes a validated package"): return
	print("PACKAGE " + exports.last_result.output_path)
	exports.cancel()
	exports._directory.text = "/tmp/not-the-remembered-parent"
	await exports.open()
	if not _expect(exports._directory.text == output_parent,
			"the last successful output parent is restored on reopen"): return
	await exports.cancel_and_drain()
	main.queue_free()
	await process_frame
	print("PASS Part 4 one-click export UI and remembered destination")
	quit(0)

func _expect(condition: bool,message: String) -> bool:
	if not condition:
		print("FAIL: " + message)
		quit(1)
	return condition
