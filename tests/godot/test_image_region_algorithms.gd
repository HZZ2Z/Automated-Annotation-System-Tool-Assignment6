extends SceneTree

const ALGORITHMS = preload("res://client/domain/image_region_algorithms.gd")
const POLYGON_OPS = preload("res://client/domain/polygon_ops.gd")

var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var algorithms: Object = ALGORITHMS.new()
	if (
		algorithms == null
		or not algorithms.has_method("region_grow")
		or not algorithms.has_method("region_grow_expanding")
		or not algorithms.has_method("live_wire")
	):
		push_error("FAIL: image region algorithms\nalgorithm script did not compile")
		quit(1)
		return
	_test_region_grow_is_seed_connected_and_tolerance_bounded()
	_test_region_grow_refuses_empty_and_unsupported_topology()
	_test_region_grow_refuses_an_artificially_truncated_roi()
	_test_region_grow_validates_inputs()
	_test_region_grow_expands_only_when_truncated_and_preserves_metadata()
	_test_region_grow_bias_changes_the_frozen_reference_candidate()
	_test_region_grow_expanding_finishes_at_an_image_edge()
	_test_region_grow_expanding_caps_before_an_oversized_retry()
	_test_region_grow_expanding_allows_a_local_result_on_a_large_image()
	_test_region_grow_expanding_validates_new_inputs_and_keeps_image_immutable()
	_test_region_grow_expanding_smooths_stair_steps_within_one_pixel()
	_test_region_grow_expanding_preserves_one_opaque_pixel()
	_test_region_grow_expanding_preserves_a_horizontal_one_pixel_strip()
	_test_region_grow_expanding_preserves_a_vertical_one_pixel_strip()
	_test_region_grow_expanding_is_exactly_deterministic()
	_test_region_grow_expanding_matches_legacy_transparent_and_boundary_behavior()
	_test_polygonize_refuses_excessive_boundary_complexity()
	_test_live_wire_prefers_a_strong_edge_deterministically()
	_test_live_wire_keeps_roi_paths_in_image_coordinates()
	_test_live_wire_validates_inputs_and_search_limit()
	_test_live_wire_refuses_oversized_searches_and_paths_without_mutating_source()
	if _failures.is_empty():
		print("PASS: image region algorithms")
		quit(0)
		return
	push_error("FAIL: image region algorithms\n%s" % "\n".join(_failures))
	quit(1)


func _test_region_grow_is_seed_connected_and_tolerance_bounded() -> void:
	var image := Image.create(6, 3, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	image.set_pixel(0, 1, Color(1.0, 0.0, 0.0))
	image.set_pixel(1, 1, Color(0.92, 0.0, 0.0))
	image.set_pixel(2, 1, Color(0.70, 0.0, 0.0))
	image.set_pixel(4, 1, Color(0.96, 0.0, 0.0))
	image.set_pixel(5, 1, Color(0.96, 0.0, 0.0))

	var result: Dictionary = ALGORITHMS.region_grow(image, Vector2i(0, 1), 0.10)
	_expect(result.get("ok", false), "region grow should accept a simple seed-connected component")
	_expect_equal(result.get("pixel_count"), 2, "region grow should include only connected pixels within tolerance")
	_expect_equal(
		result.get("polygon"),
		[[0, 1], [2, 1], [2, 2], [0, 2]],
		"region grow should emit the deterministic pixel-boundary V1 polygon",
	)

	var exact_result: Dictionary = ALGORITHMS.region_grow(image, Vector2i(0, 1), 0.0)
	_expect_equal(exact_result.get("pixel_count"), 1, "zero tolerance should require the exact seed color")
	_expect_equal(
		exact_result.get("polygon"),
		[[0, 1], [1, 1], [1, 2], [0, 2]],
		"a single selected pixel should still produce a valid four-vertex polygon",
	)


func _test_region_grow_refuses_empty_and_unsupported_topology() -> void:
	var transparent := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	transparent.fill(Color(0.0, 0.0, 0.0, 0.0))
	var empty_result: Dictionary = ALGORITHMS.region_grow(transparent, Vector2i(1, 1), 0.0)
	_expect_refusal(empty_result, &"empty_region", "a transparent seed should refuse an empty candidate")

	var ring := Image.create(5, 5, false, Image.FORMAT_RGBA8)
	ring.fill(Color.BLACK)
	for y in range(1, 4):
		for x in range(1, 4):
			if x != 2 or y != 2:
				ring.set_pixel(x, y, Color.RED)
	var hole_result: Dictionary = ALGORITHMS.region_grow(ring, Vector2i(1, 1), 0.0)
	_expect_refusal(hole_result, &"hole_topology", "a seed-connected ring should refuse a V1-inexpressible hole")

	var disconnected := PackedByteArray([1, 0, 0, 1])
	var multiple_result: Dictionary = ALGORITHMS.polygonize_mask(disconnected, Vector2i(4, 1))
	_expect_refusal(multiple_result, &"multiple_components", "a binary mask with multiple components should be refused")


func _test_region_grow_refuses_an_artificially_truncated_roi() -> void:
	var image := Image.create(200, 80, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	var result: Dictionary = ALGORITHMS.region_grow(
		image,
		Vector2i(100, 40),
		0.0,
		Rect2i(36, 0, 129, 80),
	)
	_expect_refusal(
		result,
		&"roi_truncated",
		"region grow should refuse a component clipped by an artificial ROI boundary",
	)


func _test_region_grow_validates_inputs() -> void:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	_expect_refusal(ALGORITHMS.region_grow(null, Vector2i.ZERO, 0.0), &"invalid_image", "null images should be rejected")
	_expect_refusal(ALGORITHMS.region_grow(image, Vector2i(-1, 0), 0.0), &"invalid_seed", "out-of-image seeds should be rejected")
	_expect_refusal(ALGORITHMS.region_grow(image, Vector2i.ZERO, -0.1), &"invalid_tolerance", "negative tolerance should be rejected")
	_expect_refusal(ALGORITHMS.region_grow(image, Vector2i.ZERO, NAN), &"invalid_tolerance", "non-finite tolerance should be rejected")
	_expect_refusal(
		ALGORITHMS.region_grow(image, Vector2i.ZERO, 0.0, Rect2i(1, 1, 2, 2)),
		&"invalid_seed",
		"a seed outside the requested ROI should be rejected",
	)


func _test_region_grow_expands_only_when_truncated_and_preserves_metadata() -> void:
	var image := Image.create(96, 48, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(20, 23):
		for x in range(5, 45):
			image.set_pixel(x, y, Color.RED)
	var result: Dictionary = ALGORITHMS.region_grow_expanding(
		image,
		Vector2i(20, 21),
		0.0,
		0.0,
		8,
	)
	_expect(result.get("ok", false), "expanding region grow should finish a component beyond two clipped ROIs")
	_expect_equal(result.get("expansion_count"), 2, "expansion_count should equal the two ROI retries")
	_expect_equal(result.get("roi"), Rect2i(0, 0, 53, 48), "the third centred ROI should be clipped only by image bounds")
	_expect_equal(result.get("tolerance"), 0.0, "result metadata should retain the accepted tolerance")
	_expect_equal(result.get("luminance_bias"), 0.0, "result metadata should retain the accepted bias")
	_expect(result.has("message") and result.get("message") is String, "expanding results should retain a stable message field on success and refusal")
	_expect_equal(result.get("pixel_count"), 120, "ROI expansion must preserve the complete connected component")
	_expect_equal(
		POLYGON_OPS.polygon_bounds(_polygon_from_value(result.get("polygon", []))),
		Rect2(5, 20, 40, 3),
		"dynamic ROI output should remain in full-image coordinates",
	)


func _test_region_grow_bias_changes_the_frozen_reference_candidate() -> void:
	var image := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(14, 17):
		for x in range(20, 25):
			image.set_pixel(x, y, Color(0.4, 0.4, 0.4))
		for x in range(25, 36):
			image.set_pixel(x, y, Color(0.495, 0.4, 0.4))
	var base: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(22, 15), 0.08, 0.0, 16)
	var biased: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(22, 15), 0.08, 0.04, 16)
	_expect(base.get("ok", false) and biased.get("ok", false), "both unbiased and biased candidates should be V1-safe")
	_expect_equal(base.get("pixel_count"), 15, "the unbiased reference should keep only the exact seed-colour block")
	_expect_equal(biased.get("pixel_count"), 48, "equal-RGB brightness bias should admit the connected fringe")
	_expect_equal(biased.get("luminance_bias"), 0.04, "the effective bias should be observable in result metadata")


func _test_region_grow_expanding_finishes_at_an_image_edge() -> void:
	var image := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(0, 11):
		for x in range(0, 11):
			image.set_pixel(x, y, Color.RED)
	var result: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(1, 1), 0.0, 0.0, 4)
	_expect(result.get("ok", false), "a component touching the image edge should complete without a false truncation")
	_expect_equal(result.get("expansion_count"), 2, "the edge fixture should require exactly two retries")
	_expect_equal(
		POLYGON_OPS.polygon_bounds(_polygon_from_value(result.get("polygon", []))),
		Rect2(0, 0, 11, 11),
		"image-edge completion should retain the complete pixel boundary",
	)


func _test_region_grow_expanding_caps_before_an_oversized_retry() -> void:
	var image := Image.create(1200, 1200, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	var result: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(600, 600), 0.0, 0.0)
	_expect_refusal(result, &"roi_too_large", "expansion should refuse before allocating the first ROI above 1,048,576 pixels")
	_expect_equal(result.get("expansion_count"), 4, "the cap refusal should report four requested ROI expansions")
	_expect_equal(result.get("roi"), Rect2i(88, 88, 1025, 1025), "the refusal should identify the unallocated oversized retry")


func _test_region_grow_expanding_allows_a_local_result_on_a_large_image() -> void:
	var image := Image.create(1200, 1200, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(598, 603):
		for x in range(598, 603):
			image.set_pixel(x, y, Color.WHITE)
	var result: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(600, 600), 0.0, 0.0)
	_expect(result.get("ok", false), "a large image should be accepted when its local component completes in the first legal ROI")
	_expect_equal(result.get("expansion_count"), 0, "a local success must not inspect or reject the full image area")
	_expect_equal(result.get("roi"), Rect2i(568, 568, 65, 65), "default half-size 32 should mean a centred 65 by 65 first ROI")


func _test_region_grow_expanding_validates_new_inputs_and_keeps_image_immutable() -> void:
	var image := Image.create(12, 10, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.25, 0.5, 0.75, 1.0))
	var original_bytes := image.get_data()
	_expect_refusal(ALGORITHMS.region_grow_expanding(image, Vector2i.ZERO, 0.1, 0.0, 0), &"invalid_half_size", "a zero initial half-size should be rejected")
	_expect_refusal(ALGORITHMS.region_grow_expanding(image, Vector2i.ZERO, 0.1, 0.0, -2), &"invalid_half_size", "a negative initial half-size should be rejected")
	_expect_refusal(ALGORITHMS.region_grow_expanding(image, Vector2i.ZERO, NAN, 0.0), &"invalid_tolerance", "a non-finite expanding tolerance should be rejected")
	_expect_refusal(ALGORITHMS.region_grow_expanding(image, Vector2i.ZERO, 0.1, INF), &"invalid_bias", "a non-finite luminance bias should be rejected")
	_expect_refusal(ALGORITHMS.region_grow_expanding(image, Vector2i(12, 0), 0.1, 0.0), &"invalid_seed", "an out-of-image expanding seed should be rejected")
	ALGORITHMS.region_grow_expanding(image, Vector2i(5, 5), 0.1, 0.2, 4)
	_expect_equal(image.get_data(), original_bytes, "region growing must never mutate or replace source Image bytes")
	_expect_equal(image.get_size(), Vector2i(12, 10), "region growing must preserve source Image dimensions")


func _test_region_grow_expanding_smooths_stair_steps_within_one_pixel() -> void:
	var image := Image.create(24, 24, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(4, 16):
		for x in range(4, 13 + (y - 4) / 2):
			image.set_pixel(x, y, Color.WHITE)
	var raw: Dictionary = ALGORITHMS.region_grow(image, Vector2i(5, 5), 0.0)
	var smoothed: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(5, 5), 0.0, 0.0, 16)
	var raw_ring := _polygon_from_value(raw.get("polygon", []))
	var smooth_ring := _polygon_from_value(smoothed.get("polygon", []))
	_expect(raw.get("ok", false) and smoothed.get("ok", false), "the staircase fixture should produce both legacy and expanding polygons")
	_expect(smooth_ring.size() < raw_ring.size(), "expanding region grow should deterministically remove staircase-only vertices")
	_expect(POLYGON_OPS.validate_simple_polygon(smooth_ring), "the smoothed result must remain one simple non-zero-area ring")
	_expect(POLYGON_OPS.points_fit_image(smooth_ring, Vector2(image.get_size())), "the smoothed result must stay inside image bounds")
	for point: Vector2 in raw_ring:
		_expect(
			_distance_to_ring(point, smooth_ring) <= 1.00001,
			"every original boundary vertex must remain within one image pixel of the smoothed ring",
		)


func _test_region_grow_expanding_preserves_one_opaque_pixel() -> void:
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	image.set_pixel(3, 2, Color.WHITE)
	var source_bytes := image.get_data()
	var result: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(3, 2), 0.0, 0.0, 4)
	_expect(result.get("ok", false), "smoothing must never reject a valid one-pixel component")
	_expect_equal(result.get("pixel_count"), 1, "a one-pixel component should retain its exact pixel count")
	_expect_equal(
		result.get("polygon"),
		[[3, 2], [4, 2], [4, 3], [3, 3]],
		"a one-pixel component should fall back to its independently expected unit-square boundary",
	)
	_expect_equal(image.get_data(), source_bytes, "one-pixel fallback must not mutate source Image bytes")


func _test_region_grow_expanding_preserves_a_horizontal_one_pixel_strip() -> void:
	var image := Image.create(10, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for x in range(1, 7):
		image.set_pixel(x, 3, Color.WHITE)
	var source_bytes := image.get_data()
	var result: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(2, 3), 0.0, 0.0, 4)
	_expect(result.get("ok", false), "smoothing must preserve a valid horizontal one-pixel strip")
	_expect_equal(result.get("pixel_count"), 6, "horizontal strip fallback should retain all six pixels")
	_expect_equal(
		result.get("polygon"),
		[[1, 3], [7, 3], [7, 4], [1, 4]],
		"horizontal strip fallback should retain the exact unit-width rectangle",
	)
	_expect_equal(image.get_data(), source_bytes, "horizontal strip fallback must not mutate source Image bytes")


func _test_region_grow_expanding_preserves_a_vertical_one_pixel_strip() -> void:
	var image := Image.create(8, 10, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(1, 7):
		image.set_pixel(4, y, Color.WHITE)
	var source_bytes := image.get_data()
	var result: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(4, 2), 0.0, 0.0, 4)
	_expect(result.get("ok", false), "smoothing must preserve a valid vertical one-pixel strip")
	_expect_equal(result.get("pixel_count"), 6, "vertical strip fallback should retain all six pixels")
	_expect_equal(
		result.get("polygon"),
		[[4, 1], [5, 1], [5, 7], [4, 7]],
		"vertical strip fallback should retain the exact unit-width rectangle",
	)
	_expect_equal(image.get_data(), source_bytes, "vertical strip fallback must not mutate source Image bytes")


func _test_region_grow_expanding_is_exactly_deterministic() -> void:
	var image := Image.create(16, 12, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(2, 9):
		for x in range(3, 9 + (y % 2)):
			image.set_pixel(x, y, Color(0.6, 0.2, 0.1))
	var first: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(4, 3), 0.0, 0.0, 8)
	var second: Dictionary = ALGORITHMS.region_grow_expanding(image, Vector2i(4, 3), 0.0, 0.0, 8)
	_expect_equal(second, first, "repeated expanding calls over the same bytes and parameters must be exactly deterministic")


func _test_region_grow_expanding_matches_legacy_transparent_and_boundary_behavior() -> void:
	var transparent := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	transparent.fill(Color(0.0, 0.0, 0.0, 0.0))
	var legacy_transparent: Dictionary = ALGORITHMS.region_grow(transparent, Vector2i(0, 0), 0.0)
	var expanding_transparent: Dictionary = ALGORITHMS.region_grow_expanding(transparent, Vector2i(0, 0), 0.0, 0.0, 2)
	_expect_equal(expanding_transparent.get("code"), legacy_transparent.get("code"), "transparent-seed refusal should match the legacy public behavior")

	var boundary := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	boundary.fill(Color.BLACK)
	boundary.set_pixel(0, 0, Color.RED)
	var legacy_boundary: Dictionary = ALGORITHMS.region_grow(boundary, Vector2i(0, 0), 0.0)
	var expanding_boundary: Dictionary = ALGORITHMS.region_grow_expanding(boundary, Vector2i(0, 0), 0.0, 0.0, 2)
	_expect(legacy_boundary.get("ok", false) and expanding_boundary.get("ok", false), "both public paths should accept a valid image-boundary pixel")
	_expect_equal(expanding_boundary.get("pixel_count"), legacy_boundary.get("pixel_count"), "boundary pixel count should match legacy behavior")
	_expect_equal(expanding_boundary.get("polygon"), legacy_boundary.get("polygon"), "safe fallback should retain the exact legacy boundary ring")


func _test_polygonize_refuses_excessive_boundary_complexity() -> void:
	# A connected comb is hole-free but has thousands of corners. Returning all of
	# them would feed an O(n^2) polygon validator on the UI thread.
	var size := Vector2i(2048, 3)
	var comb := PackedByteArray()
	comb.resize(size.x * size.y)
	for x in range(size.x):
		comb[x] = 1
		if x % 2 == 0:
			comb[size.x + x] = 1
			comb[size.x * 2 + x] = 1
	_expect_refusal(
		ALGORITHMS.polygonize_mask(comb, size),
		&"too_complex",
		"polygonization should refuse an excessive boundary before it can stall editing",
	)
	_expect_refusal(
		ALGORITHMS.polygonize_mask(PackedByteArray([1, 0]), Vector2i(2, 2)),
		&"invalid_mask",
		"mask dimensions should be validated before polygonization",
	)


func _test_live_wire_prefers_a_strong_edge_deterministically() -> void:
	var image := _quadrant_image(7, 7, Vector2i(3, 3))
	var expected := PackedVector2Array([
		Vector2(5, 3),
		Vector2(4, 3),
		Vector2(3, 4),
		Vector2(3, 5),
	])
	var first: Dictionary = ALGORITHMS.live_wire(image, Vector2i(5, 3), Vector2i(3, 5))
	var second: Dictionary = ALGORITHMS.live_wire(image, Vector2i(5, 3), Vector2i(3, 5))
	_expect(first.get("ok", false), "live wire should find a path between valid anchors")
	_expect_equal(first.get("points"), expected, "live wire should prefer the longer strong edge over the flat diagonal")
	_expect_equal(second.get("points"), expected, "live wire should use deterministic tie-breaking")
	_expect(float(first.get("cost", -1.0)) >= 0.0, "live wire should report a finite non-negative path cost")


func _test_live_wire_keeps_roi_paths_in_image_coordinates() -> void:
	var image := _quadrant_image(9, 9, Vector2i(4, 4))
	var result: Dictionary = ALGORITHMS.live_wire(
		image,
		Vector2i(6, 4),
		Vector2i(4, 6),
		Rect2i(2, 2, 5, 5),
	)
	_expect(result.get("ok", false), "live wire should search a valid bounded ROI")
	_expect_equal(
		result.get("points"),
		PackedVector2Array([Vector2(6, 4), Vector2(5, 4), Vector2(4, 5), Vector2(4, 6)]),
		"ROI live-wire output should remain in full-image coordinates",
	)

	var singleton: Dictionary = ALGORITHMS.live_wire(
		image,
		Vector2i(4, 4),
		Vector2i(4, 4),
		Rect2i(2, 2, 5, 5),
	)
	_expect_equal(singleton.get("points"), PackedVector2Array([Vector2(4, 4)]), "equal anchors should return one image-coordinate point")


func _test_live_wire_validates_inputs_and_search_limit() -> void:
	var image := Image.create(5, 5, false, Image.FORMAT_RGBA8)
	image.fill(Color.GRAY)
	_expect_refusal(ALGORITHMS.live_wire(null, Vector2i.ZERO, Vector2i.ONE), &"invalid_image", "live wire should reject a null image")
	_expect_refusal(ALGORITHMS.live_wire(image, Vector2i(-1, 0), Vector2i.ONE), &"invalid_anchor", "live wire should reject anchors outside the image")
	_expect_refusal(
		ALGORITHMS.live_wire(image, Vector2i.ZERO, Vector2i(4, 4), Rect2i(1, 1, 3, 3)),
		&"invalid_anchor",
		"live wire should reject anchors outside its ROI",
	)
	_expect_refusal(
		ALGORITHMS.live_wire(image, Vector2i.ZERO, Vector2i(4, 4), Rect2i(), -1),
		&"invalid_limit",
		"live wire should reject a negative expansion limit",
	)
	_expect_refusal(
		ALGORITHMS.live_wire(image, Vector2i.ZERO, Vector2i(4, 4), Rect2i(), 1),
		&"search_limit",
		"live wire should stop with a structured refusal when its expansion budget is exhausted",
	)


func _test_live_wire_refuses_oversized_searches_and_paths_without_mutating_source() -> void:
	var long_image := Image.create(2050, 1, false, Image.FORMAT_RGBA8)
	long_image.fill(Color.GRAY)
	var original_bytes := long_image.get_data()
	_expect_refusal(
		ALGORITHMS.live_wire(long_image, Vector2i(0, 0), Vector2i(2049, 0)),
		&"too_complex",
		"a live-wire path above the 2,048-point interaction limit should be refused before reaching the editor",
	)
	_expect_equal(long_image.get_data(), original_bytes, "path-limit refusal must preserve every source Image byte")
	_expect_equal(long_image.get_size(), Vector2i(2050, 1), "path-limit refusal must preserve source Image dimensions")

	var oversized := Image.create(513, 512, false, Image.FORMAT_RGBA8)
	oversized.fill(Color.GRAY)
	_expect_refusal(
		ALGORITHMS.live_wire(oversized, Vector2i.ZERO, Vector2i(512, 511)),
		&"roi_too_large",
		"the default live-wire search must retain its 262,144-pixel allocation cap",
	)
	_expect_refusal(
		ALGORITHMS.live_wire(long_image, Vector2i(2050, 0), Vector2i(2049, 0)),
		&"invalid_anchor",
		"a direct width-bound pixel must be refused instead of silently clamped",
	)


func _quadrant_image(width: int, height: int, corner: Vector2i) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(corner.y, height):
		for x in range(corner.x, width):
			image.set_pixel(x, y, Color.WHITE)
	return image


func _polygon_from_value(value: Variant) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not value is Array:
		return result
	for point: Variant in value:
		if point is Array and point.size() == 2:
			result.append(Vector2(float(point[0]), float(point[1])))
	return result


func _distance_to_ring(point: Vector2, ring: PackedVector2Array) -> float:
	var closest := INF
	for index in range(ring.size()):
		var start := ring[index]
		var finish := ring[(index + 1) % ring.size()]
		var segment := finish - start
		var amount := 0.0
		if segment.length_squared() > 0.0:
			amount = clampf((point - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		closest = minf(closest, point.distance_to(start + segment * amount))
	return closest


func _expect_refusal(result: Dictionary, code: StringName, message: String) -> void:
	_expect(not result.get("ok", true), message)
	_expect_equal(StringName(result.get("code", "")), code, "%s with a stable refusal code" % message)
	_expect(not String(result.get("message", "")).is_empty(), "%s with an explanatory message" % message)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s (expected %s, got %s)" % [message, str(expected), str(actual)])
