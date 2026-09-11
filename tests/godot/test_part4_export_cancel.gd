extends SceneTree

class DelayedExport extends RefCounted:
	const PACKAGE = preload("res://client/feedback/training_package.gd")
	var after_publication := false
	func export_package(snapshot: Dictionary, options: Dictionary, token: Variant) -> Dictionary:
		if after_publication:
			var result: Dictionary = PACKAGE.new().export_package(snapshot,options,token)
			token.report_progress({"stage":"published_barrier"})
			OS.delay_msec(400)
			return result
		token.report_progress({"stage":"slow_io"})
		OS.delay_msec(2000)
		return PACKAGE.new().export_package(snapshot,options,token)

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var main = load("res://client/app/main.tscn").instantiate()
	main.review_session_root = "/tmp/part4-export-cancel-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	root.add_child(main)
	await process_frame
	var errors: PackedStringArray = await main.open_source("res://sample/assignment_v1")
	if not expect(errors.is_empty(),"Source opens"): return
	main._history.execute(load("res://client/domain/commands/review_frames_command.gd").new([12],true),main._store)
	var exports = main._review_workflow.exports
	exports._directory.text = main.review_session_root.path_join("packages")
	var delayed := DelayedExport.new()
	main._feedback_plugin = delayed
	await exports.open()
	exports._attestation.button_pressed = true
	await process_frame
	var observed := {"slow":false,"published":false}
	exports._job.progress.connect(func(update: Dictionary):
		if update.get("stage") == "slow_io": observed.slow = true
		if update.get("stage") == "published_barrier": observed.published = true)
	exports.publish()
	while not observed.slow: await process_frame
	var started := Time.get_ticks_usec()
	exports.cancel()
	if not expect(not exports._dialog.visible and main._status_bar.text.contains("正在取消"),"cancel immediately updates UI"): return
	var ticks := 0
	while exports.is_busy():
		await process_frame
		ticks += 1
	if not expect(ticks > 30 and exports.last_result.get("cancelled",false) and not exports._dialog.visible,"slow I/O leaves event loop responsive and no result modal"): return
	if not expect(main._status_bar.text.contains("已取消") and not DirAccess.dir_exists_absolute(exports._directory.text),"cancel before publish leaves no package"): return
	print("CANCEL slow_io_wait_ms=",(Time.get_ticks_usec()-started)/1000.0," process_ticks=",ticks)
	delayed.after_publication = true
	await exports.open()
	exports._attestation.button_pressed = true
	await process_frame
	exports.publish()
	while not observed.published: await process_frame
	exports.cancel()
	while exports.is_busy(): await process_frame
	if not expect(exports.last_result.get("success",false) and FileAccess.file_exists(exports.last_result.output_path.path_join("manifest.json")),"late cancellation retains the already published valid package"): return
	if not expect(main._status_bar.text.contains("已保存在") and not exports._dialog.visible,"late completion is reported honestly without reopening old modal"): return
	await exports.cancel_and_drain()
	main.queue_free()
	await process_frame
	print("PASS Part 4 export cancellation and late publication")
	quit(0)
func expect(condition: bool, message: String) -> bool:
	if not condition:
		printerr("FAIL ",message)
		quit(1)
	return condition
