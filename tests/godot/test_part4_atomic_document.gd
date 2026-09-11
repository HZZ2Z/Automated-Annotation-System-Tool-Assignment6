extends SceneTree

var failures: Array[String] = []

class NullableValidator extends RefCounted:
	func validate(value: Variant) -> PackedStringArray:
		return PackedStringArray() if value.get("value") == null else PackedStringArray(["value must be null"])

class Validator extends RefCounted:
	func validate(value: Variant) -> PackedStringArray:
		return PackedStringArray() if value is Dictionary and value.get("value") is String else PackedStringArray(["value must be text"])

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var script_path := "res://client/workspace/atomic_document.gd"
	if not ResourceLoader.exists(script_path):
		printerr("FAIL: atomic document persistence is missing")
		quit(1)
		return
	var backend = load(script_path).new()
	var validator := Validator.new()
	var directory := "/tmp/part4-atomic-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var path := directory.path_join("label.json")
	var options := {"path": path, "expected_sha256": "", "validate": Callable(validator, "validate")}
	var first: Dictionary = backend.write_document({"schema_version": 2, "value": "before"}, options)
	_expect(first.get("success", false), "initial atomic save succeeds")
	var original := FileAccess.get_file_as_bytes(path)
	options.expected_sha256 = first.get("sha256", "")
	var invalid: Dictionary = backend.write_document({"value": 3}, options)
	_expect(not invalid.get("success", false), "invalid data is refused")
	_expect(FileAccess.get_file_as_bytes(path) == original, "invalid data leaves saved bytes unchanged")
	options.backup_existing = true
	var next: Dictionary = backend.write_document({"schema_version": 3, "value": "after"}, options)
	_expect(next.get("success", false), "migration save succeeds")
	_expect(FileAccess.get_file_as_bytes(String(next.get("backup_path", ""))) == original, "migration backup is byte-for-byte exact")
	var saved := FileAccess.get_file_as_bytes(path)
	var conflict: Dictionary = backend.write_document({"value": "stale overwrite"}, options)
	_expect(not conflict.get("success", false), "a stale external digest is refused")
	_expect(FileAccess.get_file_as_bytes(path) == saved, "conflict preserves latest saved data")
	var nullable := NullableValidator.new()
	var lossy: Dictionary = backend.write_document({"value":NAN},{"path":directory.path_join("lossy.json"),"validate":Callable(nullable,"validate")})
	_expect(not lossy.success and not FileAccess.file_exists(directory.path_join("lossy.json")),"JSON coercion cannot turn invalid input into an accepted saved document")
	var read: Dictionary = backend.read_document(path)
	_expect(read.get("payload", {}).get("value") == "after", "read round-trip recovers saved data")
	_expect(read.get("sha256") == FileAccess.get_sha256(path), "read reports exact file checksum")
	for name in DirAccess.get_files_at(directory):
		_expect(not ".tmp-" in name, "completed writes leave no temporary file")
	# Only fixtures under the unique directory created by this test are removed.
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)
	if failures.is_empty():
		print("PASS Part 4 atomic document")
		quit(0)
	else:
		printerr("\n".join(failures))
		quit(1)

func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
