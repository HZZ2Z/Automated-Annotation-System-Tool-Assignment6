extends RefCounted

const FACTORY_PATH := "res://client/pipeline/source_factory.gd"
const REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const TEMP_PREFIX := "/tmp/annotool-source-factory-"


func run(support) -> void:
	var factory_script := ResourceLoader.load(FACTORY_PATH, "Script") as Script
	support.expect(factory_script != null,
		"SourceFactory should centralize registry-backed Source opening")
	if factory_script == null:
		return
	var registry = REGISTRY_SCRIPT.new()
	support.expect_equal(
		registry.discover("res://client/plugins"), PackedStringArray(),
		"SourceFactory fixture should use the production registry")
	var root := "%s%d-%d" % [
		TEMP_PREFIX, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	var image_path := root.path_join("frame.png")
	_save_image(image_path)

	var factory = factory_script.new(registry)
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


func _save_image(path: String) -> void:
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color.CORNFLOWER_BLUE)
	image.save_png(path)


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
