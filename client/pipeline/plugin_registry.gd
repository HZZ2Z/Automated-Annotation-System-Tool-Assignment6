class_name PluginRegistry
extends RefCounted

const API_SCRIPT := preload("res://client/pipeline/plugin_api.gd")
const DESCRIPTOR_SCRIPT := preload("res://client/pipeline/plugin_descriptor.gd")
const STAGE_BASE_PATHS := {
	"source": "res://client/pipeline/stages/source_stage.gd",
	"render": "res://client/pipeline/stages/render_stage.gd",
	"edit": "res://client/pipeline/stages/edit_stage.gd",
	"feedback": "res://client/pipeline/stages/feedback_stage.gd",
}
const STAGE_NAMES := {
	"source": "SourceStage",
	"render": "RenderStage",
	"edit": "EditStage",
	"feedback": "FeedbackStage",
}
const MANIFEST_FIELDS := {
	"id": true,
	"version": true,
	"api_version": true,
	"stage": true,
	"entry": true,
	"priority": true,
	"capabilities": true,
}
const REQUIRED_FIELDS := ["id", "version", "api_version", "stage", "entry", "priority", "capabilities"]

var _plugins: Dictionary = {}
var _descriptors: Dictionary = {}


func discover(root: String) -> PackedStringArray:
	return discover_roots(PackedStringArray([root]))


func discover_roots(roots: PackedStringArray) -> PackedStringArray:
	_plugins = {}
	_descriptors = {}
	var errors := PackedStringArray()
	var candidates: Array[String] = []
	var sorted_roots := Array(roots)
	sorted_roots.sort()
	var seen_roots := {}
	for root_value: Variant in sorted_roots:
		var root := str(root_value).strip_edges().trim_suffix("/")
		if root.is_empty():
			errors.append("plugin root must be a non-empty path")
			continue
		if seen_roots.has(root):
			continue
		seen_roots[root] = true
		candidates.append_array(_find_plugin_directories(root, errors))
	candidates.sort()
	for plugin_dir: String in candidates:
		_load_plugin(plugin_dir, errors)
	errors.sort()
	return errors


func list_plugins(stage: String) -> Array:
	var stage_descriptors: Variant = _descriptors.get(stage)
	if not stage_descriptors is Dictionary:
		return []
	var result: Array = stage_descriptors.values()
	result.sort_custom(func(left: Variant, right: Variant) -> bool:
		if left.priority != right.priority:
			return left.priority > right.priority
		return String(left.id) < String(right.id)
	)
	return result


func get_descriptor(stage: String, plugin_id: String) -> Variant:
	var stage_descriptors: Variant = _descriptors.get(stage)
	if not stage_descriptors is Dictionary:
		return null
	return stage_descriptors.get(plugin_id)


func create_plugin(stage: String, plugin_id: String) -> RefCounted:
	var stage_plugins: Variant = _plugins.get(stage)
	if not stage_plugins is Dictionary:
		return null
	var registered: Variant = stage_plugins.get(plugin_id)
	var script: Script
	if registered is Script:
		script = registered
	elif registered is Object and registered != null and registered.get_script() is Script:
		script = registered.get_script() as Script
	else:
		return null
	if not script.can_instantiate() or not _can_construct_without_arguments(script):
		return null
	var instance: Variant = script.new()
	return instance as RefCounted if instance is RefCounted else null


func get_plugin(stage: String, plugin_id: String) -> RefCounted:
	return create_plugin(stage, plugin_id)


func resolve_source_plugin_id(locator: String, preferred_id: String = "") -> String:
	var candidates: Array = list_plugins("source")
	if not preferred_id.is_empty():
		var preferred: Variant = get_descriptor("source", preferred_id)
		if preferred != null:
			candidates.erase(preferred)
			candidates.push_front(preferred)
	for descriptor: Variant in candidates:
		var plugin := create_plugin("source", String(descriptor.id))
		if plugin != null and bool(plugin.can_open(locator)):
			return String(descriptor.id)
	return ""


func _find_plugin_directories(root: String, errors: PackedStringArray) -> Array[String]:
	var result: Array[String] = []
	var children := _directory_names(root)
	if children.is_empty() and DirAccess.open(root) == null:
		errors.append("plugin root cannot be opened: %s" % root)
		return result
	for child_value: Variant in children:
		var child := str(child_value)
		var child_path := root.path_join(child)
		if FileAccess.file_exists(child_path.path_join("plugin.json")):
			result.append(child_path)
		else:
			var plugin_children := _directory_names(child_path)
			if plugin_children.is_empty() and DirAccess.open(child_path) == null:
				errors.append("plugin stage cannot be opened: %s" % child_path)
				continue
			for plugin_child_value: Variant in plugin_children:
				var plugin_path := child_path.path_join(str(plugin_child_value))
				if FileAccess.file_exists(plugin_path.path_join("plugin.json")):
					result.append(plugin_path)
				else:
					errors.append("plugin manifest does not exist: %s/plugin.json" % plugin_path)
	result.sort()
	return result


func _directory_names(path: String) -> Array[String]:
	var result: Array[String] = []
	if path.begins_with("res://"):
		for entry: String in ResourceLoader.list_directory(path):
			if entry.ends_with("/"):
				result.append(entry.trim_suffix("/"))
	if result.is_empty():
		var directory := DirAccess.open(path)
		if directory != null:
			for entry: String in directory.get_directories():
				result.append(entry)
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
		var expected_arity: int = API_SCRIPT.REQUIRED_ARITY[stage][method]
		var actual_arity := _method_arity(script, method)
		if actual_arity != expected_arity:
			errors.append("%s.entry: method %s must declare %d parameters, found %d" % [manifest_path, method, expected_arity, actual_arity])
			return
	if not _script_inherits(script, STAGE_BASE_PATHS[stage]):
		errors.append("%s.entry: plugin for stage %s must inherit %s" % [manifest_path, stage, STAGE_NAMES[stage]])
		return
	stage_plugins[plugin_id] = script
	_plugins[stage] = stage_plugins
	var stage_descriptors: Dictionary = _descriptors.get(stage, {})
	stage_descriptors[plugin_id] = DESCRIPTOR_SCRIPT.new(manifest, entry_path)
	_descriptors[stage] = stage_descriptors


func _script_inherits(script: Script, expected_base_path: String) -> bool:
	var current: Script = script
	while current != null:
		if current.resource_path == expected_base_path:
			return true
		current = current.get_base_script()
	return false


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
	if manifest.has("id") and typeof(manifest["id"]) == TYPE_STRING and not _matches("^[a-z][a-z0-9_]*$", manifest["id"]):
		errors.append("%s.id: expected lowercase snake_case identifier" % path)
		valid = false
	if manifest.has("version") and typeof(manifest["version"]) == TYPE_STRING and not _is_semver(manifest["version"]):
		errors.append("%s.version: expected semantic version" % path)
		valid = false
	if manifest.has("priority"):
		var priority: Variant = manifest["priority"]
		if not _is_logical_integer(priority):
			errors.append("%s.priority: expected integer" % path)
			valid = false
	if manifest.has("capabilities"):
		var capabilities: Variant = manifest["capabilities"]
		if not capabilities is Array or capabilities.is_empty():
			errors.append("%s.capabilities: expected non-empty array" % path)
			valid = false
		else:
			var seen := {}
			for index in range(capabilities.size()):
				var capability: Variant = capabilities[index]
				if typeof(capability) != TYPE_STRING or not _matches("^[a-z][a-z0-9_.-]*$", capability):
					errors.append("%s.capabilities.%d: expected capability identifier" % [path, index])
					valid = false
				elif seen.has(capability):
					errors.append("%s.capabilities.%d: duplicate capability %s" % [path, index, capability])
					valid = false
				else:
					seen[capability] = true
	return valid


func _is_semver(value: String) -> bool:
	var numeric := "(0|[1-9][0-9]*)"
	var prerelease := "(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
	var pattern := "^%s\\.%s\\.%s(-%s(\\.%s)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$" % [
		numeric, numeric, numeric, prerelease, prerelease,
	]
	return _matches(pattern, value)


func _matches(pattern: String, value: String) -> bool:
	var regex := RegEx.new()
	return regex.compile(pattern) == OK and regex.search(value) != null


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


func _method_arity(script: Script, method_name: String) -> int:
	for method: Dictionary in script.get_script_method_list():
		if method.get("name") == method_name:
			return (method.get("args", []) as Array).size()
	return -1
