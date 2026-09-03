extends "res://client/pipeline/stages/source_stage.gd"


var _opened := false


func can_open(locator: String) -> bool:
	return locator.get_extension().to_lower() == "fixture"


func open(locator: String) -> PackedStringArray:
	if not can_open(locator):
		return PackedStringArray(["fixture source expects .fixture"])
	_opened = true
	return PackedStringArray()


func get_frame_count() -> int:
	return 1 if _opened else 0


func get_frame_entry(index: int) -> Dictionary:
	return {"frame": 0, "time_s": 0.0, "image_path": "synthetic"} if _opened and index == 0 else {}


func get_model_records() -> Array[Dictionary]:
	if not _opened:
		return []
	return [{"schema_version": 1, "source": "fixture", "frame": 0, "time_s": 0.0, "regions": []}]


func get_manifest() -> Dictionary:
	return {
		"dataset_id": "fixture",
		"source_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
		"model_version": "fixture_model_v1",
		"taxonomy_version": "fixture_taxonomy_v1",
		"frame_count": 1,
		"nominal_fps": 1.0,
	} if _opened else {}


func get_presentation() -> Dictionary:
	if not _opened:
		return {}
	return {
		"display_name": "Non-filesystem fixture",
		"source_path": "fixture://case.fixture",
		"frames": [{"index": 0, "label": "Remote frame 0", "path": "fixture://case.fixture/0"}],
		"artifacts": [],
	}


func load_texture(index: int) -> Texture2D:
	if not _opened or index != 0:
		return null
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	return ImageTexture.create_from_image(image)


func close() -> void:
	_opened = false
