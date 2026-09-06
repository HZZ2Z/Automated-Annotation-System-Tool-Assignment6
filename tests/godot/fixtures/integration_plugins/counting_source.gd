extends RefCounted

static var mode := "valid"
static var open_count := 0
static var close_count := 0


static func reset(next_mode: String = "valid") -> void:
	mode = next_mode
	open_count = 0
	close_count = 0


func can_open(_locator: String) -> bool:
	return true


func open(_path: String):
	open_count += 1
	if mode == "open_error":
		return PackedStringArray(["fixture open failure"])
	return PackedStringArray()


func get_frame_count():
	if mode == "frame_count_wrong_type":
		return "one"
	if mode in ["frame_count_mismatch", "valid_two", "valid_sparse", "records_count_mismatch", "records_hole", "entry_second_bad_frame", "entry_second_bad_time", "entry_second_remapped"]:
		return 2
	return 1


func get_frame_entry(index: int):
	if mode == "entry_wrong_type":
		return []
	if mode == "entry_bad_time":
		return {"frame": 0, "time_s": "not-a-number", "image_path": "fixture.png"}
	if mode == "entry_second_bad_frame" and index == 1:
		return {"frame": 0, "time_s": 2.5, "image_path": "fixture.png"}
	if mode == "entry_second_bad_time" and index == 1:
		return {"frame": 1, "time_s": NAN, "image_path": "fixture.png"}
	if mode in ["valid_sparse", "entry_second_remapped"]:
		return {
			"frame": index,
			"frame_id": 16 if index == 0 or mode == "entry_second_remapped" else 23,
			"time_s": 1.25 + float(index),
			"image_path": "fixture.png",
		}
	return {"frame": index, "time_s": 1.25 + float(index), "image_path": "fixture.png"}


func get_model_records():
	if mode == "records_wrong_type":
		return {}
	var records := [{
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"time_s": 1.25,
		"regions": [],
	}]
	if mode in ["valid_two", "valid_sparse", "records_hole", "entry_second_bad_frame", "entry_second_bad_time", "entry_second_remapped"]:
		records.append({
			"schema_version": 1,
			"source": "sample_v1",
			"frame": (
				2 if mode == "records_hole"
				else 23 if mode in ["valid_sparse", "entry_second_remapped"]
				else 1),
			"time_s": 2.25,
			"regions": [],
		})
	if mode in ["valid_sparse", "entry_second_remapped"]:
		records[0]["frame"] = 16
	return records


func get_manifest():
	if mode == "manifest_wrong_type":
		return []
	if mode == "manifest_empty":
		return {}
	var fps: Variant = 20.0
	if mode == "manifest_bad_fps":
		fps = 0.0
	var count := 2 if mode in ["valid_two", "valid_sparse", "records_count_mismatch", "records_hole", "entry_second_bad_frame", "entry_second_bad_time", "entry_second_remapped"] else 1
	var frames: Array[Dictionary] = []
	for index in range(count):
		frames.append({
			"frame": index,
			"time_s": 1.25 + float(index),
			"image_path": "fixture_%06d.png" % index,
		})
	return {
		"dataset_id": "counting-source",
		"frame_count": count,
		"nominal_fps": fps,
		"frames": frames,
	}


func get_presentation() -> Dictionary:
	var count_value: Variant = get_frame_count()
	var count := int(count_value) if typeof(count_value) == TYPE_INT else 1
	var frames: Array[Dictionary] = []
	for index in range(count):
		frames.append({"index": index, "label": "Fixture %d" % index, "path": "fixture://counting/%d" % index})
	return {
		"display_name": "Counting fixture",
		"source_path": "fixture://counting",
		"frames": frames,
		"artifacts": [],
	}


func load_texture(_index: int):
	if mode == "texture_wrong_type":
		return "not-a-texture"
	var image := Image.create(40, 30, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_BLUE)
	return ImageTexture.create_from_image(image)


func close() -> void:
	close_count += 1
