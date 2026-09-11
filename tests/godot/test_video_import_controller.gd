extends RefCounted

const CONTROLLER_SCRIPT := preload("res://client/services/video_import_controller.gd")
const TEMP_PREFIX := "/tmp/annotool-part3-video-import-"


func run(support, tree: SceneTree) -> void:
	var root := "%s%d-%d" % [TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	var input_path := root.path_join("input-success.mkv")
	_write_text(input_path, "fixture input")
	var output_path := root.path_join("normalized")
	var controller = CONTROLLER_SCRIPT.new()
	controller.python_path = "res://.venv/bin/python"
	controller.cli_path = "res://tests/fixtures/fake_video_import.py"
	controller.job_root = root.path_join("jobs")
	tree.root.add_child(controller)
	var progress_events: Array[Dictionary] = []
	var completed_paths: Array[String] = []
	var failures: Array[String] = []
	var cancellations := [0]
	controller.progress.connect(func(payload: Dictionary) -> void: progress_events.append(payload))
	controller.completed.connect(func(path: String) -> void: completed_paths.append(path))
	controller.failed.connect(func(message: String) -> void: failures.append(message))
	controller.cancelled.connect(func() -> void: cancellations[0] += 1)

	support.expect_equal(controller.start(input_path, output_path), PackedStringArray(),
		"a valid import job should start")
	support.expect(controller.is_running(), "start should return while the child process is running")
	var heartbeat := 0
	while controller.is_running() and heartbeat < 300:
		heartbeat += 1
		await tree.create_timer(0.01).timeout
	support.expect(heartbeat > 1, "background import should leave the UI process responsive")
	support.expect(not controller.is_running(), "successful child completion should settle the job")
	support.expect_equal(completed_paths, [output_path],
		"success should publish the exact requested output path")
	support.expect(failures.is_empty() and cancellations[0] == 0,
		"success should not emit failure or cancellation")
	support.expect(DirAccess.dir_exists_absolute(output_path),
		"the fixture should publish a new output directory")
	support.expect(not progress_events.is_empty(), "atomic progress should be forwarded")
	support.expect_equal(progress_events[-1].get("state"), "completed",
		"the final progress payload should be completed")

	var cancel_input := root.path_join("input-cancel.mkv")
	_write_text(cancel_input, "cancel fixture")
	var cancel_output := root.path_join("cancelled-output")
	support.expect_equal(controller.start(cancel_input, cancel_output), PackedStringArray(),
		"a second import should start after the first settles")
	controller.cancel()
	heartbeat = 0
	while controller.is_running() and heartbeat < 300:
		heartbeat += 1
		await tree.create_timer(0.01).timeout
	support.expect_equal(cancellations[0], 1, "cooperative cancellation should emit exactly once")
	support.expect(FileAccess.file_exists(cancel_input), "cancellation must preserve the input video")
	support.expect(not DirAccess.dir_exists_absolute(cancel_output),
		"cancellation must not publish the target directory")

	var collision := root.path_join("existing")
	DirAccess.make_dir_absolute(collision)
	_write_text(collision.path_join("keep.txt"), "keep")
	support.expect(not controller.start(input_path, collision).is_empty(),
		"an existing output directory should be rejected before process creation")
	support.expect_equal(_read_text(collision.path_join("keep.txt")), "keep",
		"output collision rejection must not overwrite existing content")

	controller.python_path = root.path_join("missing-python")
	support.expect("README" in " ".join(controller.start(input_path, root.path_join("other"))),
		"missing fixed project Python should provide the README recovery hint")
	controller.queue_free()
	await tree.process_frame
	_remove_tree(root)
	support.expect(not DirAccess.dir_exists_absolute(root), "controller fixtures should be removed")


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _remove_tree(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for child_name: String in directory.get_directories():
		_remove_tree(path.path_join(child_name))
	DirAccess.remove_absolute(path)
