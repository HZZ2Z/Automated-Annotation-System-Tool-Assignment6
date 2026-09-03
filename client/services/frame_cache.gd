class_name FrameCache
extends RefCounted

var max_size: int
var last_error := ""
var _values: Dictionary = {}
var _order: Array[int] = []


func _init(size: int = 12) -> void:
	max_size = maxi(1, size)


func get_value(index: int, loader: Callable) -> Variant:
	last_error = ""
	if index < 0:
		last_error = "cache index must be non-negative"
		return null
	if _values.has(index):
		_touch(index)
		return _values[index]
	if not loader.is_valid():
		last_error = "cache loader is not callable"
		return null
	var value: Variant = loader.call(index)
	if value == null:
		last_error = "cache loader returned null for index %d" % index
		return null
	_values[index] = value
	_touch(index)
	while _order.size() > max_size:
		_values.erase(_order.pop_front())
	return value


func has(index: int) -> bool:
	return _values.has(index)


func size() -> int:
	return _values.size()


func clear() -> void:
	_values.clear()
	_order.clear()
	last_error = ""


func _touch(index: int) -> void:
	var position := _order.find(index)
	if position >= 0:
		_order.remove_at(position)
	_order.append(index)
