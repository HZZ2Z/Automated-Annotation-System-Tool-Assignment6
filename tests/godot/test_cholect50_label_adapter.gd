extends RefCounted

const ADAPTER_PATH := "res://client/workspace/cholect50_label_adapter.gd"
const TEMP_PREFIX := "/tmp/annotool-cholect50-label-"


func run(support) -> void:
	var script := ResourceLoader.load(ADAPTER_PATH, "Script") as Script
	support.expect(script != null,
		"CholecT50 adapter should import sparse source labels without rewriting them")
	if script == null:
		return
	var root := "%s%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	var path := root.path_join("VID68.json")
	var source := {
		"video": 68,
		"fps": 1,
		"num_frames": 2,
		"categories": {"instrument": {"0": "grasper"}},
		"annotations": {
			# Column 1 is instrument; column 7 is verb and deliberately differs.
			"16": [[94, 0, 1, 0.5, 0.2, 0.3, 0.4, 9, 14, 1, -1, -1, -1, -1, 0]],
			"23": [],
		},
	}
	_write_text(path, JSON.stringify(source))
	var before := FileAccess.get_file_as_bytes(path)

	var result: Dictionary = script.new().read(
		path, "VID68", PackedInt64Array([16, 23, 30]), Vector2(1000, 500))
	support.expect_equal(result.get("errors"), PackedStringArray(),
		"compatible CholecT50 label should convert")
	var records: Dictionary = result.get("records", {})
	support.expect_equal(Array(records.keys()), [16, 23],
		"adapter should preserve labelled sparse keys and not invent frame 30")
	support.expect_equal(records[16].get("frame"), 16,
		"converted record should retain original frame ID")
	support.expect_equal(records[16].get("source"), "VID68",
		"converted record should use workspace media identity")
	support.expect_equal(records[16].get("regions")[0].get("class"), "grasper",
		"adapter should read instrument ID from CholecT50 column 1, not verb column 7")
	support.expect_equal(records[16].get("regions")[0].get("box"),
		[500.0, 100.0, 300.0, 200.0],
		"normalized source box should be converted into image pixels")
	support.expect_equal(records[23].get("regions"), [],
		"source key with no rows should remain an explicit negative")
	support.expect_equal(FileAccess.get_file_as_bytes(path), before,
		"source dataset label must remain byte-for-byte unchanged")

	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(root)


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)
