extends RefCounted

const CATALOG_PATH := "res://client/workspace/workspace_catalog.gd"
const PATHS_SCRIPT := preload("res://client/workspace/workspace_paths.gd")
const REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")
const SOURCE_FACTORY_SCRIPT := preload("res://client/pipeline/source_factory.gd")
const TEMP_PREFIX := "/tmp/annotool-workspace-catalog-"


class CancelToken extends RefCounted:
	var cancelled := false

	func is_cancelled() -> bool:
		return cancelled


func run(support) -> void:
	var script := ResourceLoader.load(CATALOG_PATH, "Script") as Script
	support.expect(script != null,
		"WorkspaceCatalog should exist so a folder can expose logical media units")
	if script == null:
		return
	_test_nested_media_and_sequence_claiming(script, support)
	_test_registry_claimed_locator(script, support)
	_test_claimed_workspace_discovery(script, support)
	_test_cancelled_scan_is_atomic(script, support)
	_test_media_id_collision_is_explicit(script, support)
	_test_portable_media_id_boundaries(support)


func _test_portable_media_id_boundaries(support) -> void:
	support.expect_equal(PATHS_SCRIPT.portable_media_id("Café"), "Caf",
		"non-ASCII characters should not be transliterated differently by runtime")
	support.expect_equal(
		PATHS_SCRIPT.portable_media_id("A".repeat(63) + " B"), "A".repeat(63),
		"64-character truncation should never leave a trailing separator")


func _test_nested_media_and_sequence_claiming(script: Script, support) -> void:
	var root := _new_temp_root("nested")
	DirAccess.make_dir_recursive_absolute(root.path_join("videos/VID68"))
	DirAccess.make_dir_recursive_absolute(root.path_join("patient"))
	DirAccess.make_dir_recursive_absolute(root.path_join("label"))
	DirAccess.make_dir_recursive_absolute(root.path_join("labels"))
	DirAccess.make_dir_recursive_absolute(root.path_join(".annotool/cache"))
	_write_text(root.path_join("videos/VID68/000023.png"), "not decoded during scan")
	_write_text(root.path_join("videos/VID68/000016.png"), "not decoded during scan")
	_write_text(root.path_join("patient/still.jpg"), "not decoded during scan")
	_write_text(root.path_join("operation.mp4"), "not probed during scan")
	_write_text(root.path_join("label/old.png"), "managed output")
	_write_text(root.path_join("labels/VID68.json"), "{}")
	_write_text(root.path_join(".annotool/cache/frame.png"), "managed cache")
	_write_text(root.path_join(".hidden.png"), "temporary")

	var catalog = script.new()
	var errors: PackedStringArray = catalog.scan(root)
	support.expect_equal(errors, PackedStringArray(),
		"nested workspace should scan without decoding media")
	var entries: Array = catalog.get_entries()
	support.expect_equal(entries.size(), 3,
		"sequence, standalone image, and video should be the only media units")
	support.expect_equal(_entry(entries, "videos/VID68").get("media_type"), "image_sequence",
		"numeric frame directory should be one image-sequence media item")
	support.expect_equal(_entry(entries, "patient/still.jpg").get("media_type"), "image",
		"ordinary photo should remain a standalone media item")
	support.expect_equal(_entry(entries, "operation.mp4").get("media_type"), "video",
		"video should be catalogued without probing it")
	support.expect(_entry(entries, "videos/VID68/000016.png").is_empty(),
		"claimed sequence frames must not also appear as standalone photos")
	support.expect(not DirAccess.dir_exists_absolute(root.path_join(".annotool/cache/operation")),
		"workspace scan must not start or publish a video import")

	var view_model: Dictionary = catalog.get_view_model()
	support.expect_equal(view_model.get("kind"), "workspace",
		"catalog should produce the explorer workspace view")
	support.expect_equal(view_model.get("media", []).size(), 3,
		"workspace view should expose only logical media units")
	_remove_tree(root)


func _test_media_id_collision_is_explicit(script: Script, support) -> void:
	var root := _new_temp_root("collision")
	DirAccess.make_dir_recursive_absolute(root.path_join("a"))
	DirAccess.make_dir_recursive_absolute(root.path_join("b"))
	_write_text(root.path_join("a/Same.png"), "a")
	_write_text(root.path_join("b/Same.jpg"), "b")

	var catalog = script.new()
	var errors: PackedStringArray = catalog.scan(root)
	support.expect(not errors.is_empty(),
		"duplicate portable media IDs should be rejected instead of silently renamed")
	support.expect("a/Same.png" in " ".join(errors) and "b/Same.jpg" in " ".join(errors),
		"collision error should identify both conflicting relative paths")
	support.expect_equal(catalog.get_entries(), [],
		"failed scan must not publish a partial workspace")
	_remove_tree(root)


func _test_registry_claimed_locator(script: Script, support) -> void:
	var root := _new_temp_root("plugin-source")
	_write_text(root.path_join("custom.fixture"), "plugin-owned locator")
	var registry = REGISTRY_SCRIPT.new()
	support.expect_equal(registry.discover_roots(PackedStringArray([
		"res://client/plugins",
		"res://tests/godot/fixtures/extension_plugins",
	])), PackedStringArray(),
		"workspace plugin fixture should discover with production plugins")
	var catalog = script.new()
	support.expect(catalog.has_method("configure_source_resolver"),
		"WorkspaceCatalog should accept the shared SourceFactory resolver")
	if catalog.has_method("configure_source_resolver"):
		catalog.configure_source_resolver(SOURCE_FACTORY_SCRIPT.new(registry))
	var errors: PackedStringArray = catalog.scan(root)
	support.expect_equal(errors, PackedStringArray(),
		"workspace scan should include a locator claimed by a Source plugin")
	var entries: Array = catalog.get_entries()
	support.expect_equal(entries.size(), 1,
		"a plugin-owned file should become one logical workspace media item")
	support.expect_equal(_entry(entries, "custom.fixture").get("media_type"), "image",
		"a plugin-owned file should use the existing file media contract")
	_remove_tree(root)


func _test_claimed_workspace_discovery(script: Script, support) -> void:
	var root := _new_temp_root("plugin-discovery")
	_write_text(root.path_join("custom.fixture"), "plugin-owned locator")
	DirAccess.make_dir_recursive_absolute(root.path_join("ignored"))
	_write_text(root.path_join("ignored/collision.png"), "generic scan must not run")
	var registry = REGISTRY_SCRIPT.new()
	support.expect_equal(registry.discover_roots(PackedStringArray([
		"res://client/plugins",
		"res://tests/godot/fixtures/extension_plugins",
	])), PackedStringArray(), "claimed-discovery fixture should load")
	var catalog = script.new()
	catalog.configure_source_resolver(SOURCE_FACTORY_SCRIPT.new(registry))
	var errors: PackedStringArray = catalog.scan(root)
	support.expect_equal(errors, PackedStringArray(),
		"claimed plugin discovery should replace generic recursion")
	var entries: Array = catalog.get_entries()
	support.expect_equal(entries.size(), 1,
		"claimed discovery should publish only its logical media list")
	support.expect_equal(_entry(entries, "custom.fixture").get("source_plugin_id"),
		"fixture_extension_source",
		"catalog should retain Factory ownership on a claimed entry")
	support.expect(_entry(entries, "ignored/collision.png").is_empty(),
		"generic recursion must stop after a plugin claims the workspace")
	_remove_tree(root)


func _test_cancelled_scan_is_atomic(script: Script, support) -> void:
	var first_root := _new_temp_root("cancel-existing")
	_write_text(first_root.path_join("still.png"), "existing")
	var catalog = script.new()
	support.expect_equal(catalog.scan(first_root), PackedStringArray(),
		"cancellation fixture should begin with a published catalog")
	var before: Dictionary = catalog.get_view_model()
	var token := CancelToken.new()
	token.cancelled = true
	var supports_token := _method_arity(script, "scan") == 2
	support.expect(supports_token,
		"WorkspaceCatalog.scan should accept a cooperative cancellation token")
	if supports_token:
		var second_root := _new_temp_root("cancel-candidate")
		_write_text(second_root.path_join("other.png"), "candidate")
		var errors: PackedStringArray = catalog.scan(second_root, token)
		support.expect("cancelled" in " ".join(errors).to_lower(),
			"a pre-cancelled scan should report cancellation")
		support.expect_equal(catalog.get_view_model(), before,
			"cancelled discovery must preserve the previously published catalog")
		_remove_tree(second_root)
	_remove_tree(first_root)


func _method_arity(script: Script, method_name: String) -> int:
	for method: Dictionary in script.get_script_method_list():
		if method.get("name") == method_name:
			return Array(method.get("args", [])).size()
	return -1


func _entry(entries: Array, relative_path: String) -> Dictionary:
	for value: Variant in entries:
		if value is Dictionary and value.get("relative_path") == relative_path:
			return value
	return {}


func _new_temp_root(label: String) -> String:
	var root := "%s%s-%d-%d" % [
		TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)


func _remove_tree(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for child_name: String in directory.get_directories():
		_remove_tree(path.path_join(child_name))
	DirAccess.remove_absolute(path)
