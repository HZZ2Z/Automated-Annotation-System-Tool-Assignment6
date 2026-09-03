@abstract
class_name SourceStage
extends RefCounted


@abstract func can_open(_locator: String) -> bool
@abstract func open(_locator: String) -> PackedStringArray
@abstract func get_frame_count() -> int
@abstract func get_frame_entry(_index: int) -> Dictionary
@abstract func get_model_records() -> Array[Dictionary]
@abstract func get_manifest() -> Dictionary
@abstract func get_presentation() -> Dictionary
@abstract func load_texture(_index: int) -> Texture2D
@abstract func close() -> void
