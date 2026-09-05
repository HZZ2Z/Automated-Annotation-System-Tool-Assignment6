extends RefCounted

const SESSION_PATH := "res://client/workspace/workspace_session.gd"
const LABEL_STORE_SCRIPT := preload("res://client/workspace/media_label_store.gd")
const ANNOTATION_STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const TEMP_PREFIX := "/tmp/annotool-workspace-session-"


func run(support, tree: SceneTree) -> void:
	var script := ResourceLoader.load(SESSION_PATH, "Script") as Script
	support.expect(script != null,
		"WorkspaceSession should debounce validated store changes into one media JSON")
	if script == null:
		return
	var root := _new_temp_root()
	var label_store = LABEL_STORE_SCRIPT.new()
	var entries: Array = [
		{"frame": 0, "frame_id": 0, "time_s": 0.0, "image_path": "000000.png"},
		{"frame": 1, "frame_id": 1, "time_s": 1.0, "image_path": "000001.png"},
	]
	var media := {
		"display_name": "clip",
		"media_id": "clip",
		"media_type": "image_sequence",
		"source_path": root.path_join("clip"),
		"relative_path": "clip",
		"source_sha256": null,
	}
	support.expect_equal(label_store.prepare(root, media, entries), PackedStringArray(),
		"session fixture label store should prepare")
	var store = ANNOTATION_STORE_SCRIPT.new()
	support.expect_equal(store.load_model_records(label_store.all_display_records()), PackedStringArray(),
		"session fixture annotation store should load")
	var session = script.new()
	tree.root.add_child(session)
	var pause_count := [0]
	var messages: Array[String] = []
	var save_count := [0]
	label_store.saved.connect(func(_path: String) -> void: save_count[0] += 1)
	session.bind(
		store,
		label_store,
		func() -> void: pause_count[0] += 1,
		func(message: String) -> void: messages.append(message))

	var first: Dictionary = store.get_corrected_record(0)
	first["regions"] = [{
		"id": "r0", "class": "grasper", "kind": "instrument",
		"box": [1.0, 1.0, 2.0, 2.0], "conf": 1.0, "track_id": null,
	}]
	var second: Dictionary = store.get_corrected_record(1)
	second["regions"] = [{
		"id": "r1", "class": "hook", "kind": "instrument",
		"box": [2.0, 2.0, 2.0, 2.0], "conf": 1.0, "track_id": null,
	}]
	store.replace_corrected_record(0, first)
	store.replace_corrected_record(1, second)
	support.expect(not FileAccess.file_exists(root.path_join("label/clip.json")),
		"closely spaced edits should wait for the debounce boundary")
	await tree.create_timer(0.35).timeout
	support.expect_equal(save_count[0], 1,
		"closely spaced committed edits should coalesce into one atomic save")
	var payload: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(root.path_join("label/clip.json"))) as Dictionary
	support.expect(payload.get("frames", {}).has("0")
		and payload.get("frames", {}).has("1"),
		"debounced media JSON should contain every changed original frame")

	first["regions"][0]["class"] = "relabelled"
	store.replace_corrected_record(0, first)
	support.expect_equal(session.flush_before_context_change(), PackedStringArray(),
		"context change should synchronously flush pending edits")
	support.expect_equal(save_count[0], 2,
		"forced flush should publish without waiting for the timer")
	support.expect(session.can_replace_context(),
		"successful flush should allow media replacement")
	support.expect_equal(pause_count[0], 0,
		"successful automatic saves should not pause playback")
	support.expect(messages.is_empty(),
		"successful automatic saves should not emit failure status")

	session.unbind()
	session.queue_free()
	await tree.process_frame
	_remove_tree(root)


func _new_temp_root() -> String:
	var root := "%s%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	return root


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
