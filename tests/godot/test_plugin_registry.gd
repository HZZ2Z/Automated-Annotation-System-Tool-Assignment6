extends RefCounted

const REGISTRY_SCRIPT = preload("res://client/pipeline/plugin_registry.gd")
const API_SCRIPT = preload("res://client/pipeline/plugin_api.gd")


static func run(support) -> void:
	support.expect("get_manifest" in API_SCRIPT.REQUIRED_METHODS["source"], "source plugin contract should require authoritative manifest access")
	var registry = REGISTRY_SCRIPT.new()
	var errors: PackedStringArray = registry.discover("res://tests/godot/fixtures/plugins")
	support.expect(registry.get_plugin("source", "fixture-source") != null, "valid fixture plugin should load while broken siblings are isolated")
	for expected_fragment in ["api_version", "duplicate plugin id fixture-source", "unknown stage", "missing method", "unsafe entry", "invalid JSON", "does not exist", "not a Script", "required field", "cannot be instantiated"]:
		support.expect(_contains(errors, expected_fragment), "registry error should mention %s" % expected_fragment)
	support.expect(_contains(errors, "nested_stage/plugin/plugin.json"), "bounded two-level scan should validate plugins under an unknown stage directory")
	var sorted_errors := Array(errors)
	sorted_errors.sort()
	support.expect_equal(Array(errors), sorted_errors, "registry errors should be deterministic")
	support.expect(registry.get_plugin("source", "missing-method") == null, "plugin missing a required method must not register")
	support.expect(_contains(errors, "missing method get_manifest for stage source"), "source plugins without authoritative manifest access should be rejected")
	support.expect(registry.get_plugin("analysis", "unknown-stage") == null, "unknown stage plugin must not register")

	var production_errors: PackedStringArray = registry.discover("res://client/plugins")
	support.expect_equal(production_errors, PackedStringArray(), "production plugin discovery should be clean")
	support.expect(registry.get_plugin("source", "image_sequence_source") != null, "nested production source plugin should be discovered")
	support.expect(registry.get_plugin("edit", "basic_edit_tools") != null, "production edit plugin should be discovered")
	support.expect(registry.get_plugin("source", "fixture-source") == null, "discover should replace prior registry state")
	support.expect(registry.get_plugin("source", "image_sequence_source") != registry.get_plugin("source", "missing"), "plugin lookup should return only the requested instance")


static func _contains(values: PackedStringArray, fragment: String) -> bool:
	for value: String in values:
		if fragment in value:
			return true
	return false
