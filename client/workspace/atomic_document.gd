## Synchronous, pure-data disk boundary. Call from a BackgroundJob, never the UI.
## A caller supplies its last observed file digest and a semantic validator.
extends RefCounted

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
const STREAM_JSON := preload("res://client/domain/stream_json.gd")

const CHUNK_BYTES := 65536
var _stream_file: FileAccess
var _stream_write_us := 0

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
	var decoded := decode_utf8(bytes, path)
	if not decoded.success:
		return decoded
	var parser := EXACT_JSON.new()
	if parser.parse(decoded.text) != OK or not parser.data is Dictionary:
		return _failure("Invalid JSON object in %s at line %d: %s" % [path, parser.get_error_line(), parser.get_error_message()])
	return {"success": true, "errors": [], "payload": parser.data, "sha256": _digest(bytes)}

func decode_utf8(bytes: PackedByteArray, path: String) -> Dictionary:
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return _failure("Invalid UTF-8 in %s" % path)
	return {"success": true, "errors": [], "text": text}

func write_document(payload: Dictionary, options: Dictionary, token: Variant = null) -> Dictionary:
	var timings := {"serialize":0,"write":0,"serialize_write":0,"readback":0,"equivalence":0,"validate":0,"publish":0}
	var path := ProjectSettings.globalize_path(String(options.get("path", ""))).simplify_path()
	if String(options.get("path", "")).is_empty():
		return _failure("A document path is required")
	var validator: Callable = options.get("validate", Callable())
	if not validator.is_valid():
		return _failure("A document validator is required")
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
	var phase_start := Time.get_ticks_usec()
	var write_error := _begin_stream(temporary)
	var streamed := {}
	if write_error.is_empty():
		_stream_write_us = 0
		streamed = STREAM_JSON.new().write(payload,Callable(self,"_stream_chunk").bind(temporary,token),token,{"trailing_newline":true,"full_precision":true})
		write_error = _end_stream(temporary)
		if not streamed.get("success",false) and write_error.is_empty(): write_error = String(streamed.get("errors",["Cannot serialize JSON"])[0])
	timings.serialize_write = Time.get_ticks_usec()-phase_start
	timings.write = _stream_write_us
	timings.serialize = maxi(0,timings.serialize_write-timings.write)
	if not write_error.is_empty():
		_remove_owned_temp(temporary)
		return _cancel_result() if _cancelled(token) else _failure(write_error)
	phase_start = Time.get_ticks_usec()
	var round_trip := read_document(temporary)
	timings.readback = Time.get_ticks_usec()-phase_start
	if not round_trip.get("success", false):
		_remove_owned_temp(temporary)
		return round_trip
	# Validate the exact document that will be published once. Equality with the
	# frozen input also rejects JSON coercion (for example NaN becoming null).
	# A second full V3 decode before serialization adds another entire Store.
	phase_start = Time.get_ticks_usec()
	var equivalent := _json_equivalent(round_trip.payload,payload)
	timings.equivalence = Time.get_ticks_usec()-phase_start
	if not equivalent:
		_remove_owned_temp(temporary)
		return _failure("Temporary document differs from the frozen input")
	phase_start = Time.get_ticks_usec()
	var validation: Variant = validator.call(round_trip.payload)
	timings.validate = Time.get_ticks_usec()-phase_start
	if not validation is PackedStringArray or not validation.is_empty() or round_trip.sha256 != streamed.get("sha256",""):
		_remove_owned_temp(temporary)
		return _failure("Temporary document failed round-trip validation: %s" % str(validation))
	conflict = _check_expected(path, expected)
	if not conflict.is_empty() or _cancelled(token):
		_remove_owned_temp(temporary)
		return _cancel_result() if _cancelled(token) else _failure(conflict)
	phase_start = Time.get_ticks_usec()
	error = _replace_file(temporary, path)
	timings.publish = Time.get_ticks_usec()-phase_start
	if error != OK:
		_remove_owned_temp(temporary)
		return _failure("Cannot atomically publish %s: %s" % [path, error_string(error)])
	# Once published, cancellation cannot undo a completed save.
	return {"success": true, "errors": [], "path": path, "sha256": round_trip.sha256, "backup_path": backup,"bytes":streamed.get("bytes",0),"max_buffer_bytes":streamed.get("max_buffer_bytes",0),"timings_us":timings}

func _begin_stream(path: String) -> String:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path): return "Temporary path already exists: %s" % path
	_stream_file = FileAccess.open(path,FileAccess.WRITE)
	return "" if _stream_file != null else "Cannot create %s: %s" % [path,error_string(FileAccess.get_open_error())]

func _stream_chunk(bytes: PackedByteArray,path: String,token: Variant) -> String:
	var started := Time.get_ticks_usec()
	var result := _write_bytes(path,bytes,token)
	_stream_write_us += Time.get_ticks_usec()-started
	return result

func _end_stream(path: String) -> String:
	if _stream_file == null: return "Cannot create %s" % path
	_stream_file.flush()
	var error := _stream_file.get_error()
	_stream_file.close()
	_stream_file = null
	return "" if error == OK else "Cannot flush %s: %s" % [path,error_string(error)]

func _json_equivalent(left: Variant,right: Variant) -> bool:
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size(): return false
		for key: Variant in left:
			if not key is String or not right.has(key) or not _json_equivalent(left[key],right[key]): return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size(): return false
		for index in range(left.size()):
			if not _json_equivalent(left[index],right[index]): return false
		return true
	# Godot's container equality distinguishes JSON 12 from 12.0. Compare those
	# numerically, while refusing an integer rounded during double conversion.
	if typeof(left) == TYPE_INT and typeof(right) == TYPE_FLOAT:
		return is_finite(right) and right >= -9223372036854775808.0 and right < 9223372036854775808.0 and int(right) == left and right == floorf(right)
	if typeof(right) == TYPE_INT and typeof(left) == TYPE_FLOAT:
		return _json_equivalent(right,left)
	return typeof(left) == typeof(right) and typeof(left) in [TYPE_NIL,TYPE_STRING,TYPE_INT,TYPE_FLOAT,TYPE_BOOL] and left == right

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
	# During streaming this remains the fault-injection seam used by crash tests.
	if _stream_file != null:
		if _cancelled(token): return "Save cancelled"
		_stream_file.store_buffer(bytes)
		return "" if _stream_file.get_error() == OK else "Cannot write %s: %s" % [path,error_string(_stream_file.get_error())]
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
