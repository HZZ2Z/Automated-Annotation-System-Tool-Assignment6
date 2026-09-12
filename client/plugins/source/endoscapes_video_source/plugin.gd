extends "res://client/pipeline/stages/source_stage.gd"

const DATASET_SCRIPT := preload(
	"res://client/plugins/source/endoscapes_video_source/endoscapes_dataset.gd")
const CACHE_SCRIPT := preload("res://client/services/frame_cache.gd")

var last_error := ""
var _root := ""
var _split_root := ""
var _split := ""
var _video_id := -1
var _manifest: Dictionary = {}
var _frame_entries: Array[Dictionary] = []
var _records: Array[Dictionary] = []
var _import_statistics: Dictionary = {}
var _export_metadata: Dictionary = {}
var _cache = CACHE_SCRIPT.new(12)
var _expected_size := Vector2i.ZERO


func can_open(locator: String) -> bool:
	return not DATASET_SCRIPT.new().inspect_locator(locator).is_empty()


func discover_workspace_media(root: String, token: Variant) -> Dictionary:
	return DATASET_SCRIPT.new().discover(root, token)


func open(locator: String) -> PackedStringArray:
	return open_with_token(locator, null)


func open_with_token(locator: String, token: Variant) -> PackedStringArray:
	close()
	var prepared: Dictionary = DATASET_SCRIPT.new().prepare_video(locator, token)
	var errors: PackedStringArray = prepared.get("errors", PackedStringArray([
		"Endoscapes preparation returned no error contract"]))
	if not errors.is_empty() or not bool(prepared.get("ok", false)):
		return _fail(errors if not errors.is_empty() else PackedStringArray([
			"Endoscapes video preparation failed"]))
	var context: Dictionary = prepared.context
	_root = String(context.root)
	_split_root = String(context.split_root)
	_split = String(context.split)
	_video_id = int(context.video_id)
	_manifest = prepared.manifest.duplicate(true)
	_frame_entries.assign(prepared.frame_entries)
	_records.assign(prepared.records)
	_import_statistics = prepared.get("statistics", {}).duplicate(true)
	_export_metadata = prepared.get("export_metadata", {}).duplicate(true)
	_cache.clear()
	_expected_size = Vector2i.ZERO
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
	if _manifest.is_empty():
		return {}
	var frames: Array[Dictionary] = []
	for index in range(_frame_entries.size()):
		var entry := _frame_entries[index]
		frames.append({
			"index": index,
			"frame_id": entry.frame_id,
			"label": entry.image_path,
			"path": _split_root.path_join(String(entry.image_path)),
		})
	return {
		"display_name": _manifest.get("source_name", "Endoscapes video"),
		"source_path": _split_root,
		"frames": frames,
		"artifacts": [{
			"kind": "source_annotations",
			"label": "annotation_coco.json",
			"path": _split_root.path_join("annotation_coco.json"),
		}],
	}


func load_texture(index: int) -> Texture2D:
	last_error = ""
	if index < 0 or index >= _frame_entries.size():
		last_error = "Endoscapes playback index %d is out of range" % index
		return null
	var value: Variant = _cache.get_value(index, _load_texture_uncached)
	if value == null:
		if last_error.is_empty():
			last_error = _cache.last_error
		return null
	return value as Texture2D


func get_cache_size() -> int:
	return _cache.size()


func get_retained_frame_path_count() -> int:
	return _frame_entries.size()


func get_import_statistics() -> Dictionary:
	return _import_statistics.duplicate(true)


## Optional Source capability. The returned value contains no Object, Texture,
## Store or cache reference and may be serialized for a background worker.
func get_export_descriptor() -> Dictionary:
	if _root.is_empty() or _split_root.is_empty() or _frame_entries.is_empty():
		return {}
	var frames: Array[Dictionary] = []
	for index in range(_frame_entries.size()):
		var entry: Dictionary = _frame_entries[index]
		var file_name := String(entry.image_path)
		frames.append({
			"source_frame_id": int(entry.frame_id),
			"source_playback_index": index,
			"file_name": file_name,
			"source_path": _split_root.path_join(file_name),
		})
	var metadata_files: Array[Dictionary] = []
	for definition: Dictionary in [
		{"role": "detection", "name": "annotation_coco.json"},
		{"role": "video", "name": "annotation_coco_vid.json"},
		{"role": "ds", "name": "annotation_ds_coco.json"},
	]:
		var path := _split_root.path_join(String(definition.name))
		if FileAccess.file_exists(path) and not DATASET_SCRIPT.new()._path_is_link(path):
			metadata_files.append({"role": definition.role, "path": path})
	var descriptor := {
		"schema_version": 1,
		"source_type": "endoscapes_coco",
		"dataset_namespace": "endoscapes2023",
		"dataset_root": _root,
		"source_split": _split,
		"video_id": _video_id,
		"frames": frames,
		"metadata_files": metadata_files,
		"import_bindings": _export_metadata.get("import_bindings", []).duplicate(true),
		"import_issues": _export_metadata.get("import_issues", []).duplicate(true),
	}
	return descriptor.duplicate(true)


func close() -> void:
	_root = ""
	_split_root = ""
	_split = ""
	_video_id = -1
	_manifest.clear()
	_frame_entries.clear()
	_records.clear()
	_import_statistics.clear()
	_export_metadata.clear()
	_cache.clear()
	_expected_size = Vector2i.ZERO
	last_error = ""


## 可选完整性边界：每次从 Source 自有路径重读，不查询或更新播放缓存。
func load_image_snapshot_uncached(index: int) -> Image:
	last_error = ""
	if index < 0 or index >= get_frame_count():
		last_error = "Endoscapes playback index %d is out of range" % index
		return null
	var texture := _load_texture_uncached(index)
	return texture.get_image() if texture != null else null


func _load_texture_uncached(index: int) -> Texture2D:
	var entry := _frame_entries[index]
	var file_name := String(entry.image_path)
	var directory := DirAccess.open(_split_root)
	if directory == null or directory.is_link(file_name):
		last_error = "Endoscapes frame %d path is unsafe" % entry.frame_id
		return null
	var absolute := _split_root.path_join(file_name)
	if not FileAccess.file_exists(absolute):
		last_error = "Endoscapes frame %d is missing: %s" % [entry.frame_id, file_name]
		return null
	var image := Image.new()
	if image.load(absolute) != OK or image.is_empty():
		last_error = "Endoscapes frame %d is corrupt: %s" % [entry.frame_id, file_name]
		return null
	var size := Vector2i(image.get_width(), image.get_height())
	if _expected_size == Vector2i.ZERO:
		_expected_size = size
	elif size != _expected_size:
		last_error = "Endoscapes frame %d dimensions %s do not match %s" % [
			entry.frame_id, size, _expected_size]
		return null
	return ImageTexture.create_from_image(image)


func _fail(errors: PackedStringArray) -> PackedStringArray:
	last_error = errors[0] if not errors.is_empty() else "Endoscapes Source failed"
	return errors
