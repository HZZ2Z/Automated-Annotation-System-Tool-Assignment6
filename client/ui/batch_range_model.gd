## 候选端点只在播放索引和原始帧号之间映射，不推导稀疏帧的索引。
class_name BatchRangeModel
extends RefCounted

var _indices := PackedInt64Array()
var _frame_ids := PackedInt64Array()

func configure(entries: Array, start_index: int, key_index: int, end_index: int) -> PackedStringArray:
	_indices.clear()
	_frame_ids.clear()
	if start_index < 0 or start_index > key_index or key_index > end_index or end_index >= entries.size():
		return PackedStringArray(["Candidate range is outside the accepted Source entries"])
	for index in range(start_index, end_index + 1):
		var frame_id: Variant = entries[index].get("frame_id")
		if typeof(frame_id) != TYPE_INT:
			_indices.clear()
			_frame_ids.clear()
			return PackedStringArray(["Candidate range has an invalid original frame ID"])
		_indices.append(index)
		_frame_ids.append(int(frame_id))
	return PackedStringArray()

func indices() -> PackedInt64Array:
	return _indices.duplicate()

func frame_ids() -> PackedInt64Array:
	return _frame_ids.duplicate()

func index_at(option: int) -> int:
	return int(_indices[option]) if option >= 0 and option < _indices.size() else -1

func option_for_index(index: int) -> int:
	return _indices.find(index)
