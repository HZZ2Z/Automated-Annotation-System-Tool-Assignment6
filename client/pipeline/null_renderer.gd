class_name NullRenderer
extends "res://client/pipeline/stages/render_stage.gd"


func set_state(_texture: Texture2D, _record: Dictionary, _transform: Variant, _selected_id: String, _opacity: float) -> void:
	pass


func draw(_canvas: CanvasItem) -> void:
	pass


func hit_test(_image_point: Vector2) -> Dictionary:
	return {}
