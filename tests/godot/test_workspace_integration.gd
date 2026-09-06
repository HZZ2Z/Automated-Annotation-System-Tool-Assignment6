extends RefCounted

const MAIN_SCENE := preload("res://client/app/main.tscn")
const TEMP_PREFIX := "/tmp/annotool-workspace-integration-"


func run(support, tree: SceneTree) -> void:
	await _test_nested_native_label_root_is_restored(support, tree)
	await _test_nested_source_label_seeds_native_root(support, tree)
	await _test_restore_autosave_and_playback(support, tree)
	await _test_corrupt_label_and_failed_save_preserve_media(support, tree)


func _test_nested_native_label_root_is_restored(
	support,
	tree: SceneTree
) -> void:
	var outer_root := _new_temp_root()
	var dataset_root := outer_root.path_join("cholect50-challenge-val")
	var sequence_path := dataset_root.path_join("videos/VID68")
	DirAccess.make_dir_recursive_absolute(sequence_path)
	_save_image(sequence_path.path_join("000016.png"), Color.RED)
	_save_image(sequence_path.path_join("000023.png"), Color.BLUE)
	DirAccess.make_dir_recursive_absolute(dataset_root.path_join("label"))
	var native_label_path := dataset_root.path_join("label/VID68.json")
	_write_json(native_label_path, _native_media_label("VID68"))
	var native_label_before := FileAccess.get_file_as_string(native_label_path)

	var main = await _mounted_main(tree)
	support.expect_equal(main.open_workspace(outer_root), PackedStringArray(),
		"outer workspace should discover media inside a nested dataset root")
	main.call("_on_workspace_media_requested", "VID68")
	var store = main.get("_store")
	var restored: Dictionary = store.get_corrected_record(16)
	var regions: Array = restored.get("regions", [])
	support.expect_equal(regions.size(), 1,
		"nested native label should be restored when an outer folder is opened")
	if not regions.is_empty():
		support.expect_equal(regions[0].get("class"), "nested-grasper",
			"nested native label content should reach the annotation store")
	var viewport = main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	support.expect_equal(viewport.get("_record").get("regions", []).size(), 1,
		"nested native label should be visible on the selected frame")
	support.expect_equal(main.get("_workspace_label_store").label_path(), native_label_path,
		"automatic reads and writes should remain under the nested dataset label root")
	support.expect(not FileAccess.file_exists(outer_root.path_join("label/VID68.json")),
		"opening an outer catalog folder must not create a duplicate outer label")
	var playback_speed = main.get_node("MainVBox/TopToolbar/PlaybackSpeed")
	support.expect_equal(playback_speed.call("get_selected_mode"), &"one_second",
		"sparse workspace sequences should default to one second per frame")
	var fps_label := main.get_node_or_null(
		"MainVBox/TimelinePanel/TimelineColumn/Transport/FpsLabel") as Label
	var frame_label := main.get_node_or_null(
		"MainVBox/TimelinePanel/TimelineColumn/Transport/FrameLabel") as Label
	support.expect(fps_label != null and fps_label.text == "FPS 0",
		"a paused workspace sequence should report zero actual playback FPS")
	support.expect(frame_label != null
		and frame_label.text == "Frame 16 (1 / 2)  ·  Time 00:00:16.000",
		"a sparse sequence should display its original frame ID and source timestamp")
	support.expect(playback_speed.call("select_mode", &"three_seconds", 5.0, true),
		"the top speed bar should accept its three-second stop")
	support.expect_equal(
		str(main.get_node("MainVBox/StatusBar").text), "Playback: 3 s/frame",
		"changing speed should report the selected seconds-per-frame clock")
	var records_before_fps: Array = store.snapshot_corrected()
	var dirty_before_fps: PackedInt64Array = store.get_dirty_frames()
	support.expect(main.seek(0), "nested native playback should seek to its first source frame")
	main.play()
	main.call("_process", 2.999)
	support.expect_equal(main.get_current_frame(), 0,
		"three-second review should wait for its complete configured interval")
	main.call("_process", 0.001)
	support.expect_equal(main.get_current_frame(), 1,
		"three-second review should advance the sparse sequence by ordered playback index")
	support.expect_equal(viewport.get("_record").get("frame"), 23,
		"nested native playback should commit the next original frame ID")
	support.expect_equal(viewport.get("_record").get("regions", []).size(), 1,
		"nested native annotations should remain visible during continuous playback")
	support.expect_equal(
		frame_label.text,
		"Frame 23 (2 / 2)  ·  Time 00:00:23.000",
		"playback should update explicit time from the committed sparse frame entry")
	support.expect_equal(store.snapshot_corrected(), records_before_fps,
		"reading and displaying FPS must not modify annotation records")
	support.expect_equal(store.get_dirty_frames(), dirty_before_fps,
		"reading and displaying FPS must not dirty annotation records")
	support.expect_equal(FileAccess.get_file_as_string(native_label_path), native_label_before,
		"reading and displaying FPS must not rewrite the native label file")
	await _free_main(main, tree)
	_remove_tree(outer_root)


func _test_nested_source_label_seeds_native_root(
	support,
	tree: SceneTree
) -> void:
	var outer_root := _new_temp_root()
	var dataset_root := outer_root.path_join("cholect50-challenge-val")
	var sequence_path := dataset_root.path_join("videos/VID70")
	DirAccess.make_dir_recursive_absolute(sequence_path)
	_save_image(sequence_path.path_join("000016.png"), Color.RED)
	_save_image(sequence_path.path_join("000023.png"), Color.BLUE)
	DirAccess.make_dir_recursive_absolute(dataset_root.path_join("labels"))
	var source_label_path := dataset_root.path_join("labels/VID70.json")
	_write_json(source_label_path, _cholect50_label())
	var source_label_before := FileAccess.get_file_as_string(source_label_path)

	var main = await _mounted_main(tree)
	support.expect_equal(main.open_workspace(outer_root), PackedStringArray(),
		"outer workspace should discover a nested source-labelled sequence")
	main.call("_on_workspace_media_requested", "VID70")
	var native_label_path := dataset_root.path_join("label/VID70.json")
	support.expect(FileAccess.file_exists(native_label_path),
		"nested source label import should create native output beside that dataset")
	support.expect_equal(main.get("_workspace_label_store").label_path(), native_label_path,
		"nested source label import should bind future automatic writes to its dataset root")
	var restored: Dictionary = main.get("_store").get_corrected_record(16)
	support.expect_equal(restored.get("regions", []).size(), 1,
		"nested CholecT50 source label should seed visible annotations")
	support.expect_equal(FileAccess.get_file_as_string(source_label_path), source_label_before,
		"nested source label must remain byte-for-byte unchanged")
	support.expect(not FileAccess.file_exists(outer_root.path_join("label/VID70.json")),
		"nested import must not create a duplicate label in the opened outer folder")
	await _free_main(main, tree)
	_remove_tree(outer_root)


func _test_restore_autosave_and_playback(support, tree: SceneTree) -> void:
	var root := _new_temp_root()
	var sequence_path := root.path_join("videos/VID68")
	DirAccess.make_dir_recursive_absolute(sequence_path)
	_save_image(sequence_path.path_join("000016.png"), Color.RED)
	_save_image(sequence_path.path_join("000023.png"), Color.BLUE)
	DirAccess.make_dir_recursive_absolute(root.path_join("labels"))
	var source_label_path := root.path_join("labels/VID68.json")
	_write_json(source_label_path, _cholect50_label())
	var source_label_before := FileAccess.get_file_as_string(source_label_path)

	var main = await _mounted_main(tree)
	support.expect_equal(main.open_workspace(root), PackedStringArray(),
		"workspace directory should open without parsing a media item")
	support.expect_equal(main.get_current_frame(), -1,
		"opening a workspace alone should not select or decode media")
	var explorer = main.get_node(
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer")
	support.expect_equal(explorer.get("_mode"), &"workspace",
		"opened workspace should remain visible as a media tree")
	support.expect(not DirAccess.dir_exists_absolute(root.path_join("label")),
		"workspace discovery should not create label output")

	main.call("_on_workspace_media_requested", "VID68")
	support.expect_equal(main.get_current_frame(), 0,
		"selected sparse sequence should open at playback index zero")
	var source = main.get("_source")
	support.expect_equal(source.get_frame_entry(0).get("frame_id"), 16,
		"first playback entry should retain original frame ID 16")
	var store = main.get("_store")
	support.expect_equal(
		store.get_corrected_record(16).get("regions", [])[0].get("class"),
		"grasper",
		"compatible read-only dataset label should seed the native media label")
	var viewport = main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport")
	support.expect_equal(viewport.get("_record").get("frame"), 16,
		"image and annotation should commit together using the original frame ID")
	var native_label_path := root.path_join("label/VID68.json")
	support.expect(FileAccess.file_exists(native_label_path),
		"first compatible source-label import should create one native media JSON")
	support.expect_equal(FileAccess.get_file_as_string(source_label_path), source_label_before,
		"source dataset label must remain byte-for-byte unchanged")

	var edited: Dictionary = store.get_corrected_record(16)
	edited["regions"][0]["class"] = "edited-grasper"
	support.expect_equal(store.replace_corrected_record(16, edited), PackedStringArray(),
		"workspace annotation edit should commit against original frame ID")
	await tree.create_timer(0.35).timeout
	var saved: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(native_label_path)) as Dictionary
	support.expect_equal(
		saved.get("frames", {}).get("16", {}).get("regions", [])[0].get("class"),
		"edited-grasper",
		"committed edit should automatically replace the single media JSON")

	var playback_speed = main.get_node("MainVBox/TopToolbar/PlaybackSpeed")
	support.expect(playback_speed.call("select_mode", &"custom", 2.5, true),
		"reviewers should be able to request an exact custom seconds-per-frame clock")
	var fps_label := main.get_node_or_null(
		"MainVBox/TimelinePanel/TimelineColumn/Transport/FpsLabel") as Label
	support.expect(fps_label != null and fps_label.text == "FPS 0",
		"changing the clock while paused should not invent measured FPS")
	var records_before_fps: Array = store.snapshot_corrected()
	var dirty_before_fps: PackedInt64Array = store.get_dirty_frames()
	var native_label_before_fps := FileAccess.get_file_as_string(native_label_path)
	var manifest_before_fps: Dictionary = main.get("_manifest").duplicate(true)
	var source_entries_before_fps: Array[Dictionary] = [
		source.get_frame_entry(0).duplicate(true),
		source.get_frame_entry(1).duplicate(true),
	]
	support.expect(main.seek(0), "playback should seek to the first sparse entry")
	main.play()
	main.call("_process", 2.499)
	support.expect_equal(main.get_current_frame(), 0,
		"custom playback should wait for the exact requested seconds per frame")
	main.call("_process", 0.001)
	support.expect_equal(main.get_current_frame(), 1,
		"custom playback should advance after the complete requested interval")
	support.expect_equal(viewport.get("_record").get("frame"), 23,
		"advanced playback should display frame 23 annotation with frame 23 image")
	support.expect_equal(store.snapshot_corrected(), records_before_fps,
		"source FPS display must not modify corrected annotation records")
	support.expect_equal(store.get_dirty_frames(), dirty_before_fps,
		"source FPS display must not alter dirty-frame state")
	support.expect_equal(FileAccess.get_file_as_string(native_label_path), native_label_before_fps,
		"actual FPS display must not rewrite the persisted native label")
	support.expect_equal(main.get("_manifest"), manifest_before_fps,
		"speed, time and FPS presentation must not mutate the in-memory manifest")
	support.expect_equal([
		source.get_frame_entry(0),
		source.get_frame_entry(1),
	], source_entries_before_fps,
		"custom playback must not rewrite any committed source-frame metadata")
	await _free_main(main, tree)

	var reopened = await _mounted_main(tree)
	support.expect_equal(reopened.open_workspace(root), PackedStringArray(),
		"saved workspace should reopen")
	reopened.call("_on_workspace_media_requested", "VID68")
	var reopened_store = reopened.get("_store")
	support.expect_equal(
		reopened_store.get_corrected_record(16).get("regions", [])[0].get("class"),
		"edited-grasper",
		"existing native media JSON should load before the source dataset label")
	support.expect_equal(FileAccess.get_file_as_string(source_label_path), source_label_before,
		"reopening native labels must not modify source dataset labels")
	await _free_main(reopened, tree)
	_remove_tree(root)


func _test_corrupt_label_and_failed_save_preserve_media(
	support,
	tree: SceneTree
) -> void:
	var root := _new_temp_root()
	for media_id_value: String in ["VID68", "VID70"]:
		var sequence := root.path_join("videos").path_join(media_id_value)
		DirAccess.make_dir_recursive_absolute(sequence)
		_save_image(sequence.path_join("000016.png"), Color.RED)
		_save_image(sequence.path_join("000023.png"), Color.BLUE)
	DirAccess.make_dir_recursive_absolute(root.path_join("label"))
	var corrupt_path := root.path_join("label/VID70.json")
	var corrupt_text := "{corrupt native label"
	var corrupt_file := FileAccess.open(corrupt_path, FileAccess.WRITE)
	if corrupt_file != null:
		corrupt_file.store_string(corrupt_text)
	corrupt_file = null

	var main = await _mounted_main(tree)
	support.expect_equal(main.open_workspace(root), PackedStringArray(),
		"failure fixture workspace should open")
	main.call("_on_workspace_media_requested", "VID68")
	var accepted_source = main.get("_source")
	var accepted_viewport_record: Dictionary = main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport"
	).get("_record").duplicate(true)
	main.call("_on_workspace_media_requested", "VID70")
	support.expect(main.get("_source") == accepted_source,
		"corrupt candidate native label should preserve accepted source")
	support.expect_equal(main.get("_workspace_media_id"), "VID68",
		"corrupt candidate native label should preserve selected media")
	support.expect_equal(main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport"
	).get("_record"), accepted_viewport_record,
		"corrupt candidate native label should preserve accepted annotation")
	support.expect_equal(FileAccess.get_file_as_string(corrupt_path), corrupt_text,
		"corrupt native label should never be overwritten with blanks")

	DirAccess.remove_absolute(corrupt_path)
	DirAccess.remove_absolute(root.path_join("label"))
	var blocker := FileAccess.open(root.path_join("label"), FileAccess.WRITE)
	if blocker != null:
		blocker.store_string("blocks automatic label directory")
	blocker = null
	var active_store = main.get("_store")
	var pending: Dictionary = active_store.get_corrected_record(16)
	pending["regions"] = []
	support.expect_equal(
		active_store.replace_corrected_record(16, pending), PackedStringArray(),
		"failure fixture should retain one valid pending edit")
	main.call("_on_workspace_media_requested", "VID70")
	support.expect(main.get("_source") == accepted_source,
		"failed forced save should block media replacement")
	support.expect_equal(main.get("_workspace_media_id"), "VID68",
		"failed forced save should keep the prior media identity")
	support.expect(main.get("_workspace_label_store").has_pending_changes(),
		"failed forced save should keep the in-memory edit pending")
	support.expect(not main.get("_workspace_session").can_replace_context(),
		"failed automatic save should close the context replacement gate")
	await _free_main(main, tree)
	_remove_tree(root)


func _mounted_main(tree: SceneTree):
	var main = MAIN_SCENE.instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	return main


func _free_main(main: Node, tree: SceneTree) -> void:
	main.queue_free()
	await tree.process_frame


func _cholect50_label() -> Dictionary:
	return {
		"fps": 1.0,
		"categories": {
			"instrument": {"0": "grasper"},
		},
		"annotations": {
			"16": [[0, 0, 0, 0.1, 0.1, 0.2, 0.2, 0]],
			"23": [],
		},
	}


func _native_media_label(media_id_value: String) -> Dictionary:
	return {
		"schema_version": 1,
		"media_id": media_id_value,
		"media_type": "image_sequence",
		"source_relative_path": "videos/%s" % media_id_value,
		"source_sha256": null,
		"frame_digits": 6,
		"frames": {
			"16": {
				"schema_version": 1,
				"source": media_id_value,
				"frame": 16,
				"time_s": 16.0,
				"regions": [{
					"id": "nested-16",
					"class": "nested-grasper",
					"kind": "instrument",
					"box": [1.0, 1.0, 4.0, 3.0],
					"conf": 1.0,
					"track_id": null,
				}],
			},
			"23": {
				"schema_version": 1,
				"source": media_id_value,
				"frame": 23,
				"time_s": 23.0,
				"regions": [{
					"id": "nested-23",
					"class": "nested-scissors",
					"kind": "instrument",
					"box": [2.0, 1.0, 3.0, 3.0],
					"conf": 1.0,
					"track_id": null,
				}],
			},
		},
	}


func _new_temp_root() -> String:
	var root := "%s%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _save_image(path: String, color: Color) -> void:
	var image := Image.create(12, 8, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.save_png(path)


func _write_json(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(value, "  ", false) + "\n")


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
