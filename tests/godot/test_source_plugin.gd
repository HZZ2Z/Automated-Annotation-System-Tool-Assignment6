extends RefCounted

const CACHE_SCRIPT = preload("res://client/services/frame_cache.gd")
const SOURCE_SCRIPT = preload("res://client/plugins/source/image_sequence_source/plugin.gd")
const TEMP_PREFIX := "/tmp/annotool-task6-"

static var _owned_temp_paths: Array[String] = []
static var _cleanup_target_checks: Dictionary = {}
static var _temp_sequence := 0


static func run(support) -> void:
	_owned_temp_paths.clear()
	_cleanup_target_checks.clear()
	_temp_sequence = 0
	_test_lru_cache(support)
	var sample_dir := _generate_sample(support)
	if not sample_dir.is_empty():
		_test_generated_sample_and_transaction(support, sample_dir)
	_test_normalized_video_without_model_output(support)
	_test_versioned_model_output_selection(support)
	_test_texture_errors_are_recoverable(support)
	_test_manifest_and_model_failures(support)
	_test_symlink_paths_are_contained(support)
	_test_linked_metadata_is_rejected(support)
	_cleanup_owned_temp_paths(support)


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
	var sample_dir := _new_temp_path("sample")
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
	var root := _new_temp_path("normalized")
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
	support.expect_equal(records[0].get("source"), "fixture.mp4", "synthesized record should preserve the frame source")
	support.expect_equal(records[0].get("regions"), [], "synthesized record should have empty regions")
	support.expect(source.load_texture(0) != null, "normalized source texture should load on demand")

	DirAccess.remove_absolute(root.path_join("frames/frame_000000.png"))
	support.expect(source.load_texture(0) != null, "already cached texture should remain available after source file removal")


static func _test_manifest_and_model_failures(support) -> void:
	var root := _new_temp_path("invalid")
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.save_png(root.path_join("frames/frame_000000.png"))
	var source = SOURCE_SCRIPT.new()

	var missing_model_manifest := _base_manifest("missing-real-model", "model_output_v1", 8, 6)
	_write_json(root.path_join("manifest.json"), missing_model_manifest)
	var errors: PackedStringArray = source.open(root)
	support.expect(_contains(errors, "model_output_v1.jsonl"), "v1 manifest should require its same-named JSONL")

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

	var bad_record_manifest := _base_manifest("bad-record", "model_output_v1", 8, 6)
	bad_record_manifest["source_name"] = "sample_v1"
	_write_json(root.path_join("manifest.json"), bad_record_manifest)
	var bad_record := {
		"schema_version": 1,
		"source": "wrong-source",
		"frame": 0,
		"time_s": 0.0,
		"regions": [],
	}
	_write_text(root.path_join("model_output_v1.jsonl"), JSON.stringify(bad_record) + "\n")
	errors = source.open(root)
	support.expect(_contains(errors, "source"), "model record source should align with manifest")

	bad_record["source"] = "sample_v1"
	bad_record["time_s"] = 1.0
	_write_text(root.path_join("model_output_v1.jsonl"), JSON.stringify(bad_record) + "\n")
	errors = source.open(root)
	support.expect(_contains(errors, "time_s"), "model record time should align with manifest")


static func _test_texture_errors_are_recoverable(support) -> void:
	var missing_root := _new_temp_path("missing-frame")
	_make_one_frame_source(missing_root, 8, 6)
	var missing_source = SOURCE_SCRIPT.new()
	support.expect_equal(missing_source.open(missing_root), PackedStringArray(), "missing-frame fixture should open before its file is removed")
	DirAccess.remove_absolute(missing_root.path_join("frames/frame_000000.png"))
	support.expect(missing_source.load_texture(0) == null and "missing" in missing_source.last_error, "missing frame after open should return a readable recoverable error")

	var corrupt_root := _new_temp_path("corrupt-frame")
	_make_one_frame_source(corrupt_root, 8, 6)
	var corrupt_source = SOURCE_SCRIPT.new()
	support.expect_equal(corrupt_source.open(corrupt_root), PackedStringArray(), "corrupt-frame fixture should open before its file is changed")
	_write_text(corrupt_root.path_join("frames/frame_000000.png"), "not png data")
	support.expect(corrupt_source.load_texture(0) == null and "corrupt" in corrupt_source.last_error, "corrupt frame should return a readable recoverable error")

	var wrong_size_root := _new_temp_path("wrong-size")
	_make_one_frame_source(wrong_size_root, 9, 6)
	var wrong_size_source = SOURCE_SCRIPT.new()
	support.expect_equal(wrong_size_source.open(wrong_size_root), PackedStringArray(), "wrong-size fixture should open without eagerly decoding textures")
	support.expect(wrong_size_source.load_texture(0) == null and "dimensions" in wrong_size_source.last_error, "decoded texture dimensions should match the manifest")


static func _test_symlink_paths_are_contained(support) -> void:
	var preserved_root := _new_temp_path("symlink-preserved")
	_make_one_frame_source(preserved_root, 8, 6)
	var source = SOURCE_SCRIPT.new()
	support.expect_equal(source.open(preserved_root), PackedStringArray(), "transaction baseline source should open")
	var preserved_dataset: String = source.get_manifest().get("dataset_id", "")

	var outside_file_root := _new_temp_path("outside-file")
	DirAccess.make_dir_recursive_absolute(outside_file_root)
	var outside_image := Image.create(13, 7, false, Image.FORMAT_RGBA8)
	outside_image.fill(Color.MAGENTA)
	var outside_file := outside_file_root.path_join("outside.png")
	support.expect_equal(outside_image.save_png(outside_file), OK, "outside symlink target should be created")

	var leaf_link_root := _new_temp_path("leaf-link")
	_make_one_frame_source(leaf_link_root, 8, 6)
	var leaf_path := leaf_link_root.path_join("frames/frame_000000.png")
	support.expect_equal(DirAccess.remove_absolute(leaf_path), OK, "leaf fixture file should be removed before linking")
	support.expect_equal(_create_link(outside_file, leaf_path), OK, "leaf frame symlink should be created")
	_register_cleanup_target_check(leaf_link_root, outside_file)
	var errors: PackedStringArray = source.open(leaf_link_root)
	support.expect(_contains(errors, "link"), "open should reject a symlink frame file")
	support.expect_equal(source.get_manifest().get("dataset_id"), preserved_dataset, "rejected leaf symlink should preserve the prior source")

	var outside_directory_root := _new_temp_path("outside-directory")
	DirAccess.make_dir_recursive_absolute(outside_directory_root)
	support.expect_equal(outside_image.save_png(outside_directory_root.path_join("frame_000000.png")), OK, "outside directory target frame should be created")
	var directory_link_root := _new_temp_path("directory-link")
	DirAccess.make_dir_recursive_absolute(directory_link_root)
	_write_json(directory_link_root.path_join("manifest.json"), _base_manifest("directory-link", "none", 8, 6))
	support.expect_equal(_create_link(outside_directory_root, directory_link_root.path_join("frames")), OK, "intermediate directory symlink should be created")
	_register_cleanup_target_check(directory_link_root, outside_directory_root)
	errors = source.open(directory_link_root)
	support.expect(_contains(errors, "link"), "open should reject a symlink in an intermediate path component")
	support.expect_equal(source.get_manifest().get("dataset_id"), preserved_dataset, "rejected directory symlink should preserve the prior source")

	var swapped_root := _new_temp_path("swapped-link")
	_make_one_frame_source(swapped_root, 8, 6)
	var swapped_source = SOURCE_SCRIPT.new()
	support.expect_equal(swapped_source.open(swapped_root), PackedStringArray(), "TOCTOU fixture should open before its uncached frame changes")
	var swapped_path := swapped_root.path_join("frames/frame_000000.png")
	support.expect_equal(DirAccess.remove_absolute(swapped_path), OK, "TOCTOU frame should be removed before linking")
	support.expect_equal(_create_link(outside_file, swapped_path), OK, "TOCTOU frame symlink should be created")
	_register_cleanup_target_check(swapped_root, outside_file)
	support.expect(swapped_source.load_texture(0) == null and "link" in swapped_source.last_error, "load_texture should recheck and reject a frame replaced by a symlink")


static func _test_linked_metadata_is_rejected(support) -> void:
	var manifest_baseline_root := _new_temp_path("manifest-baseline")
	_make_one_frame_source(manifest_baseline_root, 8, 6)
	var manifest_source = SOURCE_SCRIPT.new()
	support.expect_equal(manifest_source.open(manifest_baseline_root), PackedStringArray(), "normal source should open before linked manifest replacement")
	var manifest_baseline_dataset: String = manifest_source.get_manifest().get("dataset_id", "")
	var manifest_cached_texture: Texture2D = manifest_source.load_texture(0)
	support.expect(manifest_cached_texture != null, "baseline source texture should enter the cache")

	var outside_manifest_root := _new_temp_path("outside-manifest")
	DirAccess.make_dir_recursive_absolute(outside_manifest_root)
	var outside_manifest := outside_manifest_root.path_join("manifest.json")
	_write_json(outside_manifest, _base_manifest("linked-manifest", "none", 8, 6))
	var linked_manifest_root := _new_temp_path("linked-manifest")
	_make_one_frame_source(linked_manifest_root, 8, 6)
	var linked_manifest_path := linked_manifest_root.path_join("manifest.json")
	support.expect_equal(DirAccess.remove_absolute(linked_manifest_path), OK, "local manifest should be removed before linking")
	support.expect_equal(_create_link(outside_manifest, linked_manifest_path), OK, "manifest symlink should be created")
	_register_cleanup_target_check(linked_manifest_root, outside_manifest)
	var errors: PackedStringArray = manifest_source.open(linked_manifest_root)
	support.expect(_contains(errors, "manifest.json") and _contains(errors, "link"), "open should identify and reject a linked manifest before reading it")
	support.expect_equal(manifest_source.get_manifest().get("dataset_id"), manifest_baseline_dataset, "linked manifest rejection should preserve the prior source")
	DirAccess.remove_absolute(manifest_baseline_root.path_join("frames/frame_000000.png"))
	support.expect(manifest_source.load_texture(0) == manifest_cached_texture, "linked manifest rejection should preserve the prior frame cache")

	var model_baseline_root := _new_temp_path("model-baseline")
	_make_one_frame_source(model_baseline_root, 8, 6)
	var model_source = SOURCE_SCRIPT.new()
	support.expect_equal(model_source.open(model_baseline_root), PackedStringArray(), "normal source should open before linked model replacement")
	var model_baseline_dataset: String = model_source.get_manifest().get("dataset_id", "")
	var model_cached_texture: Texture2D = model_source.load_texture(0)
	support.expect(model_cached_texture != null, "model baseline texture should enter the cache")

	var outside_model_root := _new_temp_path("outside-model")
	DirAccess.make_dir_recursive_absolute(outside_model_root)
	var linked_model_root := _new_temp_path("linked-model")
	_make_one_frame_source(linked_model_root, 8, 6)
	var linked_model_manifest := _base_manifest("linked-model", "model_output_v1", 8, 6)
	linked_model_manifest["source_name"] = "sample_v1"
	_write_json(linked_model_root.path_join("manifest.json"), linked_model_manifest)
	var outside_model := outside_model_root.path_join("model_output_v1.jsonl")
	var valid_record := {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"time_s": 0.0,
		"regions": [],
	}
	_write_text(outside_model, JSON.stringify(valid_record) + "\n")
	var linked_model_path := linked_model_root.path_join("model_output_v1.jsonl")
	support.expect_equal(_create_link(outside_model, linked_model_path), OK, "model output symlink should be created")
	_register_cleanup_target_check(linked_model_root, outside_model)
	errors = model_source.open(linked_model_root)
	support.expect(_contains(errors, "model_output_v1.jsonl") and _contains(errors, "link"), "open should identify and reject linked model output before reading it")
	support.expect_equal(model_source.get_manifest().get("dataset_id"), model_baseline_dataset, "linked model rejection should preserve the prior source")
	DirAccess.remove_absolute(model_baseline_root.path_join("frames/frame_000000.png"))
	support.expect(model_source.load_texture(0) == model_cached_texture, "linked model rejection should preserve the prior frame cache")


static func _make_one_frame_source(root: String, image_width: int, image_height: int) -> void:
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(image_width, image_height, false, Image.FORMAT_RGBA8)
	image.fill(Color.GREEN)
	image.save_png(root.path_join("frames/frame_000000.png"))
	_write_json(root.path_join("manifest.json"), _base_manifest(root.get_file(), "none", 8, 6))


static func _test_versioned_model_output_selection(support: TestSupport) -> void:
	var valid_root := _new_temp_path("versioned-model")
	_make_one_frame_source(valid_root, 8, 6)
	var manifest := _base_manifest("versioned-model", "model_output_v1", 8, 6)
	manifest["source_name"] = "sample_v1"
	_write_json(valid_root.path_join("manifest.json"), manifest)
	_write_text(valid_root.path_join("model_output_v1.jsonl"), JSON.stringify(_model_record("sample_v1")) + "\n")
	var source = SOURCE_SCRIPT.new()
	support.expect_equal(source.open(valid_root), PackedStringArray(), "model_output_v1 should load its same-named JSONL")
	support.expect_equal(source.get_model_records()[0].get("source"), "sample_v1", "record source should identify the frame source")

	var unversioned_root := _new_temp_path("unversioned-model")
	_make_one_frame_source(unversioned_root, 8, 6)
	_write_json(unversioned_root.path_join("manifest.json"), manifest)
	_write_text(unversioned_root.path_join("model_output.jsonl"), JSON.stringify(_model_record("sample_v1")) + "\n")
	var errors: PackedStringArray = source.open(unversioned_root)
	support.expect(_contains(errors, "model_output_v1.jsonl"), "unversioned fallback must be refused")

	var future_root := _new_temp_path("future-model")
	_make_one_frame_source(future_root, 8, 6)
	var future_manifest := _base_manifest("future-model", "model_output_v2", 8, 6)
	future_manifest["source_name"] = "sample_v1"
	_write_json(future_root.path_join("manifest.json"), future_manifest)
	errors = source.open(future_root)
	support.expect(_contains(errors, "unsupported") and _contains(errors, "model_output_v2"), "legal future name must not be validated as v1")


static func _model_record(source_id: String) -> Dictionary:
	return {
		"schema_version": 1,
		"source": source_id,
		"frame": 0,
		"time_s": 0.0,
		"regions": [],
	}


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


static func _new_temp_path(label: String) -> String:
	_temp_sequence += 1
	var path := "%s%s-%d-%d-%d" % [TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec(), _temp_sequence]
	_owned_temp_paths.append(path)
	return path


static func _cleanup_owned_temp_paths(support) -> void:
	var cleanup_paths := _owned_temp_paths.duplicate()
	cleanup_paths.reverse()
	for path: String in cleanup_paths:
		if not path.begins_with(TEMP_PREFIX) or path == TEMP_PREFIX:
			support.expect(false, "refusing to clean unowned temporary path: %s" % path)
			continue
		_remove_tree_without_following_links(path)
		support.expect(not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path) and not _is_link(path), "temporary test path should be removed: %s" % path)
		for target: String in _cleanup_target_checks.get(path, []):
			support.expect(FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target), "removing a linked fixture must not remove its outside target: %s" % target)
	_owned_temp_paths.clear()
	_cleanup_target_checks.clear()


static func _remove_tree_without_following_links(path: String) -> void:
	if _is_link(path) or FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return
	if not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for directory_name: String in directory.get_directories():
		var child := path.path_join(directory_name)
		if directory.is_link(directory_name):
			DirAccess.remove_absolute(child)
		else:
			_remove_tree_without_following_links(child)
	DirAccess.remove_absolute(path)


static func _is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


static func _create_link(source: String, target: String) -> Error:
	var parent := DirAccess.open(target.get_base_dir())
	if parent == null:
		return ERR_CANT_OPEN
	return parent.create_link(source, target)


static func _register_cleanup_target_check(link_root: String, outside_target: String) -> void:
	var targets: Array = _cleanup_target_checks.get(link_root, [])
	targets.append(outside_target)
	_cleanup_target_checks[link_root] = targets
