extends RefCounted


const CLASS_COLOR_RESOLVER := preload("res://client/domain/class_color_resolver.gd")


static func run(support) -> void:
	var resolver = CLASS_COLOR_RESOLVER.new({"classes": [
		{"id": "grasper", "color": "#ef4444"},
	]})
	support.expect(resolver.color_for("grasper").is_equal_approx(Color("#ef4444")),
		"explicit taxonomy color must win")
	support.expect_equal(resolver.color_for("custom lesion"), resolver.color_for(" custom lesion "),
		"trimmed equivalent labels must resolve identically")
	support.expect_equal(resolver.color_for("custom lesion"),
		CLASS_COLOR_RESOLVER.new({}).color_for("custom lesion"),
		"custom colors must be stable across resolver instances")
	support.expect(resolver.color_for("custom lesion") != resolver.color_for("another lesion"),
		"ordinary distinct custom labels should not collapse to one fallback")
