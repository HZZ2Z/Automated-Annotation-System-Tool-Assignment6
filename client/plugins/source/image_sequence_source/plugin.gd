extends "res://client/pipeline/stages/source_stage.gd"

const CACHE_SCRIPT := preload("res://client/services/frame_cache.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const MANIFEST_FIELDS := {
	"schema_version": true,
	"dataset_id": true,
	"source_name": true,
	"source_sha256": true,
	"width": true,
	"height": true,
	"frame_count": true,
	"nominal_fps": true,
	"frames": true,
	"similarity_scores": true,
	"model_version": true,
	"taxonomy_version": true,
}
const REQUIRED_MANIFEST_FIELDS := [
	"schema_version", "dataset_id", "source_name", "source_sha256", "width", "height",
	"frame_count", "nominal_fps", "frames", "model_version", "taxonomy_version",
]
const FRAME_FIELDS := {"frame": true, "time_s": true, "image_path": true}
const REQUIRED_FRAME_FIELDS := ["frame", "time_s", "image_path"]

var last_error := ""
var _root := ""
var _manifest: Dictionary = {}
var _model_records: Array[Dictionary] = []
var _cache = CACHE_SCRIPT.new(12)


func can_open(locator: String) -> bool:
	var root := ProjectSettings.globalize_path(locator).simplify_path().trim_suffix("/")
	return DirAccess.dir_exists_absolute(root)


func open(path: String) -> PackedStringArray:
	last_error = ""
	var errors := PackedStringArray()
	var root := ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	if not DirAccess.dir_exists_absolute(root):
		errors.append("source directory does not exist: %s" % path)
		return _finish_errors(errors)
	var manifest_link_error := _path_link_error(root, "manifest.json")
	if not manifest_link_error.is_empty():
		errors.append("manifest.json: %s" % manifest_link_error)
		return _finish_errors(errors)
	var manifest := _read_json_object(root.path_join("manifest.json"), "manifest", errors)
	if manifest.is_empty() and not errors.is_empty():
		return _finish_errors(errors)
	_validate_manifest(manifest, root, errors)
	if not errors.is_empty():
		return _finish_errors(errors)
	var records := _read_model_records(root, manifest, errors)
	if not errors.is_empty():
		return _finish_errors(errors)

	_root = root
	_manifest = manifest.duplicate(true)
	_model_records.clear()
	for record: Dictionary in records:
		_model_records.append(record.duplicate(true))
	_cache.clear()
	return errors


func get_frame_count() -> int:
	return int(_manifest.get("frame_count", 0))


func get_frame_entry(index: int) -> Dictionary:
	if index < 0 or index >= get_frame_count():
		return {}
	return _manifest["frames"][index].duplicate(true)


func get_model_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _model_records:
		result.append(record.duplicate(true))
	return result


func get_manifest() -> Dictionary:
	return _manifest.duplicate(true)


func get_presentation() -> Dictionary:
	if _root.is_empty() or _manifest.is_empty():
		return {}
	var frames: Array[Dictionary] = []
	for index in range(get_frame_count()):
		var entry: Dictionary = _manifest["frames"][index]
		var relative_path := str(entry["image_path"])
		frames.append({
			"index": index,
			"label": relative_path,
			"path": _root.path_join(relative_path),
		})
	var artifacts: Array[Dictionary] = [{"label": "manifest.json", "path": _root.path_join("manifest.json")}]
	var model_version := str(_manifest.get("model_version", "none"))
	if model_version != "none":
		var model_file := "%s.jsonl" % model_version
		artifacts.append({"label": model_file, "path": _root.path_join(model_file)})
	return {
		"display_name": str(_manifest.get("dataset_id", _root.get_file())),
		"source_path": _root,
		"frames": frames,
		"artifacts": artifacts,
	}


func load_texture(index: int) -> Texture2D:
	last_error = ""
	if index < 0 or index >= get_frame_count():
		last_error = "frame index %d is out of range" % index
		return null
	var value: Variant = _cache.get_value(index, _load_texture_uncached)
	if value == null:
		if last_error.is_empty():
			last_error = _cache.last_error
		return null
	return value as Texture2D


func close() -> void:
	_root = ""
	_manifest.clear()
	_model_records.clear()
	_cache.clear()
	last_error = ""


func _load_texture_uncached(index: int) -> Texture2D:
	var entry: Dictionary = _manifest["frames"][index]
	var link_error := _path_link_error(_root, entry["image_path"])
	if not link_error.is_empty():
		last_error = "frame %d path is unsafe: %s" % [index, link_error]
		return null
	var frame_path := _root.path_join(entry["image_path"])
	if not FileAccess.file_exists(frame_path):
		last_error = "frame %d file is missing: %s" % [index, entry["image_path"]]
		return null
	var image := Image.new()
	var image_error := image.load(frame_path)
	if image_error != OK:
		last_error = "frame %d image is corrupt or unreadable: %s" % [index, entry["image_path"]]
		return null
	if image.get_width() != int(_manifest["width"]) or image.get_height() != int(_manifest["height"]):
		last_error = "frame %d dimensions %dx%d do not match manifest %dx%d" % [
			index, image.get_width(), image.get_height(), int(_manifest["width"]), int(_manifest["height"]),
		]
		return null
	return ImageTexture.create_from_image(image)


func _validate_manifest(manifest: Dictionary, root: String, errors: PackedStringArray) -> void:
	for key: Variant in manifest.keys():
		if typeof(key) != TYPE_STRING or not MANIFEST_FIELDS.has(key):
			errors.append("manifest.%s: additional field is not allowed" % str(key))
	for field: String in REQUIRED_MANIFEST_FIELDS:
		if not manifest.has(field):
			errors.append("manifest.%s: required field missing" % field)

	_validate_exact_integer(manifest, "schema_version", 1, errors)
	for field: String in ["dataset_id", "source_name", "model_version", "taxonomy_version"]:
		if manifest.has(field):
			var value: Variant = manifest[field]
			if typeof(value) != TYPE_STRING or value.is_empty():
				errors.append("manifest.%s: expected non-empty string" % field)
	if manifest.has("source_sha256"):
		var digest: Variant = manifest["source_sha256"]
		if typeof(digest) != TYPE_STRING or not _is_sha256(digest):
			errors.append("manifest.source_sha256: expected 64 hexadecimal characters")
	for field: String in ["width", "height", "frame_count"]:
		if manifest.has(field):
			var value: Variant = manifest[field]
			if not _is_logical_integer(value) or value <= 0:
				errors.append("manifest.%s: expected positive integer" % field)
	if manifest.has("nominal_fps"):
		var fps: Variant = manifest["nominal_fps"]
		if not _is_finite_number(fps) or fps <= 0:
			errors.append("manifest.nominal_fps: expected finite positive number")

	var frames: Variant = manifest.get("frames")
	if not frames is Array:
		if manifest.has("frames"):
			errors.append("manifest.frames: expected array")
		return
	var frame_count := int(manifest.get("frame_count", -1)) if _is_logical_integer(manifest.get("frame_count")) else -1
	if frame_count >= 0 and frames.size() != frame_count:
		errors.append("manifest.frames: expected exactly frame_count entries")
	var previous_time := -1.0
	var paths := {}
	for index in range(frames.size()):
		var entry: Variant = frames[index]
		var entry_path := "manifest.frames.%d" % index
		if not entry is Dictionary:
			errors.append("%s: expected object" % entry_path)
			continue
		for key: Variant in entry.keys():
			if typeof(key) != TYPE_STRING or not FRAME_FIELDS.has(key):
				errors.append("%s.%s: additional field is not allowed" % [entry_path, str(key)])
		for field: String in REQUIRED_FRAME_FIELDS:
			if not entry.has(field):
				errors.append("%s.%s: required field missing" % [entry_path, field])
		var frame: Variant = entry.get("frame")
		if not _is_logical_integer(frame) or int(frame) != index:
			errors.append("%s.frame: expected contiguous index %d" % [entry_path, index])
		var time_s: Variant = entry.get("time_s")
		if not _is_finite_number(time_s) or time_s < 0:
			errors.append("%s.time_s: expected finite non-negative number" % entry_path)
		elif float(time_s) < previous_time:
			errors.append("%s.time_s: timestamps must be non-decreasing" % entry_path)
		else:
			previous_time = float(time_s)
		var image_path: Variant = entry.get("image_path")
		if typeof(image_path) != TYPE_STRING or not _is_safe_relative_path(image_path):
			errors.append("%s.image_path: expected portable relative POSIX path" % entry_path)
			continue
		if paths.has(image_path):
			errors.append("%s.image_path: duplicate path %s" % [entry_path, image_path])
		paths[image_path] = true
		var link_error := _path_link_error(root, image_path)
		if not link_error.is_empty():
			errors.append("%s.image_path: %s" % [entry_path, link_error])
			continue
		var resolved := root.path_join(image_path).simplify_path()
		if not resolved.begins_with(root + "/"):
			errors.append("%s.image_path: path escapes source root" % entry_path)
		elif not FileAccess.file_exists(resolved):
			errors.append("%s.image_path: frame file does not exist: %s" % [entry_path, image_path])

	if manifest.has("similarity_scores"):
		var scores: Variant = manifest["similarity_scores"]
		if not scores is Array:
			errors.append("manifest.similarity_scores: expected array")
		else:
			var expected_size := maxi(0, frame_count - 1)
			if frame_count >= 0 and scores.size() != expected_size:
				errors.append("manifest.similarity_scores: expected exactly %d entries" % expected_size)
			for index in range(scores.size()):
				var score: Variant = scores[index]
				if not _is_finite_number(score) or score < 0 or score > 1:
					errors.append("manifest.similarity_scores.%d: expected finite number between 0 and 1" % index)


func _read_model_records(root: String, manifest: Dictionary, errors: PackedStringArray) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var model_version := str(manifest["model_version"])
	var filename := ""
	if model_version == "none":
		for index in range(int(manifest["frame_count"])):
			var entry: Dictionary = manifest["frames"][index]
			records.append({
				"schema_version": 1,
				"source": manifest["source_name"],
				"frame": index,
				"time_s": entry["time_s"],
				"regions": [],
			})
	elif not _is_model_output_version(model_version):
		errors.append("manifest.model_version: expected none or model_output_vX")
		return records
	elif model_version != "model_output_v1":
		errors.append("unsupported model output contract: %s" % model_version)
		return records
	else:
		filename = "%s.jsonl" % model_version
		var link_error := _path_link_error(root, filename)
		if not link_error.is_empty():
			errors.append("%s: %s" % [filename, link_error])
			return records
		var model_path := root.path_join(filename)
		if not FileAccess.file_exists(model_path):
			errors.append(
				"%s is required when model_version is %s" % [filename, model_version]
			)
			return records
		var file := FileAccess.open(model_path, FileAccess.READ)
		if file == null:
			errors.append("%s cannot be read" % filename)
			return records
		var line_number := 0
		while not file.eof_reached():
			var line := file.get_line()
			line_number += 1
			if line.strip_edges().is_empty():
				continue
			var parser := JSON.new()
			if parser.parse(line) != OK:
				errors.append(
					"%s:%d: invalid JSON: %s"
					% [filename, line_number, parser.get_error_message()]
				)
				continue
			if not parser.data is Dictionary:
				errors.append("%s:%d: expected object" % [filename, line_number])
				continue
			records.append(parser.data)

	var store = STORE_SCRIPT.new()
	var contract_errors: PackedStringArray = store.load_model_records(records)
	for error: String in contract_errors:
		errors.append("model_output.%s" % error)
	var frame_count := int(manifest["frame_count"])
	if records.size() != frame_count:
		errors.append("model_output: expected %d records, got %d" % [frame_count, records.size()])
	for index in range(mini(records.size(), frame_count)):
		var record: Dictionary = records[index]
		if not _is_logical_integer(record.get("frame")) or int(record.get("frame")) != index:
			errors.append("model_output.%d.frame: expected frame %d" % [index, index])
		if record.get("source") != manifest["source_name"]:
			errors.append("model_output.%d.source: must match manifest source_name" % index)
		if record.has("time_s") and (not _is_finite_number(record["time_s"]) or not is_equal_approx(float(record["time_s"]), float(manifest["frames"][index]["time_s"]))):
			errors.append("model_output.%d.time_s: must match manifest frame time" % index)
	if not errors.is_empty():
		return []
	var validated: Array[Dictionary] = []
	for index in range(frame_count):
		validated.append(store.get_model_record(index))
	return validated


func _is_model_output_version(value: String) -> bool:
	const PREFIX := "model_output_v"
	if not value.begins_with(PREFIX):
		return false
	var digits := value.substr(PREFIX.length())
	if digits.is_empty() or digits.unicode_at(0) < 49 or digits.unicode_at(0) > 57:
		return false
	for index in range(1, digits.length()):
		var code := digits.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true


func _read_json_object(path: String, label: String, errors: PackedStringArray) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("%s file is missing or unreadable: %s" % [label, path.get_file()])
		return {}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		errors.append("%s: invalid JSON at line %d: %s" % [label, parser.get_error_line(), parser.get_error_message()])
		return {}
	if not parser.data is Dictionary:
		errors.append("%s: expected object" % label)
		return {}
	return parser.data


func _validate_exact_integer(record: Dictionary, field: String, expected: int, errors: PackedStringArray) -> void:
	if record.has(field) and (not _is_logical_integer(record[field]) or int(record[field]) != expected):
		errors.append("manifest.%s: expected integer %d" % [field, expected])


func _finish_errors(errors: PackedStringArray) -> PackedStringArray:
	errors.sort()
	last_error = errors[0] if not errors.is_empty() else ""
	return errors


func _is_safe_relative_path(path: String) -> bool:
	if path.is_empty() or path.is_absolute_path() or "\\" in path or ":" in path:
		return false
	if path.length() >= 2 and path.unicode_at(1) == 58:
		return false
	for segment: String in path.split("/", true):
		if segment.is_empty() or segment == "." or segment == "..":
			return false
	return true


func _path_link_error(root: String, relative_path: String) -> String:
	var current := root
	for segment: String in relative_path.split("/", false):
		var directory := DirAccess.open(current)
		if directory == null:
			return "cannot inspect path component %s" % current
		if directory.is_link(segment):
			return "symbolic link or junction is not allowed: %s" % current.path_join(segment)
		current = current.path_join(segment)
	return ""


func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 65 and code <= 70) and not (code >= 97 and code <= 102):
			return false
	return true


func _is_logical_integer(value: Variant) -> bool:
	return _is_finite_number(value) and float(value) == floorf(float(value))


func _is_finite_number(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value))
