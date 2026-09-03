extends RefCounted

const REGISTRY_SCRIPT = preload("res://client/pipeline/plugin_registry.gd")
const RENDERER_SCRIPT = preload("res://client/plugins/render/canvas_region_renderer/plugin.gd")
const TRANSFORM_SCRIPT = preload("res://client/services/viewport_transform.gd")


static func run(support) -> void:
	_test_box_and_concave_polygon_hits(support)
	_test_repeated_polygon_vertex_does_not_hit_everything(support)
	_test_reverse_draw_order_wins(support)
	_test_overlay_descriptions(support)
	_test_production_registry_discovery(support)


static func _test_box_and_concave_polygon_hits(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	renderer.set_state(null, _record([_box_region(), _concave_region()]), _configured_transform(), "", 0.35)
	support.expect_equal(renderer.hit_test(Vector2(25, 25)).get("id"), "concave", "point inside concave polygon should hit it")
	support.expect_equal(renderer.hit_test(Vector2(80, 20)).get("id"), "concave", "point inside concave polygon arm should hit it")
	support.expect_equal(renderer.hit_test(Vector2(80, 80)), {}, "point in concave polygon notch should remain outside")
	support.expect_equal(renderer.hit_test(Vector2(45, 45)).get("id"), "box", "box-only point should hit the box")
	support.expect_equal(renderer.hit_test(Vector2(200, 200)), {}, "point outside every region should miss")


static func _test_repeated_polygon_vertex_does_not_hit_everything(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	var repeated_vertex_region := {
		"id": "repeated",
		"class": "unknown",
		"kind": "region",
		"polygon": [[0, 0], [100, 0], [100, 0], [100, 100], [0, 100]],
	}
	renderer.set_state(null, _record([repeated_vertex_region]), _configured_transform(), "", 0.35)
	support.expect_equal(renderer.hit_test(Vector2(150, 50)), {}, "a repeated polygon vertex must not turn a zero-length edge into a global hit")


static func _test_reverse_draw_order_wins(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	var transform = _configured_transform()
	renderer.set_state(null, _record([_box_region(), _concave_region()]), transform, "", 0.35)
	support.expect_equal(renderer.hit_test(Vector2(25, 25)).get("id"), "concave", "last overlapping region should be topmost")
	renderer.set_state(null, _record([_concave_region(), _box_region()]), transform, "", 0.35)
	support.expect_equal(renderer.hit_test(Vector2(25, 25)).get("id"), "box", "reversing region order should reverse the overlap winner")


static func _test_overlay_descriptions(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	var box := _box_region()
	box["conf"] = 0.92
	box["filled"] = true
	var polygon := _concave_region()
	polygon["class"] = "class_not_in_taxonomy"
	polygon["filled"] = true
	renderer.set_state(null, _record([box, polygon]), _configured_transform(), "box", 0.4)
	var commands: Array[Dictionary] = renderer.get_overlay_descriptions()
	support.expect_equal(commands.size(), 2, "one overlay description should be built per region")
	if commands.size() != 2:
		return
	var box_command := commands[0]
	support.expect_equal(box_command.get("shape"), "box", "box region should retain box geometry")
	support.expect(box_command.get("selected", false), "selected region should be emphasized")
	support.expect_equal(box_command.get("line_width"), 4.0, "selected outline should be wider")
	support.expect_equal(box_command.get("label"), "grasper 0.92", "confidence should be included when present")
	support.expect_equal(box_command.get("handles", []).size(), 8, "selected box should expose eight resize handles")
	var box_color: Color = box_command.get("color", Color.TRANSPARENT)
	support.expect(box_color.is_equal_approx(Color("#ef4444", 0.4)), "known class should use cached taxonomy color and global opacity")
	support.expect(box_command.get("fill", false), "filled box should request a fill")

	var polygon_command := commands[1]
	support.expect_equal(polygon_command.get("shape"), "polygon", "polygon region should retain polygon geometry")
	var outline: PackedVector2Array = polygon_command.get("outline", PackedVector2Array())
	support.expect(outline.size() == 7 and outline[0].is_equal_approx(outline[-1]), "polygon outline should be explicitly closed")
	support.expect_equal(polygon_command.get("label"), "class_not_in_taxonomy", "label without confidence should contain only the class")
	var fallback_color: Color = polygon_command.get("color", Color.TRANSPARENT)
	support.expect(fallback_color.is_equal_approx(Color("#a855f7", 0.4)), "unknown class should use the stable taxonomy fallback color")
	support.expect(polygon_command.get("fill", false), "concave polygon should request a fill")


static func _test_production_registry_discovery(support) -> void:
	var registry = REGISTRY_SCRIPT.new()
	var errors: PackedStringArray = registry.discover("res://client/plugins")
	support.expect_equal(errors, PackedStringArray(), "production render manifest should satisfy the strict registry contract")
	var renderer = registry.get_plugin("render", "canvas_region_renderer")
	support.expect(renderer != null, "production canvas renderer should be discovered")
	if renderer == null:
		return
	for method: String in ["set_state", "draw", "hit_test"]:
		support.expect(renderer.has_method(method), "production renderer should implement %s" % method)


static func _configured_transform():
	var transform = TRANSFORM_SCRIPT.new()
	transform.configure(Vector2(200, 120), Rect2(0, 0, 800, 600))
	return transform


static func _record(regions: Array) -> Dictionary:
	return {
		"schema_version": 1,
		"dataset_id": "renderer-test",
		"source": "model_output_v1",
		"frame": 0,
		"image_size": [200, 120],
		"regions": regions,
	}


static func _box_region() -> Dictionary:
	return {
		"id": "box",
		"class": "grasper",
		"kind": "instrument",
		"box": [10, 10, 40, 40],
	}


static func _concave_region() -> Dictionary:
	return {
		"id": "concave",
		"class": "cystic_duct",
		"kind": "anatomy",
		"polygon": [[0, 0], [100, 0], [100, 40], [40, 40], [40, 100], [0, 100]],
	}
