extends "res://client/pipeline/stages/source_stage.gd"


const CACHE_SCRIPT := preload("res://client/services/frame_cache.gd")
const PATHS_SCRIPT := preload("res://client/workspace/workspace_paths.gd")
const IMAGE_EXTENSIONS := {"jpeg": true, "jpg": true, "png": true}


var last_error := ""
var _root := ""
var _media_id := ""
var _nominal_fps := 1.0
var _manifest: Dictionary = {}
var _records: Array[Dictionary] = []
var _cache = CACHE_SCRIPT.new(12)
var _expected_size := Vector2i.ZERO


func can_open(locator: String) -> bool:
	var root := ProjectSettings.globalize_path(locator).simplify_path().trim_suffix("/")
	return DirAccess.dir_exists_absolute(root)


func open(locator: String) -> PackedStringArray:
	var root := ProjectSettings.globalize_path(locator).simplify_path().trim_suffix("/")
	return open_for_media(root, PATHS_SCRIPT.portable_media_id(root.get_file()), 1.0)


func open_for_media(
	locator: String,
	media_id_value: String,
	nominal_fps: float = 1.0
) -> PackedStringArray:
	var errors := PackedStringArray()
	var root := ProjectSettings.globalize_path(locator).simplify_path().trim_suffix("/")
	if not DirAccess.dir_exists_absolute(root):
		return _fail(PackedStringArray(["Image-sequence directory does not exist: %s" % root]))
	if not PATHS_SCRIPT.is_portable_media_id(media_id_value):
		return _fail(PackedStringArray(["Image-sequence media ID is not portable: %s" % media_id_value]))
	if not is_finite(nominal_fps) or nominal_fps <= 0.0:
		return _fail(PackedStringArray(["Image-sequence FPS must be finite and positive"]))

	var directory := DirAccess.open(root)
	if directory == null:
		return _fail(PackedStringArray(["Cannot read image-sequence directory: %s" % root]))
	var entries: Array[Dictionary] = []
	var frame_ids := {}
	for file_name: String in directory.get_files():
		if file_name.begins_with(".") or directory.is_link(file_name):
			continue
		if not IMAGE_EXTENSIONS.has(file_name.get_extension().to_lower()):
			continue
		var stem := file_name.get_basename()
		if not _is_decimal(stem):
			continue
		var frame_id := int(stem)
		if frame_id < 0 or frame_id > 999999:
			errors.append("Sequence frame ID is outside 000000-999999: %s" % file_name)
		elif frame_ids.has(frame_id):
			errors.append(
				"Sequence has duplicate numeric frame ID %d: %s and %s" % [
					frame_id, frame_ids[frame_id], file_name])
		else:
			frame_ids[frame_id] = file_name
			entries.append({
				"frame_id": frame_id,
				"image_path": file_name,
			})
	if entries.size() < 2:
		errors.append("Image sequence requires at least two numeric image files")
	if not errors.is_empty():
		return _fail(errors)
	entries.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return int(left["frame_id"]) < int(right["frame_id"])
	)

	var manifest_frames: Array[Dictionary] = []
	var records: Array[Dictionary] = []
	for playback_index in range(entries.size()):
		var value: Dictionary = entries[playback_index]
		var frame_id: int = value["frame_id"]
		var time_s := float(frame_id) / nominal_fps
		manifest_frames.append({
			"frame": playback_index,
			"frame_id": frame_id,
			"time_s": time_s,
			"image_path": value["image_path"],
		})
		records.append({
			"schema_version": 1,
			"source": media_id_value,
			"frame": frame_id,
			"time_s": time_s,
			"regions": [],
		})
	var manifest := {
		"schema_version": 1,
		"dataset_id": media_id_value,
		"source_name": root.get_file(),
		"source_sha256": null,
		"frame_count": manifest_frames.size(),
		"nominal_fps": nominal_fps,
		"frames": manifest_frames,
		"model_version": "none",
		"taxonomy_version": "v1",
	}

	_root = root
	_media_id = media_id_value
	_nominal_fps = nominal_fps
	_manifest = manifest
	_records = records
	_cache.clear()
	_expected_size = Vector2i.ZERO
	last_error = ""
	return PackedStringArray()


func get_frame_count() -> int:
	return int(_manifest.get("frame_count", 0))


func get_frame_entry(index: int) -> Dictionary:
	if index < 0 or index >= get_frame_count():
		return {}
	return (_manifest["frames"][index] as Dictionary).duplicate(true)


func get_model_records() -> Array[Dictionary]:
	return _records.duplicate(true)


func get_manifest() -> Dictionary:
	return _manifest.duplicate(true)


func get_presentation() -> Dictionary:
	if _root.is_empty():
		return {}
	var frames: Array[Dictionary] = []
	for index in range(get_frame_count()):
		var entry := _manifest["frames"][index] as Dictionary
		frames.append({
			"index": index,
			"frame_id": entry["frame_id"],
			"label": entry["image_path"],
			"path": _root.path_join(entry["image_path"]),
		})
	return {
		"display_name": _media_id,
		"source_path": _root,
		"frames": frames,
		"artifacts": [],
	}


func load_texture(index: int) -> Texture2D:
	last_error = ""
	if index < 0 or index >= get_frame_count():
		last_error = "sequence playback index %d is out of range" % index
		return null
	var value: Variant = _cache.get_value(index, _load_texture_uncached)
	if value == null:
		if last_error.is_empty():
			last_error = _cache.last_error
		return null
	return value as Texture2D


func close() -> void:
	_root = ""
	_media_id = ""
	_manifest.clear()
	_records.clear()
	_cache.clear()
	_expected_size = Vector2i.ZERO
	last_error = ""


func _load_texture_uncached(index: int) -> Texture2D:
	var entry := _manifest["frames"][index] as Dictionary
	var image_path: String = entry["image_path"]
	var directory := DirAccess.open(_root)
	if directory == null or directory.is_link(image_path):
		last_error = "sequence frame %d path is unsafe" % entry["frame_id"]
		return null
	var absolute := _root.path_join(image_path)
	if not FileAccess.file_exists(absolute):
		last_error = "sequence frame %d is missing: %s" % [entry["frame_id"], image_path]
		return null
	var image := Image.new()
	if image.load(absolute) != OK or image.is_empty():
		last_error = "sequence frame %d image is corrupt or unreadable: %s" % [
			entry["frame_id"], image_path]
		return null
	var size := Vector2i(image.get_width(), image.get_height())
	if _expected_size == Vector2i.ZERO:
		_expected_size = size
	elif size != _expected_size:
		last_error = "sequence frame %d dimensions %s do not match %s" % [
			entry["frame_id"], size, _expected_size]
		return null
	return ImageTexture.create_from_image(image)


func _is_decimal(value: String) -> bool:
	if value.is_empty():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true


func _fail(errors: PackedStringArray) -> PackedStringArray:
	last_error = errors[0] if not errors.is_empty() else "Image sequence failed"
	return errors
