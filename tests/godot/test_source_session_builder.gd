extends RefCounted

const BUILDER_PATH := "res://client/pipeline/source_session_builder.gd"


class SparseSource extends RefCounted:
	var manifest := {
		"schema_version": 1,
		"dataset_id": "VID68",
		"source_name": "VID68",
		"source_sha256": null,
		"frame_count": 2,
		"nominal_fps": 1.0,
		"model_version": "none",
		"taxonomy_version": "v1",
	}
	var entries: Array[Dictionary] = [
		{"frame": 0, "frame_id": 16, "time_s": 16.0, "image_path": "000016.png"},
		{"frame": 1, "frame_id": 23, "time_s": 23.0, "image_path": "000023.png"},
	]
	var records: Array[Dictionary] = [
		{"schema_version": 1, "source": "VID68", "frame": 16, "time_s": 16.0, "regions": []},
		{"schema_version": 1, "source": "VID68", "frame": 23, "time_s": 23.0, "regions": []},
	]
	var texture: Texture2D

	func _init() -> void:
		var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
		image.fill(Color.DARK_RED)
		texture = ImageTexture.create_from_image(image)

	func get_frame_count() -> int:
		return entries.size()

	func get_manifest() -> Dictionary:
		return manifest.duplicate(true)

	func get_model_records() -> Array[Dictionary]:
		return records.duplicate(true)

	func get_frame_entry(index: int) -> Dictionary:
		return entries[index].duplicate(true)

	func load_texture(_index: int) -> Texture2D:
		return texture

	func get_presentation() -> Dictionary:
		return {
			"display_name": "VID68",
			"source_path": "/tmp/VID68",
			"frames": [],
			"artifacts": [],
		}


func run(support) -> void:
	var builder_script := ResourceLoader.load(BUILDER_PATH, "Script") as Script
	support.expect(builder_script != null,
		"SourceSessionBuilder should own common Source output validation")
	if builder_script == null:
		return
	var builder = builder_script.new()
	var source := SparseSource.new()
	var result: Dictionary = builder.build(source, false)
	support.expect_equal(result.get("errors"), PackedStringArray(),
		"builder should accept unique sparse original frame ids")
	support.expect_equal(result.get("frame_entries", [])[0].get("frame"), 0,
		"builder should retain a continuous playback index")
	support.expect_equal(result.get("frame_entries", [])[0].get("frame_id"), 16,
		"builder should retain the first original frame id")
	support.expect_equal(result.get("frame_entries", [])[1].get("frame_id"), 23,
		"builder should retain the second original frame id")
	support.expect_equal(result.get("records", [])[1].get("frame"), 23,
		"builder should align model records to original frame ids")
	support.expect_equal(result.get("playback_frames"), [
		{"frame": 0, "time_s": 16.0},
		{"frame": 1, "time_s": 23.0},
	], "builder should expose playback-only entries without renumbering records")

	(result["frame_entries"][0] as Dictionary)["frame_id"] = 99
	(result["records"][0] as Dictionary)["frame"] = 99
	(result["manifest"] as Dictionary)["dataset_id"] = "mutated"
	support.expect_equal(source.entries[0]["frame_id"], 16,
		"snapshot frame entries should not alias Source state")
	support.expect_equal(source.records[0]["frame"], 16,
		"snapshot records should not alias Source state")
	support.expect_equal(source.manifest["dataset_id"], "VID68",
		"snapshot manifest should not alias Source state")

	var duplicate := SparseSource.new()
	duplicate.entries[1]["frame_id"] = 16
	support.expect(_contains(builder.build(duplicate, false).get("errors", []),
		"repeats original frame"),
		"builder should reject duplicate original frame ids")

	var mismatch := SparseSource.new()
	mismatch.records[1]["frame"] = 22
	support.expect(_contains(builder.build(mismatch, false).get("errors", []),
		"original frame 23"),
		"builder should reject a record mapped to the wrong original frame")

	var bad_fps := SparseSource.new()
	bad_fps.manifest["nominal_fps"] = 0.0
	support.expect(_contains(builder.build(bad_fps, false).get("errors", []),
		"nominal_fps"),
		"builder should reject a non-positive source clock")

	var missing_texture := SparseSource.new()
	missing_texture.texture = null
	support.expect(_contains(
		builder.build(missing_texture, false).get("errors", []), "texture"),
		"builder should reject an unreadable first frame")


func _contains(values: Variant, fragment: String) -> bool:
	if not values is PackedStringArray and not values is Array:
		return false
	for value: Variant in values:
		if fragment.to_lower() in String(value).to_lower():
			return true
	return false
