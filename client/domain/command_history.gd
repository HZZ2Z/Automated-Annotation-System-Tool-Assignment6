class_name CommandHistory
extends RefCounted


var capacity: int
var _undo_stack: Array = []
var _redo_stack: Array = []


func _init(requested_capacity: int = 200) -> void:
	capacity = maxi(1, requested_capacity)


func execute(command: Variant, store: Variant) -> PackedStringArray:
	if not command is Object:
		return PackedStringArray(["command: expected an object with apply(store) and revert(store)"])
	if not command.has_method("apply") or not command.has_method("revert"):
		return PackedStringArray(["command: expected apply(store) and revert(store)"])
	if command.has_method("is_noop"):
		var no_op: Variant = command.is_noop()
		if typeof(no_op) != TYPE_BOOL:
			return PackedStringArray(["command: is_noop must return bool"])
		if no_op:
			return PackedStringArray()
	var result: Variant = command.apply(store)
	if not result is PackedStringArray:
		return PackedStringArray(["command: apply must return PackedStringArray"])
	if not result.is_empty():
		return result
	_undo_stack.append(command)
	_trim_undo_stack()
	_redo_stack.clear()
	return result


func undo(store: Variant) -> bool:
	if _undo_stack.is_empty():
		return false
	var command: Variant = _undo_stack.pop_back()
	command.revert(store)
	_redo_stack.append(command)
	return true


func redo(store: Variant) -> PackedStringArray:
	if _redo_stack.is_empty():
		return PackedStringArray(["history: nothing to redo"])
	var command: Variant = _redo_stack.back()
	var result: Variant = command.apply(store)
	if not result is PackedStringArray:
		return PackedStringArray(["command: apply must return PackedStringArray"])
	if not result.is_empty():
		return result
	_redo_stack.pop_back()
	_undo_stack.append(command)
	_trim_undo_stack()
	return result


func can_undo() -> bool:
	return not _undo_stack.is_empty()


func can_redo() -> bool:
	return not _redo_stack.is_empty()


func get_undo_count() -> int:
	return _undo_stack.size()


func get_redo_count() -> int:
	return _redo_stack.size()


func _trim_undo_stack() -> void:
	while _undo_stack.size() > capacity:
		_undo_stack.pop_front()
