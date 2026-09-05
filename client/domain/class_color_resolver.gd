class_name ClassColorResolver
extends RefCounted


const DEFAULT_COLOR := Color("#a855f7")
var _explicit_colors: Dictionary = {}


func _init(taxonomy: Dictionary = {}) -> void:
	for value: Variant in taxonomy.get("classes", []):
		if value is Dictionary:
			var label := normalized_label(str(value.get("id", "")))
			var encoded: Variant = value.get("color")
			if not label.is_empty() and typeof(encoded) == TYPE_STRING:
				_explicit_colors[label] = Color.from_string(String(encoded), DEFAULT_COLOR)


func color_for(class_label: String) -> Color:
	var label := normalized_label(class_label)
	if _explicit_colors.has(label):
		return _explicit_colors[label]
	var value := _fnv1a_32(label)
	var hue := float(value % 360) / 360.0
	return Color.from_hsv(hue, 0.72, 0.92, 1.0)


func normalized_label(class_label: String) -> String:
	return class_label.strip_edges()


func _fnv1a_32(value: String) -> int:
	var result := 2166136261
	for byte: int in value.to_utf8_buffer():
		result = ((result ^ byte) * 16777619) & 0xffffffff
	return result
