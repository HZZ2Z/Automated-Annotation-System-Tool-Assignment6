class_name SourceFactory
extends RefCounted


var _registry: Variant


func _init(registry: Variant) -> void:
	_registry = registry


func resolve_plugin_id(locator: String, preferred_id: String = "") -> String:
	if (
		not _registry is Object
		or not _registry.has_method("list_plugins")
		or not _registry.has_method("create_plugin")
		or not _registry.has_method("get_descriptor")
	):
		return ""
	if (
		not preferred_id.is_empty()
		and _registry.get_descriptor("source", preferred_id) == null
	):
		return ""
	for descriptor: Variant in _ordered_source_descriptors(preferred_id):
		var plugin: Variant = _registry.create_plugin("source", String(descriptor.id))
		if plugin != null and bool(plugin.can_open(locator)):
			return String(descriptor.id)
	return ""


func discover_workspace_media(
	root: String,
	preferred_id: String = "",
	token: Variant = null,
) -> Dictionary:
	if (
		not _registry is Object
		or not _registry.has_method("list_plugins")
		or not _registry.has_method("create_plugin")
		or not _registry.has_method("get_descriptor")
	):
		return _discovery_result(false, "", [], PackedStringArray([
			"Source registry is unavailable"]))
	if (
		not preferred_id.is_empty()
		and _registry.get_descriptor("source", preferred_id) == null
	):
		return _discovery_result(false, preferred_id, [], PackedStringArray([
			"Configured source plugin is unavailable: %s" % preferred_id]))
	for descriptor: Variant in _ordered_source_descriptors(preferred_id):
		var plugin_id := String(descriptor.id)
		var plugin: Variant = _registry.create_plugin("source", plugin_id)
		if plugin == null or not plugin.has_method("discover_workspace_media"):
			continue
		var checked := _validate_discovery_result(
			plugin.discover_workspace_media(root, token), plugin_id)
		if not checked.errors.is_empty() or checked.claimed:
			return checked
	return _discovery_result(false, "", [], PackedStringArray())


func open(
	locator: String,
	preferred_id: String = "",
	token: Variant = null,
) -> Dictionary:
	if (
		not _registry is Object
		or not _registry.has_method("list_plugins")
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
	var value: Variant = (
		source.open_with_token(locator, token)
		if source.has_method("open_with_token")
		else source.open(locator)
	)
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


func _ordered_source_descriptors(preferred_id: String) -> Array:
	var descriptors: Array = _registry.list_plugins("source")
	if preferred_id.is_empty():
		return descriptors
	var preferred: Variant = _registry.get_descriptor("source", preferred_id)
	if preferred == null:
		return []
	descriptors.erase(preferred)
	descriptors.push_front(preferred)
	return descriptors


func _validate_discovery_result(value: Variant, plugin_id: String) -> Dictionary:
	var invalid := func(reason: String) -> Dictionary:
		return _discovery_result(false, plugin_id, [], PackedStringArray([
			"Source plugin workspace discovery is invalid (%s): %s" % [plugin_id, reason]
		]))
	if not value is Dictionary:
		return invalid.call("expected Dictionary")
	var response := value as Dictionary
	for required: String in ["claimed", "media", "errors"]:
		if not response.has(required):
			return invalid.call("missing field %s" % required)
	if typeof(response.claimed) != TYPE_BOOL:
		return invalid.call("claimed must be bool")
	if not response.media is Array:
		return invalid.call("media must be Array")
	if not response.errors is PackedStringArray:
		return invalid.call("errors must be PackedStringArray")
	var errors := PackedStringArray(response.errors)
	if not errors.is_empty():
		return _discovery_result(false, plugin_id, [], errors)
	if not bool(response.claimed):
		if not response.media.is_empty():
			return invalid.call("unclaimed result must not contain media")
		return _discovery_result(false, plugin_id, [], PackedStringArray())
	var detached_media: Array[Dictionary] = []
	for index in range(response.media.size()):
		var media_value: Variant = response.media[index]
		if not media_value is Dictionary:
			return invalid.call("media[%d] must be Dictionary" % index)
		var media := (media_value as Dictionary).duplicate(true)
		for field: String in [
			"display_name", "media_id", "media_type", "source_path", "relative_path",
		]:
			if not media.has(field) or typeof(media[field]) != TYPE_STRING \
				or String(media[field]).is_empty():
				return invalid.call("media[%d].%s must be a non-empty string" % [index, field])
		media["source_plugin_id"] = plugin_id
		detached_media.append(media)
	return _discovery_result(true, plugin_id, detached_media, PackedStringArray())


func _discovery_result(
	claimed: bool,
	plugin_id: String,
	media: Array,
	errors: PackedStringArray,
) -> Dictionary:
	return {
		"claimed": claimed,
		"plugin_id": plugin_id,
		"media": media.duplicate(true),
		"errors": PackedStringArray(errors),
	}
