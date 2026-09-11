extends RefCounted

func activate(_context: Dictionary) -> PackedStringArray: return PackedStringArray()
func set_active_tool(_tool_id: StringName) -> PackedStringArray: return PackedStringArray()
func get_active_tool() -> StringName: return &"select"
func handle_pointer(_event: InputEvent, _image_position: Vector2) -> void: pass
func handle_key(_event: InputEvent) -> bool: return false
func begin_add_box() -> void: pass
func cancel() -> void: pass
