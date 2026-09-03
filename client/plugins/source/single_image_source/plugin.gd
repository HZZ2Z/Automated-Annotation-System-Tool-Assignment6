extends RefCounted

const SUPPORTED_EXTENSIONS := ["png", "jpg", "jpeg"]

var last_error := ""
var _path := ""
var _manifest: Dictionary = {}
var _record: Dictionary = {}
var _image: Image
var _texture: Texture2D


func open(path: String) -> PackedStringArray:
	close()
	var errors := PackedStringArray()
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	if DirAccess.dir_exists_absolute(absolute):
		errors.append("Single-image source expects a PNG or JPEG file, not a directory")
		return _fail(errors)
	if not FileAccess.file_exists(absolute):
		errors.append("Image file does not exist: %s" % absolute)
		return _fail(errors)
	var extension := absolute.get_extension().to_lower()
	if extension not in SUPPORTED_EXTENSIONS:
		errors.append("Unsupported image extension: .%s" % extension)
		return _fail(errors)

	var candidate_image := Image.new()
	var image_error := candidate_image.load(absolute)
	if image_error != OK or candidate_image.is_empty():
		errors.append("Image is corrupt or unreadable: %s" % absolute.get_file())
		return _fail(errors)
	if candidate_image.get_width() <= 0 or candidate_image.get_height() <= 0:
		errors.append("Image dimensions must be positive")
		return _fail(errors)
	var digest := FileAccess.get_sha256(absolute)
	if digest.length() != 64:
		errors.append("Image SHA-256 could not be calculated")
		return _fail(errors)

	var dataset_id := _safe_dataset_id(absolute.get_file().get_basename())
	var candidate_manifest := {
		"schema_version": 1,
		"dataset_id": dataset_id,
		"source_name": absolute.get_file(),
		"source_sha256": digest,
		"width": candidate_image.get_width(),
		"height": candidate_image.get_height(),
		"frame_count": 1,
		"nominal_fps": 1.0,
		"frames": [{"frame": 0, "time_s": 0.0, "image_path": absolute.get_file()}],
		"model_version": "none",
		"taxonomy_version": "v1",
	}
	var candidate_record := {
		"schema_version": 1,
		"source": absolute.get_file(),
		"frame": 0,
		"time_s": 0.0,
		"regions": [],
	}

	_path = absolute
	_image = candidate_image
	_texture = ImageTexture.create_from_image(_image)
	_manifest = candidate_manifest
	_record = candidate_record
	last_error = ""
	return PackedStringArray()


func get_frame_count() -> int:
	return 1 if not _path.is_empty() else 0


func get_frame_entry(index: int) -> Dictionary:
	if index != 0 or _manifest.is_empty():
		return {}
	return (_manifest["frames"][0] as Dictionary).duplicate(true)


func get_model_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _record.is_empty():
		result.append(_record.duplicate(true))
	return result


func get_manifest() -> Dictionary:
	return _manifest.duplicate(true)


func load_texture(index: int) -> Texture2D:
	last_error = ""
	if _path.is_empty():
		last_error = "single-image source is closed"
		return null
	if index != 0:
		last_error = "frame index %d is out of range" % index
		return null
	return _texture


func close() -> void:
	_path = ""
	_manifest.clear()
	_record.clear()
	_texture = null
	_image = null
	last_error = ""


func _fail(errors: PackedStringArray) -> PackedStringArray:
	last_error = errors[0] if not errors.is_empty() else "single-image source failed"
	return errors


func _safe_dataset_id(value: String) -> String:
	var result := ""
	var previous_separator := false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		var is_ascii_letter := (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var is_digit := code >= 48 and code <= 57
		if is_ascii_letter or is_digit:
			result += value.substr(index, 1).to_lower()
			previous_separator = false
		elif not result.is_empty() and not previous_separator:
			result += "_"
			previous_separator = true
	while result.ends_with("_"):
		result = result.left(-1)
	return result if not result.is_empty() else "single_image"
