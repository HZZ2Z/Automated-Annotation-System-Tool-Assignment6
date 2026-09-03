@abstract
class_name RenderStage
extends RefCounted


@abstract func set_state(_texture: Texture2D, _record: Dictionary, _transform: Variant, _selected_id: String, _opacity: float) -> void
@abstract func draw(_canvas: CanvasItem) -> void
@abstract func hit_test(_image_point: Vector2) -> Dictionary
