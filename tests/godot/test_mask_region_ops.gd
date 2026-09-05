extends RefCounted

const MASK_OPS := preload("res://client/domain/mask_region_ops.gd")
const RESULT_KEYS := ["mask", "message", "ok", "polygon", "roi", "status"]


static func run(support) -> void:
	_test_polygon_rasterization_is_bounded_and_isolated(support)
	_test_circular_dot_and_segment_sampling(support)
	_test_union_subtract_and_topology_retention(support)
	_test_overlap_detection_and_annotation_boundary_fill(support)
	_test_fill_accepts_only_enclosed_seed_components(support)
	_test_close_gaps_is_local_bounded_and_reports_no_op(support)
	_test_clipping_validation_and_allocation_limit(support)
	_test_v1_conversion_uses_a_typed_single_ring(support)


static func _test_polygon_rasterization_is_bounded_and_isolated(support) -> void:
	var base: Dictionary = MASK_OPS.rasterize_polygon(_box_ring(10, 10, 20, 20), Vector2i(80, 60))
	_expect_contract(base, support, "polygon rasterization")
	support.expect_equal(base["status"], &"single", "a rasterized box is one V1 component")
	support.expect_equal(base["roi"], Rect2i(8, 8, 24, 24), "polygon rasterization scans only two padded local pixels")
	support.expect_equal(_selected_count(base), 400, "a 20x20 box selects exactly 400 pixel centers")
	support.expect_equal(
		base["polygon"],
		PackedVector2Array([Vector2(10, 10), Vector2(30, 10), Vector2(30, 30), Vector2(10, 30)]),
		"the bounded box mask polygonizes back to its image-coordinate ring",
	)

	var candidate: Dictionary = MASK_OPS.to_v1_candidate(base)
	base["mask"][0] = 255
	base["polygon"][0] = Vector2.ZERO
	support.expect_equal(candidate["mask"][0], 0, "public results deep-copy the source mask")
	support.expect_equal(candidate["polygon"][0], Vector2(10, 10), "public results deep-copy the typed polygon")


static func _test_circular_dot_and_segment_sampling(support) -> void:
	var dot: Dictionary = MASK_OPS.rasterize_stroke(
		PackedVector2Array([Vector2(5, 5)]), 1.0, Vector2i(30, 20)
	)
	_expect_contract(dot, support, "brush dot")
	support.expect_equal(dot["status"], &"single", "one brush click creates one component")
	support.expect_equal(_selected_count(dot), 4, "a radius-one dot samples four enclosed pixel centers, not a square brush")
	support.expect(_at(dot, Vector2i(4, 4)) != 0, "a dot includes a pixel center inside its circle")
	support.expect_equal(_at(dot, Vector2i(3, 3)), 0, "a dot excludes a pixel center outside its circle")

	var segment: Dictionary = MASK_OPS.rasterize_stroke(
		PackedVector2Array([Vector2(5, 5), Vector2(9, 5)]), 1.0, Vector2i(30, 20)
	)
	_expect_contract(segment, support, "brush segment")
	support.expect(_at(segment, Vector2i(8, 4)) != 0, "a stroke samples pixel centers against the segment body")
	support.expect(_at(segment, Vector2i(4, 4)) != 0, "a stroke keeps a circular start cap")
	support.expect_equal(_at(segment, Vector2i(5, 3)), 0, "a stroke does not use an axis-aligned rectangular footprint")


static func _test_union_subtract_and_topology_retention(support) -> void:
	var base: Dictionary = MASK_OPS.rasterize_polygon(_box_ring(10, 10, 20, 20), Vector2i(80, 60))
	var stroke: Dictionary = MASK_OPS.rasterize_stroke(
		PackedVector2Array([Vector2(28, 20), Vector2(40, 20)]), 4.0, Vector2i(80, 60)
	)
	var painted: Dictionary = MASK_OPS.combine(base, stroke, &"union")
	_expect_contract(painted, support, "overlapping union")
	support.expect_equal(painted["status"], &"single", "overlapping Paint remains one component")
	support.expect(painted["roi"].size.x < 80 and painted["roi"].size.y < 60, "Paint combines only the union of two local ROIs")

	var disjoint: Dictionary = MASK_OPS.rasterize_stroke(
		PackedVector2Array([Vector2(65, 20)]), 2.0, Vector2i(80, 60)
	)
	var multiple: Dictionary = MASK_OPS.combine(base, disjoint, &"union")
	_expect_contract(multiple, support, "disjoint union")
	support.expect_equal(multiple["status"], &"multi_component", "disjoint Paint is refused as multiple V1 components")
	support.expect(not multiple["ok"], "multiple-component Paint is not a committable candidate")
	support.expect(_selected_count(multiple) > _selected_count(base), "multiple-component refusal retains every raw foreground component")
	support.expect(multiple["roi"].has_point(Vector2i(65, 20)), "multiple-component refusal retains the bounded ROI covering the remote component")

	var erased: Dictionary = MASK_OPS.combine(base, base, &"subtract")
	_expect_contract(erased, support, "complete subtraction")
	support.expect_equal(erased["status"], &"empty", "complete Eraser is classified")
	support.expect(not erased["ok"], "full erasure is a refusal candidate")
	support.expect_equal(erased["roi"], base["roi"], "empty refusal retains the subject's bounded ROI")
	support.expect_equal(erased["mask"].size(), base["mask"].size(), "empty refusal retains the full raw mask dimensions")
	support.expect_equal(_selected_count(erased), 0, "complete subtraction clears bytes rather than inventing geometry")

	var outer: Dictionary = MASK_OPS.rasterize_polygon(_box_ring(10, 10, 20, 20), Vector2i(80, 60))
	var inner: Dictionary = MASK_OPS.rasterize_polygon(_box_ring(15, 15, 10, 10), Vector2i(80, 60))
	var hole: Dictionary = MASK_OPS.combine(outer, inner, &"subtract")
	_expect_contract(hole, support, "hole subtraction")
	support.expect_equal(hole["status"], &"hole", "Eraser reports a V1-inexpressible hole")
	support.expect(not hole["ok"], "an Eraser hole is not committable")
	support.expect_equal(_at(hole, Vector2i(12, 12)), 1, "hole refusal retains the surrounding foreground bytes")
	support.expect_equal(_at(hole, Vector2i(18, 18)), 0, "hole refusal retains the erased interior bytes")


static func _test_overlap_detection_and_annotation_boundary_fill(support) -> void:
	var first := MASK_OPS.rasterize_polygon(_box_ring(10, 10, 12, 12), Vector2i(80, 60))
	var touching := MASK_OPS.rasterize_stroke_mask(PackedVector2Array([Vector2(20, 16)]), 2.0, Vector2i(80, 60))
	var separate := MASK_OPS.rasterize_stroke_mask(PackedVector2Array([Vector2(40, 16)]), 2.0, Vector2i(80, 60))
	support.expect(MASK_OPS.masks_overlap(first, touching), "Paint target inference should detect shared selected pixels")
	support.expect(not MASK_OPS.masks_overlap(first, separate), "Paint target inference should reject merely nearby disjoint masks")

	var boundary := {"roi": Rect2i(), "mask": PackedByteArray()}
	for ring: PackedVector2Array in [
		_box_ring(20, 20, 40, 5), _box_ring(20, 55, 40, 5),
		_box_ring(20, 25, 5, 30), _box_ring(55, 25, 5, 30),
	]:
		boundary = MASK_OPS.combine_masks(boundary, MASK_OPS.rasterize_polygon(ring, Vector2i(80, 70)), &"union")
	var enclosed := MASK_OPS.find_enclosed_blank(boundary, Vector2(40, 40), Vector2i(80, 70))
	_expect_contract(enclosed, support, "annotation-boundary Fill")
	support.expect_equal(enclosed["status"], &"single", "the clicked enclosed blank component should be committable")
	support.expect_equal(_polygon_bounds(enclosed["polygon"]), Rect2(25, 25, 30, 30),
		"Fill should extract only the smallest enclosed blank component containing the seed")
	var outside := MASK_OPS.find_enclosed_blank(boundary, Vector2(70, 40), Vector2i(80, 70))
	support.expect_equal(outside["status"], &"open", "an exterior-connected blank seed should be refused")
	support.expect(String(outside["message"]).contains("No closed region"), "open Fill refusal should name the missing closure")
	var occupied := MASK_OPS.find_enclosed_blank(boundary, Vector2(22, 30), Vector2i(80, 70))
	support.expect_equal(occupied["status"], &"invalid", "a seed on an existing annotation should be refused")
	support.expect(String(occupied["message"]).contains("blank"), "occupied Fill refusal should request a blank seed")


static func _test_fill_accepts_only_enclosed_seed_components(support) -> void:
	var closed := _outline_state(Rect2i(10, 10, 9, 9), 1, 7, [])
	var filled: Dictionary = MASK_OPS.fill_enclosed(closed, Vector2i(14, 14), 0.0)
	_expect_contract(filled, support, "closed-contour Fill")
	support.expect_equal(filled["status"], &"single", "Fill turns a closed outline into one solid V1 candidate")
	support.expect(filled["ok"], "a seed enclosed by the painted contour is committable")
	support.expect_equal(_at(filled, Vector2i(14, 14)), 1, "Fill selects the seed-connected enclosed background")
	support.expect_equal(_at(filled, Vector2i(10, 10)), 0, "Fill does not flood border-connected background outside the contour")

	var one_pixel_gap := _outline_state(Rect2i(10, 10, 9, 9), 1, 7, [4])
	var approximately_closed: Dictionary = MASK_OPS.fill_enclosed(one_pixel_gap, Vector2i(14, 14), 1.0)
	_expect_contract(approximately_closed, support, "approximately closed Fill")
	support.expect_equal(approximately_closed["status"], &"single", "Fill repairs a one-pixel contour gap within its supplied radius")
	support.expect(approximately_closed["ok"], "an approximately closed seed component is accepted")
	support.expect_equal(_at(approximately_closed, Vector2i(14, 11)), 1, "Fill closes the small gap before filling the interior")
	var two_pixel_gap := _outline_state(Rect2i(10, 10, 13, 13), 3, 9, [6, 7])
	var two_pixel_refused: Dictionary = MASK_OPS.fill_enclosed(two_pixel_gap, Vector2i(16, 16), 1.0)
	_expect_contract(two_pixel_refused, support, "two-pixel Fill above the supplied bound")
	support.expect_equal(two_pixel_refused["status"], &"open", "Fill radius one cannot bridge a two-pixel contour gap")
	support.expect(not two_pixel_refused["ok"], "a contour gap longer than the supplied Fill bound is refused")
	support.expect_equal(two_pixel_refused["mask"], two_pixel_gap["mask"], "over-bound Fill refusal retains the raw editable outline")
	support.expect_equal(_at(two_pixel_refused, Vector2i(16, 13)), 0, "radius-one Fill does not silently close the first byte of a two-pixel gap")
	var two_pixel_closed: Dictionary = MASK_OPS.fill_enclosed(two_pixel_gap, Vector2i(16, 16), 2.0)
	_expect_contract(two_pixel_closed, support, "two-pixel Fill at the supplied bound")
	support.expect_equal(two_pixel_closed["status"], &"single", "Fill repairs a two-pixel contour gap only when the supplied radius permits it")
	support.expect(two_pixel_closed["ok"], "a two-pixel gap is committable when the Fill bound is two")
	support.expect_equal(_at(two_pixel_closed, Vector2i(17, 13)), 1, "two-pixel approximate closure retains the repaired boundary")

	var large_gap := _outline_state(Rect2i(10, 10, 11, 11), 1, 9, [3, 4, 5, 6, 7])
	var refused: Dictionary = MASK_OPS.fill_enclosed(large_gap, Vector2i(15, 15), 1.0)
	_expect_contract(refused, support, "open-contour Fill")
	support.expect_equal(refused["status"], &"open", "Fill refuses a seed component still connected to the ROI border")
	support.expect(not refused["ok"], "a large open contour cannot commit")
	support.expect(not String(refused["message"]).is_empty(), "open-contour refusal explains how to continue")
	support.expect_equal(refused["roi"], large_gap["roi"], "open-contour refusal retains the original bounded ROI")
	support.expect_equal(refused["mask"], large_gap["mask"], "open-contour refusal retains the raw editable outline")


static func _test_close_gaps_is_local_bounded_and_reports_no_op(support) -> void:
	var roi := Rect2i(20, 30, 15, 9)
	var bytes := PackedByteArray()
	bytes.resize(roi.size.x * roi.size.y)
	for y in range(2, 7):
		for x in range(2, 11):
			bytes[y * roi.size.x + x] = 1
	bytes[2 * roi.size.x + 5] = 0
	bytes[2 * roi.size.x + 7] = 0
	var two_notches := {"roi": roi, "mask": bytes}
	var local: Dictionary = MASK_OPS.close_gaps(two_notches, Vector2i(25, 32), 1.0)
	_expect_contract(local, support, "local Close Gaps")
	support.expect(local["ok"], "a changed simple Close Gaps result is a committable candidate")
	support.expect_equal(local["status"], &"single", "a changed simple Close Gaps result reports the single-ring status")
	support.expect_equal(_at(local, Vector2i(25, 32)), 1, "Close Gaps repairs the one-pixel notch at focus")
	support.expect_equal(_at(local, Vector2i(27, 32)), 0, "read padding cannot modify an otherwise fillable pixel outside the exact radius-one focus neighborhood")
	support.expect_equal(local["roi"], roi, "Close Gaps preserves the bounded source ROI")

	var solid: Dictionary = MASK_OPS.rasterize_polygon(_box_ring(10, 10, 12, 12), Vector2i(80, 60))
	var no_op: Dictionary = MASK_OPS.close_gaps(solid, Vector2i(16, 16), 2.0)
	_expect_contract(no_op, support, "Close Gaps no-op")
	support.expect_equal(no_op["status"], &"no_op", "Close Gaps explicitly reports unchanged output")
	support.expect(not no_op["ok"], "an unchanged close does not create a commit candidate")
	support.expect_equal(no_op["mask"], solid["mask"], "a no-op returns an isolated copy of the original bytes")

	for invalid_radius in [0.0, 9.0, NAN]:
		var invalid: Dictionary = MASK_OPS.close_gaps(solid, Vector2i(16, 16), invalid_radius)
		_expect_contract(invalid, support, "invalid Close Gaps radius")
		support.expect_equal(invalid["status"], &"invalid", "Close Gaps accepts only finite radii from one through eight")
		support.expect(not String(invalid["message"]).is_empty(), "invalid Close Gaps radius has an explanatory refusal")


static func _test_clipping_validation_and_allocation_limit(support) -> void:
	var clipped: Dictionary = MASK_OPS.rasterize_polygon(_box_ring(-5, -5, 10, 10), Vector2i(8, 8))
	_expect_contract(clipped, support, "clipped polygon")
	support.expect_equal(clipped["roi"].position, Vector2i.ZERO, "partly out-of-image input clips its padded ROI at the image origin")
	support.expect_equal(_selected_count(clipped), 25, "clipping keeps only in-image pixel centers")
	support.expect_equal(
		clipped["polygon"],
		PackedVector2Array([Vector2(0, 0), Vector2(5, 0), Vector2(5, 5), Vector2(0, 5)]),
		"clipped foreground polygonizes to the in-image boundary",
	)

	var outside: Dictionary = MASK_OPS.rasterize_stroke(
		PackedVector2Array([Vector2(-20, -20)]), 2.0, Vector2i(8, 8)
	)
	_expect_contract(outside, support, "fully out-of-image stroke")
	support.expect_equal(outside["status"], &"empty", "fully out-of-image input is an explicit empty refusal")
	support.expect_equal(outside["roi"], Rect2i(), "fully clipped input does not allocate a fake image-sized ROI")

	var too_large: Dictionary = MASK_OPS.rasterize_polygon(
		_box_ring(10, 10, 1100, 1000), Vector2i(2048, 2048)
	)
	_expect_contract(too_large, support, "oversized local ROI")
	support.expect_equal(too_large["status"], &"roi_too_large", "a candidate above 1,048,576 pixels is hard-refused before allocation")
	support.expect_equal(too_large["mask"].size(), 0, "oversized refusal allocates no raster mask")
	support.expect(not String(too_large["message"]).is_empty(), "oversized refusal explains the bounded limit")
	var sparse_merge: Dictionary = MASK_OPS.combine(
		{"roi": Rect2i(0, 0, 1, 1), "mask": PackedByteArray([1])},
		{"roi": Rect2i(2000, 2000, 1, 1), "mask": PackedByteArray([1])},
		&"union",
	)
	_expect_contract(sparse_merge, support, "oversized merged ROI")
	support.expect_equal(sparse_merge["status"], &"roi_too_large", "far-apart local masks cannot force a full-image-sized allocation")
	support.expect_equal(sparse_merge["mask"].size(), 0, "oversized merged ROI is refused before remapping bytes")
	var oversized_state: Dictionary = MASK_OPS.to_v1_candidate(
		{"roi": Rect2i(0, 0, 1025, 1024), "mask": PackedByteArray()}
	)
	_expect_contract(oversized_state, support, "oversized supplied mask state")
	support.expect_equal(oversized_state["status"], &"roi_too_large", "supplied mask declarations above the hard pixel limit are refused first")
	var malformed_length: Dictionary = MASK_OPS.to_v1_candidate(
		{"roi": Rect2i(3, 4, 2, 2), "mask": PackedByteArray([1, 0, 1])}
	)
	_expect_contract(malformed_length, support, "malformed mask byte length")
	support.expect_equal(malformed_length["status"], &"invalid", "mask length must exactly match the declared bounded ROI")
	var zero_sized_nonempty: Dictionary = MASK_OPS.to_v1_candidate(
		{"roi": Rect2i(3, 4, 0, 2), "mask": PackedByteArray([1])}
	)
	_expect_contract(zero_sized_nonempty, support, "zero-sized nonempty mask state")
	support.expect_equal(zero_sized_nonempty["status"], &"invalid", "a zero-sized ROI cannot carry nonempty mask bytes")
	var overflow_mask := PackedByteArray()
	overflow_mask.resize(8)
	overflow_mask.fill(1)
	var overflowing_end: Dictionary = MASK_OPS.to_v1_candidate(
		{"roi": Rect2i(2147483644, 7, 8, 1), "mask": overflow_mask}
	)
	_expect_contract(overflowing_end, support, "overflowing ROI end")
	support.expect_equal(overflowing_end["status"], &"invalid", "state validation refuses x end-coordinate overflow before polygon offset")
	support.expect(not overflowing_end["ok"], "overflowing ROI ends never become V1 candidates")
	var overflow_merge: Dictionary = MASK_OPS.combine(
		{"roi": Rect2i(2, 2, 1, 1), "mask": PackedByteArray([1])},
		{"roi": Rect2i(9, 2147483644, 1, 8), "mask": overflow_mask},
		&"union",
	)
	_expect_contract(overflow_merge, support, "overflowing ROI before merge")
	support.expect_equal(overflow_merge["status"], &"invalid", "state validation refuses y end-coordinate overflow before ROI merge")

	var invalid_size: Dictionary = MASK_OPS.rasterize_polygon(_box_ring(0, 0, 2, 2), Vector2i.ZERO)
	_expect_contract(invalid_size, support, "invalid image size")
	support.expect_equal(invalid_size["status"], &"invalid", "non-positive image sizes are refused")
	var invalid_radius: Dictionary = MASK_OPS.rasterize_stroke(
		PackedVector2Array([Vector2.ONE]), INF, Vector2i(8, 8)
	)
	_expect_contract(invalid_radius, support, "non-finite brush radius")
	support.expect_equal(invalid_radius["status"], &"invalid", "non-finite brush radii are refused")
	var unknown: Dictionary = MASK_OPS.combine(clipped, clipped, &"xor")
	_expect_contract(unknown, support, "unknown boolean operation")
	support.expect_equal(unknown["status"], &"invalid", "unknown byte-wise boolean operations are refused")


static func _test_v1_conversion_uses_a_typed_single_ring(support) -> void:
	var roi := Rect2i(7, 9, 4, 3)
	var mask := PackedByteArray([
		255, 255, 0, 0,
		255, 255, 0, 0,
		0, 0, 0, 0,
	])
	var candidate: Dictionary = MASK_OPS.to_v1_candidate({"roi": roi, "mask": mask})
	_expect_contract(candidate, support, "V1 conversion")
	support.expect(candidate["ok"], "one simple raw component converts to a V1 candidate")
	support.expect_equal(candidate["status"], &"single", "one simple component receives the common single status")
	support.expect(candidate["polygon"] is PackedVector2Array, "JSON-style polygonizer points are explicitly converted to PackedVector2Array")
	support.expect_equal(
		candidate["polygon"],
		PackedVector2Array([Vector2(7, 9), Vector2(9, 9), Vector2(9, 11), Vector2(7, 11)]),
		"V1 conversion preserves ROI origin in image coordinates",
	)
	mask[0] = 0
	support.expect_equal(candidate["mask"][0], 255, "V1 conversion deep-copies caller-owned raw bytes")


static func _box_ring(x: float, y: float, width: float, height: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(x, y), Vector2(x + width, y),
		Vector2(x + width, y + height), Vector2(x, y + height),
	])


static func _polygon_bounds(points: PackedVector2Array) -> Rect2:
	var minimum := points[0]
	var maximum := points[0]
	for point: Vector2 in points:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	return Rect2(minimum, maximum - minimum)


static func _outline_state(roi: Rect2i, first: int, last: int, top_gaps: Array) -> Dictionary:
	var mask := PackedByteArray()
	mask.resize(roi.size.x * roi.size.y)
	for x in range(first, last + 1):
		if x not in top_gaps:
			mask[first * roi.size.x + x] = 1
		mask[last * roi.size.x + x] = 1
	for y in range(first, last + 1):
		mask[y * roi.size.x + first] = 1
		mask[y * roi.size.x + last] = 1
	return {"roi": roi, "mask": mask}


static func _at(state: Dictionary, point: Vector2i) -> int:
	var roi: Rect2i = state["roi"]
	if not roi.has_point(point):
		return 0
	var local := point - roi.position
	return state["mask"][local.y * roi.size.x + local.x]


static func _selected_count(state: Dictionary) -> int:
	var count := 0
	for value: int in state["mask"]:
		if value != 0:
			count += 1
	return count


static func _expect_contract(result: Dictionary, support, context: String) -> void:
	var keys: Array = result.keys()
	keys.sort()
	support.expect_equal(keys, RESULT_KEYS, "%s exposes exactly the common result fields" % context)
	support.expect(result["ok"] is bool, "%s ok is bool" % context)
	support.expect(result["status"] is StringName, "%s status is StringName" % context)
	support.expect(result["roi"] is Rect2i, "%s roi is Rect2i" % context)
	support.expect(result["mask"] is PackedByteArray, "%s mask is PackedByteArray" % context)
	support.expect(result["polygon"] is PackedVector2Array, "%s polygon is PackedVector2Array" % context)
	support.expect(result["message"] is String, "%s message is String" % context)
