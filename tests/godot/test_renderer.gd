extends RefCounted

const REGISTRY_SCRIPT = preload("res://client/pipeline/plugin_registry.gd")
const CLASS_COLOR_RESOLVER = preload("res://client/domain/class_color_resolver.gd")
const RENDERER_SCRIPT = preload("res://client/plugins/render/canvas_region_renderer/plugin.gd")
const TRANSFORM_SCRIPT = preload("res://client/services/viewport_transform.gd")


static func run(support) -> void:
	_test_box_and_concave_polygon_hits(support)
	_test_polygon_precedence_when_both_exist(support)
	_test_record_state_is_an_isolated_snapshot(support)
	_test_repeated_polygon_vertex_does_not_hit_everything(support)
	_test_reverse_draw_order_wins(support)
	_test_overlay_descriptions(support)
	_test_transient_hover_reuses_geometry_cache(support)
	_test_brush_preview_suppresses_only_committed_drawing(support)
	_test_committed_overlay_descriptions_have_no_preview_ids(support)
	_test_geometry_cache_and_viewport_culling(support)
	_test_production_registry_discovery(support)


static func _test_box_and_concave_polygon_hits(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	renderer.set_state(null, _record([_box_region(), _concave_region()]), _configured_transform(), "", 0.35)
	support.expect_equal(renderer.hit_test(Vector2(25, 25)).get("id"), "concave", "point inside concave polygon should hit it")
	support.expect_equal(renderer.hit_test(Vector2(80, 20)).get("id"), "concave", "point inside concave polygon arm should hit it")
	support.expect_equal(renderer.hit_test(Vector2(80, 80)), {}, "point in concave polygon notch should remain outside")
	support.expect_equal(renderer.hit_test(Vector2(45, 45)).get("id"), "box", "box-only point should hit the box")
	support.expect_equal(renderer.hit_test(Vector2(200, 200)), {}, "point outside every region should miss")


static func _test_record_state_is_an_isolated_snapshot(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	var caller_record := _record([_box_region()])
	renderer.set_state(null, caller_record, _configured_transform(), "", 0.35)
	caller_record["regions"][0]["id"] = "caller-mutated"
	caller_record["regions"][0]["box"] = [120, 10, 40, 40]
	var caller_snapshot: Dictionary = caller_record.duplicate(true)
	support.expect_equal(renderer.hit_test(Vector2(25, 25)).get("id"), "box", "renderer should keep the snapshot supplied to set_state")
	support.expect_equal(renderer.hit_test(Vector2(135, 25)), {}, "caller mutation should not change renderer hit testing before another set_state")
	var descriptions: Array[Dictionary] = renderer.get_overlay_descriptions()
	support.expect_equal(descriptions[0].get("id"), "box", "caller mutation should not change current overlay descriptions")
	support.expect_equal(caller_record, caller_snapshot, "renderer reads must never modify the caller's annotation dictionary")

	renderer.set_state(null, caller_record, _configured_transform(), "", 0.35)
	support.expect_equal(renderer.hit_test(Vector2(25, 25)), {}, "explicitly setting a changed snapshot should replace old renderer geometry")
	support.expect_equal(renderer.hit_test(Vector2(135, 25)).get("id"), "caller-mutated", "explicitly setting a changed snapshot should update renderer hit testing")


static func _test_polygon_precedence_when_both_exist(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	var hybrid := _box_region()
	hybrid["id"] = "hybrid"
	hybrid["polygon"] = [[10, 10], [30, 10], [30, 30], [10, 30]]
	renderer.set_state(null, _record([hybrid]), _configured_transform(), "", 0.35)
	support.expect_equal(renderer.hit_test(Vector2(20, 20)).get("id"), "hybrid", "hybrid region should hit inside its canonical polygon")
	support.expect_equal(renderer.hit_test(Vector2(45, 45)), {}, "hybrid region box should be ignored outside its valid polygon")
	var descriptions: Array[Dictionary] = renderer.get_overlay_descriptions()
	support.expect(descriptions.size() == 1 and descriptions[0].get("shape") == "polygon", "hybrid region should be rendered once as a polygon")


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
	var polygon := _concave_region()
	polygon["class"] = "class_not_in_taxonomy"
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
	support.expect(box_color.is_equal_approx(Color("#ef4444", 1.0)), "known-class outline should remain fully opaque")
	var selected_fill: Color = box_command.get("fill_color", Color.TRANSPARENT)
	support.expect(selected_fill.is_equal_approx(Color("#ef4444", 1.0)), "selected fill should remain fully opaque regardless of the slider")
	support.expect(box_command.get("fill", false), "schema-valid regions without a filled field should show an overlay fill")
	var label_background: Rect2 = box_command.get("label_background", Rect2())
	support.expect(_configured_transform().viewport_rect.encloses(label_background), "label background should be clamped inside the viewport")

	var polygon_command := commands[1]
	support.expect_equal(polygon_command.get("shape"), "polygon", "polygon region should retain polygon geometry")
	var outline: PackedVector2Array = polygon_command.get("outline", PackedVector2Array())
	support.expect(outline.size() == 7 and outline[0].is_equal_approx(outline[-1]), "polygon outline should be explicitly closed")
	support.expect_equal(polygon_command.get("label"), "class_not_in_taxonomy", "label without confidence should contain only the class")
	var fallback_color: Color = polygon_command.get("color", Color.TRANSPARENT)
	var expected_fallback: Color = CLASS_COLOR_RESOLVER.new({}).color_for("class_not_in_taxonomy")
	support.expect(fallback_color.is_equal_approx(expected_fallback), "unknown-class outline should use the resolver's deterministic fallback color")
	var polygon_fill: Color = polygon_command.get("fill_color", Color.TRANSPARENT)
	var expected_fallback_fill := expected_fallback
	expected_fallback_fill.a = 0.4
	support.expect(polygon_fill.is_equal_approx(expected_fallback_fill), "opacity should affect only the unselected class-color fill")
	support.expect(polygon_command.get("fill", false), "concave polygon without a filled field should request an overlay fill")

	renderer.set_state(null, _record([box, polygon]), _configured_transform(), "concave", 0.4)
	var selected_polygon_commands: Array[Dictionary] = renderer.get_overlay_descriptions()
	support.expect_equal(selected_polygon_commands[1].get("handles", []).size(), 8, "selected polygon should expose eight bounds-resize handles")


static func _test_transient_hover_reuses_geometry_cache(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	renderer.set_state(null, _record([_box_region(), _concave_region()]), _configured_transform(), "", 0.35)
	var before: Dictionary = renderer.get_cache_stats()
	var normal := _command_for_id(renderer.get_overlay_descriptions(), "concave")
	renderer.set_hovered_region_id("concave")
	var commands: Array[Dictionary] = renderer.get_overlay_descriptions()
	var hovered := _command_for_id(commands, "concave")
	var box := _command_for_id(commands, "box")
	var hovered_fill: Color = hovered.get("fill_color", Color.TRANSPARENT)
	var hovered_outline: Color = hovered.get("color", Color.TRANSPARENT)
	support.expect(hovered.get("hovered", false), "hovered command must expose transient hover state")
	support.expect_equal(hovered.get("line_width"), 3.0, "hovered region should use the dedicated hover outline width")
	support.expect(hovered_fill.a > 0.64 and hovered_fill.a <= 1.0, "hovered fill should remain visibly opaque (got %.3f)" % hovered_fill.a)
	support.expect(hovered_outline.a == 1.0, "hovered outline must remain fully opaque")
	var normal_outline: Color = normal.get("color", Color.TRANSPARENT)
	support.expect(hovered_outline.is_equal_approx(normal_outline.darkened(0.18)), "hovered outline should darken the normal class color by 0.18")
	support.expect(not box.get("hovered", false), "hover must affect exactly one stable region ID")
	var after: Dictionary = renderer.get_cache_stats()
	support.expect_equal(after.get("geometry_rebuilds"), before.get("geometry_rebuilds"), "hover must reuse cached image-space geometry")
	support.expect(int(after.get("screen_rebuilds", 0)) > int(before.get("screen_rebuilds", 0)), "hover must rebuild screen-space commands")

	renderer.set_state(null, _record([_box_region(), _concave_region()]), _configured_transform(), "concave", 0.35)
	renderer.set_hovered_region_id("concave")
	var selected_hover := _command_for_id(renderer.get_overlay_descriptions(), "concave")
	support.expect(selected_hover.get("selected", false), "selected region must retain selected state while hovered")
	support.expect(not selected_hover.get("hovered", false), "selection must dominate hover presentation")
	support.expect_equal(selected_hover.get("line_width"), 4.0, "selected styling must retain the selected outline width")
	var selected_fill: Color = selected_hover.get("fill_color", Color.TRANSPARENT)
	support.expect_equal(selected_fill.a, 1.0, "selected fill must remain fully opaque while hovered")

	renderer.set_state(null, _record([_box_region(), _concave_region()]), _configured_transform(), "", 0.35)
	renderer.set_hovered_region_id("")
	var cleared := _command_for_id(renderer.get_overlay_descriptions(), "concave")
	support.expect(not cleared.get("hovered", false), "empty hover ID must restore normal rendering")
	support.expect_equal(cleared.get("line_width"), 2.0, "clearing hover must restore normal outline width")


static func _test_brush_preview_suppresses_only_committed_drawing(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	renderer.set_state(null, _record([_box_region(), _concave_region()]), _configured_transform(), "box", 0.35)
	var before: Dictionary = renderer.get_cache_stats()
	renderer.set_suppressed_region_id("box")
	var commands: Array[Dictionary] = renderer.get_overlay_descriptions()
	support.expect_equal(_command_for_id(commands, "box"), {},
		"a brush result preview should hide the selected committed shape instead of drawing both")
	support.expect(not _command_for_id(commands, "concave").is_empty(),
		"brush suppression must not hide unrelated regions")
	support.expect_equal(renderer.hit_test(Vector2(45, 45)).get("id"), "box",
		"visual suppression must not change image-space hit testing")
	var suppressed_stats: Dictionary = renderer.get_cache_stats()
	support.expect_equal(suppressed_stats.get("geometry_rebuilds"), before.get("geometry_rebuilds"),
		"transient brush suppression must reuse parsed geometry")
	renderer.set_suppressed_region_ids(PackedStringArray(["box", "concave"]))
	support.expect_equal(renderer.get_overlay_descriptions().size(), 0, "batch preview hides every affected region")
	renderer.set_suppressed_region_ids(PackedStringArray())
	support.expect_equal(renderer.get_overlay_descriptions().size(), 2, "cancelling batch preview restores all regions")
	renderer.set_suppressed_region_id("")
	support.expect(not _command_for_id(renderer.get_overlay_descriptions(), "box").is_empty(),
		"clearing a brush preview should restore the committed region")


static func _command_for_id(commands: Array[Dictionary], region_id: String) -> Dictionary:
	for command: Dictionary in commands:
		if str(command.get("id", "")) == region_id:
			return command
	return {}


static func _test_committed_overlay_descriptions_have_no_preview_ids(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	renderer.set_state(null, _record([_box_region(), _concave_region()]), _configured_transform(), "", 0.35)
	for description: Dictionary in renderer.get_overlay_descriptions():
		support.expect(not str(description.get("id", "")).begins_with("__"), "Renderer receives committed regions only; transient IDs belong to EditOverlay")


static func _test_geometry_cache_and_viewport_culling(support) -> void:
	var renderer = RENDERER_SCRIPT.new()
	var record := _record([_box_region(), _concave_region()])
	var transform = _configured_transform()
	renderer.set_state(null, record, transform, "", 0.35)
	var initial_stats: Dictionary = renderer.get_cache_stats()
	support.expect_equal(initial_stats.get("geometry_rebuilds"), 1, "first record state should parse geometry once")
	transform.pan_by(Vector2(25, -10))
	renderer.set_state(null, record, transform, "", 0.6)
	var transformed_stats: Dictionary = renderer.get_cache_stats()
	support.expect_equal(transformed_stats.get("geometry_rebuilds"), 1, "zoom, pan, selection, and opacity changes should reuse parsed image-space geometry")
	support.expect(int(transformed_stats.get("screen_rebuilds", 0)) > int(initial_stats.get("screen_rebuilds", 0)), "view changes should rebuild only screen-space commands")
	transform.pan_by(Vector2(5000, 5000))
	renderer.set_state(null, record, transform, "", 0.6)
	support.expect_equal(renderer.get_overlay_descriptions().size(), 0, "regions fully outside the viewport should be culled from draw commands")
	record["regions"][0]["box"] = [120, 10, 40, 40]
	renderer.set_state(null, record, transform, "", 0.6)
	support.expect_equal(renderer.get_cache_stats().get("geometry_rebuilds"), 2, "an explicit in-place record mutation should invalidate the geometry snapshot")


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
