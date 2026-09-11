extends SceneTree

const CANDIDATE := preload("res://client/domain/model_assist_candidate.gd")
const SUPPORT := preload("res://tests/godot/test_support.gd")
const TEMP_PREFIX := "/tmp/model-assist-candidate-"


func _initialize() -> void:
	var support = SUPPORT.new()
	run_suite(support)
	if support.failures.is_empty():
		print("PASS model assist candidate safety")
		quit(0)
	else:
		printerr(support.failure_report())
		quit(1)


static func run_suite(support) -> void:
	_test_valid_concave_candidate_is_defensive(support)
	_test_empty_full_nonbinary_roi_and_hash_refusals(support)
	_test_path_and_symlink_refusals(support)
	_test_hole_component_and_complexity_refusals(support)


static func _test_valid_concave_candidate_is_defensive(support) -> void:
	var job := _job("valid")
	var image := _mask(20, 18)
	for y in range(2, 15):
		for x in range(2, 7):
			image.set_pixel(x, y, Color.WHITE)
	for y in range(10, 15):
		for x in range(7, 17):
			image.set_pixel(x, y, Color.WHITE)
	var descriptor := _save(job, "candidate.png", image, Rect2i(10, 12, 20, 18))
	var original_bytes := FileAccess.get_file_as_bytes(job.path_join("candidate.png"))
	var result: Dictionary = CANDIDATE.validate_file(job, descriptor, Vector2i(80, 60))
	support.expect(result.get("ok", false), "valid concave binary ROI becomes a safe candidate: " + str(result.get("reason", "")))
	support.expect(result.get("polygon") is PackedVector2Array and result.get("polygon", PackedVector2Array()).size() >= 6, "valid concave candidate returns typed image-space Poly")
	support.expect(result.get("mask") is Dictionary and result.mask.roi == Rect2i(10, 12, 20, 18), "candidate retains a bounded defensive mask state")
	result.mask.mask[0] = 7
	support.expect_equal(FileAccess.get_file_as_bytes(job.path_join("candidate.png")), original_bytes, "candidate validation never mutates source mask bytes")
	_remove(job)


static func _test_empty_full_nonbinary_roi_and_hash_refusals(support) -> void:
	var job := _job("basic-refusal")
	var empty := _mask(8, 6)
	var empty_descriptor := _save(job, "empty.png", empty, Rect2i(2, 3, 8, 6))
	_refused(support, CANDIDATE.validate_file(job, empty_descriptor, Vector2i(20, 15)), "empty")
	var full := _mask(20, 15)
	full.fill(Color.WHITE)
	var full_descriptor := _save(job, "full.png", full, Rect2i(0, 0, 20, 15))
	_refused(support, CANDIDATE.validate_file(job, full_descriptor, Vector2i(20, 15)), "full-image")
	var nonbinary := _mask(8, 6)
	nonbinary.set_pixel(2, 2, Color(0.5, 0.5, 0.5, 1.0))
	var nonbinary_descriptor := _save(job, "nonbinary.png", nonbinary, Rect2i(2, 3, 8, 6))
	_refused(support, CANDIDATE.validate_file(job, nonbinary_descriptor, Vector2i(20, 15)), "nonbinary")
	var valid := _mask(4, 4)
	for y in range(1, 3):
		for x in range(1, 3):
			valid.set_pixel(x, y, Color.WHITE)
	var overflow := _save(job, "overflow.png", valid, Rect2i(18, 13, 4, 4))
	_refused(support, CANDIDATE.validate_file(job, overflow, Vector2i(20, 15)), "ROI overflow")
	var wrong_hash := overflow.duplicate(true)
	wrong_hash.roi = [2, 3, 4, 4]
	wrong_hash.sha256 = "0".repeat(64)
	_refused(support, CANDIDATE.validate_file(job, wrong_hash, Vector2i(20, 15)), "hash mismatch")
	_remove(job)


static func _test_path_and_symlink_refusals(support) -> void:
	var job := _job("paths")
	var image := _mask(6, 6)
	for y in range(1, 5):
		for x in range(1, 5):
			image.set_pixel(x, y, Color.WHITE)
	var descriptor := _save(job, "candidate.png", image, Rect2i(2, 2, 6, 6))
	for path_value: String in ["../candidate.png", "/tmp/candidate.png", "candidate.jpg", "./candidate.png"]:
		var bad := descriptor.duplicate(true)
		bad.path = path_value
		_refused(support, CANDIDATE.validate_file(job, bad, Vector2i(20, 20)), "unsafe path")
	var directory := DirAccess.open(job)
	var linked := directory.create_link(job.path_join("candidate.png"), job.path_join("linked.png"))
	support.expect_equal(linked, OK, "symlink refusal fixture is created")
	if linked == OK:
		var symlink_descriptor := descriptor.duplicate(true)
		symlink_descriptor.path = "linked.png"
		_refused(support, CANDIDATE.validate_file(job, symlink_descriptor, Vector2i(20, 20)), "symlink")
	_remove(job)


static func _test_hole_component_and_complexity_refusals(support) -> void:
	var job := _job("topology")
	var multiple := _mask(12, 8)
	for point: Vector2i in [Vector2i(2, 2), Vector2i(9, 5)]:
		multiple.set_pixelv(point, Color.WHITE)
	_refused(support, CANDIDATE.validate_file(job, _save(job, "multiple.png", multiple, Rect2i(2, 2, 12, 8)), Vector2i(30, 20)), "multiple components")
	var hole := _mask(12, 12)
	for y in range(1, 11):
		for x in range(1, 11):
			if x < 4 or x > 7 or y < 4 or y > 7:
				hole.set_pixel(x, y, Color.WHITE)
	_refused(support, CANDIDATE.validate_file(job, _save(job, "hole.png", hole, Rect2i(2, 2, 12, 12)), Vector2i(30, 30)), "hole")
	var complex := _mask(513, 32)
	for y in range(32):
		if y % 2 == 0:
			for x in range(513):
				complex.set_pixel(x, y, Color.WHITE)
		else:
			complex.set_pixel(512 if int(y / 2) % 2 == 0 else 0, y, Color.WHITE)
	var complex_result := CANDIDATE.validate_file(job, _save(job, "complex.png", complex, Rect2i(0, 0, 513, 32)), Vector2i(600, 40))
	_refused(support, complex_result, "over-complex/self-touching boundary")
	var complex_reason := str(complex_result.get("reason", "")).to_lower()
	support.expect("complex" in complex_reason or "simpl" in complex_reason or "too detailed" in complex_reason,
		"complex boundary refusal identifies V1 contour safety: " + complex_reason)
	_remove(job)


static func _job(label: String) -> String:
	var path := "%s%s-%d-%d" % [TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(path)
	return path


static func _mask(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_L8)
	image.fill(Color.BLACK)
	return image


static func _save(job: String, name: String, image: Image, roi: Rect2i) -> Dictionary:
	var path := job.path_join(name)
	image.save_png(path)
	return {"path": name, "roi": [roi.position.x, roi.position.y, roi.size.x, roi.size.y], "sha256": FileAccess.get_sha256(path), "score": 0.875}


static func _refused(support, result: Dictionary, label: String) -> void:
	support.expect(not result.get("ok", false), "%s candidate must be refused" % label)
	support.expect(not str(result.get("reason", "")).is_empty(), "%s refusal must explain the boundary" % label)


static func _remove(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path) or not path.begins_with(TEMP_PREFIX):
		return
	var directory := DirAccess.open(path)
	for name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name: String in directory.get_directories():
		var child := path.path_join(name)
		var nested := DirAccess.open(child)
		for leaf: String in nested.get_files():
			DirAccess.remove_absolute(child.path_join(leaf))
		DirAccess.remove_absolute(child)
	DirAccess.remove_absolute(path)
