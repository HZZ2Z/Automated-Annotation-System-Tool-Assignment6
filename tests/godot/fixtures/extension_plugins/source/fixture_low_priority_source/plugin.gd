extends "res://client/pipeline/stages/source_stage.gd"

func can_open(locator: String) -> bool: return locator.get_extension().to_lower() == "fixture"
func open(_locator: String) -> PackedStringArray: return PackedStringArray()
func get_frame_count() -> int: return 1
func get_frame_entry(_index: int) -> Dictionary: return {"frame": 0, "time_s": 0.0}
func get_model_records() -> Array[Dictionary]: return []
func get_manifest() -> Dictionary: return {}
func get_presentation() -> Dictionary: return {}
func load_texture(_index: int) -> Texture2D: return null
func close() -> void: pass
