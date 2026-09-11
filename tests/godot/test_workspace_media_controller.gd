extends RefCounted

const CONTROLLER_PATH := "res://client/workspace/workspace_media_controller.gd"
const FACTORY_PATH := "res://client/pipeline/source_factory.gd"
const REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const TEMP_PREFIX := "/tmp/annotool-workspace-media-"


class ProbeImporter extends Node:
	signal progress(payload: Dictionary)
	signal completed(output_path: String)
	signal failed(message: String)
	signal cancelled

	var running := false
	var start_count := 0
	var last_input := ""
	var last_output := ""

	func start(input: String, output: String) -> PackedStringArray:
		start_count += 1
		last_input = input
		last_output = output
		running = true
		return PackedStringArray()

	func is_running() -> bool:
		return running

	func cancel() -> void:
		running = false
		cancelled.emit()


class ProbeSource extends RefCounted:
	var close_count := 0
	var source_id := ""

	func _init(value: String) -> void:
		source_id = value

	func get_manifest() -> Dictionary:
		return {"source_sha256": null}

	func get_import_statistics() -> Dictionary:
		return {"imported_regions": 7, "polygon_regions": 5,
			"box_fallbacks": 2, "skipped_regions": 1}

	func close() -> void:
		close_count += 1


class DelayedFactory extends RefCounted:
	var sources := {}

	func open(locator: String, _preferred: String = "", _token: Variant = null) -> Dictionary:
		if locator.ends_with("slow.fixture"):
			OS.delay_msec(200)
		var source := ProbeSource.new(locator.get_file())
		sources[locator] = source
		return {"source": source, "plugin_id": "probe_source", "errors": PackedStringArray()}


func run(support, tree: SceneTree) -> void:
	var script := ResourceLoader.load(CONTROLLER_PATH, "Script") as Script
	support.expect(script != null,
		"WorkspaceMediaController should open selected media and lazily import videos")
	if script == null:
		return
	var root := _new_temp_root()
	var sequence_path := root.path_join("videos/VID68")
	DirAccess.make_dir_recursive_absolute(sequence_path)
	_save_image(sequence_path.path_join("000016.png"), Color.RED)
	_save_image(sequence_path.path_join("000023.png"), Color.BLUE)
	var video_path := root.path_join("clip.mp4")
	_write_text(video_path, "video identity fixture")
	var importer := ProbeImporter.new()
	tree.root.add_child(importer)
	var controller = script.new()
	tree.root.add_child(controller)
	var factory_script := ResourceLoader.load(FACTORY_PATH, "Script") as Script
	support.expect(factory_script != null,
		"workspace media should receive the shared SourceFactory")
	if factory_script == null:
		controller.queue_free()
		importer.queue_free()
		await tree.process_frame
		_remove_tree(root)
		return
	var registry = REGISTRY_SCRIPT.new()
	support.expect_equal(
		registry.discover("res://client/plugins"), PackedStringArray(),
		"workspace media fixture should discover production Source plugins")
	controller.configure(root, importer, factory_script.new(registry))
	var ready_payloads: Array[Dictionary] = []
	var imports: Array[Dictionary] = []
	controller.media_ready.connect(
		func(payload: Dictionary) -> void: ready_payloads.append(payload))
	controller.import_started.connect(
		func(input: String, output: String) -> void:
			imports.append({"input": input, "output": output}))

	var sequence_entry := {
		"display_name": "VID68",
		"media_id": "VID68",
		"media_type": "image_sequence",
		"source_path": sequence_path,
		"relative_path": "videos/VID68",
	}
	support.expect_equal(controller.select_media(sequence_entry), PackedStringArray(),
		"selected image sequence should open without FFmpeg")
	support.expect_equal(ready_payloads.size(), 1,
		"sequence selection should produce one ready source")
	support.expect_equal(
		ready_payloads[0].get("source").get_frame_entry(0).get("frame_id"), 16,
		"ready sequence should preserve sparse original frame mapping")
	support.expect_equal(importer.start_count, 0,
		"existing sequence selection must not start video import")

	var video_entry := {
		"display_name": "clip.mp4",
		"media_id": "clip",
		"media_type": "video",
		"source_path": video_path,
		"relative_path": "clip.mp4",
	}
	support.expect_equal(controller.select_media(video_entry), PackedStringArray(),
		"selected uncached video should start background import")
	support.expect_equal(importer.start_count, 1,
		"cache miss should start exactly one import")
	support.expect_equal(importer.last_output, root.path_join(".annotool/cache/clip"),
		"video import output should be deterministic")
	support.expect_equal(imports.size(), 1,
		"controller should expose the deterministic source and destination")
	support.expect(not controller.select_media(video_entry).is_empty(),
		"duplicate selection should be refused while import is active")

	controller.cancel()
	_make_valid_cache(root, video_path)
	support.expect_equal(controller.select_media(video_entry), PackedStringArray(),
		"matching deterministic video cache should reopen directly")
	support.expect_equal(importer.start_count, 1,
		"matching video cache must not start a second import")
	support.expect_equal(ready_payloads.size(), 2,
		"cache reuse should publish one additional ready source")

	var delayed_factory := DelayedFactory.new()
	controller.configure(root, importer, delayed_factory)
	var slow_path := root.path_join("slow.fixture")
	var latest_path := root.path_join("latest.fixture")
	_write_text(slow_path, "slow")
	_write_text(latest_path, "latest")
	var slow_entry := {
		"display_name": "slow", "media_id": "slow", "media_type": "image",
		"source_path": slow_path, "relative_path": "slow.fixture",
		"source_plugin_id": "probe_source",
	}
	var latest_entry := {
		"display_name": "latest", "media_id": "latest", "media_type": "image",
		"source_path": latest_path, "relative_path": "latest.fixture",
		"source_plugin_id": "probe_source",
	}
	var ready_before := ready_payloads.size()
	support.expect_equal(controller.select_media(slow_entry), PackedStringArray(),
		"plugin-owned Source preparation should start in the background")
	await tree.create_timer(0.05).timeout
	support.expect_equal(controller.select_media(latest_entry), PackedStringArray(),
		"a newer plugin-owned selection should supersede the running generation")
	var ticks := 0
	while controller.is_busy() and ticks < 300:
		await tree.create_timer(0.01).timeout
		ticks += 1
	support.expect(ticks > 2 and ticks < 300,
		"background Source opening should keep the event loop responsive and terminate")
	support.expect_equal(ready_payloads.size(), ready_before + 1,
		"only the latest Source generation should publish media_ready")
	if ready_payloads.size() > ready_before:
		support.expect_equal(ready_payloads[-1].get("media_entry", {}).get("media_id"),
			"latest", "latest-wins should publish the selected media identity")
		support.expect_equal(ready_payloads[-1].get("import_statistics"), {
			"imported_regions": 7, "polygon_regions": 5,
			"box_fallbacks": 2, "skipped_regions": 1,
		}, "media_ready should carry detached Source import statistics")
	var stale_source: Variant = delayed_factory.sources.get(slow_path)
	support.expect(stale_source != null and stale_source.close_count == 1,
		"a stale Source returned by an uncooperative worker should be closed exactly once")
	support.expect(controller.has_method("cancel_and_drain"),
		"workspace replacement should be able to cancel and drain Source preparation")
	if controller.has_method("cancel_and_drain"):
		await controller.cancel_and_drain()
	controller.queue_free()
	importer.queue_free()
	await tree.process_frame
	_remove_tree(root)


func _new_temp_root() -> String:
	var root := "%s%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _save_image(path: String, color: Color) -> void:
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.save_png(path)


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)


func _make_valid_cache(root: String, video_path: String) -> void:
	var cache := root.path_join(".annotool/cache/clip")
	DirAccess.make_dir_recursive_absolute(cache.path_join("frames"))
	_save_image(cache.path_join("frames/frame_000000.png"), Color.GREEN)
	var manifest := {
		"schema_version": 1,
		"dataset_id": "clip",
		"source_name": "clip.mp4",
		"source_sha256": FileAccess.get_sha256(video_path),
		"width": 8,
		"height": 6,
		"frame_count": 1,
		"nominal_fps": 25.0,
		"frames": [{
			"frame": 0,
			"time_s": 0.0,
			"image_path": "frames/frame_000000.png",
		}],
		"model_version": "none",
		"taxonomy_version": "v1",
	}
	var file := FileAccess.open(cache.path_join("manifest.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(manifest, "  ", false) + "\n")


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
