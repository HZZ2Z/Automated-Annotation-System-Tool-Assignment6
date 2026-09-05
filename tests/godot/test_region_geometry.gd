extends RefCounted

const REGION_GEOMETRY = preload("res://client/domain/region_geometry.gd")


static func run(support) -> void:
	_test_polygon_precedes_box(support)
	_test_invalid_polygon_falls_back_to_box(support)
	_test_concave_polygon_and_boundary_hits(support)
	_test_invalid_geometry_is_rejected(support)
	_test_geometry_fits_inclusive_image_bounds(support)


static func _test_polygon_precedes_box(support) -> void:
	var region := {
		"box": [0, 0, 100, 100],
		"polygon": [[10, 10], [40, 10], [40, 40], [10, 40]],
	}
	support.expect_equal(REGION_GEOMETRY.canonical_shape(region), &"polygon", "a valid polygon should be canonical when a fallback box is also present")
	support.expect(REGION_GEOMETRY.contains(region, Vector2(20, 20)), "the canonical polygon interior should hit")
	support.expect(not REGION_GEOMETRY.contains(region, Vector2(80, 80)), "the fallback box must not expand a valid polygon hit area")
	support.expect_equal(REGION_GEOMETRY.image_bounds(region), Rect2(10, 10, 30, 30), "bounds should describe only the canonical polygon")


static func _test_invalid_polygon_falls_back_to_box(support) -> void:
	var region := {
		"box": [5, 6, 30, 40],
		"polygon": [[10, 10], [20, 20]],
	}
	support.expect_equal(REGION_GEOMETRY.canonical_shape(region), &"box", "a polygon with fewer than three vertices should fall back to a valid box")
	support.expect(REGION_GEOMETRY.contains(region, Vector2(10, 10)), "fallback box geometry should remain selectable")
	support.expect(REGION_GEOMETRY.contains(region, Vector2(35, 46)), "box bottom-right boundary should remain selectable for resize handles")
	support.expect_equal(REGION_GEOMETRY.image_bounds(region), Rect2(5, 6, 30, 40), "fallback bounds should come from the box")


static func _test_concave_polygon_and_boundary_hits(support) -> void:
	var region := {
		"polygon": [[0, 0], [100, 0], [100, 40], [40, 40], [40, 100], [0, 100], [0, 100]],
	}
	support.expect(REGION_GEOMETRY.contains(region, Vector2(20, 80)), "a concave polygon arm should hit")
	support.expect(not REGION_GEOMETRY.contains(region, Vector2(80, 80)), "a concave polygon notch should miss")
	support.expect(REGION_GEOMETRY.contains(region, Vector2(40, 75)), "a polygon boundary should be selectable")
	support.expect(not REGION_GEOMETRY.contains(region, Vector2(150, 50)), "a repeated vertex must not create a global boundary hit")


static func _test_invalid_geometry_is_rejected(support) -> void:
	for region: Dictionary in [
		{},
		{"box": [0, 0, 0, 10]},
		{"box": [0, 0, INF, 10]},
		{"polygon": [[0, 0], [10, NAN], [20, 0]]},
	]:
		support.expect_equal(REGION_GEOMETRY.canonical_shape(region), &"", "invalid region geometry should have no canonical shape")
		support.expect(not REGION_GEOMETRY.contains(region, Vector2.ZERO), "invalid region geometry should never hit")


static func _test_geometry_fits_inclusive_image_bounds(support) -> void:
	var image_size := Vector2(100, 80)
	support.expect(
		REGION_GEOMETRY.fits_image({"box": [0, 0, 100, 80]}, image_size),
		"a box whose ends equal the image size should fit the inclusive image boundary",
	)
	support.expect(
		not REGION_GEOMETRY.fits_image({"box": [90, 70, 11, 10]}, image_size),
		"a box end beyond the right image edge must be rejected",
	)
	support.expect(
		REGION_GEOMETRY.fits_image({
			"box": [-50, -50, 200, 200],
			"polygon": [[0, 0], [100, 0], [50, 80]],
		}, image_size),
		"canonical polygon bounds should take priority over a stale out-of-bounds fallback box",
	)
	support.expect(
		not REGION_GEOMETRY.fits_image({"polygon": [[0, 0], [101, 0], [50, 80]]}, image_size),
		"a polygon point beyond an image edge must be rejected",
	)
	support.expect(
		not REGION_GEOMETRY.fits_image({"polygon": [[0, 0], [NAN, 10], [20, 20]]}, image_size),
		"region image fitting should inherit the shared non-finite point refusal",
	)
	support.expect(
		not REGION_GEOMETRY.fits_image({"box": [0, 0, 10, 10]}, Vector2.ZERO),
		"an unavailable image size must never validate geometry",
	)
