class_name PluginRegistry
extends RefCounted

const API_SCRIPT := preload("res://client/pipeline/plugin_api.gd")
const MANIFEST_FIELDS := {
	"id": true,
	"version": true,
	"api_version": true,
	"stage": true,
	"entry": true,
}
const REQUIRED_FIELDS := ["id", "version", "api_version", "stage", "entry"]

var _plugins: Dictionary = {}


func discover(root: String) -> PackedStringArray:
	_plugins = {}
	var errors := PackedStringArray()
	var candidates := _find_plugin_directories(root, errors)
	for plugin_dir: String in candidates:
		_load_plugin(plugin_dir, errors)
	errors.sort()
	return errors


func get_plugin(stage: String, plugin_id: String) -> RefCounted:
	var stage_plugins: Variant = _plugins.get(stage)
	if not stage_plugins is Dictionary:
		return null
	var plugin: Variant = stage_plugins.get(plugin_id)
	return plugin as RefCounted


func _find_plugin_directories(root: String, errors: PackedStringArray) -> Array[String]:
	var result: Array[String] = []
	var directory := DirAccess.open(root)
	if directory == null:
		errors.append("plugin root cannot be opened: %s" % root)
		return result
	var children := Array(directory.get_directories())
	children.sort()
	for child_value: Variant in children:
		var child := str(child_value)
		var child_path := root.path_join(child)
		if FileAccess.file_exists(child_path.path_join("plugin.json")):
			result.append(child_path)
		else:
			var stage_directory := DirAccess.open(child_path)
			if stage_directory == null:
				errors.append("plugin stage cannot be opened: %s" % child_path)
				continue
			var plugin_children := Array(stage_directory.get_directories())
			plugin_children.sort()
			for plugin_child_value: Variant in plugin_children:
				var plugin_path := child_path.path_join(str(plugin_child_value))
				if FileAccess.file_exists(plugin_path.path_join("plugin.json")):
					result.append(plugin_path)
				else:
					errors.append("plugin manifest does not exist: %s/plugin.json" % plugin_path)
	result.sort()
	return result


func _load_plugin(plugin_dir: String, errors: PackedStringArray) -> void:
	var manifest_path := plugin_dir.path_join("plugin.json")
	var error_count := errors.size()
	var manifest := _read_manifest(manifest_path, errors)
	if errors.size() > error_count:
		return
	if not _validate_manifest(manifest, manifest_path, errors):
		return

	var stage: String = manifest["stage"]
	var plugin_id: String = manifest["id"]
	var stage_plugins: Dictionary = _plugins.get(stage, {})
	if stage_plugins.has(plugin_id):
		errors.append("%s: duplicate plugin id %s for stage %s" % [manifest_path, plugin_id, stage])
		return

	var entry: String = manifest["entry"]
	if not _is_safe_relative_path(entry):
		errors.append("%s.entry: unsafe entry path %s" % [manifest_path, entry])
		return
	var entry_path := plugin_dir.path_join(entry).simplify_path()
	var base_path := plugin_dir.simplify_path().trim_suffix("/") + "/"
	if not entry_path.begins_with(base_path):
		errors.append("%s.entry: unsafe entry path escapes plugin directory" % manifest_path)
		return
	if not FileAccess.file_exists(entry_path):
		errors.append("%s.entry: file does not exist: %s" % [manifest_path, entry])
		return
	var resource: Resource = ResourceLoader.load(entry_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not resource is Script:
		errors.append("%s.entry: resource is not a Script: %s" % [manifest_path, entry])
		return
	var script := resource as Script
	if not script.can_instantiate() or not _can_construct_without_arguments(script):
		errors.append("%s.entry: Script cannot be instantiated: %s" % [manifest_path, entry])
		return
	var instance: Variant = script.new()
	if not instance is RefCounted:
		errors.append("%s.entry: Script cannot be instantiated as a RefCounted plugin" % manifest_path)
		return
	for method: String in API_SCRIPT.REQUIRED_METHODS[stage]:
		if not instance.has_method(method):
			errors.append("%s.entry: missing method %s for stage %s" % [manifest_path, method, stage])
			return
	stage_plugins[plugin_id] = instance
	_plugins[stage] = stage_plugins


func _read_manifest(path: String, errors: PackedStringArray) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("%s: cannot read plugin manifest" % path)
		return {}
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	if parse_error != OK:
		errors.append("%s: invalid JSON at line %d: %s" % [path, parser.get_error_line(), parser.get_error_message()])
		return {}
	var value: Variant = parser.data
	if not value is Dictionary:
		errors.append("%s: plugin manifest must be an object" % path)
		return {}
	return value


func _validate_manifest(manifest: Dictionary, path: String, errors: PackedStringArray) -> bool:
	var valid := true
	for key: Variant in manifest.keys():
		if typeof(key) != TYPE_STRING or not MANIFEST_FIELDS.has(key):
			errors.append("%s.%s: additional field is not allowed" % [path, str(key)])
			valid = false
	for field: String in REQUIRED_FIELDS:
		if not manifest.has(field):
			errors.append("%s.%s: required field missing" % [path, field])
			valid = false
	for field: String in ["id", "version", "stage", "entry"]:
		if manifest.has(field):
			var value: Variant = manifest[field]
			if typeof(value) != TYPE_STRING or value.is_empty():
				errors.append("%s.%s: expected non-empty string" % [path, field])
				valid = false
	if manifest.has("api_version"):
		var api_version: Variant = manifest["api_version"]
		if not _is_logical_integer(api_version) or int(api_version) != API_SCRIPT.API_VERSION:
			errors.append("%s.api_version: incompatible API version, expected %d" % [path, API_SCRIPT.API_VERSION])
			valid = false
	if manifest.has("stage") and typeof(manifest["stage"]) == TYPE_STRING and not manifest["stage"] in API_SCRIPT.STAGES:
		errors.append("%s.stage: unknown stage %s" % [path, manifest["stage"]])
		valid = false
	return valid


func _is_safe_relative_path(path: String) -> bool:
	if path.is_empty() or path.is_absolute_path() or "\\" in path or ":" in path:
		return false
	if path.length() >= 2 and path.unicode_at(1) == 58:
		return false
	for segment: String in path.split("/", true):
		if segment.is_empty() or segment == "." or segment == "..":
			return false
	return true


func _is_logical_integer(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value)) and float(value) == floorf(float(value))


func _can_construct_without_arguments(script: Script) -> bool:
	for method: Dictionary in script.get_script_method_list():
		if method.get("name") != "_init":
			continue
		var arguments: Array = method.get("args", [])
		var defaults: Array = method.get("default_args", [])
		return arguments.size() <= defaults.size()
	return true
