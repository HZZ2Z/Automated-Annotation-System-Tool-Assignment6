extends SceneTree

const RESOLVER := preload("res://client/workspace/export_baseline_resolver.gd")
const SESSION_LOADER := preload("res://client/workspace/session_loader.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")


class TestToken:
	extends RefCounted
	var _cancelled: bool

	func _init(cancelled: bool) -> void:
		_cancelled = cancelled

	func is_cancelled() -> bool:
		return _cancelled


func _initialize() -> void:
	var support := SUPPORT.new()
	var base := "/tmp/export-baseline-resolver-%d-%d" % [
		OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(base)
	_test_resolver_contract(support, base)
	_test_session_descriptor_contract(support, base)
	for failure: String in support.failures:
		print("FAIL: " + failure)
	if support.failures.is_empty():
		print("PASS trusted workspace baseline resolution")
	_remove_tree(base)
	quit(0 if support.failures.is_empty() else 1)


func _test_resolver_contract(s, base: String) -> void:
	var root := base.path_join("workspace")
	var label_directory := root.path_join("labels")
	DirAccess.make_dir_recursive_absolute(label_directory)
	var label_path := label_directory.path_join("VID68.json")
	var source_label := _cholect50_label(false)
	_write_text(label_path, JSON.stringify(source_label))
	var snapshot := {
		"media_id": "VID68",
		"source": "source://VID68",
		"frame_entries": [
			{"frame": 0, "frame_id": 16},
			{"frame": 1, "frame_id": 23, "time_s": 0.92},
			{"frame": 2, "frame_id": 30, "time_s": 1.2},
		],
	}
	var descriptor := {
		"kind": "cholect50",
		"path": label_path,
		"root": root,
		"media_id": "VID68",
		"image_size": [800.0, 450.0],
	}
	var snapshot_before := snapshot.duplicate(true)
	var descriptor_before := descriptor.duplicate(true)
	var result: Dictionary = RESOLVER.new().resolve(snapshot, descriptor)
	s.expect(result.get("success", false), "trusted Cholec baseline resolves: %s" % str(result.get("errors")))
	s.expect_equal(result.get("records", []).size(), 3,
		"resolver completes Source coverage")
	if result.get("records", []).size() == 3:
		var records: Array = result.records
		s.expect_equal(records[0].get("source"), snapshot.source,
			"resolver uses exact frozen Source identity")
		s.expect_equal(records.map(func(record): return record.get("frame")), [16, 23, 30],
			"resolver preserves exact sparse frame identities and order")
		s.expect(not records[0].has("time_s"),
			"resolver preserves absent optional Source time")
		s.expect_equal(records[1].get("regions"), [],
			"missing annotation becomes empty baseline")
		s.expect_equal(records[1].get("time_s"), snapshot.frame_entries[1].time_s,
			"empty baseline preserves optional Source time")
		s.expect_equal(records[2].get("time_s"), snapshot.frame_entries[2].time_s,
			"annotated baseline uses Source time instead of adapter-derived time")
	s.expect_equal(result.get("source_sha256"), FileAccess.get_sha256(label_path),
		"resolver reports deterministic exact source bytes SHA-256")
	s.expect_equal(snapshot, snapshot_before, "resolver is read-only for snapshot input")
	s.expect_equal(descriptor, descriptor_before, "resolver is read-only for descriptor input")
	if result.get("descriptor") is Dictionary:
		result.descriptor.image_size[0] = 1.0
		s.expect_equal(descriptor.image_size[0], 800.0,
			"resolver result owns a deep descriptor copy")

	var cancelled := RESOLVER.new().resolve(
		snapshot, descriptor, TestToken.new(true))
	s.expect(not cancelled.get("success", true), "cancelled resolution is rejected")
	s.expect(_contains(cancelled.get("errors", []), "cancel"),
		"cancelled resolution explains its gate")
	var extended_descriptor := descriptor.duplicate(true)
	extended_descriptor["fallback_path"] = label_path
	var extended := RESOLVER.new().resolve(snapshot, extended_descriptor)
	s.expect(not extended.get("success", true),
		"unrecognized descriptor keys cannot expand the trusted Source boundary")

	var outside_path := base.path_join("outside.json")
	_write_text(outside_path, JSON.stringify(source_label))
	var traversal := descriptor.duplicate(true)
	traversal.path = root.path_join("../outside.json")
	var traversed := RESOLVER.new().resolve(snapshot, traversal)
	s.expect(not traversed.get("success", true),
		"descriptor path traversal outside the selected root is rejected")
	s.expect(_contains(traversed.get("errors", []), "root"),
		"traversal rejection identifies the trusted root boundary")

	var linked_path := label_directory.path_join("linked.json")
	var link_error := OS.execute("ln", ["-s", outside_path, linked_path])
	s.expect_equal(link_error, OK, "symlink refusal fixture is created")
	if link_error == OK:
		var linked := descriptor.duplicate(true)
		linked.path = linked_path
		var linked_result := RESOLVER.new().resolve(snapshot, linked)
		s.expect(not linked_result.get("success", true),
			"declared baseline symbolic link is rejected")
		s.expect(_contains(linked_result.get("errors", []), "symbolic"),
			"symlink rejection identifies link safety")


func _test_session_descriptor_contract(s, base: String) -> void:
	var root := base.path_join("session-workspace")
	DirAccess.make_dir_recursive_absolute(root.path_join("labels"))
	var imported_path := root.path_join("labels/VID68.json")
	_write_text(imported_path, JSON.stringify(_cholect50_label(true)))
	var entries := [
		{"frame": 0, "frame_id": 16, "time_s": 0.64},
		{"frame": 1, "frame_id": 30, "time_s": 1.2},
	]
	var options := {
		"root": root,
		"media": {
			"media_id": "VID68",
			"media_type": "image_sequence",
			"relative_path": "videos/VID68",
			"source_relative_path": "videos/VID68",
			"source_sha256": null,
			"label_root": root,
		},
		"frame_entries": entries,
		"records": [],
		"manifest": {"model_version": "none"},
		"image_size": Vector2(800.0, 450.0),
		"taxonomy_version": "t1",
	}
	var loader := SESSION_LOADER.new()
	var first: Dictionary = loader.open_workspace(options, TestToken.new(false))
	s.expect(first.get("success", false),
		"source-labelled workspace opens: %s" % str(first.get("errors")))
	if not first.get("success", false):
		return
	s.expect_equal(first.label_store.flush(), PackedStringArray(),
		"first source import persists a native session fixture")
	var second: Dictionary = loader.open_workspace(options, TestToken.new(false))
	s.expect(second.get("success", false),
		"workspace with an existing native session reopens")
	if not second.get("success", false):
		return
	var expected := {
		"kind": "cholect50",
		"path": imported_path,
		"root": root,
		"media_id": "VID68",
		"image_size": [800.0, 450.0],
	}
	var exposed: Dictionary = second.label_store.baseline_descriptor()
	s.expect_equal(exposed, expected,
		"session loader retains the canonical Source-declared descriptor even after native save")
	exposed.path = "mutated-by-caller"
	s.expect_equal(second.label_store.baseline_descriptor(), expected,
		"media label store returns an isolated descriptor copy")
	second.label_store.clear()
	s.expect_equal(second.label_store.baseline_descriptor(), {},
		"clearing the media store clears its transient descriptor")


func _cholect50_label(include_all_source_entries: bool) -> Dictionary:
	var annotations := {
		"16": [[0, 0, 0, 0.1, 0.2, 0.3, 0.4, 0]],
		"30": [[1, 0, 0, 0.5, 0.1, 0.2, 0.3, 0]],
	}
	if include_all_source_entries:
		annotations["23"] = []
	return {
		"fps": 25.0,
		"categories": {"instrument": {"0": "grasper"}},
		"annotations": annotations,
	}


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)
		file.close()


func _contains(values: Variant, needle: String) -> bool:
	for value: Variant in values:
		if needle.to_lower() in String(value).to_lower():
			return true
	return false


func _remove_tree(path: String) -> void:
	if FileAccess.file_exists(path) or _is_link(path):
		DirAccess.remove_absolute(path)
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	for directory_name: String in directory.get_directories():
		var child := path.path_join(directory_name)
		if directory.is_link(directory_name):
			DirAccess.remove_absolute(child)
		else:
			_remove_tree(child)
	DirAccess.remove_absolute(path)


func _is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())
