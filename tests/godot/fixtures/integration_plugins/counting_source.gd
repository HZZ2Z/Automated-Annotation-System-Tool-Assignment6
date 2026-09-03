extends RefCounted

static var mode := "valid"
static var open_count := 0
static var close_count := 0


static func reset(next_mode: String = "valid") -> void:
	mode = next_mode
	open_count = 0
	close_count = 0


func open(_path: String):
	open_count += 1
	if mode == "open_error":
		return PackedStringArray(["fixture open failure"])
	return PackedStringArray()


func get_frame_count():
	if mode == "frame_count_wrong_type":
		return "one"
	if mode in ["frame_count_mismatch", "valid_two", "records_count_mismatch", "records_hole", "entry_second_bad_frame", "entry_second_bad_time"]:
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
	return {"frame": index, "time_s": 1.25 + float(index), "image_path": "fixture.png"}


func get_model_records():
	if mode == "records_wrong_type":
		return {}
	var records := [{
		"schema_version": 1,
		"dataset_id": "counting-source",
		"source": "model_output_v1",
		"frame": 0,
		"time_s": 1.25,
		"image_size": [40, 30],
		"regions": [],
	}]
	if mode in ["valid_two", "records_hole", "entry_second_bad_frame", "entry_second_bad_time"]:
		records.append({
			"schema_version": 1,
			"dataset_id": "counting-source",
			"source": "model_output_v1",
			"frame": 2 if mode == "records_hole" else 1,
			"time_s": 2.25,
			"image_size": [40, 30],
			"regions": [],
		})
	return records


func get_manifest():
	if mode == "manifest_wrong_type":
		return []
	if mode == "manifest_empty":
		return {}
	var fps: Variant = 20.0
	if mode == "manifest_bad_fps":
		fps = 0.0
	var count := 2 if mode in ["valid_two", "records_count_mismatch", "records_hole", "entry_second_bad_frame", "entry_second_bad_time"] else 1
	return {"frame_count": count, "nominal_fps": fps}


func load_texture(_index: int):
	if mode == "texture_wrong_type":
		return "not-a-texture"
	var image := Image.create(40, 30, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_BLUE)
	return ImageTexture.create_from_image(image)


func close() -> void:
	close_count += 1
