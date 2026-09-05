extends RefCounted

const TRANSFORM_SCRIPT = preload("res://client/services/viewport_transform.gd")


static func run(support) -> void:
	_test_letterbox_and_round_trip(support)
	_test_portrait_image_letterbox(support)
	_test_transform_matrix_and_image_bounds(support)
	_test_zoom_anchor_and_limits(support)
	_test_pan_updates_forward_and_inverse_mapping(support)
	_test_same_image_resize_preserves_view_center(support)
	_test_reset_to_fit(support)
	_test_invalid_dimensions_are_safe(support)


static func _test_letterbox_and_round_trip(support) -> void:
	var transform = TRANSFORM_SCRIPT.new()
	support.expect(transform.configure(Vector2(640, 360), Rect2(25, 40, 1000, 800)), "positive image and viewport sizes should configure")
	support.expect(absf(transform.fit_scale - 1.5625) < 0.000001, "fit scale should preserve aspect ratio")
	support.expect(transform.letterbox_offset.distance_to(Vector2(0, 118.75)) < 0.000001, "wide image should be vertically letterboxed")
	var image_point := Vector2(320, 180)
	var viewport_point: Vector2 = transform.image_to_viewport(image_point)
	support.expect(viewport_point.distance_to(Vector2(525, 440)) < 0.000001, "image center should map to viewport center including its origin")
	var round_trip: Vector2 = transform.viewport_to_image(viewport_point)
	support.expect(round_trip.distance_to(image_point) < 0.000001, "forward and inverse mappings should round-trip exactly")


static func _test_portrait_image_letterbox(support) -> void:
	var transform = TRANSFORM_SCRIPT.new()
	support.expect(transform.configure(Vector2(100, 200), Rect2(15, 25, 800, 400)), "portrait image should configure in a wide viewport")
	support.expect(absf(transform.fit_scale - 2.0) < 0.000001, "portrait image should fit by viewport height")
	support.expect(transform.letterbox_offset.distance_to(Vector2(300, 0)) < 0.00001, "portrait image should receive horizontal letterboxing")
	var image_center := Vector2(50, 100)
	support.expect(transform.image_to_viewport(image_center).distance_to(Vector2(415, 225)) < 0.00001, "portrait image center should include the non-zero viewport origin")
	support.expect(transform.viewport_to_image(transform.image_to_viewport(image_center)).distance_to(image_center) < 0.00001, "portrait image mapping should round-trip within the numeric contract")


static func _test_transform_matrix_and_image_bounds(support) -> void:
	var transform = TRANSFORM_SCRIPT.new()
	transform.configure(Vector2(320, 240), Rect2(10, 20, 640, 640))
	support.expect(not transform.contains_viewport_point(Vector2(15, 25)), "letterbox space should not be treated as image content")
	transform.zoom_at(Vector2(330, 340), 1.75)
	transform.pan_by(Vector2(23, -17))
	var image_point := Vector2(91.25, 73.5)
	var image_to_viewport: Transform2D = transform.get_image_to_viewport_transform()
	var viewport_to_image: Transform2D = transform.get_viewport_to_image_transform()
	var viewport_point: Vector2 = image_to_viewport * image_point
	support.expect(viewport_point.distance_to(transform.image_to_viewport(image_point)) < 0.00001, "the public forward matrix should be the sole image-to-viewport mapping")
	support.expect((viewport_to_image * viewport_point).distance_to(image_point) < 0.00001, "the public inverse matrix should invert scaled and translated viewport coordinates")
	support.expect(transform.contains_viewport_point(viewport_point), "a transformed image point should be inside the displayed image")
	support.expect(transform.contains_viewport_point(transform.image_to_viewport(transform.image_size)), "the displayed bottom-right image boundary should count as image content")


static func _test_zoom_anchor_and_limits(support) -> void:
	var transform = TRANSFORM_SCRIPT.new()
	transform.configure(Vector2(640, 360), Rect2(0, 0, 1000, 800))
	var cursor := Vector2(173.25, 287.5)
	var anchored_image_point: Vector2 = transform.viewport_to_image(cursor)
	transform.zoom_at(cursor, 2.25)
	support.expect(transform.image_to_viewport(anchored_image_point).distance_to(cursor) < 0.00001, "zoom should keep the image point beneath the cursor fixed")
	transform.zoom_at(cursor, 1000.0)
	support.expect(absf(transform.user_zoom - 20.0) < 0.000001, "zoom should clamp to the maximum")
	var maximum_anchor_error: float = transform.image_to_viewport(anchored_image_point).distance_to(cursor)
	var maximum_anchor_image_error: float = maximum_anchor_error / (transform.fit_scale * transform.user_zoom)
	support.expect(maximum_anchor_image_error < 0.00001, "clamped maximum zoom should preserve the cursor anchor within the image-coordinate contract (error=%s image pixels)" % maximum_anchor_image_error)
	transform.zoom_at(cursor, 0.000001)
	support.expect(absf(transform.user_zoom - 0.1) < 0.000001, "zoom should clamp to the minimum")
	support.expect(transform.image_to_viewport(anchored_image_point).distance_to(cursor) < 0.00001, "clamped minimum zoom should preserve the cursor anchor")


static func _test_pan_updates_forward_and_inverse_mapping(support) -> void:
	var transform = TRANSFORM_SCRIPT.new()
	transform.configure(Vector2(320, 240), Rect2(10, 20, 640, 480))
	transform.zoom_at(Vector2(330, 260), 1.5)
	var image_point := Vector2(90, 70)
	var before: Vector2 = transform.image_to_viewport(image_point)
	var delta := Vector2(47.5, -23.25)
	transform.pan_by(delta)
	var after: Vector2 = transform.image_to_viewport(image_point)
	support.expect(after.distance_to(before + delta) < 0.000001, "pan should translate image drawing by the requested viewport delta")
	support.expect(transform.viewport_to_image(after).distance_to(image_point) < 0.000001, "inverse mapping should include pan")


static func _test_same_image_resize_preserves_view_center(support) -> void:
	var transform = TRANSFORM_SCRIPT.new()
	transform.configure(Vector2(640, 360), Rect2(0, 0, 1000, 800))
	transform.zoom_at(transform.image_to_viewport(Vector2.ZERO), 2.5)
	transform.pan_by(Vector2(37, -19))
	var preserved_image_center: Vector2 = transform.viewport_to_image(transform.viewport_rect.get_center())
	transform.configure(Vector2(640, 360), Rect2(25, 40, 800, 600))
	support.expect(absf(transform.user_zoom - 2.5) < 0.000001, "same-image viewport resize should preserve user zoom")
	support.expect(absf(transform.fit_scale - 1.25) < 0.000001, "same-image viewport resize should recompute fit scale")
	support.expect_equal(transform.letterbox_offset, Vector2(0, 75), "same-image viewport resize should recompute letterboxing")
	support.expect(transform.image_to_viewport(preserved_image_center).distance_to(transform.viewport_rect.get_center()) < 0.00001, "same-image viewport resize should preserve the image point at the view center")
	var image_point := Vector2(123, 87)
	support.expect(transform.viewport_to_image(transform.image_to_viewport(image_point)).distance_to(image_point) < 0.00001, "resized preserved view should keep exact inverse mapping")

	transform.configure(Vector2(320, 240), Rect2(25, 40, 800, 600))
	support.expect_equal(transform.user_zoom, 1.0, "new image dimensions should reset user zoom")
	support.expect_equal(transform.pan, Vector2.ZERO, "new image dimensions should reset pan")


static func _test_reset_to_fit(support) -> void:
	var transform = TRANSFORM_SCRIPT.new()
	support.expect(not transform.reset_to_fit(), "an unconfigured transform should refuse reset-to-fit")
	transform.configure(Vector2(640, 360), Rect2(20, 30, 1000, 800))
	transform.zoom_at(Vector2(300, 250), 3.0)
	transform.pan_by(Vector2(71, -46))
	support.expect(transform.reset_to_fit(), "a changed camera should reset to fit")
	support.expect_equal(transform.user_zoom, 1.0, "reset-to-fit should restore unit user zoom")
	support.expect_equal(transform.pan, Vector2.ZERO, "reset-to-fit should remove user pan")
	support.expect(not transform.reset_to_fit(), "an already fitted camera should not report another change")


static func _test_invalid_dimensions_are_safe(support) -> void:
	var transform = TRANSFORM_SCRIPT.new()
	support.expect(not transform.configure(Vector2.ZERO, Rect2(0, 0, 640, 480)), "zero image size should be rejected")
	support.expect(not transform.is_configured(), "zero image size should leave the transform unconfigured")
	support.expect_equal(transform.image_to_viewport(Vector2(4, 5)), Vector2.ZERO, "unconfigured forward mapping should return a safe sentinel")
	support.expect_equal(transform.viewport_to_image(Vector2(4, 5)), Vector2.ZERO, "unconfigured inverse mapping should return a safe sentinel")
	transform.zoom_at(Vector2(10, 10), 2.0)
	transform.pan_by(Vector2(5, 5))
	support.expect_equal(transform.user_zoom, 1.0, "unconfigured zoom should be ignored")
	support.expect_equal(transform.pan, Vector2.ZERO, "unconfigured pan should be ignored")
	support.expect(not transform.configure(Vector2(10, 10), Rect2(0, 0, -1, 20)), "negative viewport size should be rejected")
	support.expect(not transform.configure(Vector2(NAN, 10), Rect2(0, 0, 20, 20)), "non-finite dimensions should be rejected")
