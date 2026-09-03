extends RefCounted


const VALIDATOR_PATH := "res://client/domain/annotation_validator.gd"


static func run(support: TestSupport) -> void:
	_characterize_json_numbers(support)
	var validator_script := ResourceLoader.load(VALIDATOR_PATH)
	support.expect(validator_script != null, "AnnotationValidator script should exist")
	if validator_script == null:
		return
	var validator = validator_script.new()
	_test_annotation_fixtures(validator, support)
	_test_top_level_contract(validator, support)
	_test_region_contract(validator, support)
	_test_geometry_bounds_and_duplicates(validator, support)
	_test_malformed_variants_do_not_crash(validator, support)


static func _characterize_json_numbers(support: TestSupport) -> void:
	var parsed: Variant = JSON.parse_string('{"integer":1,"decimal":1.0,"items":[2,2.5]}')
	support.expect(parsed is Dictionary, "Godot JSON number characterization should parse an object")
	if not parsed is Dictionary:
		return
	support.expect(typeof(parsed["integer"]) == TYPE_FLOAT, "Godot JSON whole numbers are represented as floats")
	support.expect(typeof(parsed["decimal"]) == TYPE_FLOAT, "Godot JSON decimal numbers should parse as floats")
	support.expect(typeof(parsed["items"][0]) == TYPE_FLOAT, "Godot JSON array whole numbers are represented as floats")
	print("INFO: Godot JSON numeric types integer=%s decimal=%s" % [type_string(typeof(parsed["integer"])), type_string(typeof(parsed["decimal"]))])


static func _test_annotation_fixtures(validator, support: TestSupport) -> void:
	var valid_dir := DirAccess.open("res://core/fixtures/valid")
	support.expect(valid_dir != null, "valid fixture directory should open")
	if valid_dir != null:
		for filename in valid_dir.get_files():
			if filename.begins_with("annotation-") and filename.ends_with(".json"):
				var record: Variant = _read_json("res://core/fixtures/valid/%s" % filename)
				support.expect(validator.validate_record(record).is_empty(), "valid annotation fixture rejected: %s" % filename)
	var invalid_dir := DirAccess.open("res://core/fixtures/invalid")
	support.expect(invalid_dir != null, "invalid fixture directory should open")
	if invalid_dir != null:
		for filename in invalid_dir.get_files():
			if filename.begins_with("annotation-") and filename.ends_with(".json"):
				var record: Variant = _read_json("res://core/fixtures/invalid/%s" % filename)
				support.expect(not validator.validate_record(record).is_empty(), "invalid annotation fixture accepted: %s" % filename)


static func _test_top_level_contract(validator, support: TestSupport) -> void:
	var required_fields := ["schema_version", "dataset_id", "source", "frame", "image_size", "regions"]
	for field in required_fields:
		var missing := _valid_box()
		missing.erase(field)
		_expect_error_path(validator.validate_record(missing), field, support, "missing top-level field should be rejected")

	var unknown := _valid_box()
	unknown["unexpected"] = true
	_expect_error_path(validator.validate_record(unknown), "unexpected", support, "unknown top-level field should be rejected")

	var invalid_values := [
		["schema_version", 1.5],
		["schema_version", true],
		["schema_version", 2],
		["dataset_id", ""],
		["dataset_id", 12],
		["source", "model_output_v0"],
		["source", "model_output_v01"],
		["source", "model_output_v1\n"],
		["source", "human_corrected\n"],
		["source", 1],
		["frame", -1],
		["frame", 0.5],
		["frame", true],
		["time_s", -0.01],
		["time_s", NAN],
		["time_s", INF],
		["time_s", true],
		["time_s", null],
		["image_size", null],
		["image_size", [640]],
		["image_size", [640, 360, 1]],
		["image_size", [640.5, 360]],
		["image_size", [640, 0]],
		["image_size", [true, 360]],
		["regions", {}],
	]
	for item in invalid_values:
		var record := _valid_box()
		record[item[0]] = item[1]
		_expect_error_path(validator.validate_record(record), item[0], support, "invalid top-level value should be rejected: %s" % item[0])

	for source in ["model_output_v1", "model_output_v10", "model_output_v999", "human_corrected"]:
		var valid_source := _valid_box()
		valid_source["source"] = source
		support.expect(validator.validate_record(valid_source).is_empty(), "valid source rejected: %s" % source)


static func _test_region_contract(validator, support: TestSupport) -> void:
	var not_a_region := _valid_box()
	not_a_region["regions"] = ["bad"]
	_expect_error_path(validator.validate_record(not_a_region), "regions.0", support, "non-object region should be rejected")

	for field in ["id", "class", "kind"]:
		var missing := _valid_box()
		missing["regions"][0].erase(field)
		_expect_error_path(validator.validate_record(missing), "regions.0.%s" % field, support, "missing region field should be rejected")
		var empty := _valid_box()
		empty["regions"][0][field] = ""
		_expect_error_path(validator.validate_record(empty), "regions.0.%s" % field, support, "empty region field should be rejected")
		var wrong_type := _valid_box()
		wrong_type["regions"][0][field] = 7
		_expect_error_path(validator.validate_record(wrong_type), "regions.0.%s" % field, support, "non-string region field should be rejected")

	var unknown := _valid_box()
	unknown["regions"][0]["unexpected"] = true
	_expect_error_path(validator.validate_record(unknown), "regions.0.unexpected", support, "unknown region field should be rejected")

	var neither := _valid_box()
	neither["regions"][0].erase("box")
	_expect_error_path(validator.validate_record(neither), "regions.0", support, "region without geometry should be rejected")
	var both := _valid_box()
	both["regions"][0]["polygon"] = [[0, 0], [1, 0], [0, 1]]
	_expect_error_path(validator.validate_record(both), "regions.0", support, "region with both geometries should be rejected")

	var optional_invalid_values := [
		["conf", -0.01], ["conf", 1.01], ["conf", NAN], ["conf", INF], ["conf", true],
		["track_id", 4], ["filled", 1],
	]
	for item in optional_invalid_values:
		var record := _valid_box()
		record["regions"][0][item[0]] = item[1]
		_expect_error_path(validator.validate_record(record), "regions.0.%s" % item[0], support, "invalid optional region value should be rejected")
	for track_id in [null, "", "track-1"]:
		var valid_track := _valid_box()
		valid_track["regions"][0]["track_id"] = track_id
		support.expect(validator.validate_record(valid_track).is_empty(), "valid track_id rejected")
	for conf in [0, 0.0, 1, 1.0]:
		var valid_conf := _valid_box()
		valid_conf["regions"][0]["conf"] = conf
		support.expect(validator.validate_record(valid_conf).is_empty(), "inclusive confidence boundary rejected: %s" % str(conf))


static func _test_geometry_bounds_and_duplicates(validator, support: TestSupport) -> void:
	var invalid_boxes := [
		[null, "null geometry"],
		[{}, "object geometry"],
		[PackedFloat32Array([0, 0, 10, 10]), "packed array geometry"],
		[[0, 0, 10], "shape"],
		[[0, 0, 10, 10, 1], "shape"],
		[[0, 0, 0, 10], "positive width"],
		[[0, 0, 10, -1], "positive height"],
		[[-1, 0, 10, 10], "non-negative x"],
		[[0, -1, 10, 10], "non-negative y"],
		[[631, 0, 10, 10], "right bound"],
		[[0, 351, 10, 10], "bottom bound"],
		[[0, 0, NAN, 10], "finite number"],
		[[0, 0, INF, 10], "finite number"],
		[[0, 0, true, 10], "numeric value"],
	]
	for item in invalid_boxes:
		var record := _valid_box()
		record["regions"][0]["box"] = item[0]
		_expect_error_path(validator.validate_record(record), "regions.0.box", support, "invalid box accepted: %s" % item[1])
	var edge_box := _valid_box()
	edge_box["regions"][0]["box"] = [600, 330, 40, 30]
	support.expect(validator.validate_record(edge_box).is_empty(), "box ending exactly on image bounds should be valid")

	var invalid_polygons := [
		[null, "null geometry"],
		[{}, "object geometry"],
		[PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN]), "packed array geometry"],
		[[[0, 0], [1, 1]], "cardinality"],
		[[[0, 0], [1, 0], [0]], "vertex shape"],
		[[[0, 0], [1, 0], [0, 1, 2]], "vertex shape"],
		[[[0, 0], [1, 0], [NAN, 1]], "finite vertex"],
		[[[0, 0], [1, 0], [640, 1]], "exclusive width bound"],
		[[[0, 0], [1, 0], [1, 360]], "exclusive height bound"],
		[[[0, 0], [1, 0], [-0.1, 1]], "non-negative vertex"],
	]
	for item in invalid_polygons:
		var record := _valid_polygon()
		record["regions"][0]["polygon"] = item[0]
		var errors: PackedStringArray = validator.validate_record(record)
		support.expect(not errors.is_empty(), "invalid polygon accepted: %s" % item[1])
		support.expect(_contains_path_prefix(errors, "regions.0.polygon"), "polygon error should include regions.0.polygon path: %s" % item[1])
	var edge_polygon := _valid_polygon()
	edge_polygon["regions"][0]["polygon"] = [[639.999, 359.999], [1, 0], [0, 1]]
	support.expect(validator.validate_record(edge_polygon).is_empty(), "polygon vertices just inside bounds should be valid")

	var duplicate := _valid_box()
	duplicate["image_size"] = [640]
	duplicate["regions"].append(duplicate["regions"][0].duplicate(true))
	var duplicate_errors: PackedStringArray = validator.validate_record(duplicate)
	_expect_error_path(duplicate_errors, "image_size", support, "malformed image size should be rejected")
	_expect_error_path(duplicate_errors, "regions.1.id", support, "duplicate IDs should still be detected with malformed image size")


static func _test_malformed_variants_do_not_crash(validator, support: TestSupport) -> void:
	for malformed in [null, true, 1, 1.0, "record", [], PackedInt32Array([1, 2])]:
		var errors: PackedStringArray = validator.validate_record(malformed)
		support.expect(not errors.is_empty(), "malformed top-level Variant should return errors: %s" % type_string(typeof(malformed)))
		support.expect(_contains_path_prefix(errors, "$"), "malformed top-level error should identify root path")
	var malformed_nested := _valid_box()
	malformed_nested["image_size"] = PackedInt32Array([640, 360])
	malformed_nested["regions"] = [PackedStringArray(["bad"])]
	var nested_errors: PackedStringArray = validator.validate_record(malformed_nested)
	_expect_error_path(nested_errors, "image_size", support, "packed image size should be rejected without crashing")
	_expect_error_path(nested_errors, "regions.0", support, "packed region should be rejected without crashing")


static func _expect_error_path(errors: PackedStringArray, path: String, support: TestSupport, message: String) -> void:
	support.expect(_contains_path_prefix(errors, path), "%s; expected path %s in %s" % [message, path, str(errors)])


static func _contains_path_prefix(errors: PackedStringArray, path: String) -> bool:
	for error in errors:
		if error.begins_with("%s:" % path) or error.begins_with("%s." % path):
			return true
	return false


static func _read_json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func _valid_box() -> Dictionary:
	return _read_json("res://core/fixtures/valid/annotation-box.json")


static func _valid_polygon() -> Dictionary:
	return _read_json("res://core/fixtures/valid/annotation-polygon.json")
