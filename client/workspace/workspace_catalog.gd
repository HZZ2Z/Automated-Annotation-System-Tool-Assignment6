class_name WorkspaceCatalog
extends RefCounted


const PATHS_SCRIPT := preload("res://client/workspace/workspace_paths.gd")
const IMAGE_EXTENSIONS := {"jpeg": true, "jpg": true, "png": true}
const VIDEO_EXTENSIONS := {
	"avi": true,
	"m4v": true,
	"mkv": true,
	"mov": true,
	"mp4": true,
	"mpeg": true,
	"mpg": true,
	"webm": true,
}
const EXCLUDED_DIRECTORIES := {
	".annotool": true,
	"label": true,
	"labels": true,
}


var _root := ""
var _entries: Array[Dictionary] = []
var _entries_by_id: Dictionary = {}


func scan(root: String) -> PackedStringArray:
	var normalized := ProjectSettings.globalize_path(root).simplify_path().trim_suffix("/")
	if normalized.is_empty() or not DirAccess.dir_exists_absolute(normalized):
		return PackedStringArray(["Workspace directory does not exist: %s" % normalized])
	if _path_is_link(normalized):
		return PackedStringArray(["Workspace directory must not be a symbolic link: %s" % normalized])

	var candidate_entries: Array[Dictionary] = []
	var scan_errors := PackedStringArray()
	_scan_directory(normalized, normalized, candidate_entries, scan_errors)
	if not scan_errors.is_empty():
		return scan_errors
	if candidate_entries.is_empty():
		return PackedStringArray(["Workspace contains no supported images or videos"])
	candidate_entries.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return String(left["relative_path"]) < String(right["relative_path"])
	)

	var candidate_by_id := {}
	var collision_errors := PackedStringArray()
	for entry: Dictionary in candidate_entries:
		var media_id_value: String = entry["media_id"]
		if candidate_by_id.has(media_id_value):
			var previous: Dictionary = candidate_by_id[media_id_value]
			collision_errors.append(
				"Media ID collision '%s': %s and %s" % [
					media_id_value,
					previous["relative_path"],
					entry["relative_path"],
				]
			)
		else:
			candidate_by_id[media_id_value] = entry
	if not collision_errors.is_empty():
		return collision_errors

	_root = normalized
	_entries = candidate_entries
	_entries_by_id = candidate_by_id
	return PackedStringArray()


func get_root() -> String:
	return _root


func get_entries() -> Array[Dictionary]:
	return _entries.duplicate(true)


func get_entry(media_id_value: String) -> Dictionary:
	var value: Variant = _entries_by_id.get(media_id_value)
	return value.duplicate(true) if value is Dictionary else {}


func get_view_model() -> Dictionary:
	if _root.is_empty():
		return {}
	return {
		"kind": "workspace",
		"display_name": _root.get_file(),
		"root_path": _root,
		"media": _entries.duplicate(true),
	}


func _scan_directory(
	workspace_root: String,
	directory_path: String,
	entries: Array[Dictionary],
	errors: PackedStringArray
) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		errors.append("Cannot read workspace directory: %s" % directory_path)
		return

	var child_directories := Array(directory.get_directories())
	child_directories.sort()
	for child_value: Variant in child_directories:
		var child_name := String(child_value)
		if child_name.begins_with(".") or EXCLUDED_DIRECTORIES.has(child_name.to_lower()):
			continue
		if directory.is_link(child_name):
			continue
		var child_path := directory_path.path_join(child_name)
		var sequence_files := _numeric_sequence_files(child_path)
		if sequence_files.size() >= 2:
			entries.append(_media_entry(
				workspace_root, child_path, child_name, "image_sequence"))
			continue
		_scan_directory(workspace_root, child_path, entries, errors)
		if not errors.is_empty():
			return

	var file_names := Array(directory.get_files())
	file_names.sort()
	for file_value: Variant in file_names:
		var file_name := String(file_value)
		if file_name.begins_with(".") or directory.is_link(file_name):
			continue
		var extension := file_name.get_extension().to_lower()
		var media_type := ""
		if IMAGE_EXTENSIONS.has(extension):
			media_type = "image"
		elif VIDEO_EXTENSIONS.has(extension):
			media_type = "video"
		else:
			continue
		var source_path := directory_path.path_join(file_name)
		entries.append(_media_entry(
			workspace_root, source_path, file_name.get_basename(), media_type))


func _numeric_sequence_files(directory_path: String) -> PackedStringArray:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return PackedStringArray()
	var result := PackedStringArray()
	for file_name: String in directory.get_files():
		if file_name.begins_with(".") or directory.is_link(file_name):
			continue
		if not IMAGE_EXTENSIONS.has(file_name.get_extension().to_lower()):
			continue
		var stem := file_name.get_basename()
		if stem.is_valid_int() and int(stem) >= 0:
			result.append(file_name)
	return result


func _media_entry(
	workspace_root: String,
	source_path: String,
	id_stem: String,
	media_type: String
) -> Dictionary:
	var relative_path := source_path.substr(workspace_root.length() + 1)
	var media_id_value := PATHS_SCRIPT.portable_media_id(id_stem)
	var label_root := _resolve_label_root(workspace_root, source_path, media_id_value)
	var source_relative_path := source_path.substr(label_root.length() + 1)
	return {
		"display_name": source_path.get_file(),
		"media_id": media_id_value,
		"media_type": media_type,
		"source_path": source_path,
		"relative_path": relative_path.replace("\\", "/"),
		"label_root": label_root,
		"source_relative_path": source_relative_path.replace("\\", "/"),
	}


func _resolve_label_root(
	workspace_root: String,
	source_path: String,
	media_id_value: String
) -> String:
	var current := source_path.get_base_dir()
	var nearest_label_directory_root := ""
	while current == workspace_root or current.begins_with(workspace_root + "/"):
		var native_directory := current.path_join("label")
		var source_directory := current.path_join("labels")
		var native_path := native_directory.path_join("%s.json" % media_id_value)
		var source_label_path := source_directory.path_join("%s.json" % media_id_value)
		if (
			_label_file_exists(native_directory, native_path)
			or _label_file_exists(source_directory, source_label_path)
		):
			return current
		if nearest_label_directory_root.is_empty() and (
			_safe_directory_exists(native_directory)
			or _safe_directory_exists(source_directory)
		):
			nearest_label_directory_root = current
		if current == workspace_root:
			break
		current = current.get_base_dir()
	return (
		nearest_label_directory_root
		if not nearest_label_directory_root.is_empty()
		else workspace_root
	)


func _label_file_exists(directory_path: String, file_path: String) -> bool:
	return (
		_safe_directory_exists(directory_path)
		and FileAccess.file_exists(file_path)
		and not _path_is_link(file_path)
	)


func _safe_directory_exists(path: String) -> bool:
	return DirAccess.dir_exists_absolute(path) and not _path_is_link(path)


func _path_is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())
