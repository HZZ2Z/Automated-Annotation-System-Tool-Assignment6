extends RefCounted

const CACHE_SCRIPT = preload("res://client/services/frame_cache.gd")
const SOURCE_SCRIPT = preload("res://client/plugins/source/image_sequence_source/plugin.gd")


static func run(support) -> void:
	_test_lru_cache(support)
	var sample_dir := _generate_sample(support)
	if sample_dir.is_empty():
		return
	_test_generated_sample_and_transaction(support, sample_dir)
	_test_normalized_video_without_model_output(support)
	_test_texture_errors_are_recoverable(support)
	_test_manifest_and_model_failures(support)


static func _test_lru_cache(support) -> void:
	var cache = CACHE_SCRIPT.new(3)
	var loads := {}
	var loader := func(index: int) -> String:
		loads[index] = int(loads.get(index, 0)) + 1
		return "frame-%d" % index
	for index in [0, 1, 2]:
		cache.get_value(index, loader)
	cache.get_value(0, loader)
	cache.get_value(3, loader)
	support.expect(cache.has(0) and cache.has(2) and cache.has(3), "LRU should retain touched and recent entries")
	support.expect(not cache.has(1), "LRU should evict the least recently used entry")
	support.expect_equal(cache.size(), 3, "cache must remain bounded")
	support.expect_equal(loads.get(0), 1, "cache hit should not call the loader again")

	var minimum_cache = CACHE_SCRIPT.new(0)
	support.expect_equal(minimum_cache.max_size, 1, "cache size should clamp to one")
	support.expect(minimum_cache.get_value(-1, loader) == null and "index" in minimum_cache.last_error, "negative cache index should be recoverable")
	support.expect(minimum_cache.get_value(0, Callable()) == null and "loader" in minimum_cache.last_error, "invalid loader should be recoverable")
	var null_loader := func(_index: int): return null
	support.expect(minimum_cache.get_value(9, null_loader) == null, "null loads should return null")
	support.expect(not minimum_cache.has(9), "null loads must not be cached")
	minimum_cache.get_value(0, loader)
	minimum_cache.clear()
	support.expect_equal(minimum_cache.size(), 0, "clear should remove cached entries")


static func _generate_sample(support) -> String:
	var sample_dir := "/tmp/annotool-task6-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var output: Array = []
	var python := ProjectSettings.globalize_path("res://.venv/bin/python")
	var result := OS.execute(python, ["python/make_sample_input.py", "--output", sample_dir, "--seed", "6006"], output, true)
	support.expect_equal(result, 0, "real sample generator should succeed: %s" % "\n".join(output))
	return sample_dir if result == 0 else ""


static func _test_generated_sample_and_transaction(support, sample_dir: String) -> void:
	var source = SOURCE_SCRIPT.new()
	var errors: PackedStringArray = source.open(sample_dir)
	support.expect_equal(errors, PackedStringArray(), "generated sample should open")
	support.expect_equal(source.get_frame_count(), 120, "generated sample should expose 120 frames")
	var texture: Texture2D = source.load_texture(0)
	support.expect(texture != null and texture.get_width() == 640 and texture.get_height() == 360, "generated frame texture should be 640x360")
	var records: Array[Dictionary] = source.get_model_records()
	support.expect_equal(records.size(), 120, "generated sample should expose 120 model records")
	support.expect_equal(source.get_manifest().get("similarity_scores", []).size(), 119, "generated sample should expose 119 similarity scores")

	var frame_copy: Dictionary = source.get_frame_entry(0)
	frame_copy["image_path"] = "mutated"
	support.expect(source.get_frame_entry(0).get("image_path") != "mutated", "frame entries should be defensive copies")
	records[0]["regions"].clear()
	support.expect(not source.get_model_records()[0]["regions"].is_empty(), "model records should be deep defensive copies")

	var replacement_errors: PackedStringArray = source.open("/tmp/definitely-missing-task6-source")
	support.expect(not replacement_errors.is_empty(), "missing replacement source should report an error")
	support.expect_equal(source.get_frame_count(), 120, "failed replacement should preserve the valid source")
	support.expect_equal(source.get_model_records().size(), 120, "failed replacement should preserve model records")
	support.expect(source.load_texture(-1) == null and "index" in source.last_error, "out-of-range texture load should be recoverable")
	support.expect(source.load_texture(120) == null and "index" in source.last_error, "past-end texture load should be recoverable")
	source.close()
	support.expect_equal(source.get_frame_count(), 0, "close should clear frames")
	support.expect_equal(source.get_model_records(), [], "close should clear records")


static func _test_normalized_video_without_model_output(support) -> void:
	var root := "/tmp/annotool-task6-normalized-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLUE)
	support.expect_equal(image.save_png(root.path_join("frames/frame_000000.png")), OK, "normalized fixture frame should save")
	var manifest := _base_manifest("normalized-none", "none", 8, 6)
	_write_json(root.path_join("manifest.json"), manifest)

	var source = SOURCE_SCRIPT.new()
	var errors: PackedStringArray = source.open(root)
	support.expect_equal(errors, PackedStringArray(), "model_version none source should synthesize records when JSONL is absent")
	var records: Array[Dictionary] = source.get_model_records()
	support.expect_equal(records.size(), 1, "normalized source should synthesize one record per frame")
	support.expect_equal(records[0].get("source"), "model_output_v1", "synthesized record should use the shared model source contract")
	support.expect_equal(records[0].get("regions"), [], "synthesized record should have empty regions")
	support.expect(source.load_texture(0) != null, "normalized source texture should load on demand")

	DirAccess.remove_absolute(root.path_join("frames/frame_000000.png"))
	support.expect(source.load_texture(0) != null, "already cached texture should remain available after source file removal")


static func _test_manifest_and_model_failures(support) -> void:
	var root := "/tmp/annotool-task6-invalid-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.save_png(root.path_join("frames/frame_000000.png"))
	var source = SOURCE_SCRIPT.new()

	var missing_model_manifest := _base_manifest("missing-real-model", "real-model-v2", 8, 6)
	_write_json(root.path_join("manifest.json"), missing_model_manifest)
	var errors: PackedStringArray = source.open(root)
	support.expect(_contains(errors, "model_output.jsonl"), "real model version should require model_output.jsonl")

	var invalid_manifest := _base_manifest("bad-extra", "none", 8, 6)
	invalid_manifest["unexpected"] = true
	_write_json(root.path_join("manifest.json"), invalid_manifest)
	errors = source.open(root)
	support.expect(_contains(errors, "additional field"), "manifest should reject unknown fields")

	invalid_manifest = _base_manifest("bad-scores", "none", 8, 6)
	invalid_manifest["similarity_scores"] = [0.2]
	_write_json(root.path_join("manifest.json"), invalid_manifest)
	errors = source.open(root)
	support.expect(_contains(errors, "similarity_scores"), "manifest should require exactly frame_count - 1 similarity scores")

	invalid_manifest = _base_manifest("bad-path", "none", 8, 6)
	invalid_manifest["frames"][0]["image_path"] = "../outside.png"
	_write_json(root.path_join("manifest.json"), invalid_manifest)
	errors = source.open(root)
	support.expect(_contains(errors, "image_path"), "manifest should reject traversal paths")

	image.save_png(root.path_join("https:frame.png"))
	invalid_manifest = _base_manifest("bad-url", "none", 8, 6)
	invalid_manifest["frames"][0]["image_path"] = "https:frame.png"
	_write_json(root.path_join("manifest.json"), invalid_manifest)
	errors = source.open(root)
	support.expect(_contains(errors, "portable relative POSIX path"), "manifest should reject URL-scheme paths even without slashes")

	var bad_record_manifest := _base_manifest("bad-record", "real-model-v1", 8, 6)
	_write_json(root.path_join("manifest.json"), bad_record_manifest)
	var bad_record := {
		"schema_version": 1,
		"dataset_id": "wrong-dataset",
		"source": "model_output_v1",
		"frame": 0,
		"time_s": 0.0,
		"image_size": [8, 6],
		"regions": [],
	}
	_write_text(root.path_join("model_output.jsonl"), JSON.stringify(bad_record) + "\n")
	errors = source.open(root)
	support.expect(_contains(errors, "dataset_id"), "model record dataset should align with manifest")

	bad_record["dataset_id"] = "bad-record"
	bad_record["time_s"] = 1.0
	_write_text(root.path_join("model_output.jsonl"), JSON.stringify(bad_record) + "\n")
	errors = source.open(root)
	support.expect(_contains(errors, "time_s"), "model record time should align with manifest")


static func _test_texture_errors_are_recoverable(support) -> void:
	var missing_root := "/tmp/annotool-task6-missing-frame-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_make_one_frame_source(missing_root, 8, 6)
	var missing_source = SOURCE_SCRIPT.new()
	support.expect_equal(missing_source.open(missing_root), PackedStringArray(), "missing-frame fixture should open before its file is removed")
	DirAccess.remove_absolute(missing_root.path_join("frames/frame_000000.png"))
	support.expect(missing_source.load_texture(0) == null and "missing" in missing_source.last_error, "missing frame after open should return a readable recoverable error")

	var corrupt_root := "/tmp/annotool-task6-corrupt-frame-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_make_one_frame_source(corrupt_root, 8, 6)
	var corrupt_source = SOURCE_SCRIPT.new()
	support.expect_equal(corrupt_source.open(corrupt_root), PackedStringArray(), "corrupt-frame fixture should open before its file is changed")
	_write_text(corrupt_root.path_join("frames/frame_000000.png"), "not png data")
	support.expect(corrupt_source.load_texture(0) == null and "corrupt" in corrupt_source.last_error, "corrupt frame should return a readable recoverable error")

	var wrong_size_root := "/tmp/annotool-task6-wrong-size-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_make_one_frame_source(wrong_size_root, 9, 6)
	var wrong_size_source = SOURCE_SCRIPT.new()
	support.expect_equal(wrong_size_source.open(wrong_size_root), PackedStringArray(), "wrong-size fixture should open without eagerly decoding textures")
	support.expect(wrong_size_source.load_texture(0) == null and "dimensions" in wrong_size_source.last_error, "decoded texture dimensions should match the manifest")


static func _make_one_frame_source(root: String, image_width: int, image_height: int) -> void:
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(image_width, image_height, false, Image.FORMAT_RGBA8)
	image.fill(Color.GREEN)
	image.save_png(root.path_join("frames/frame_000000.png"))
	_write_json(root.path_join("manifest.json"), _base_manifest(root.get_file(), "none", 8, 6))


static func _base_manifest(dataset_id: String, model_version: String, width: int, height: int) -> Dictionary:
	return {
		"schema_version": 1,
		"dataset_id": dataset_id,
		"source_name": "fixture.mp4",
		"source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"width": width,
		"height": height,
		"frame_count": 1,
		"nominal_fps": 30.0,
		"frames": [{"frame": 0, "time_s": 0.0, "image_path": "frames/frame_000000.png"}],
		"model_version": model_version,
		"taxonomy_version": "none",
	}


static func _write_json(path: String, value: Variant) -> void:
	_write_text(path, JSON.stringify(value, "  ") + "\n")


static func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)


static func _contains(values: PackedStringArray, fragment: String) -> bool:
	for value: String in values:
		if fragment in value:
			return true
	return false
