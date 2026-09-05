extends RefCounted

const REGISTRY_SCRIPT = preload("res://client/pipeline/plugin_registry.gd")
const API_SCRIPT = preload("res://client/pipeline/plugin_api.gd")


static func run(support) -> void:
	support.expect("get_manifest" in API_SCRIPT.REQUIRED_METHODS["source"], "source plugin contract should require authoritative manifest access")
	support.expect("can_open" in API_SCRIPT.REQUIRED_METHODS["source"], "source routing should be owned by source plugins")
	support.expect("get_presentation" in API_SCRIPT.REQUIRED_METHODS["source"], "source plugins should own format-specific explorer metadata")
	var registry = REGISTRY_SCRIPT.new()
	var errors: PackedStringArray = registry.discover("res://tests/godot/fixtures/plugins")
	support.expect(registry.get_plugin("source", "fixture_source") != null, "valid fixture plugin should load while broken siblings are isolated")
	for expected_fragment in ["api_version", "duplicate plugin id fixture_source", "unknown stage", "missing method", "unsafe entry", "invalid JSON", "does not exist", "not a Script", "required field", "cannot be instantiated"]:
		support.expect(_contains(errors, expected_fragment), "registry error should mention %s" % expected_fragment)
	support.expect(_contains(errors, "must inherit SourceStage"), "duck-typed source plugins should be rejected before runtime use")
	support.expect(registry.get_plugin("source", "duck_typed_source") == null, "a RefCounted with matching method names must not bypass the typed Stage contract")
	support.expect(_contains(errors, "nested_stage/plugin/plugin.json"), "bounded two-level scan should validate plugins under an unknown stage directory")
	var sorted_errors := Array(errors)
	sorted_errors.sort()
	support.expect_equal(Array(errors), sorted_errors, "registry errors should be deterministic")
	support.expect(registry.get_plugin("source", "missing_method") == null, "plugin missing a required method must not register")
	support.expect(_contains(errors, "missing method get_manifest for stage source"), "source plugins without authoritative manifest access should be rejected")
	support.expect(registry.get_plugin("edit", "missing_edit_ui") == null, "edit plugins missing tool descriptors and generic actions must not register")
	support.expect(_contains(errors, "missing method get_tool_descriptors for stage edit"), "edit API should include plugin-owned UI descriptions")
	support.expect("set_active_tool" in API_SCRIPT.REQUIRED_METHODS["edit"], "edit API v1 should expose explicit tool selection")
	support.expect("get_active_tool" in API_SCRIPT.REQUIRED_METHODS["edit"], "edit API v1 should expose the active tool for UI synchronization")
	support.expect("deactivate" in API_SCRIPT.REQUIRED_METHODS["edit"], "edit API v1 should expose an explicit teardown lifecycle")
	support.expect(registry.get_plugin("analysis", "unknown_stage") == null, "unknown stage plugin must not register")

	var production_errors: PackedStringArray = registry.discover("res://client/plugins")
	support.expect_equal(production_errors, PackedStringArray(), "production plugin discovery should be clean")
	support.expect(registry.has_method("list_plugins") and registry.has_method("get_descriptor") and registry.has_method("create_plugin"),
		"registry should expose descriptor discovery and fresh-instance factory APIs")
	if registry.has_method("list_plugins") and registry.has_method("get_descriptor") and registry.has_method("create_plugin"):
		var source_descriptors: Array = registry.list_plugins("source")
		support.expect_equal(source_descriptors.size(), 2, "registry should list both production source descriptors")
		var descriptor: Variant = registry.get_descriptor("edit", "basic_edit_tools")
		support.expect(descriptor != null, "registry should expose the edit descriptor without instantiating plugin state")
		if descriptor != null:
			support.expect_equal(descriptor.stage, &"edit", "descriptor should expose the declared stage")
			support.expect(descriptor.has_capability(&"range_propagate"), "descriptor should expose declared capabilities")
		var first: Variant = registry.create_plugin("source", "image_sequence_source")
		var second: Variant = registry.create_plugin("source", "image_sequence_source")
		support.expect(first != null and second != null and first != second, "registry factories should create isolated plugin instances")
	support.expect(registry.get_plugin("source", "image_sequence_source") != null, "nested production source plugin should be discovered")
	support.expect(registry.get_plugin("edit", "basic_edit_tools") != null, "production edit plugin should be discovered")
	support.expect(registry.get_plugin("source", "fixture_source") == null, "discover should replace prior registry state")
	support.expect(registry.get_plugin("source", "image_sequence_source") != registry.get_plugin("source", "missing"), "plugin lookup should return only the requested instance")
	var manifest_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		"res://client/plugins/edit/basic_edit_tools/plugin.json"
	))
	support.expect(manifest_value is Dictionary, "the basic edit manifest should remain valid JSON")
	if manifest_value is Dictionary:
		var capabilities: Array = manifest_value.get("capabilities", [])
		support.expect("delete" in capabilities,
			"Delete remains an EditStage capability for the Select keyboard path")
		support.expect(not "wipe" in capabilities, "Wipe must not remain an EditStage capability")
		support.expect(not "close_gaps" in capabilities and "eraser" in capabilities,
			"the manifest must remove Close Gaps while retaining Eraser")
	var edit: Variant = registry.create_plugin("edit", "basic_edit_tools")
	if edit != null:
		support.expect_equal(edit.invoke(&"set_tool_option", {
			"option_id": &"brush_radius", "value": 13.0,
		}), PackedStringArray(), "the shared brush radius should accept a finite in-range value")
		support.expect_equal(edit.get("_brush_radius_image_px"), 13.0,
			"accepted brush-radius options should update plugin state")
		support.expect(not edit.invoke(&"set_tool_option", {
			"option_id": &"brush_radius", "value": INF,
		}).is_empty(), "non-finite brush radius must be refused")
		support.expect_equal(edit.get("_brush_radius_image_px"), 13.0,
			"a refused brush radius must preserve the accepted value")

	var extension_errors: PackedStringArray = registry.discover("res://tests/godot/fixtures/extension_plugins")
	support.expect_equal(extension_errors, PackedStringArray(), "an external fixture directory should load without registry changes")
	support.expect_equal(registry.resolve_source_plugin_id("case.fixture"), "fixture_extension_source",
		"overlapping sources should resolve deterministically to the highest-priority plugin")
	var extension: Variant = registry.create_plugin("source", "fixture_extension_source")
	support.expect(extension != null, "the newly dropped-in source should be creatable")
	if extension != null:
		support.expect_equal(extension.open("case.fixture"), PackedStringArray(), "the extension source should be usable through the unchanged Source API")
		support.expect_equal(extension.get_frame_count(), 1, "the extension source should provide indexed frames")

	support.expect(registry.has_method("discover_roots"), "registry should support startup discovery across production and teammate plugin roots")
	if registry.has_method("discover_roots"):
		var multi_root_errors: PackedStringArray = registry.discover_roots(PackedStringArray([
			"res://client/plugins",
			"res://tests/godot/fixtures/extension_plugins",
		]))
		support.expect_equal(multi_root_errors, PackedStringArray(), "multiple plugin roots should be discovered as one deterministic registry")
		support.expect_equal(registry.resolve_source_plugin_id("case.fixture"), "fixture_extension_source",
			"priority routing should also work when extensions are loaded beside production plugins")


static func _contains(values: PackedStringArray, fragment: String) -> bool:
	for value: String in values:
		if fragment in value:
			return true
	return false
