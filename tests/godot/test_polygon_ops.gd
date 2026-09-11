extends SceneTree

const POLYGON_OPS = preload("res://client/domain/polygon_ops.gd")
const TEST_SUPPORT = preload("res://tests/godot/test_support.gd")


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var support = TEST_SUPPORT.new()
	_test_sanitize_freehand(support)
	_test_simple_polygon_validation(support)
	_test_ring_equivalence_ignores_start_and_winding(support)
	_test_box_conversion_and_bounds(support)
	_test_points_fit_inclusive_image_bounds(support)
	_test_affine_resize_by_handle(support)
	_test_boolean_single_and_empty_results(support)
	_test_boolean_multi_component_results(support)
	_test_boolean_holes_and_invalid_topology(support)
	_test_morphological_close(support)
	_test_brush_stroke_polygon(support)
	if support.failures.is_empty():
		print("PASS: PolygonOps vector geometry")
		quit(0)
		return
	push_error("FAIL: PolygonOps vector geometry\n%s" % support.failure_report())
	quit(1)


func _test_sanitize_freehand(support) -> void:
	var samples := PackedVector2Array([
		Vector2(0, 0),
		Vector2(0, 0),
		Vector2(4, 0),
		Vector2(8, 0),
		Vector2(8, 8),
		Vector2(0, 8),
		Vector2(0.2, 0.2),
	])
	var sanitized: PackedVector2Array = POLYGON_OPS.sanitize_freehand(samples, 0.25, 0.5)
	support.expect_equal(
		sanitized,
		PackedVector2Array([Vector2(0, 0), Vector2(8, 0), Vector2(8, 8), Vector2(0, 8)]),
		"freehand sanitizing should deduplicate, snap-close, and simplify a ring without storing a repeated endpoint",
	)
	support.expect_equal(
		POLYGON_OPS.sanitize_freehand(PackedVector2Array([Vector2.ZERO, Vector2(NAN, 1), Vector2.ONE])),
		PackedVector2Array(),
		"freehand sanitizing should reject non-finite samples",
	)
	support.expect_equal(
		POLYGON_OPS.sanitize_freehand(PackedVector2Array([
			Vector2(0, 0), Vector2(10, 10), Vector2(0, 10), Vector2(10, 0),
		])),
		PackedVector2Array(),
		"freehand sanitizing must refuse a self-intersecting ring before it reaches a command",
	)
	support.expect_equal(
		POLYGON_OPS.sanitize_freehand(PackedVector2Array([
			Vector2(0, 0), Vector2(5, 0), Vector2(10, 0),
		])),
		PackedVector2Array(),
		"freehand sanitizing must refuse a zero-area ring before it reaches a command",
	)
	support.expect_equal(
		POLYGON_OPS.sanitize_freehand(PackedVector2Array([
			Vector2(0, 0), Vector2(20, 0), Vector2(20, 20), Vector2(10, 20),
		]), 0.0, 3.0),
		PackedVector2Array(),
		"a commit-time close tolerance must refuse a contour whose endpoints are not approximately closed",
	)


func _test_simple_polygon_validation(support) -> void:
	var rectangle := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	var concave := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 4), Vector2(4, 4), Vector2(4, 10), Vector2(0, 10)])
	var bow_tie := PackedVector2Array([Vector2(0, 0), Vector2(10, 10), Vector2(0, 10), Vector2(10, 0)])
	support.expect(POLYGON_OPS.validate_simple_polygon(rectangle), "a rectangle should be a valid simple polygon")
	support.expect(POLYGON_OPS.validate_simple_polygon(concave), "a concave non-self-intersecting ring should be valid")
	support.expect(not POLYGON_OPS.validate_simple_polygon(bow_tie), "a self-intersecting bow-tie must be rejected")
	support.expect(
		not POLYGON_OPS.validate_simple_polygon(PackedVector2Array([Vector2.ZERO, Vector2(10, 0), Vector2(20, 0)])),
		"a zero-area collinear ring must be rejected",
	)
	support.expect(
		not POLYGON_OPS.validate_simple_polygon(PackedVector2Array([Vector2.ZERO, Vector2(10, 0), Vector2(10, 10), Vector2.ZERO])),
		"an explicitly repeated closing endpoint must be rejected by the canonical ring validator",
	)
	support.expect(
		not POLYGON_OPS.validate_simple_polygon(PackedVector2Array([Vector2.ZERO, Vector2(10, 0), Vector2(0, 10), Vector2(10, 0)])),
		"a repeated non-adjacent vertex must be rejected",
	)


func _test_ring_equivalence_ignores_start_and_winding(support) -> void:
	var ring := PackedVector2Array([
		Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10),
	])
	var rotated := PackedVector2Array([
		Vector2(10, 10), Vector2(0, 10), Vector2(0, 0), Vector2(10, 0),
	])
	var reversed := PackedVector2Array([
		Vector2(0, 0), Vector2(0, 10), Vector2(10, 10), Vector2(10, 0),
	])
	var changed := PackedVector2Array([
		Vector2(0, 0), Vector2(11, 0), Vector2(10, 10), Vector2(0, 10),
	])
	var densified_reversed := PackedVector2Array([
		Vector2(10, 5), Vector2(10, 0), Vector2(5, 0), Vector2(0, 0),
		Vector2(0, 5), Vector2(0, 10), Vector2(5, 10), Vector2(10, 10),
	])
	var repeated_closure_and_duplicates := PackedVector2Array([
		Vector2(0, 0), Vector2(0, 0), Vector2(5, 0), Vector2(10, 0),
		Vector2(10, 10), Vector2(0, 10), Vector2(0, 0), Vector2(0, 0),
	])
	var concave := PackedVector2Array([
		Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(5, 5), Vector2(0, 10),
	])
	var concave_without_corner := PackedVector2Array([
		Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10),
	])
	support.expect(POLYGON_OPS.equivalent_ring(ring, rotated), "ring equality should ignore the chosen first vertex")
	support.expect(POLYGON_OPS.equivalent_ring(ring, reversed), "ring equality should ignore winding direction")
	support.expect(
		POLYGON_OPS.equivalent_ring(ring, densified_reversed),
		"ring equality should ignore rotated/reversed extra collinear vertices from Geometry2D",
	)
	support.expect(
		POLYGON_OPS.equivalent_ring(ring, repeated_closure_and_duplicates),
		"ring equality should ignore repeated closure and consecutive zero-length vertices",
	)
	support.expect(
		not POLYGON_OPS.equivalent_ring(concave, concave_without_corner),
		"ring equality must retain a genuine concave corner while removing only collinear vertices",
	)
	support.expect(not POLYGON_OPS.equivalent_ring(ring, changed), "ring equality must still detect a real geometry change")


func _test_box_conversion_and_bounds(support) -> void:
	var expected := PackedVector2Array([Vector2(10, 20), Vector2(40, 20), Vector2(40, 60), Vector2(10, 60)])
	support.expect_equal(POLYGON_OPS.box_to_polygon([10, 20, 30, 40]), expected, "a V1 box array should convert to its four corners")
	support.expect_equal(POLYGON_OPS.box_to_polygon(Rect2(10, 20, 30, 40)), expected, "a Rect2 should use the same corner order as a V1 box")
	support.expect_equal(POLYGON_OPS.box_to_polygon([10, 20, 0, 40]), PackedVector2Array(), "a non-positive box should not produce a polygon")
	support.expect_equal(
		POLYGON_OPS.polygon_bounds(PackedVector2Array([Vector2(-2, 4), Vector2(5, 3), Vector2(1, 9)])),
		Rect2(-2, 3, 7, 6),
		"polygon bounds should include every vertex",
	)
	support.expect_equal(POLYGON_OPS.polygon_bounds(PackedVector2Array()), Rect2(), "an empty ring should have empty bounds")


func _test_points_fit_inclusive_image_bounds(support) -> void:
	var boundary := PackedVector2Array([Vector2.ZERO, Vector2(100, 0), Vector2(100, 80), Vector2(0, 80)])
	support.expect(POLYGON_OPS.points_fit_image(boundary, Vector2(100, 80)), "points on every image edge should fit the inclusive boundary")
	support.expect(POLYGON_OPS.points_fit_image([[0, 0], [100, 80]], Vector2(100, 80)), "array points should share the same image-boundary predicate")
	support.expect(not POLYGON_OPS.points_fit_image([[-0.01, 0], [10, 10]], Vector2(100, 80)), "a negative point must not fit the image")
	support.expect(not POLYGON_OPS.points_fit_image([[0, 0], [100.01, 80]], Vector2(100, 80)), "a point beyond the far edge must not fit the image")
	support.expect(
		not POLYGON_OPS.points_fit_image(
			PackedVector2Array([Vector2.ZERO, Vector2(NAN, 10), Vector2(20, 20)]),
			Vector2(100, 80),
		),
		"a PackedVector2Array NaN must not bypass the finite image-boundary contract",
	)
	support.expect(
		not POLYGON_OPS.points_fit_image(
			PackedVector2Array([Vector2.ZERO, Vector2(10, INF), Vector2(20, 20)]),
			Vector2(100, 80),
		),
		"a PackedVector2Array infinity must not fit the image",
	)
	support.expect(not POLYGON_OPS.points_fit_image(boundary, Vector2(NAN, 80)), "a non-finite image size must be rejected")
	support.expect(not POLYGON_OPS.points_fit_image(boundary, Vector2(0, 80)), "a non-positive image size must be rejected")


func _test_affine_resize_by_handle(support) -> void:
	var rectangle := POLYGON_OPS.box_to_polygon([0, 0, 10, 10])
	var corner_scaled: PackedVector2Array = POLYGON_OPS.resize_by_handle(rectangle, 4, Vector2(20, 30))
	support.expect_equal(
		corner_scaled,
		PackedVector2Array([Vector2(0, 0), Vector2(20, 0), Vector2(20, 30), Vector2(0, 30)]),
		"bottom-right resize should scale both polygon axes around the opposite corner",
	)
	var triangle := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])
	support.expect_equal(
		POLYGON_OPS.resize_by_handle(triangle, 4, Vector2(20, 30)),
		PackedVector2Array([Vector2(0, 0), Vector2(20, 0), Vector2(0, 30)]),
		"affine resize should preserve non-box polygon geometry",
	)
	support.expect_equal(
		POLYGON_OPS.resize_by_handle(rectangle, 7, Vector2(-5, 999)),
		PackedVector2Array([Vector2(-5, 0), Vector2(10, 0), Vector2(10, 10), Vector2(-5, 10)]),
		"a left-middle handle should resize only the horizontal axis",
	)
	var clamped: PackedVector2Array = POLYGON_OPS.resize_by_handle(rectangle, 0, Vector2(20, 20), 2.0)
	support.expect_equal(POLYGON_OPS.polygon_bounds(clamped), Rect2(8, 8, 2, 2), "a handle must not cross its opposite side or collapse below the minimum size")
	support.expect_equal(POLYGON_OPS.resize_by_handle(rectangle, 8, Vector2.ONE), PackedVector2Array(), "an unknown handle should be rejected")


func _test_boolean_single_and_empty_results(support) -> void:
	var left := POLYGON_OPS.box_to_polygon([0, 0, 10, 10])
	var overlapping := POLYGON_OPS.box_to_polygon([5, 0, 10, 10])
	var merged: Dictionary = POLYGON_OPS.union(left, overlapping)
	_expect_result_contract(merged, support)
	support.expect_equal(merged.status, &"single", "overlapping polygons should union to one V1-safe outer ring")
	support.expect(POLYGON_OPS.validate_simple_polygon(merged.polygon), "a single union result should itself be a valid simple polygon")
	support.expect(is_equal_approx(_absolute_area(merged.polygon), 150.0), "overlapping 10x10 boxes should have union area 150")
	support.expect_equal(POLYGON_OPS.polygon_bounds(merged.polygon), Rect2(0, 0, 15, 10), "the single union result should cover both boxes")

	var removed: Dictionary = POLYGON_OPS.difference(left, left)
	_expect_result_contract(removed, support)
	support.expect_equal(removed.status, &"empty", "subtracting an identical polygon should produce an explicit empty result")
	support.expect_equal(removed.polygon, PackedVector2Array(), "an empty boolean result must not expose a fake primary polygon")
	support.expect(removed.polygons.is_empty(), "an empty boolean result must contain no rings")

	var untouched: Dictionary = POLYGON_OPS.difference(left, POLYGON_OPS.box_to_polygon([20, 20, 5, 5]))
	support.expect_equal(untouched.status, &"single", "subtracting a disjoint polygon should preserve one outer ring")
	support.expect(is_equal_approx(_absolute_area(untouched.polygon), 100.0), "a disjoint subtraction should preserve the subject area")


func _test_boolean_multi_component_results(support) -> void:
	var left := POLYGON_OPS.box_to_polygon([0, 0, 10, 10])
	var right := POLYGON_OPS.box_to_polygon([20, 0, 10, 10])
	var disjoint_union: Dictionary = POLYGON_OPS.union(left, right)
	_expect_result_contract(disjoint_union, support)
	support.expect_equal(disjoint_union.status, &"multi_component", "a disjoint union should report multiple components")
	support.expect_equal(disjoint_union.polygons.size(), 2, "all disjoint union components must be retained")
	support.expect_equal(disjoint_union.polygon, PackedVector2Array(), "a multi-component result must not silently select one primary polygon")

	var stripe := POLYGON_OPS.box_to_polygon([4, -1, 2, 12])
	var split: Dictionary = POLYGON_OPS.difference(left, stripe)
	_expect_result_contract(split, support)
	support.expect_equal(split.status, &"multi_component", "a subtraction that splits the subject should report multiple components")
	support.expect_equal(split.polygons.size(), 2, "both pieces of a split subtraction must be retained")


func _test_boolean_holes_and_invalid_topology(support) -> void:
	var outer := POLYGON_OPS.box_to_polygon([0, 0, 20, 20])
	var inner := POLYGON_OPS.box_to_polygon([5, 5, 10, 10])
	var holed: Dictionary = POLYGON_OPS.difference(outer, inner)
	_expect_result_contract(holed, support)
	support.expect_equal(holed.status, &"unsupported_topology", "a difference with a hole must be rejected as unsupported by V1")
	support.expect_equal(holed.polygons.size(), 2, "the outer and hole rings must both be retained for diagnosis")
	support.expect_equal(holed.polygon, PackedVector2Array(), "a holed result must never silently discard the inner ring")
	support.expect(not String(holed.message).is_empty(), "an unsupported topology result should explain the refusal")

	var bow_tie := PackedVector2Array([Vector2(0, 0), Vector2(10, 10), Vector2(0, 10), Vector2(10, 0)])
	var invalid: Dictionary = POLYGON_OPS.union(bow_tie, inner)
	_expect_result_contract(invalid, support)
	support.expect_equal(invalid.status, &"unsupported_topology", "invalid boolean inputs should be rejected before Geometry2D")
	support.expect(invalid.polygons.is_empty(), "invalid inputs should not fabricate output rings")
	support.expect(not String(invalid.message).is_empty(), "invalid input refusal should carry a message")


func _test_morphological_close(support) -> void:
	var narrow_notch := PackedVector2Array([
		Vector2(10, 10), Vector2(30, 10), Vector2(30, 30), Vector2(21, 30),
		Vector2(21, 14), Vector2(19, 14), Vector2(19, 30), Vector2(10, 30),
	])
	var closed: Dictionary = POLYGON_OPS.close_polygon(narrow_notch, 2.0)
	_expect_result_contract(closed, support)
	support.expect_equal(closed.status, &"single", "closing a narrow notch should retain one V1-safe component")
	support.expect(POLYGON_OPS.validate_simple_polygon(closed.polygon), "the closed contour should remain a simple polygon")
	support.expect(_absolute_area(closed.polygon) > _absolute_area(narrow_notch), "closing should add area across the narrow notch")
	var refused: Dictionary = POLYGON_OPS.close_polygon(narrow_notch, -1.0)
	support.expect_equal(refused.status, &"unsupported_topology", "a non-positive closing radius should be refused")


func _test_brush_stroke_polygon(support) -> void:
	var stroke: Dictionary = POLYGON_OPS.stroke_polygon(
		PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)]),
		3.0,
	)
	_expect_result_contract(stroke, support)
	support.expect_equal(stroke.status, &"single", "one continuous brush stroke should form one polygon")
	support.expect(POLYGON_OPS.validate_simple_polygon(stroke.polygon), "a brush footprint should be a V1-safe simple polygon")
	support.expect(POLYGON_OPS.polygon_bounds(stroke.polygon).size.x > 20.0, "round brush caps should extend beyond both stroke endpoints")
	var dot: Dictionary = POLYGON_OPS.stroke_polygon(PackedVector2Array([Vector2(5, 5)]), 2.0)
	support.expect_equal(dot.status, &"single", "one brush click should create a circular footprint")
	support.expect(POLYGON_OPS.validate_simple_polygon(dot.polygon), "a brush dot should be a simple polygon")


func _expect_result_contract(result: Dictionary, support) -> void:
	support.expect(result.has("status"), "boolean results should expose a status")
	support.expect(result.has("polygon"), "boolean results should expose a single-ring slot")
	support.expect(result.has("polygons"), "boolean results should retain every returned ring")
	support.expect(result.has("message"), "boolean results should expose a diagnostic message")


func _absolute_area(polygon: PackedVector2Array) -> float:
	var twice_area := 0.0
	for index in range(polygon.size()):
		twice_area += polygon[index].cross(polygon[(index + 1) % polygon.size()])
	return absf(twice_area) * 0.5
