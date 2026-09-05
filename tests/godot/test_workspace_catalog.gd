extends RefCounted

const CATALOG_PATH := "res://client/workspace/workspace_catalog.gd"
const PATHS_SCRIPT := preload("res://client/workspace/workspace_paths.gd")
const TEMP_PREFIX := "/tmp/annotool-workspace-catalog-"


func run(support) -> void:
	var script := ResourceLoader.load(CATALOG_PATH, "Script") as Script
	support.expect(script != null,
		"WorkspaceCatalog should exist so a folder can expose logical media units")
	if script == null:
		return
	_test_nested_media_and_sequence_claiming(script, support)
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
