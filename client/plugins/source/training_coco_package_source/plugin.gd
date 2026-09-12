extends "res://client/pipeline/stages/source_stage.gd"

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
const CACHE_SCRIPT := preload("res://client/services/frame_cache.gd")
const PACKAGE_READER := preload("res://client/services/coco_parent_validator.gd")

var last_error := ""
var _root := ""
var _manifest: Dictionary = {}
var _frame_entries: Array[Dictionary] = []
var _records: Array[Dictionary] = []
var _artifacts: Array[Dictionary] = []
var _statistics: Dictionary = {}
var _cache = CACHE_SCRIPT.new(12)


func can_open(locator: String) -> bool:
	var root := ProjectSettings.globalize_path(locator).simplify_path().trim_suffix("/")
	if not DirAccess.dir_exists_absolute(root) or _path_is_link(root):
		return false
	var manifest_path := root.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path) or _path_is_link(manifest_path):
		return false
	var value: Variant = EXACT_JSON.parse_string(
		FileAccess.get_file_as_string(manifest_path))
	return value is Dictionary and value.get(
		"package_type") == "training_coco_v1"


func open(locator: String) -> PackedStringArray:
	return open_with_token(locator, null)


func open_with_token(locator: String, token: Variant) -> PackedStringArray:
	var root := ProjectSettings.globalize_path(locator).simplify_path().trim_suffix("/")
	if not can_open(root):
		return _fail(PackedStringArray([
			"Directory is not a training_coco_v1 package: %s" % root]))
	var result: Dictionary = PACKAGE_READER.read_source_projection(root, token)
	if bool(result.get("cancelled", false)):
		return _fail(PackedStringArray(["Training COCO package opening cancelled"]))
	var errors := PackedStringArray()
	for value: Variant in result.get("errors", []):
		errors.append(String(value))
	if not bool(result.get("success", false)) or not errors.is_empty():
		if errors.is_empty():
			errors.append("Training COCO package reader failed")
		return _fail(errors)
	var projection_value: Variant = result.get("projection")
	if not projection_value is Dictionary:
		return _fail(PackedStringArray(["Training COCO source projection is invalid"]))
	var projection := projection_value as Dictionary
	for field: String in [
		"manifest", "frame_entries", "records", "artifacts", "statistics",
	]:
		if not projection.has(field):
			return _fail(PackedStringArray([
				"Training COCO source projection is missing %s" % field]))
	if (
		not projection.manifest is Dictionary
		or not projection.frame_entries is Array
		or not projection.records is Array
		or not projection.artifacts is Array
		or not projection.statistics is Dictionary
		or projection.frame_entries.is_empty()
		or projection.frame_entries.size() != projection.records.size()
	):
		return _fail(PackedStringArray(["Training COCO source projection has invalid fields"]))
	_root = root
	_manifest = projection.manifest.duplicate(true)
	_frame_entries.assign(projection.frame_entries)
	_records.assign(projection.records)
	_artifacts.assign(projection.artifacts)
	_statistics = projection.statistics.duplicate(true)
	_cache.clear()
	last_error = ""
	return PackedStringArray()


func get_frame_count() -> int:
	return _frame_entries.size()


func get_frame_entry(index: int) -> Dictionary:
	if index < 0 or index >= _frame_entries.size():
		return {}
	return _frame_entries[index].duplicate(true)


func get_model_records() -> Array[Dictionary]:
	return _records.duplicate(true)


func get_manifest() -> Dictionary:
	return _manifest.duplicate(true)


func get_presentation() -> Dictionary:
	if _root.is_empty() or _manifest.is_empty():
		return {}
	var frames: Array[Dictionary] = []
	for index in range(_frame_entries.size()):
		var entry: Dictionary = _frame_entries[index]
		var relative_path := String(entry.image_path)
		frames.append({
			"index": index,
			"frame_id": int(entry.frame_id),
			"label": relative_path.get_file(),
			"path": _root.path_join(relative_path),
		})
	return {
		"display_name": String(_manifest.get("source_name", _root.get_file())),
		"source_path": _root,
		"frames": frames,
		"artifacts": _artifacts.duplicate(true),
	}


func load_texture(index: int) -> Texture2D:
	last_error = ""
	if index < 0 or index >= _frame_entries.size():
		last_error = "Training package frame index %d is out of range" % index
		return null
	var value: Variant = _cache.get_value(index, _load_texture_uncached)
	if value == null:
		if last_error.is_empty():
			last_error = _cache.last_error
		return null
	return value as Texture2D


func load_image_snapshot_uncached(index: int) -> Image:
	last_error = ""
	if index < 0 or index >= _frame_entries.size():
		last_error = "Training package frame index %d is out of range" % index
		return null
	var texture := _load_texture_uncached(index)
	return texture.get_image() if texture != null else null


func get_import_statistics() -> Dictionary:
	return _statistics.duplicate(true)


func close() -> void:
	_root = ""
	_manifest.clear()
	_frame_entries.clear()
	_records.clear()
	_artifacts.clear()
	_statistics.clear()
	_cache.clear()
	last_error = ""


func _load_texture_uncached(index: int) -> Texture2D:
	var entry: Dictionary = _frame_entries[index]
	var relative_path := String(entry.image_path)
	if not _safe_relative_path(relative_path):
		last_error = "Training package frame %d path is unsafe" % entry.frame_id
		return null
	var first_segment := relative_path.get_slice("/", 0)
	if _path_is_link(_root.path_join(first_segment)):
		last_error = "Training package image directory became symbolic"
		return null
	var absolute := _root.path_join(relative_path)
	if _path_is_link(absolute) or not FileAccess.file_exists(absolute):
		last_error = "Training package frame %d is missing or unsafe: %s" % [
			entry.frame_id, relative_path]
		return null
	var image := Image.new()
	if image.load(absolute) != OK or image.is_empty():
		last_error = "Training package frame %d is corrupt: %s" % [
			entry.frame_id, relative_path]
		return null
	return ImageTexture.create_from_image(image)


func _safe_relative_path(path: String) -> bool:
	if path.is_empty() or path.is_absolute_path() or "\\" in path or ":" in path:
		return false
	for segment: String in path.split("/", true):
		if segment.is_empty() or segment == "." or segment == "..":
			return false
	return true


func _path_is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


func _fail(errors: PackedStringArray) -> PackedStringArray:
	last_error = errors[0] if not errors.is_empty() else "Training COCO source failed"
	return errors
