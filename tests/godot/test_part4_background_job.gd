extends SceneTree

var failures: Array[String] = []

class Worker extends RefCounted:
	func run(token) -> Dictionary:
		for index in range(40):
			if token.is_cancelled():
				return {"success": false, "cancelled": true}
			token.report_progress({"completed": index, "total": 40})
			OS.delay_msec(50)
		return {"success": true, "value": 42}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := "res://client/services/background_job.gd"
	if not ResourceLoader.exists(path):
		printerr("FAIL: background task runner is missing")
		quit(1)
		return
	var script = load(path)
	var job = script.new()
	root.add_child(job)
	var worker := Worker.new()
	var results: Array = []
	var progress: Array = []
	job.finished.connect(func(result): results.append(result))
	job.progress.connect(func(value): progress.append(value))
	_expect(job.start(Callable(worker, "run")).is_empty(), "a valid job starts")
	_expect(not job.start(Callable(worker, "run")).is_empty(), "a busy runner refuses a second job")
	var heartbeats := 0
	var started := Time.get_ticks_msec()
	while job.is_running() and Time.get_ticks_msec() - started < 5000:
		await create_timer(0.02).timeout
		heartbeats += 1
	_expect(not job.is_running(), "worker finishes")
	_expect(heartbeats >= 20, "two seconds of worker IO must not block the event loop")
	_expect(results.size() == 1 and results[0].get("value") == 42, "result is delivered exactly once")
	_expect(not progress.is_empty(), "worker progress is delivered on the main loop")
	_expect(job.start(Callable(worker, "run")).is_empty(), "completed runner can start a new job")
	await create_timer(0.06).timeout
	job.cancel()
	started = Time.get_ticks_msec()
	while job.is_running() and Time.get_ticks_msec() - started < 2000:
		await process_frame
	_expect(results.size() == 2 and results[1].get("cancelled", false), "cancellation is cooperative and reported")
	job.queue_free()
	await process_frame
	if failures.is_empty():
		print("PASS Part 4 background jobs (%d responsive heartbeats)" % heartbeats)
		quit(0)
	else:
		printerr("\n".join(failures))
		quit(1)

func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
