class_name PluginDescriptor
extends RefCounted


var id: StringName
var version: String
var api_version: int
var stage: StringName
var entry_path: String
var capabilities: PackedStringArray
var priority: int


func _init(manifest: Dictionary, resolved_entry_path: String) -> void:
	id = StringName(manifest["id"])
	version = String(manifest["version"])
	api_version = int(manifest["api_version"])
	stage = StringName(manifest["stage"])
	entry_path = resolved_entry_path
	priority = int(manifest["priority"])
	capabilities = PackedStringArray()
	for value: Variant in manifest["capabilities"]:
		capabilities.append(String(value))
	capabilities.sort()


func has_capability(capability: StringName) -> bool:
	return String(capability) in capabilities


func to_dictionary() -> Dictionary:
	return {
		"id": String(id),
		"version": version,
		"api_version": api_version,
		"stage": String(stage),
		"entry_path": entry_path,
		"capabilities": Array(capabilities),
		"priority": priority,
	}
