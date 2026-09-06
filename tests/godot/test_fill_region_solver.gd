extends "res://tests/godot/test_keyboard_reachability.gd"


func _run_tests() -> void:
	var path := "res://client/domain/fill_region_solver.gd"
	if not FileAccess.file_exists(path):
		push_error("FAIL: FillRegionSolver does not exist")
		quit(1)
		return
	var solver = load(path)
	var outline := _outline_state(Rect2i(10, 10, 25, 25), 3, 21, [12])
	var original := outline.duplicate(true)
	var strict: Dictionary = solver.solve(outline, Vector2(20, 20), Vector2i(60, 60), 0, false)
	_expect_equal(strict.get("status"), &"open", "strict Fill must refuse a one-pixel gap")
	var repaired: Dictionary = solver.solve(outline, Vector2(20, 20), Vector2i(60, 60), 1, false)
	_expect_equal(repaired.get("status"), &"single", "radius one must close a one-pixel gap")
	_expect(repaired.get("requires_confirmation", false), "a repaired fill requires confirmation")
	_expect(not repaired.get("repair_mask", {}).is_empty(), "repair pixels must be available for preview")
	_expect_equal(outline, original, "solver must not mutate its input")
	var outside: Dictionary = solver.solve(outline, Vector2(12, 12), Vector2i(60, 60), 1, false)
	_expect_equal(outside.get("status"), &"open", "an exterior seed must remain open after closing")
	var border := _outline_state(Rect2i(0, 0, 25, 25), 0, 21, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21])
	var edge: Dictionary = solver.solve(border, Vector2(10, 10), Vector2i(60, 60), 1, false)
	_expect_equal(edge.get("status"), &"open", "real image edge is not an implicit boundary")
	var tight := _outline_state(Rect2i(10, 10, 22, 22), 0, 21, [])
	var expanded: Dictionary = solver.solve(tight, Vector2(20, 20), Vector2i(60, 60), 0, true)
	_expect_equal(expanded.get("status"), &"single", "tight ROI must be safely padded before fill")
	var huge := {"roi": Rect2i(0, 0, 1048577, 1), "mask": PackedByteArray()}
	var refused: Dictionary = solver.solve(huge, Vector2.ZERO, Vector2i(2000000, 2), 1, false)
	_expect(not refused.get("ok", true), "over-budget input must be refused")
	var occupied: Dictionary = solver.solve(outline, Vector2(13, 13), Vector2i(60, 60), 1, false)
	_expect_equal(occupied.get("status"), &"invalid", "barrier seeds must be refused")
	var two := {"roi": Rect2i(10, 10, 65, 25), "mask": PackedByteArray()}
	two.mask.resize(65 * 25)
	for y in range(25):
		for x in range(25):
			two.mask[y * 65 + x] = outline.mask[y * 25 + x]
			two.mask[y * 65 + x + 32] = outline.mask[y * 25 + x]
	var local: Dictionary = solver.solve(two, Vector2(20, 20), Vector2i(100, 60), 1, false)
	_expect_equal(local.get("status"), &"single", "one of two independent open outlines can be repaired")
	if local.get("requires_confirmation", false):
		var repair: Dictionary = local.repair_mask
		for y in range(repair.roi.position.y, repair.roi.end.y):
			for x in range(42, repair.roi.end.x):
				_expect_equal(repair.mask[(y - repair.roi.position.y) * repair.roi.size.x + x - repair.roi.position.x], 0,
					"repair must leave the unrelated second outline open")
	var limit := {"roi": Rect2i(10, 10, 1024, 1024), "mask": PackedByteArray()}
	limit.mask.resize(1024 * 1024)
	var padding_refusal: Dictionary = solver.solve(limit, Vector2(20, 20), Vector2i(2000, 1200), 1, false)
	_expect_equal(padding_refusal.get("status"), &"roi_too_large", "safety padding must count toward the ROI budget")
	if _failures.is_empty():
		print("PASS: bounded Fill solver")
		quit(0)
	else:
		push_error("FAIL: bounded Fill solver\n%s" % "\n".join(_failures))
		quit(1)
