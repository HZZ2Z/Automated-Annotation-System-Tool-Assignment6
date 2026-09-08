## Synchronous, pure-data disk boundary. Call from a BackgroundJob, never the UI.
## A caller supplies its last observed file digest and a semantic validator.
extends RefCounted

const EXACT_JSON := preload("res://client/domain/exact_json.gd")

const CHUNK_BYTES := 65536

func read_document(path: String) -> Dictionary:
	if _is_link(path) or _has_link_ancestor(path.get_base_dir()):
		return _failure("Refusing symbolic-link document: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("Cannot read %s: %s" % [path, error_string(FileAccess.get_open_error())])
	var bytes := file.get_buffer(file.get_length())
	var error := file.get_error()
	file.close()
	if error != OK:
		return _failure("Cannot read complete document %s: %s" % [path, error_string(error)])
	var parser := EXACT_JSON.new()
	if parser.parse(bytes.get_string_from_utf8()) != OK or not parser.data is Dictionary:
		return _failure("Invalid JSON object in %s at line %d: %s" % [path, parser.get_error_line(), parser.get_error_message()])
	return {"success": true, "errors": [], "payload": parser.data, "sha256": _digest(bytes)}

func write_document(payload: Dictionary, options: Dictionary, token: Variant = null) -> Dictionary:
	var path := ProjectSettings.globalize_path(String(options.get("path", ""))).simplify_path()
	if String(options.get("path", "")).is_empty():
		return _failure("A document path is required")
	var validator: Callable = options.get("validate", Callable())
	if not validator.is_valid():
		return _failure("A document validator is required")
	var validation: Variant = validator.call(payload)
	if not validation is PackedStringArray or not validation.is_empty():
		return _failure("Document validation failed: %s" % str(validation))
	if _cancelled(token):
		return _cancel_result()
	var expected := String(options.get("expected_sha256", ""))
	var conflict := _check_expected(path, expected)
	if not conflict.is_empty():
		return _failure(conflict)
	var directory := path.get_base_dir()
	if _has_link_ancestor(directory):
		return _failure("Document directory must not traverse a symbolic link: %s" % directory)
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return _failure("Cannot create document directory %s: %s" % [directory, error_string(error)])
	if _has_link_ancestor(directory):
		return _failure("Document directory must not traverse a symbolic link: %s" % directory)
	var backup := ""
	if bool(options.get("backup_existing", false)) and not expected.is_empty():
		backup = path + ".legacy-" + expected + ".bak"
		var backup_errors := _preserve_original(path, backup, expected, token)
		if not backup_errors.is_empty():
			return _failure(backup_errors)
	var temporary := _temporary_path(path)
	if FileAccess.file_exists(temporary) or DirAccess.dir_exists_absolute(temporary) or _is_link(temporary):
		return _failure("Temporary path already exists: %s" % temporary)
	var bytes := (JSON.stringify(payload, "", true, true) + "\n").to_utf8_buffer()
	var write_error := _write_bytes(temporary, bytes, token)
	if not write_error.is_empty():
		_remove_owned_temp(temporary)
		return _cancel_result() if _cancelled(token) else _failure(write_error)
	var round_trip := read_document(temporary)
	if not round_trip.get("success", false):
		_remove_owned_temp(temporary)
		return round_trip
	validation = validator.call(round_trip.payload)
	if not validation is PackedStringArray or not validation.is_empty() or round_trip.sha256 != _digest(bytes):
		_remove_owned_temp(temporary)
		return _failure("Temporary document failed round-trip validation: %s" % str(validation))
	conflict = _check_expected(path, expected)
	if not conflict.is_empty() or _cancelled(token):
		_remove_owned_temp(temporary)
		return _cancel_result() if _cancelled(token) else _failure(conflict)
	error = _replace_file(temporary, path)
	if error != OK:
		_remove_owned_temp(temporary)
		return _failure("Cannot atomically publish %s: %s" % [path, error_string(error)])
	# Once published, cancellation cannot undo a completed save.
	return {"success": true, "errors": [], "path": path, "sha256": round_trip.sha256, "backup_path": backup}

func _check_expected(path: String, expected: String) -> String:
	if _is_link(path) or DirAccess.dir_exists_absolute(path):
		return "Document path is not a regular file: %s" % path
	var exists := FileAccess.file_exists(path)
	if expected.is_empty():
		return "Document changed externally; reopen before saving: %s" % path if exists else ""
	if not exists or FileAccess.get_sha256(path) != expected:
		return "Document changed externally; reopen before saving: %s" % path
	return ""

func _write_bytes(path: String, bytes: PackedByteArray, token: Variant) -> String:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		return "Temporary path already exists: %s" % path
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Cannot create %s: %s" % [path, error_string(FileAccess.get_open_error())]
	var offset := 0
	while offset < bytes.size():
		if _cancelled(token):
			file.close()
			return "Save cancelled"
		file.store_buffer(bytes.slice(offset, mini(offset + CHUNK_BYTES, bytes.size())))
		if file.get_error() != OK:
			var detail := error_string(file.get_error())
			file.close()
			return "Cannot write %s: %s" % [path, detail]
		offset += CHUNK_BYTES
	file.flush()
	var error := file.get_error()
	file.close()
	return "" if error == OK else "Cannot flush %s: %s" % [path, error_string(error)]

func _preserve_original(path: String, backup: String, expected: String, token: Variant) -> String:
	if FileAccess.file_exists(backup):
		return "" if not _is_link(backup) and FileAccess.get_sha256(backup) == expected else "Legacy backup conflict: %s" % backup
	if DirAccess.dir_exists_absolute(backup):
		return "Legacy backup path is occupied: %s" % backup
	var bytes := FileAccess.get_file_as_bytes(path)
	if _digest(bytes) != expected:
		return "Original changed while creating migration backup: %s" % path
	var temporary := _temporary_path(backup)
	if FileAccess.file_exists(temporary) or DirAccess.dir_exists_absolute(temporary) or _is_link(temporary):
		return "Temporary backup path already exists: %s" % temporary
	var error := _write_bytes(temporary, bytes, token)
	if not error.is_empty():
		_remove_owned_temp(temporary)
		return error
	if FileAccess.get_sha256(temporary) != expected:
		_remove_owned_temp(temporary)
		return "Migration backup checksum mismatch"
	var publish_error := _replace_file(temporary, backup)
	if publish_error != OK:
		_remove_owned_temp(temporary)
		return "Cannot publish migration backup: %s" % error_string(publish_error)
	return ""

func _replace_file(from: String, to: String) -> Error:
	return DirAccess.rename_absolute(from, to)

func _temporary_path(path: String) -> String:
	return "%s.tmp-%d-%d" % [path, OS.get_process_id(), Time.get_ticks_usec()]

func _remove_owned_temp(path: String) -> void:
	# This method receives only paths freshly allocated by this invocation.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())

func _has_link_ancestor(directory: String) -> bool:
	var current := directory
	while not current.is_empty() and current != "/":
		if _is_link(current):
			return true
		current = current.get_base_dir()
	return false

func _digest(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()

func _cancelled(token: Variant) -> bool:
	return token != null and token.is_cancelled()

func _failure(message: String) -> Dictionary:
	return {"success": false, "errors": [message], "cancelled": false}

func _cancel_result() -> Dictionary:
	return {"success": false, "errors": ["Save cancelled"], "cancelled": true}
