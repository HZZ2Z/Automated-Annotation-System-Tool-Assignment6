extends SceneTree
const REPO := preload("res://client/workspace/session_repository.gd")
const JOB := preload("res://client/services/background_job.gd")
const LABEL := preload("res://client/workspace/media_label_store.gd")
const SESSION := preload("res://client/workspace/workspace_session.gd")
const REPLACE := preload("res://client/domain/commands/replace_frame_command.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const PACKAGE := preload("res://client/feedback/training_package.gd")

class InputProbe extends Node:
	var mutex := Mutex.new()
	var thread := Thread.new()
	var running := true
	var queue: Array[int] = []
	var latencies: Array[float] = []
	func _ready() -> void: thread.start(_produce)
	func _produce() -> void:
		while true:
			mutex.lock()
			var keep := running
			if keep: queue.append(Time.get_ticks_usec())
			mutex.unlock()
			if not keep: return
			OS.delay_msec(10)
	func _process(_delta: float) -> void:
		mutex.lock()
		var pending := queue
		queue = []
		mutex.unlock()
		for stamp: int in pending:
			var event := InputEventKey.new()
			event.pressed = true
			event.keycode = KEY_F24
			event.set_meta("issued_at",stamp)
			Input.parse_input_event(event)
	func _input(event: InputEvent) -> void:
		if event.has_meta("issued_at"):
			latencies.append((Time.get_ticks_usec()-int(event.get_meta("issued_at")))/1000.0)
	func clear() -> void:
		mutex.lock(); queue = []; mutex.unlock()
		latencies = []
	func stop() -> void:
		mutex.lock(); running = false; mutex.unlock()
		while thread.is_alive(): await get_tree().process_frame
		thread.wait_to_finish()

class Fixtures extends RefCounted:
	func build(count: int,path: String,_token: Variant) -> Dictionary:
		var records: Array = []
		var entries: Array = []
		for frame in range(count):
			var regions: Array = []
			for index in range(20): regions.append({"id":"r%d"%index,"class":"tool","kind":"instrument","box":[index*8,2,3,4],"track_id":"track%d"%index,"conf":0.75})
			records.append({"schema_version":1,"source":"clip","frame":frame,"time_s":frame/30.0,"regions":regions})
			entries.append({"frame":frame,"frame_id":frame,"time_s":frame/30.0})
		print("PHASE fixture records ready ",count)
		return REPO.new().open_session({"path":path,"media_id":"clip","media_type":"image_sequence","source":"clip","source_relative_path":"images","source_sha256":null,"baseline_kind":"model","frame_entries":entries,"seed_records":records})

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var count := 120
	var samples := 15
	var args := OS.get_cmdline_user_args()
	if not args.is_empty(): count = int(args[0])
	if args.size()>1: samples = int(args[1])
	var directory := ProjectSettings.globalize_path("res://output/part4-performance-%d-%d" % [count,Time.get_ticks_usec()])
	var fixture := Fixtures.new()
	var job = JOB.new()
	root.add_child(job)
	job.start(Callable(fixture,"build"),[count,directory.path_join("session.json")])
	var opened: Dictionary = await job.finished
	if not opened.success: fail(opened); return
	print("PHASE Store ready ",count)
	var store = opened.store
	var label = LABEL.new()
	label.adopt_session(opened)
	var session = SESSION.new()
	root.add_child(session)
	session.bind(store,label,Callable(),Callable())
	var probe := InputProbe.new()
	root.add_child(probe)
	var history = HISTORY.new(200)
	var delays: Array = []
	var snapshots: Array = []
	var save_worker_ms: Array = []
	session._job.finished.connect(func(result: Dictionary): save_worker_ms.append(result.get("elapsed_ms",-1)))
	var started := Time.get_ticks_usec()
	var errors: PackedStringArray = await session.flush_before_context_change()
	if not errors.is_empty(): await probe.stop(); fail(errors); return
	print("PHASE initial save done ",count)
	probe.clear()
	for index in range(samples):
		var before: Dictionary = store.get_corrected_record(12)
		var after := before.duplicate(true)
		after.regions[0].class = "iteration%d" % index
		history.execute(REPLACE.new(12,before,after),store)
		started = Time.get_ticks_usec()
		var snapshot: Dictionary = store.freeze_snapshot()
		snapshots.append((Time.get_ticks_usec()-started)/1000.0)
		started = Time.get_ticks_usec()
		var revision: int = snapshot.revision
		while session.saved_revision() < revision and session.status().state != "failed": await process_frame
		if session.status().state == "failed": await probe.stop(); fail(session.status()); return
		delays.append((Time.get_ticks_usec()-started)/1000.0)
	print("PHASE edit saves done ",count)
	var save_input := probe.latencies.duplicate()
	probe.clear()
	var frozen: Dictionary = store.freeze_snapshot()
	var diff_started := Time.get_ticks_usec()
	var diff_job = JOB.new()
	root.add_child(diff_job)
	var package_service = PACKAGE.new()
	diff_job.start(Callable(package_service,"preview"),[frozen,{"kind":"review_export_v1"}])
	var diff: Dictionary = await diff_job.finished
	var diff_ms := (Time.get_ticks_usec()-diff_started)/1000.0
	print("PHASE diff done ",count)
	if not diff.success: await probe.stop(); fail(diff); return
	started = Time.get_ticks_usec()
	job.start(Callable(package_service,"export_package"),[frozen,{"kind":"review_export_v1","output_parent":directory}])
	var exported: Dictionary = await job.finished
	var export_ms := (Time.get_ticks_usec()-started)/1000.0
	if not exported.success: await probe.stop(); fail(exported); return
	var export_input := probe.latencies.duplicate()
	await probe.stop()
	var result := {"success":true,"godot":Engine.get_version_info().string,"frames":count,"regions_per_frame":20,"samples":samples,"no_images_loaded":true,"input_probe":"10ms producer-thread requests delivered as InputEventKey on SceneTree; includes main-thread scheduling delay","snapshot_ms":stats(snapshots),"autosave_after_edit_ms":stats(delays),"save_worker_ms":stats(save_worker_ms),"save_input_response_ms":stats(save_input),"diff_ms":diff_ms,"export_total_ms":export_ms,"export_steps_ms":exported.get("timings_ms",{}),"export_input_response_ms":stats(export_input),"package_path":exported.output_path}
	var file := FileAccess.open(directory.path_join("results.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t",true,true)+"\n"); file.close()
	print(JSON.stringify(result,"",true,true))
	session.unbind(); session.queue_free(); probe.queue_free(); job.queue_free(); diff_job.queue_free()
	await process_frame
	quit(0)
func stats(values: Array) -> Dictionary:
	if values.is_empty(): return {"samples":0}
	values.sort()
	return {"samples":values.size(),"p50":values[int(ceil(values.size()*0.5))-1],"p95":values[int(ceil(values.size()*0.95))-1],"max":values[-1]}
func fail(value: Variant) -> void:
	printerr("FAIL ",value)
	quit(1)
