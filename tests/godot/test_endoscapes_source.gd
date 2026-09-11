extends RefCounted

const SOURCE_PATH := "res://client/plugins/source/endoscapes_video_source/plugin.gd"
const REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const SOURCE_FACTORY_SCRIPT := preload("res://client/pipeline/source_factory.gd")
const CATALOG_SCRIPT := preload("res://client/workspace/workspace_catalog.gd")
const TEMP_PREFIX := "/tmp/annotool-endoscapes-source-"


func run(support) -> void:
	var source_script := ResourceLoader.load(SOURCE_PATH, "Script") as Script
	support.expect(source_script != null,
		"Endoscapes Source plugin should be installed")
	if source_script == null:
		return
	var root := _new_fixture()
	var source = source_script.new()
	var discovery: Dictionary = source.discover_workspace_media(root, null)
	support.expect(bool(discovery.get("claimed", false)),
		"standard Endoscapes markers should be claimed")
	support.expect_equal(discovery.get("errors"), PackedStringArray(),
		"valid Endoscapes discovery should have no errors")
	var media: Array = discovery.get("media", [])
	support.expect_equal(media.size(), 3,
		"only split/video pairs should become workspace media")
	var train_one := _entry_by_id(media, "endoscapes_train_video_001")
	support.expect_equal(train_one.get("relative_path"), "train/video-001",
		"mask paths must not become media")
	support.expect_equal(train_one.get("baseline_kind"), "imported_labels",
		"Endoscapes videos should advertise imported-label baselines")
	support.expect(not train_one.has("frame_paths"),
		"workspace summaries must not retain all frame paths")
	for value: Variant in media:
		support.expect(not String(value.get("source_path", "")).contains("semseg"),
			"semseg files must never become Source locators")

	var locator := root.path_join("train/1_25.jpg")
	support.expect(source.can_open(locator),
		"a representative frame under a validated split should route to Endoscapes")
	support.expect(not source.can_open(root.path_join("stray.jpg")),
		"an unrelated JPEG at the dataset root should not be claimed")
	support.expect_equal(source.open(locator), PackedStringArray(),
		"opening one video should build metadata without decoding textures")
	support.expect_equal(source.get_frame_count(), 2,
		"only the selected video's frames should be retained")
	support.expect_equal(source.get_retained_frame_path_count(), 2,
		"the Source should retain exactly one video's frame paths")
	support.expect_equal(source.get_cache_size(), 0,
		"opening should not decode any frame texture")
	support.expect_equal(source.get_frame_entry(0).get("frame"), 0,
		"playback positions should begin contiguously at zero")
	support.expect_equal(source.get_frame_entry(0).get("frame_id"), 25,
		"the first sparse Endoscapes frame ID should be preserved")
	support.expect_equal(source.get_frame_entry(1).get("frame_id"), 50,
		"compound frame names should be sorted by numeric frame ID")
	var records: Array = source.get_model_records()
	support.expect_equal(records.size(), 2,
		"SourceStage should expose one imported record per selected frame")
	support.expect_equal([records[0].get("frame"), records[1].get("frame")], [25, 50],
		"imported records should use original frame IDs")
	var expected_box := {
		"id": "endoscapes-train-10025-7001",
		"class": "cystic_duct",
		"kind": "anatomy",
		"box": [1.0, 2.0, 3.0, 4.0],
	}
	var frame_twenty_five_regions: Array = records[0].get("regions", [])
	support.expect_equal(frame_twenty_five_regions.size(), 2,
		"valid bbox and polygon annotations should enter the first frame")
	if frame_twenty_five_regions.size() >= 2:
		support.expect_equal(frame_twenty_five_regions[0], expected_box,
			"COCO bbox/category conversion should produce a stable V1 region")
		var tool_region: Dictionary = frame_twenty_five_regions[1]
		support.expect_equal(tool_region.get("kind"), "instrument",
			"the COCO tool category should map to the instrument kind")
		support.expect(tool_region.has("polygon") and tool_region.has("box"),
			"a safe compressed RLE should add a polygon while retaining its bbox")
		support.expect(not tool_region.has("conf") and not tool_region.has("verified"),
			"official labels must not invent confidence or verification state")
	var frame_fifty_regions: Array = records[1].get("regions", [])
	support.expect_equal(frame_fifty_regions.size(), 2,
		"only valid selected-video annotations should enter the second frame")
	if frame_fifty_regions.size() >= 2:
		support.expect(not frame_fifty_regions[0].has("polygon")
			and not frame_fifty_regions[1].has("polygon"),
			"malformed and image-boundary RLE should safely retain box-only regions")
	support.expect(source.has_method("get_import_statistics"),
		"Endoscapes Source should expose detached import statistics")
	if source.has_method("get_import_statistics"):
		var statistics: Dictionary = source.get_import_statistics()
		support.expect_equal(statistics.get("imported_regions"), 4,
			"import statistics should count only regions published to V1")
		support.expect_equal(statistics.get("polygon_regions"), 1,
			"import statistics should count accepted single-ring polygons")
		support.expect_equal(statistics.get("box_fallbacks"), 2,
			"malformed and boundary-touching masks should be visible box fallbacks")
		support.expect_equal(statistics.get("skipped_regions"), 2,
			"unknown categories and geometry-free annotations should be counted as skips")
		support.expect_equal(statistics.get("fallback_reasons"), {
			"rle_decode_failed": 1,
			"image_boundary": 1,
		}, "fallback diagnostics should explain every safe box degradation")
	support.expect_equal(source.get_manifest().get("model_version"), "endoscapes-coco-v1",
		"successful conversion should identify the imported baseline version")
	support.expect_equal(source.get_manifest().get("frame_step"), 25,
		"Endoscapes manifest should declare its sampled original-frame step")
	var texture: Texture2D = source.load_texture(1)
	support.expect(texture != null and texture.get_width() == 8 and texture.get_height() == 6,
		"selected-video textures should decode on demand")
	support.expect_equal(source.get_cache_size(), 1,
		"one texture request should retain one decoded texture")
	_save_image(root.path_join("train/1_50.jpg"), Color.GREEN)
	support.expect(source.load_texture(1).get_image().get_pixel(0, 0).b > 0.8,
		"normal Endoscapes playback retains cached pixels after replacement")
	support.expect(source.has_method("load_image_snapshot_uncached"),
		"Endoscapes Source supplies an optional uncached image snapshot boundary")
	if source.has_method("load_image_snapshot_uncached"):
		var fresh: Image = source.load_image_snapshot_uncached(1)
		support.expect(fresh != null and fresh.get_pixel(0, 0).g > 0.8,
			"Endoscapes fresh snapshot sees replaced JPEG pixels through a primed cache")
		if fresh != null: fresh.fill(Color.RED)
		var next: Image = source.load_image_snapshot_uncached(1)
		support.expect(next != null and next.get_pixel(0, 0).g > 0.8,
			"Endoscapes fresh snapshots are detached images")
		support.expect_equal(source.get_cache_size(), 1,
			"integrity reads do not evict or populate the playback cache")
		support.expect(source.load_image_snapshot_uncached(2) == null,
			"Endoscapes fresh snapshot checks playback bounds")

	var registry = REGISTRY_SCRIPT.new()
	support.expect_equal(registry.discover("res://client/plugins"), PackedStringArray(),
		"the production registry should accept the Endoscapes plugin")
	var factory = SOURCE_FACTORY_SCRIPT.new(registry)
	support.expect_equal(factory.resolve_plugin_id(locator), "endoscapes_video_source",
		"Endoscapes should route before the generic single-image Source")
	var catalog = CATALOG_SCRIPT.new()
	catalog.configure_source_resolver(factory)
	support.expect_equal(catalog.scan(root), PackedStringArray(),
		"WorkspaceCatalog should consume video-level Endoscapes discovery")
	support.expect_equal(catalog.get_entries().size(), 3,
		"catalog publication should remain video-level")

	source.close()
	support.expect_equal(source.get_frame_count(), 0,
		"close should clear selected-video frame metadata")
	support.expect_equal(source.get_retained_frame_path_count(), 0,
		"close should release all retained frame paths")
	support.expect_equal(source.get_cache_size(), 0,
		"close should release decoded textures")
	_remove_tree(root)


func _entry_by_id(entries: Array, media_id: String) -> Dictionary:
	for value: Variant in entries:
		if value is Dictionary and value.get("media_id") == media_id:
			return value
	return {}


func _new_fixture() -> String:
	var root := "%s%d-%d" % [TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	for directory: String in ["train", "val", "test", "semseg"]:
		DirAccess.make_dir_recursive_absolute(root.path_join(directory))
	_write_text(root.path_join("all_metadata.csv"), "video_id,split\n")
	_write_text(root.path_join("train/annotation_coco.json"), JSON.stringify(_train_coco()))
	for split: String in ["val", "test"]:
		_write_text(root.path_join(split).path_join("annotation_coco.json"),
			JSON.stringify({"images": [], "annotations": [], "categories": _categories()}))
	_save_image(root.path_join("train/1_50.jpg"), Color.BLUE)
	_save_image(root.path_join("train/1_25.jpg"), Color.RED)
	_save_image(root.path_join("train/2_10.jpg"), Color.GREEN)
	_save_image(root.path_join("test/121_100.jpg"), Color.YELLOW)
	_save_png(root.path_join("semseg/1_25.png"), Color.WHITE)
	_save_image(root.path_join("stray.jpg"), Color.PURPLE)
	return root


func _train_coco() -> Dictionary:
	return {
		"images": [
			{"id": 20010, "file_name": "2_10.jpg", "height": 6, "width": 8,
				"video_id": 2, "frame_id": null},
			{"id": 10050, "file_name": "1_50.jpg", "height": 6, "width": 8,
				"video_id": 1, "frame_id": null},
			{"id": 10025, "file_name": "1_25.jpg", "height": 6, "width": 8,
				"video_id": 1, "frame_id": null},
		],
		"annotations": [
			{"id": 7006, "image_id": 10050, "category_id": 1,
				"bbox": [1, 1, 2, 2], "segmentation": {"size": [6, 8], "counts": "P"}},
			{"id": 7004, "image_id": 20010, "category_id": 1, "bbox": [1, 1, 2, 2]},
			{"id": 7002, "image_id": 10025, "category_id": 6,
				"bbox": [1, 1, 3, 3], "segmentation": {"size": [6, 8], "counts": "733000g0"}},
			{"id": 7003, "image_id": 10050, "category_id": 999, "bbox": [1, 1, 2, 2]},
			{"id": 7001, "image_id": 10025, "category_id": 4, "bbox": [1, 2, 3, 4]},
			{"id": 7005, "image_id": 10050, "category_id": 1, "bbox": [-1, 0, 2, 2]},
			{"id": 7007, "image_id": 10050, "category_id": 1,
				"bbox": [0, 0, 1, 1], "segmentation": {"size": [6, 8], "counts": "01_1"}},
		],
		"categories": _categories(),
	}


func _categories() -> Array:
	return [
		{"id": 1, "name": "cystic_plate", "supercategory": "anatomy"},
		{"id": 2, "name": "calot_triangle", "supercategory": "anatomy"},
		{"id": 3, "name": "cystic_artery", "supercategory": "anatomy"},
		{"id": 4, "name": "cystic_duct", "supercategory": "anatomy"},
		{"id": 5, "name": "gallbladder", "supercategory": "anatomy"},
		{"id": 6, "name": "tool", "supercategory": "tool"},
	]


func _save_image(path: String, color: Color) -> void:
	var image := Image.create(8, 6, false, Image.FORMAT_RGB8)
	image.fill(color)
	image.save_jpg(path, 0.95)


func _save_png(path: String, color: Color) -> void:
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.save_png(path)


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for child_name: String in directory.get_directories():
		_remove_tree(path.path_join(child_name))
	DirAccess.remove_absolute(path)
