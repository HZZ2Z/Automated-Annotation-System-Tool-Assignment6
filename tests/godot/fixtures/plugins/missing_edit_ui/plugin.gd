extends RefCounted

func activate(_context: Dictionary) -> PackedStringArray: return PackedStringArray()
func handle_pointer(_event: InputEvent, _image_position: Vector2) -> void: pass
func handle_key(_event: InputEvent) -> bool: return false
func begin_add_box() -> void: pass
func cancel() -> void: pass
