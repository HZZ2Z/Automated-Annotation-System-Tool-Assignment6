## Bounded compact JSON encoder. Container order is canonical: object keys are
## sorted recursively and array order is preserved. Scalar spelling and escapes
## are delegated to Godot's native JSON encoder.
class_name StreamJson
extends RefCounted

const CHUNK_BYTES := 65536

var _sink := Callable()
var _token: Variant
var _buffer := PackedByteArray()
var _hash := HashingContext.new()
var _bytes := 0
var _max_buffer := 0
var _error := ""
var _full_precision := true

func write(value: Variant, sink: Callable, token: Variant = null, options: Dictionary = {}) -> Dictionary:
	if not sink.is_valid():
		return _failure("A JSON byte sink is required")
	_sink = sink
	_token = token
	_full_precision = bool(options.get("full_precision",true))
	_buffer = PackedByteArray()
	_bytes = 0
	_max_buffer = 0
	_error = ""
	_hash = HashingContext.new()
	_hash.start(HashingContext.HASH_SHA256)
	if _cancelled(): return _cancel_result()
	_emit_value(value,false)
	if _error.is_empty() and bool(options.get("trailing_newline",false)): _append_text("\n")
	if _error.is_empty(): _flush()
	if not _error.is_empty():
		return _cancel_result() if _cancelled() else _failure(_error)
	return {"success":true,"errors":[],"cancelled":false,"sha256":_hash.finish().hex_encode(),"bytes":_bytes,"max_buffer_bytes":_max_buffer}

func _emit_value(value: Variant, native_subtree: bool = false) -> void:
	if not _error.is_empty() or _cancelled():
		if _error.is_empty(): _error = "JSON serialization cancelled"
		return
	if value is Dictionary:
		if native_subtree:
			_append_text(JSON.stringify(_sorted_copy(value),"",true,_full_precision))
			return
		_append_text("{")
		var keys: Array = value.keys()
		keys.sort()
		for index in range(keys.size()):
			if index > 0: _append_text(",")
			_append_text(JSON.stringify(keys[index],"",true,_full_precision))
			_append_text(":")
			_emit_value(value[keys[index]],false)
		_append_text("}")
	elif value is Array:
		_append_text("[")
		for index in range(value.size()):
			if index > 0: _append_text(",")
			_emit_value(value[index],value[index] is Dictionary)
		_append_text("]")
	else:
		_append_text(JSON.stringify(value,"",true,_full_precision))

static func _sorted_copy(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys(); keys.sort()
		var result := {}
		for key: Variant in keys: result[key] = _sorted_copy(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value: result.append(_sorted_copy(item))
		return result
	return value

func _append_text(fragment: String) -> void:
	if not _error.is_empty(): return
	var encoded := fragment.to_utf8_buffer()
	var offset := 0
	while offset < encoded.size():
		if _cancelled(): _error = "JSON serialization cancelled"; return
		var take := mini(CHUNK_BYTES-_buffer.size(),encoded.size()-offset)
		_buffer.append_array(encoded.slice(offset,offset+take))
		offset += take
		_max_buffer = maxi(_max_buffer,_buffer.size())
		if _buffer.size() == CHUNK_BYTES:
			_flush()
			if not _error.is_empty(): return

func _flush() -> void:
	if _buffer.is_empty() or not _error.is_empty(): return
	if _cancelled(): _error = "JSON serialization cancelled"; return
	var chunk := _buffer
	_buffer = PackedByteArray()
	var outcome: Variant = _sink.call(chunk)
	if outcome is String and not outcome.is_empty(): _error = outcome; return
	if outcome is Error and outcome != OK: _error = error_string(outcome); return
	_hash.update(chunk)
	_bytes += chunk.size()

func _cancelled() -> bool:
	return _token != null and _token.is_cancelled()

func _failure(message: String) -> Dictionary:
	return {"success":false,"errors":[message],"cancelled":false,"bytes":_bytes,"max_buffer_bytes":_max_buffer}

func _cancel_result() -> Dictionary:
	return {"success":false,"errors":["JSON serialization cancelled"],"cancelled":true,"bytes":_bytes,"max_buffer_bytes":_max_buffer}

static func record_digests(records: Array) -> Dictionary:
	var references := records.duplicate()
	references.sort_custom(func(left: Variant,right: Variant): return float(left.get("frame",0)) < float(right.get("frame",0)))
	var legacy := HashingContext.new(); legacy.start(HashingContext.HASH_SHA256)
	var current := HashingContext.new(); current.start(HashingContext.HASH_SHA256)
	legacy.update("[".to_utf8_buffer()); current.update("[".to_utf8_buffer())
	for index in range(references.size()):
		if index > 0: legacy.update(",".to_utf8_buffer()); current.update(",".to_utf8_buffer())
		var normalized: Variant = _normalize(references[index])
		legacy.update(JSON.stringify(normalized).to_utf8_buffer())
		current.update(JSON.stringify(normalized,"",true,true).to_utf8_buffer())
	legacy.update("]".to_utf8_buffer()); current.update("]".to_utf8_buffer())
	return {"legacy":legacy.finish().hex_encode(),"current":current.finish().hex_encode()}

static func _normalize(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys(); keys.sort()
		var result := {}
		for key: Variant in keys: result[key] = _normalize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value: result.append(_normalize(item))
		return result
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT: return float(value)
	return value
