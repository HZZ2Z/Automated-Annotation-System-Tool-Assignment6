## Provider 只读取给定快照并产生候选；Store、历史和审核状态仍由控制器拥有。
class_name BatchPropagationProvider
extends RefCounted

func provider_id() -> StringName: return &""
func availability() -> Dictionary: return {"available":false,"reason":"Provider is not configured","details":{}}
func begin(_context: Dictionary) -> PackedStringArray: return PackedStringArray(["Provider is not implemented"])
func step() -> void: pass
func cancel() -> void: pass
func is_running() -> bool: return false
func progress_text() -> String: return ""
func get_result() -> Dictionary: return {}
func validate_source() -> PackedStringArray: return PackedStringArray()
