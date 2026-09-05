extends RefCounted

const SOURCE_PATH := "res://client/workspace/workspace_sequence_source.gd"
const TEMP_PREFIX := "/tmp/annotool-workspace-sequence-"


func run(support) -> void:
	var script := ResourceLoader.load(SOURCE_PATH, "Script") as Script
	support.expect(script != null,
		"WorkspaceSequenceSource should map sparse frame IDs to ordered playback")
	if script == null:
		return
	var root := "%s%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	_save_image(root.path_join("000023.png"), Color.BLUE)
	_save_image(root.path_join("000016.png"), Color.RED)

	var source = script.new()
	support.expect_equal(source.open_for_media(root, "VID68", 1.0), PackedStringArray(),
		"numeric image sequence should open without decoding all textures")
	support.expect_equal(source.get_frame_count(), 2,
		"sequence should expose its exact ordered item count")
	support.expect_equal(source.get_frame_entry(0), {
		"frame": 0,
		"frame_id": 16,
		"time_s": 16.0,
		"image_path": "000016.png",
	}, "first playback item should retain sparse original frame ID 16")
	support.expect_equal(source.get_frame_entry(1).get("frame_id"), 23,
		"numeric ordering must not use lexicographic insertion order")
	var records: Array = source.get_model_records()
	support.expect_equal([records[0].get("frame"), records[1].get("frame")], [16, 23],
		"display records should be keyed by original frame IDs")
	support.expect_equal(records[0].get("source"), "VID68",
		"display records should use the catalog's stable media ID")
	var texture: Texture2D = source.load_texture(0)
	support.expect(texture != null and texture.get_width() == 8 and texture.get_height() == 6,
		"selected sequence frame should load on demand")

	_write_text(root.path_join("000023.png"), "corrupt after open")
	support.expect(source.load_texture(1) == null and "corrupt" in source.last_error,
		"open should not have eagerly decoded an unselected sequence frame")
	support.expect_equal(source.get_frame_entry(0).get("frame_id"), 16,
		"failed later texture load should preserve accepted sequence metadata")
	source.close()
	support.expect_equal(source.get_frame_count(), 0,
		"close should clear sequence state")
	_remove_tree(root)


func _save_image(path: String, color: Color) -> void:
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
	DirAccess.remove_absolute(path)
