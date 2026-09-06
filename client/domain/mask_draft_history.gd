class_name MaskDraftHistory
extends RefCounted

const OPS := preload("res://client/domain/mask_region_ops.gd")
var capacity := 200
var byte_budget := 32 * 1024 * 1024
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _bytes := 0


func record(before: Dictionary, after: Dictionary) -> void:
	if before == after:
		return
	var roi: Rect2i = before.roi.merge(after.roi)
	var indices := PackedInt32Array()
	var old := PackedByteArray()
	var next := PackedByteArray()
	for y in range(roi.position.y, roi.end.y):
		for x in range(roi.position.x, roi.end.x):
			var point := Vector2i(x, y)
			var a := OPS._byte_at(before.roi, before.mask, point)
			var b := OPS._byte_at(after.roi, after.mask, point)
			if a != b:
				indices.append((y - roi.position.y) * roi.size.x + x - roi.position.x)
				old.append(a)
				next.append(b)
	for entry: Dictionary in _redo:
		_bytes -= entry.bytes
	_redo.clear()
	var entry := {"roi": roi, "before_roi": before.roi, "after_roi": after.roi,
		"indices": indices, "old": old, "next": next, "bytes": indices.size() * 6 + 64}
	_undo.append(entry)
	_bytes += entry.bytes
	while _undo.size() > capacity or _bytes > byte_budget:
		_bytes -= _undo.pop_front().bytes


func undo(current: Dictionary) -> Dictionary:
	if _undo.is_empty():
		return {}
	var entry: Dictionary = _undo.pop_back()
	_redo.append(entry)
	return _restore(current, entry, true)


func redo(current: Dictionary) -> Dictionary:
	if _redo.is_empty():
		return {}
	var entry: Dictionary = _redo.pop_back()
	_undo.append(entry)
	return _restore(current, entry, false)


func clear() -> void:
	_undo.clear()
	_redo.clear()
	_bytes = 0


func counts() -> Dictionary:
	return {"undo": _undo.size(), "redo": _redo.size(), "bytes": _bytes}


func _restore(current: Dictionary, entry: Dictionary, reverse: bool) -> Dictionary:
	var roi: Rect2i = entry.before_roi if reverse else entry.after_roi
	var mask := PackedByteArray()
	mask.resize(roi.size.x * roi.size.y)
	for y in range(roi.position.y, roi.end.y):
		for x in range(roi.position.x, roi.end.x):
			mask[(y - roi.position.y) * roi.size.x + x - roi.position.x] = OPS._byte_at(current.roi, current.mask, Vector2i(x, y))
	var values: PackedByteArray = entry.old if reverse else entry.next
	for i in range(entry.indices.size()):
		var index: int = entry.indices[i]
		var point: Vector2i = entry.roi.position + Vector2i(index % entry.roi.size.x, index / entry.roi.size.x)
		if roi.has_point(point):
			mask[(point.y - roi.position.y) * roi.size.x + point.x - roi.position.x] = values[i]
	return {"roi": roi, "mask": mask}
