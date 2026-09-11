extends RefCounted

const MAIN_SCENE := preload("res://client/app/main.tscn")
const TEMP_PREFIX := "/tmp/annotool-workspace-integration-"


class SlowDiscoveryFactory extends RefCounted:
	func discover_workspace_media(
		root: String,
		_preferred_id: String,
		token: Variant,
	) -> Dictionary:
		for _index in range(60):
			if token != null and token.is_cancelled():
				return {"claimed": true, "plugin_id": "slow_source", "media": [],
					"errors": PackedStringArray(["Workspace scan cancelled"])}
			OS.delay_msec(10)
		return {
			"claimed": true,
			"plugin_id": "slow_source",
			"media": [{
				"display_name": "frame.png", "media_id": "slow_frame",
				"media_type": "image", "source_path": root.path_join("frame.png"),
				"relative_path": "frame.png", "source_plugin_id": "slow_source",
			}],
			"errors": PackedStringArray(),
		}

	func resolve_plugin_id(_locator: String, _preferred_id: String = "") -> String:
		return ""


func run(support, tree: SceneTree) -> void:
	await _test_workspace_scan_is_background_and_cancellable(support, tree)
	await _test_endoscapes_main_lazy_round_trip(support, tree)
	await _test_nested_native_label_root_is_restored(support, tree)
	await _test_nested_source_label_seeds_native_root(support, tree)
	await _test_restore_autosave_and_playback(support, tree)
	await _test_corrupt_label_and_failed_save_preserve_media(support, tree)


func _test_workspace_scan_is_background_and_cancellable(
	support,
	tree: SceneTree,
) -> void:
	var root := _new_temp_root()
	_save_image(root.path_join("frame.png"), Color.WHITE)
	var main = await _mounted_main(tree)
	main.set("_source_factory", SlowDiscoveryFactory.new())
	var scan_button := main.get_node_or_null(
		"MainVBox/TopToolbar/CancelWorkspaceScan") as Button
	support.expect(main.get("_workspace_catalog_controller") != null,
		"Main should mount one WorkspaceCatalogController")
	support.expect(scan_button != null,
		"the toolbar should expose an explicit workspace-scan cancel button")
	var result_box: Array[PackedStringArray] = []
	var finished := [false]
	var launch := func() -> void:
		result_box.append(await main.open_workspace(root))
		finished[0] = true
	var started := Time.get_ticks_msec()
	launch.call()
	var dispatch_elapsed := Time.get_ticks_msec() - started
	support.expect(dispatch_elapsed < 100,
		"workspace scan dispatch should return control before slow discovery completes")
	var heartbeats := 0
	while heartbeats < 5 and not finished[0]:
		await tree.process_frame
		heartbeats += 1
	support.expect(heartbeats == 5 and not finished[0],
		"Main UI should keep processing frames during workspace discovery")
	if scan_button != null:
		support.expect(scan_button.visible,
			"workspace scan cancel should be visible only while discovery is active")
		scan_button.pressed.emit()
	var wait_ticks := 0
	while not finished[0] and wait_ticks < 300:
		await tree.create_timer(0.01).timeout
		wait_ticks += 1
	support.expect(finished[0] and not result_box.is_empty()
		and not result_box[0].is_empty(),
		"cancelled workspace open should settle with an explicit error result")
	support.expect_equal(main.get("_workspace_root"), "",
		"cancelled discovery must preserve the previously active workspace")
	if scan_button != null:
		support.expect(not scan_button.visible,
			"workspace scan cancel should hide after cancellation drains")
	await _free_main(main, tree)
	_remove_tree(root)


func _test_endoscapes_main_lazy_round_trip(support, tree: SceneTree) -> void:
	var root := _new_endoscapes_fixture()
	var main = await _mounted_main(tree)
	support.expect_equal(await main.open_workspace(root), PackedStringArray(),
		"Main should open a synthetic Endoscapes root through background discovery")
	var explorer = main.get_node(
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer")
	support.expect_equal(explorer.get("_mode"), &"workspace",
		"Endoscapes discovery should remain a navigable workspace tree")
	support.expect_equal(explorer.get("_media_items").size(), 2,
		"only logical videos, never individual frames or semseg masks, should be listed")
	support.expect_equal(explorer.get("_frame_items").size(), 0,
		"inactive Endoscapes videos must not materialize frame nodes")

	await _select_media(main, "endoscapes_train_video_001", tree)
	var first_source = main.get("_source")
	var first_store = main.get("_store")
	support.expect(first_source != null,
		"Endoscapes video 1 should activate: %s" % str(
			main.get_node("MainVBox/StatusBar").text))
	if first_source == null:
		await _free_main(main, tree)
		_remove_tree(root)
		return
	support.expect_equal(first_source.get_frame_count(), 2,
		"selecting video 1 should retain only its two source frames")
	support.expect_equal([
		first_source.get_frame_entry(0).get("frame_id"),
		first_source.get_frame_entry(1).get("frame_id"),
	], [25, 50], "Main playback should preserve sparse Endoscapes frame IDs")
	support.expect_equal(first_store.freeze_snapshot().get("baseline_kind"),
		"imported_labels",
		"official COCO records should be recorded as imported labels, not model output")
	support.expect_equal(first_store.get_corrected_record(25).get("regions", []).size(), 2,
		"official COCO regions should seed the selected video's Store")
	support.expect_equal(explorer.get("_mode"), &"workspace",
		"showing current frames must not replace the selectable video tree")
	support.expect_equal(explorer.get("_frame_items").size(), 2,
		"only the selected video's frame nodes should be materialized")
	var status := str(main.get_node("MainVBox/StatusBar").text)
	support.expect(status.length() <= 180 and "2 frames" in status
		and "2 regions" in status and "0 mask" in status and "0 skipped" in status,
		"one bounded status should summarize frame count and label conversion counters")

	var edited: Dictionary = first_store.get_corrected_record(25)
	edited["regions"][0]["class"] = "edited_cystic_plate"
	support.expect_equal(first_store.replace_corrected_record(25, edited), PackedStringArray(),
		"the synthetic Endoscapes edit should commit against original frame ID 25")
	await main._flush_workspace_changes()
	support.expect(FileAccess.file_exists(root.path_join(
		"label/endoscapes_train_video_001.json")),
		"Endoscapes edits should save to a native Project6 label outside source splits")

	await _select_media(main, "endoscapes_train_video_002", tree)
	support.expect_equal(first_source.get_frame_count(), 0,
		"switching videos should close and release the previous Source frame table")
	support.expect_equal(first_source.get_cache_size(), 0,
		"switching videos should release the previous Source texture cache")
	support.expect_equal(explorer.get("_frame_items").size(), 1,
		"the active-frame branch should replace, not accumulate across videos")
	await _select_media(main, "endoscapes_train_video_001", tree)
	support.expect_equal(main.get("_store").get_corrected_record(25).get(
		"regions", [])[0].get("class"), "edited_cystic_plate",
		"saved Project6 labels should override official COCO when a video reopens")
	await _free_main(main, tree)
	_remove_tree(root)


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
	support.expect_equal(await main.open_workspace(outer_root), PackedStringArray(),
		"outer workspace should discover media inside a nested dataset root")
	await _select_media(main,"VID68",tree)
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
	support.expect_equal(await main.open_workspace(outer_root), PackedStringArray(),
		"outer workspace should discover a nested source-labelled sequence")
	await _select_media(main,"VID70",tree)
	await main._flush_workspace_changes()
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
	support.expect_equal(await main.open_workspace(root), PackedStringArray(),
		"workspace directory should open without parsing a media item")
	support.expect_equal(main.get_current_frame(), -1,
		"opening a workspace alone should not select or decode media")
	var explorer = main.get_node(
		"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer")
	support.expect_equal(explorer.get("_mode"), &"workspace",
		"opened workspace should remain visible as a media tree")
	support.expect(not DirAccess.dir_exists_absolute(root.path_join("label")),
		"workspace discovery should not create label output")

	await _select_media(main,"VID68",tree)
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
	await main._flush_workspace_changes()
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
	await main._flush_workspace_changes()
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
	var export_result: Dictionary = await main.export_package(root.path_join("review_packages"),"review_export_v1")
	support.expect(export_result.get("success",false),
		"workspace review export should accept sparse original frame ids: " + str(export_result.get("errors",[])))
	var export_path: String = export_result.get("output_path","")
	support.expect_equal(_read_jsonl_frames(
		export_path.path_join("data/corrected_annotations.jsonl")), [16, 23],
		"workspace handoff should preserve sparse original frame ids")
	var handoff_manifest: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(export_path.path_join("manifest.json")))
	support.expect(handoff_manifest is Dictionary
		and handoff_manifest.get("media", {}).get("media_id") == "VID68",
		"workspace handoff should identify the selected media")
	support.expect(handoff_manifest is Dictionary
		and handoff_manifest.get("media", {}).get(
			"source_sha256", "missing") == null,
		"workspace handoff should retain an unavailable sequence hash as null")
	await _free_main(main, tree)

	var reopened = await _mounted_main(tree)
	support.expect_equal(await reopened.open_workspace(root), PackedStringArray(),
		"saved workspace should reopen")
	await _select_media(reopened,"VID68",tree)
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
	support.expect_equal(await main.open_workspace(root), PackedStringArray(),
		"failure fixture workspace should open")
	await _select_media(main,"VID68",tree)
	var accepted_source = main.get("_source")
	var accepted_viewport_record: Dictionary = main.get_node(
		"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport"
	).get("_record").duplicate(true)
	await _select_media(main,"VID70",tree)
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
	DirAccess.rename_absolute(root.path_join("label"),root.path_join("label.saved"))
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
	await _select_media(main,"VID70",tree)
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
	main.set("review_session_root", "/tmp/part4-regression-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()])
	tree.root.add_child(main)
	await tree.process_frame
	return main


func _free_main(main: Node, tree: SceneTree) -> void:
	if main.get("_workspace_catalog_controller") != null:
		await main.get("_workspace_catalog_controller").cancel_and_drain()
	if main.get("_workspace_media_controller") != null:
		await main.get("_workspace_media_controller").cancel_and_drain()
	if main.get("_workspace_session") != null:
		main.get("_workspace_session").suspend_autosave(true)
		await main.get("_workspace_session").settle_running()
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


func _new_endoscapes_fixture() -> String:
	var root := _new_temp_root()
	for directory: String in ["train", "val", "test", "semseg"]:
		DirAccess.make_dir_recursive_absolute(root.path_join(directory))
	_write_text(root.path_join("all_metadata.csv"), "video_id,split\n")
	var categories := [
		{"id": 1, "name": "cystic_plate", "supercategory": "anatomy"},
		{"id": 2, "name": "calot_triangle", "supercategory": "anatomy"},
		{"id": 3, "name": "cystic_artery", "supercategory": "anatomy"},
		{"id": 4, "name": "cystic_duct", "supercategory": "anatomy"},
		{"id": 5, "name": "gallbladder", "supercategory": "anatomy"},
		{"id": 6, "name": "tool", "supercategory": "tool"},
	]
	_write_json(root.path_join("train/annotation_coco.json"), {
		"images": [
			{"id": 10050, "file_name": "1_50.jpg", "height": 6, "width": 8,
				"video_id": 1, "frame_id": null},
			{"id": 20010, "file_name": "2_10.jpg", "height": 6, "width": 8,
				"video_id": 2, "frame_id": null},
			{"id": 10025, "file_name": "1_25.jpg", "height": 6, "width": 8,
				"video_id": 1, "frame_id": null},
		],
		"annotations": [
			{"id": 7001, "image_id": 10025, "category_id": 1,
				"bbox": [1, 1, 3, 3]},
			{"id": 7002, "image_id": 10025, "category_id": 6,
				"bbox": [2, 1, 2, 3]},
			{"id": 7003, "image_id": 20010, "category_id": 4,
				"bbox": [1, 1, 3, 3]},
		],
		"categories": categories,
	})
	for split: String in ["val", "test"]:
		_write_json(root.path_join(split).path_join("annotation_coco.json"), {
			"images": [], "annotations": [], "categories": categories,
		})
	_save_jpg(root.path_join("train/1_50.jpg"), Color.BLUE)
	_save_jpg(root.path_join("train/1_25.jpg"), Color.RED)
	_save_jpg(root.path_join("train/2_10.jpg"), Color.GREEN)
	_save_image(root.path_join("semseg/1_25.png"), Color.WHITE)
	return root


func _save_image(path: String, color: Color) -> void:
	var image := Image.create(12, 8, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.save_png(path)


func _save_jpg(path: String, color: Color) -> void:
	var image := Image.create(8, 6, false, Image.FORMAT_RGB8)
	image.fill(color)
	image.save_jpg(path, 0.95)


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)


func _write_json(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(value, "  ", false) + "\n")


func _read_jsonl_frames(path: String) -> Array:
	var result: Array = []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return result
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var value: Variant = JSON.parse_string(line)
		if value is Dictionary:
			result.append(int(value.get("frame", -1)))
	return result


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

func _select_media(main: Node, media_id: String, tree: SceneTree) -> void:
	var done := [false]
	var launch := func():
		await main._on_workspace_media_requested(media_id)
		done[0] = true
	launch.call()
	var started := Time.get_ticks_msec()
	while not done[0] and Time.get_ticks_msec()-started < 15000:
		if main._review_workflow._leave_dialog.visible:
			main._review_workflow._leave_dialog.confirmed.emit()
		await tree.process_frame
	assert(done[0], "media selection did not settle")
