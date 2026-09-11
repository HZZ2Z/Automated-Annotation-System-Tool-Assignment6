extends RefCounted

const FACTORY_PATH := "res://client/pipeline/source_factory.gd"
const REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const TEMP_PREFIX := "/tmp/annotool-source-factory-"


class MinimalSource extends RefCounted:
	func can_open(locator: String) -> bool:
		return locator == "minimal.fixture"

	func open(_locator: String) -> PackedStringArray:
		return PackedStringArray()

	func close() -> void:
		pass


class MinimalRegistry extends RefCounted:
	func list_plugins(stage: String) -> Array:
		return [{"id": "minimal_source"}] if stage == "source" else []

	func get_descriptor(stage: String, plugin_id: String) -> Variant:
		if stage == "source" and plugin_id == "minimal_source":
			return {"id": "minimal_source"}
		return null

	func create_plugin(stage: String, plugin_id: String) -> Variant:
		if stage == "source" and plugin_id == "minimal_source":
			return MinimalSource.new()
		return null


func run(support) -> void:
	var factory_script := ResourceLoader.load(FACTORY_PATH, "Script") as Script
	support.expect(factory_script != null,
		"SourceFactory should centralize registry-backed Source opening")
	if factory_script == null:
		return
	_test_minimal_registry_contract(factory_script, support)
	var registry = REGISTRY_SCRIPT.new()
	support.expect_equal(registry.discover_roots(PackedStringArray([
		"res://client/plugins",
		"res://tests/godot/fixtures/extension_plugins",
	])), PackedStringArray(),
		"SourceFactory fixture should use production and extension plugins")
	var root := "%s%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	var image_path := root.path_join("frame.png")
	_save_image(image_path)

	var factory = factory_script.new(registry)
	_test_optional_workspace_discovery(factory, root, support)
	support.expect_equal(factory.resolve_plugin_id(image_path), "single_image_source",
		"SourceFactory should expose the same read-only route used by UI discovery")
	var opened: Dictionary = factory.open(image_path)
	support.expect(opened.get("source") != null,
		"SourceFactory should return an opened registry instance")
	support.expect_equal(opened.get("plugin_id"), "single_image_source",
		"SourceFactory should report the routed descriptor")
	support.expect_equal(opened.get("errors"), PackedStringArray(),
		"a successful SourceFactory result should have no errors")
	if opened.get("source") != null:
		support.expect_equal(opened["source"].get_frame_count(), 1,
			"the returned Source should already be open")
		opened["source"].close()

	var rejected: Dictionary = factory.open(root.path_join("unknown.bin"))
	support.expect(
		rejected.get("source") == null
		and rejected.get("plugin_id") == ""
		and rejected.get("errors") is PackedStringArray
		and not rejected["errors"].is_empty(),
		"unsupported locators should return a closed, readable failure result")
	var missing_preferred: Dictionary = factory.open(image_path, "missing_source")
	support.expect(
		missing_preferred.get("source") == null
		and missing_preferred.get("plugin_id") == "missing_source"
		and "Configured source plugin is unavailable" in " ".join(
			missing_preferred.get("errors", PackedStringArray())),
		"an unavailable configured Source should fail before fallback routing")
	_remove_tree(root)


func _test_minimal_registry_contract(factory_script: Script, support) -> void:
	var factory = factory_script.new(MinimalRegistry.new())
	var opened: Dictionary = factory.open("minimal.fixture")
	support.expect_equal(opened.get("plugin_id"), "minimal_source",
		"SourceFactory open should require only the registry methods it actually calls")
	support.expect(opened.get("source") != null,
		"an otherwise valid registry must not need the unused legacy resolver method")
	if opened.get("source") != null:
		opened["source"].close()


func _test_optional_workspace_discovery(factory: Variant, root: String, support) -> void:
	support.expect(factory.has_method("discover_workspace_media"),
		"SourceFactory should expose optional plugin-owned workspace discovery")
	if not factory.has_method("discover_workspace_media"):
		return
	_write_text(root.path_join("custom.fixture"), "plugin-owned locator")
	var discovered: Dictionary = factory.discover_workspace_media(root)
	support.expect(bool(discovered.get("claimed", false)),
		"the first claiming Source plugin should own workspace discovery")
	support.expect_equal(discovered.get("plugin_id"), "fixture_extension_source",
		"Factory should attach the claiming plugin ID")
	support.expect(discovered.get("errors") is PackedStringArray,
		"discovery errors should keep the packed-string contract")
	var media: Array = discovered.get("media", [])
	support.expect_equal(media.size(), 1,
		"claimed discovery should return one logical fixture medium")
	if media.size() == 1:
		support.expect_equal(media[0].get("relative_path"), "custom.fixture",
			"Factory should preserve the plugin-owned logical relative path")
		media[0]["relative_path"] = "mutated"
	var repeated: Dictionary = factory.discover_workspace_media(root)
	support.expect_equal(repeated.get("media", [])[0].get("relative_path"),
		"custom.fixture",
		"Factory results must not retain caller-mutated plugin arrays")

	DirAccess.remove_absolute(root.path_join("custom.fixture"))
	_write_text(root.path_join("malformed.discovery"), "reject")
	var malformed: Dictionary = factory.discover_workspace_media(root)
	support.expect(
		not bool(malformed.get("claimed", false))
		and malformed.get("plugin_id") == "fixture_extension_source"
		and malformed.get("errors") is PackedStringArray
		and not malformed.get("errors", PackedStringArray()).is_empty(),
		"malformed discovery must fail at its owning plugin instead of falling back")
	DirAccess.remove_absolute(root.path_join("malformed.discovery"))


func _save_image(path: String) -> void:
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color.CORNFLOWER_BLUE)
	image.save_png(path)


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
