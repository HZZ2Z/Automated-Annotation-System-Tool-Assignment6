extends SceneTree
## Headless production adapter. IO runs on BackgroundJob; demo edits use real commands.
const WORKER = preload("res://client/cli/part4_worker.gd")
const JOB = preload("res://client/services/background_job.gd")
const SESSION = preload("res://client/workspace/workspace_session.gd")
const LABEL = preload("res://client/workspace/media_label_store.gd")
const HISTORY = preload("res://client/domain/command_history.gd")
const MOVE = preload("res://client/domain/commands/move_region_command.gd")
const RELABEL = preload("res://client/domain/commands/relabel_region_command.gd")
const ADD = preload("res://client/domain/commands/add_box_command.gd")
const DELETE = preload("res://client/domain/commands/delete_region_command.gd")
const TRACK = preload("res://client/domain/commands/set_track_id_command.gd")
const REVIEW = preload("res://client/domain/commands/review_frames_command.gd")
var worker = WORKER.new()
var job
var result_path = ""
func _initialize(): call_deferred("run")
func run():
	var args = OS.get_cmdline_user_args()
	if args.size() != 2:
		print(JSON.stringify(worker.failure("Runner expects request JSON and result path")))
		quit(2)
		return
	result_path = args[1]
	var options = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not options is Dictionary:
		finish(worker.failure("Invalid runner request"))
		return
	job = JOB.new()
	root.add_child(job)
	var result = await demo(options) if options.command == "demo" else await dispatch("execute",[options])
	finish(result)
func dispatch(method: String, args: Array) -> Dictionary:
	var errors = job.start(Callable(worker,method),args)
	if not errors.is_empty(): return worker.failure("; ".join(errors))
	return await job.finished
func demo(options: Dictionary) -> Dictionary:
	var opened = await dispatch("create_demo",[options])
	if not opened.success: return opened
	var store = opened.store
	var label = LABEL.new()
	label.adopt_session(opened)
	var session = SESSION.new()
	root.add_child(session)
	session.bind(store,label,Callable(),Callable())
	var history = HISTORY.new()
	var errors = PackedStringArray()
	for frame in [12,13]: errors.append_array(history.execute(MOVE.new(frame,store.get_corrected_record(frame),"tool1",Vector2(5,0)),store))
	errors.append_array(history.execute(RELABEL.new(24,store.get_corrected_record(24),"tool1","scissors","instrument"),store))
	errors.append_array(history.execute(ADD.new(36,store.get_corrected_record(36),[310,30,40,50],"grasper","instrument"),store))
	errors.append_array(history.execute(DELETE.new(72,store.get_corrected_record(72),"tool1"),store))
	for id in ["tool1","tool2"]: errors.append_array(history.execute(TRACK.new(90,store.get_corrected_record(90),id,"corrected-"+id),store))
	errors.append_array(history.execute(REVIEW.new([12,13,24,36,72,90],true),store))
	if not errors.is_empty():
		await session.settle_running()
		session.free()
		return worker.failure("Real demo command failed: " + "; ".join(errors))
	var revision = store.current_revision()
	var began = Time.get_ticks_msec()
	# Wait for the real 300 ms idle autosave, without forcing a save request.
	while session.saved_revision() < revision and session.status().state != "failed" and Time.get_ticks_msec()-began < 20000:
		await process_frame
	await session.settle_running()
	if session.saved_revision() != revision:
		var message = str(session.status())
		session.free()
		return worker.failure("Autosave did not persist demo revision: " + message)
	var autosave_ms = Time.get_ticks_msec()-began
	var snapshot = store.freeze_snapshot()
	var save_options = label.save_options()
	session.unbind()
	session.free()
	var result = await dispatch("finish_demo",[snapshot,save_options,options.output])
	if result.success:
		history = HISTORY.new()
		if history.can_undo() or history.can_redo(): return worker.failure("Fresh round history is not empty")
		result["new_round_history_empty"] = true
		result["autosave_ms"] = autosave_ms
		result["real_command_count"] = 8
	return result
func finish(result: Dictionary):
	var file = FileAccess.open(result_path,FileAccess.WRITE)
	if file == null:
		printerr("Cannot write CLI result")
		quit(1)
		return
	file.store_string(JSON.stringify(result,"",true,true)+"\n")
	file.close()
	quit(0 if result.get("success",false) else 1)
