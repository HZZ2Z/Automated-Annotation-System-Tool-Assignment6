extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const MASK_OPS := preload("res://client/domain/mask_region_ops.gd")
const BUFFER_PATH := "res://client/domain/brush_stroke_buffer.gd"


func _initialize() -> void:
	var support := SUPPORT.new()
	var started := Time.get_ticks_usec()
	run(support)
	if support.failures.is_empty():
		print("PASS brush_stroke_buffer (%.3f ms)" % ((Time.get_ticks_usec() - started) / 1000.0))
		if "--benchmark" in OS.get_cmdline_user_args():
			_benchmark()
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)


static func run(support) -> void:
	support.expect(ResourceLoader.exists(BUFFER_PATH), "incremental BrushStrokeBuffer must exist")
	if not ResourceLoader.exists(BUFFER_PATH):
		return
	var buffer_script = load(BUFFER_PATH)
	support.expect(buffer_script != null and buffer_script.can_instantiate(), "brush script must compile")
	if buffer_script == null or not buffer_script.can_instantiate():
		return
	_test_literal_circle(buffer_script, support)
	_test_reference_paths(buffer_script, support)
	_test_snapshot_ownership(buffer_script, support)
	_test_validation_and_budget(buffer_script, support)
	_test_large_finite_values(buffer_script, support)


static func _test_literal_circle(buffer_script, support) -> void:
	var buffer = buffer_script.new()
	support.expect(buffer.begin(1.0, Vector2i(8, 8)).is_empty(), "positive circle starts")
	support.expect(buffer.append_point(Vector2(2.5, 2.5)).is_empty(), "single point paints a circle")
	var state: Dictionary = buffer.snapshot()
	var expected := [Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3)]
	for y in range(8):
		for x in range(8):
			support.expect_equal(_at(state, x, y), int(Vector2i(x, y) in expected), "radius one literal pixel (%d,%d)" % [x, y])


static func _test_reference_paths(buffer_script, support) -> void:
	var size := Vector2i(48, 32)
	var paths := [
		PackedVector2Array([Vector2(3.5, 5.5), Vector2(19.5, 5.5), Vector2(19.5, 5.5)]),
		PackedVector2Array([Vector2(2, 2), Vector2(27, 19), Vector2(4, 24), Vector2(2, 2)]),
		PackedVector2Array([Vector2(-12, -8), Vector2(-6, 10), Vector2(22, 10), Vector2(60, 42)]),
		PackedVector2Array([Vector2(70, -20), Vector2(70, 50), Vector2(-20, 50)]),
		PackedVector2Array([Vector2(24, 16), Vector2(12, 8), Vector2(36, 24), Vector2(6, 4), Vector2(44, 28)]),
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 628451
	var random_path := PackedVector2Array()
	for index in range(24):
		random_path.append(Vector2(rng.randf_range(-10, 58), rng.randf_range(-10, 42)))
	paths.append(random_path)
	for radius in [0.25, 1.0, 2.75]:
		for path: PackedVector2Array in paths:
			var buffer = buffer_script.new()
			buffer.begin(radius, size)
			var prefix := PackedVector2Array()
			for point in path:
				prefix.append(point)
				support.expect(buffer.append_point(point).is_empty(), "finite clipped segments append")
				var actual: Dictionary = buffer.snapshot()
				var reference := _slow_full_image(prefix, radius, size)
				var same_pixels := true
				for y in range(size.y):
					for x in range(size.x):
						if _at(actual, x, y) != reference[y * size.x + x]:
							same_pixels = false
							break
					if not same_pixels:
						break
				support.expect(same_pixels, "every prefix matches independent full-image reference (radius %s, prefix %s)" % [radius, prefix.size()])
				var legacy: Dictionary = MASK_OPS.rasterize_stroke_mask(prefix, radius, size)
				if legacy["ok"]:
					support.expect_equal(actual["roi"], legacy["roi"], "logical bounds preserve legacy padding")
					support.expect(actual["mask"] == legacy["mask"], "all legacy raster bytes match")


static func _test_snapshot_ownership(buffer_script, support) -> void:
	var buffer = buffer_script.new()
	buffer.begin(1.0, Vector2i(128, 128))
	buffer.append_point(Vector2(60.5, 60.5))
	var earlier: Dictionary = buffer.snapshot()
	var frozen: Dictionary = earlier.duplicate(true)
	for point in [Vector2(3, 4), Vector2(110, 8), Vector2(9, 112), Vector2(120, 120)]:
		support.expect(buffer.append_point(point).is_empty(), "growth in every direction succeeds")
	support.expect_equal(earlier, frozen, "retained preview stays unchanged after later growth")
	var latest: Dictionary = buffer.snapshot()
	var expected: Dictionary = latest.duplicate(true)
	latest["mask"].fill(255)
	latest["roi"] = Rect2i()
	support.expect_equal(buffer.snapshot(), expected, "caller mutation cannot corrupt buffer")
	buffer.reset()
	support.expect_equal(buffer.snapshot(), {"roi": Rect2i(), "mask": PackedByteArray()}, "reset drops previous stroke")
	support.expect(not buffer.append_point(Vector2.ONE).is_empty(), "append after reset requires begin")
	buffer.begin(1.0, Vector2i(8, 8))
	support.expect_equal(buffer.snapshot()["mask"].size(), 0, "new gesture has no pixels")


static func _test_validation_and_budget(buffer_script, support) -> void:
	var buffer = buffer_script.new()
	support.expect(not buffer.append_point(Vector2.ONE).is_empty(), "append before begin refuses")
	for radius in [0.0, -1.0, NAN, INF]:
		support.expect(not buffer.begin(radius, Vector2i(100, 100)).is_empty(), "invalid radius refuses")
	for size in [Vector2i.ZERO, Vector2i(10, -1)]:
		support.expect(not buffer.begin(1.0, size).is_empty(), "nonpositive image refuses")
	buffer.begin(1.0, Vector2i(4096, 4096))
	buffer.append_point(Vector2(10, 10))
	var saved: Dictionary = buffer.snapshot()
	for point in [Vector2(INF, 5), Vector2(5, NAN), Vector2(3000, 3000)]:
		support.expect(not buffer.append_point(point).is_empty(), "invalid or excessive segment refuses")
		support.expect_equal(buffer.snapshot(), saved, "failed append preserves ROI and every byte")
	support.expect(buffer.append_point(Vector2(15, 10)).is_empty(), "valid append recovers after refusal")
	var legacy: Dictionary = MASK_OPS.rasterize_stroke_mask(PackedVector2Array([Vector2(10, 10), Vector2(15, 10)]), 1.0, Vector2i(4096, 4096))
	support.expect_equal(buffer.snapshot()["mask"], legacy["mask"], "refused point never becomes the next segment endpoint")
	buffer.begin(1.0, Vector2i(1024, 1024))
	buffer.append_point(Vector2(0, 0))
	support.expect(buffer.append_point(Vector2(1024, 1024)).is_empty(), "exact one-million-pixel cap is accepted despite spare growth")
	support.expect_equal(buffer.snapshot()["mask"].size(), 1048576, "snapshot includes exact permitted image area")
	buffer.begin(1.0, Vector2i(1025, 1024))
	buffer.append_point(Vector2(0, 0))
	var before: Dictionary = buffer.snapshot()
	support.expect(not buffer.append_point(Vector2(1025, 1024)).is_empty(), "one row over area budget refuses")
	support.expect_equal(buffer.snapshot(), before, "near-cap refusal remains atomic")


static func _test_large_finite_values(buffer_script, support) -> void:
	var buffer = buffer_script.new()
	buffer.begin(2.0e20, Vector2i(8, 8))
	support.expect(buffer.append_point(Vector2(1.0e20, 1.0e20)).is_empty(), "large finite radius and point remain safely clipped")
	var dot: Dictionary = buffer.snapshot()
	var full := PackedByteArray()
	full.resize(64)
	full.fill(1)
	support.expect_equal(dot["mask"], full, "finite distant dot with larger radius covers the complete small image")
	buffer.begin(1.0, Vector2i(8, 8))
	buffer.append_point(Vector2(-1.0e20, 2.5))
	support.expect(buffer.append_point(Vector2(1.0e20, 2.5)).is_empty(), "extreme finite segment crosses the image without overflow")
	var stroke: Dictionary = buffer.snapshot()
	for y in range(8):
		for x in range(8):
			support.expect_equal(_at(stroke, x, y), int(y >= 1 and y <= 3), "distant horizontal segment keeps its literal three-pixel width")


# 独立参考逐像素调用引擎最近点查询，不复用缓冲区的距离公式或包围盒。
static func _slow_full_image(points: PackedVector2Array, radius: float, size: Vector2i) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(size.x * size.y)
	for y in range(size.y):
		for x in range(size.x):
			var center := Vector2(x + 0.5, y + 0.5)
			var distance := center.distance_to(points[0])
			for index in range(1, points.size()):
				var closest := Geometry2D.get_closest_point_to_segment(center, points[index - 1], points[index])
				distance = minf(distance, center.distance_to(closest))
			mask[y * size.x + x] = int(distance <= radius)
	return mask


static func _at(state: Dictionary, x: int, y: int) -> int:
	var roi: Rect2i = state["roi"]
	if not roi.has_point(Vector2i(x, y)):
		return 0
	return state["mask"][(y - roi.position.y) * roi.size.x + x - roi.position.x]


static func _benchmark() -> void:
	var buffer_script = load(BUFFER_PATH)
	for count in [16, 64, 128]:
		var path := PackedVector2Array()
		for index in range(count):
			path.append(Vector2(160 + index * 3, 200 + sin(index * 0.15) * 30))
		var buffer = buffer_script.new()
		buffer.begin(5.0, Vector2i(1280, 800))
		var append_us := 0
		var preview_us := 0
		for point in path:
			var started := Time.get_ticks_usec()
			buffer.append_point(point)
			append_us += Time.get_ticks_usec() - started
			started = Time.get_ticks_usec()
			buffer.snapshot()
			preview_us += Time.get_ticks_usec() - started
		var started := Time.get_ticks_usec()
		MASK_OPS.rasterize_stroke_mask(path, 5.0, Vector2i(1280, 800))
		var legacy_us := Time.get_ticks_usec() - started
		print("BENCH points=%d append_total_ms=%.3f preview_snapshot_total_ms=%.3f legacy_final_raster_ms=%.3f" % [count, append_us / 1000.0, preview_us / 1000.0, legacy_us / 1000.0])
