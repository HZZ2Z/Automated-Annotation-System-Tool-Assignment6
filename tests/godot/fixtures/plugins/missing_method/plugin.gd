extends RefCounted

func open(_path: String) -> PackedStringArray: return PackedStringArray()
func get_frame_count() -> int: return 0
func get_frame_entry(_index: int) -> Dictionary: return {}
func get_model_records() -> Array[Dictionary]: return []
func close() -> void: pass
