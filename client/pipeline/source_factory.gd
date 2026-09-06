class_name SourceFactory
extends RefCounted


var _registry: Variant


func _init(registry: Variant) -> void:
	_registry = registry


func resolve_plugin_id(locator: String, preferred_id: String = "") -> String:
	if (
		not _registry is Object
		or not _registry.has_method("resolve_source_plugin_id")
		or not _registry.has_method("get_descriptor")
	):
		return ""
	if (
		not preferred_id.is_empty()
		and _registry.get_descriptor("source", preferred_id) == null
	):
		return ""
	return String(_registry.resolve_source_plugin_id(locator, preferred_id))


func open(locator: String, preferred_id: String = "") -> Dictionary:
	if (
		not _registry is Object
		or not _registry.has_method("resolve_source_plugin_id")
		or not _registry.has_method("create_plugin")
		or not _registry.has_method("get_descriptor")
	):
		return _result(null, "", PackedStringArray([
			"Source registry is unavailable"]))
	if (
		not preferred_id.is_empty()
		and _registry.get_descriptor("source", preferred_id) == null
	):
		return _result(null, preferred_id, PackedStringArray([
			"Configured source plugin is unavailable: %s" % preferred_id]))
	var plugin_id := resolve_plugin_id(locator, preferred_id)
	if plugin_id.is_empty():
		return _result(null, "", PackedStringArray([
			"No source plugin accepts this locator"]))
	var source: Variant = _registry.create_plugin("source", plugin_id)
	if source == null:
		return _result(null, plugin_id, PackedStringArray([
			"Source plugin could not be created: %s" % plugin_id]))
	var value: Variant = source.open(locator)
	if not value is PackedStringArray:
		source.close()
		return _result(null, plugin_id, PackedStringArray([
			"Source plugin open must return PackedStringArray"]))
	var errors := value as PackedStringArray
	if not errors.is_empty():
		source.close()
		return _result(null, plugin_id, errors)
	return _result(source, plugin_id, PackedStringArray())


func _result(
	source: Variant,
	plugin_id: String,
	errors: PackedStringArray
) -> Dictionary:
	return {
		"source": source,
		"plugin_id": plugin_id,
		"errors": PackedStringArray(errors),
	}
