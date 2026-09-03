@abstract
class_name EditStage
extends RefCounted


@abstract func get_tool_descriptors() -> Array[Dictionary]
@abstract func activate(_context: Dictionary) -> PackedStringArray
@abstract func set_active_tool(_tool_id: StringName) -> PackedStringArray
@abstract func get_active_tool() -> StringName
@abstract func handle_pointer(_event: InputEvent, _image_position: Vector2) -> void
@abstract func handle_key(_event: InputEvent) -> bool
@abstract func invoke(_action_id: StringName, _payload: Dictionary = {}) -> PackedStringArray
@abstract func cancel() -> void
@abstract func deactivate() -> void
