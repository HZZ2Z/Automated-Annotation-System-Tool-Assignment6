extends RefCounted

const SOURCE_SCRIPT := preload("res://client/plugins/source/image_sequence_source/plugin.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const FEEDBACK_SCRIPT := preload("res://client/plugins/feedback/file_training_handoff/plugin.gd")
const TEMP_PREFIX := "/tmp/annotool-part1-1-immutability-"


static func run(support: TestSupport) -> void:
	var root := "%s%d-%d" % [TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root.path_join("frames"))
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_GREEN)
	support.expect_equal(image.save_png(root.path_join("frames/frame_000000.png")), OK, "fixture frame should save")
	var manifest := {
		"schema_version": 1,
		"dataset_id": "immutability-fixture",
		"source_name": "sample_v1",
		"source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"width": 8,
		"height": 6,
		"frame_count": 1,
		"nominal_fps": 30.0,
		"frames": [{"frame": 0, "time_s": 0.0, "image_path": "frames/frame_000000.png"}],
		"model_version": "model_output_v1",
		"taxonomy_version": "none",
	}
	var model_record := {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"time_s": 0.0,
		"regions": [
			{
				"id": "reg-1",
				"class": "grasper",
				"kind": "instrument",
				"box": [1, 1, 2, 2],
			}
		],
	}
	_write_text(root.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n")
	var model_path := root.path_join("model_output_v1.jsonl")
	_write_text(model_path, JSON.stringify(model_record) + "\n")
	var before_hash := FileAccess.get_sha256(model_path)
	var source = SOURCE_SCRIPT.new()
	support.expect_equal(source.open(root), PackedStringArray(), "versioned model output should open")
	var store = STORE_SCRIPT.new()
	support.expect_equal(store.load_model_records(source.get_model_records()), PackedStringArray(), "source records should load")
	var corrected := store.get_corrected_record(0)
	corrected["regions"][0]["class"] = "reviewed"
	support.expect_equal(store.replace_corrected_record(0, corrected), PackedStringArray(), "corrected edit should apply")
	var feedback = FEEDBACK_SCRIPT.new()
	support.expect_equal(
		feedback.export({
			"records": store.snapshot_corrected(),
			"output_path": root.path_join("training_update_v1"),
			"source_manifest": manifest,
			"model_digest": store.model_digest(),
			"dirty_frames": [0],
			"batch_operations": [],
		}),
		PackedStringArray(),
		"corrected export should succeed at a different path",
	)
	support.expect_equal(FileAccess.get_sha256(model_path), before_hash, "load, edit and export must not modify model_output_v1.jsonl")
	_remove_tree(root)


static func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)


static func _remove_tree(path: String) -> void:
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
